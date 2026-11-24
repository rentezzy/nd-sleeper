import Core
import Dispatch
import Foundation
import IOKit.ps
import notify
import os
import XPC

public final class HelperService: @unchecked Sendable {
    private enum ArmedDeadline {
        case fromArming(Duration)
        case at(ContinuousClock.Instant)
    }

    private let queue = DispatchQueue(label: ServiceIdentifier.helper)
    private let logger = Logger(subsystem: ServiceIdentifier.helper, category: "helper")
    private var listener: xpc_connection_t?
    private var agent: xpc_connection_t?
    private var requestedDeadline = ArmedDeadline.fromArming(SafetyLimit.autoHelperDeadline)
    private var deadlineTimer: DispatchSourceTimer?
    private var deadlineEndsAt: ContinuousClock.Instant?
    private var powerToken = NOTIFY_TOKEN_INVALID
    private var terminationSource: DispatchSourceSignal?

    public init() {}

    public func run() -> Never {
        queue.async { self.start() }
        dispatchMain()
    }

    private func start() {
        logger.notice("helper \(BuildInfo.version, privacy: .public) started")
        if PowerManagement.isOnBattery() {
            clearFlag(reason: "started on battery")
        }
        handleTermination()
        watchPowerSource()
        listen()
    }

    private func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in
            self?.clearFlag(reason: "helper stopping", sleepIfLidClosed: false)
            exit(0)
        }
        source.resume()
        terminationSource = source
    }

    private func watchPowerSource() {
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &powerToken, queue) { [weak self] _ in
            self?.powerSourceChanged()
        }
        if status != NOTIFY_STATUS_OK {
            logger.fault("power source watch failed with status \(status)")
        }
    }

    private func listen() {
        let listener = xpc_connection_create_mach_service(
            ServiceIdentifier.helper,
            queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else {
                self?.listenerFailed()
                return
            }
            self?.accept(event)
        }
        xpc_connection_resume(listener)
        self.listener = listener
    }

    private func listenerFailed() {
        logger.fault("mach service listener failed, exiting")
        clearFlag(reason: "listener failed", sleepIfLidClosed: false)
        exit(1)
    }

    private func accept(_ peer: xpc_connection_t) {
        xpc_connection_set_target_queue(peer, queue)
        nonisolated(unsafe) let connection = peer
        xpc_connection_set_event_handler(peer) { [weak self] event in
            self?.received(event, from: connection)
        }
        xpc_connection_resume(peer)
    }

    private func received(_ event: xpc_object_t, from peer: xpc_connection_t) {
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
            disconnected(peer)
            return
        }

        let euid = xpc_connection_get_euid(peer)
        guard ConsoleUser.isAllowed(euid: euid) else {
            logger.error("rejected request from uid \(euid)")
            xpc_connection_cancel(peer)
            return
        }
        guard let request = decodeRequest(event) else {
            reply(to: event, on: peer, with: .failed(reason: "malformed request", status: status()))
            return
        }

        if euid != 0 {
            promoteToAgent(peer, euid: euid)
        }
        reply(to: event, on: peer, with: handle(request))
    }

    private func promoteToAgent(_ peer: xpc_connection_t, euid: uid_t) {
        guard peer !== agent else { return }

        let previous = agent
        agent = peer
        if let previous {
            xpc_connection_cancel(previous)
        }
        logger.notice("agent connected as uid \(euid)")
    }

    private func disconnected(_ peer: xpc_connection_t) {
        guard peer === agent else { return }

        agent = nil
        requestedDeadline = .fromArming(SafetyLimit.autoHelperDeadline)
        logger.notice("agent disconnected")
        if PowerManagement.isOnBattery() {
            clearFlag(reason: "agent disconnected on battery")
        }
    }

    private func handle(_ request: HelperRequest) -> HelperResponse {
        switch request {
        case let .setFlagOn(deadline):
            requestedDeadline = armed(deadline)
            guard PowerManagement.setSleepDisabled(true) else { return failed("could not set the sleep flag") }
            armDeadlineIfOnBattery()
            return .status(status())
        case .setFlagOff:
            resetDeadline()
            guard PowerManagement.setSleepDisabled(false) else { return failed("could not clear the sleep flag") }
            return .status(status())
        case .sleepNow:
            resetDeadline()
            guard PowerManagement.setSleepDisabled(false) else { return failed("could not clear the sleep flag") }
            guard PowerManagement.sleepSystem() else { return failed("sleep request was refused") }
            logger.notice("sleeping on agent request")
            return .status(status())
        case .readStatus:
            return .status(status())
        }
    }

    private func armed(_ deadline: HelperDeadline) -> ArmedDeadline {
        switch deadline {
        case .automatic, .untimedHold(remaining: nil):
            .fromArming(deadline.batteryLimit)
        case .timedHold, .untimedHold:
            .at(.now + deadline.batteryLimit)
        }
    }

    private func failed(_ reason: String) -> HelperResponse {
        logger.error("\(reason, privacy: .public)")
        return .failed(reason: reason, status: status())
    }

    private func status() -> HelperStatus {
        HelperStatus(
            version: BuildInfo.version,
            flagOn: PowerManagement.readSleepDisabled(),
            onBattery: PowerManagement.isOnBattery(),
            deadlineRemainingSeconds: deadlineEndsAt.map { max(0, ($0 - ContinuousClock.now).seconds) }
        )
    }

    private func powerSourceChanged() {
        guard PowerManagement.isOnBattery() else {
            cancelDeadlineTimer()
            return
        }
        guard agent != nil else {
            clearFlag(reason: "unplugged with no agent connected")
            return
        }
        armDeadlineIfOnBattery()
    }

    private func armDeadlineIfOnBattery() {
        cancelDeadlineTimer()
        guard PowerManagement.isOnBattery(), PowerManagement.readSleepDisabled() == true else { return }

        let endsAt = switch requestedDeadline {
        case let .fromArming(limit): ContinuousClock.now + limit
        case let .at(instant): instant
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, (endsAt - .now).seconds), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.deadlineExpired()
        }
        timer.resume()
        deadlineTimer = timer
        deadlineEndsAt = endsAt
    }

    private func cancelDeadlineTimer() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        deadlineEndsAt = nil
    }

    private func resetDeadline() {
        cancelDeadlineTimer()
        requestedDeadline = .fromArming(SafetyLimit.autoHelperDeadline)
    }

    private func deadlineExpired() {
        cancelDeadlineTimer()
        guard PowerManagement.isOnBattery() else { return }

        clearFlag(reason: "battery deadline reached")
    }

    private func clearFlag(reason: String, sleepIfLidClosed: Bool = true) {
        resetDeadline()
        guard PowerManagement.readSleepDisabled() != false else { return }

        guard PowerManagement.setSleepDisabled(false) else {
            logger.fault("failed to clear the sleep flag: \(reason, privacy: .public)")
            return
        }
        logger.notice("cleared the sleep flag: \(reason, privacy: .public)")
        notifyAgent()
        sleepIfLidClosedOnBattery(sleepIfLidClosed)
    }

    private func sleepIfLidClosedOnBattery(_ enabled: Bool) {
        guard enabled, PowerManagement.isOnBattery(), PowerManagement.isLidClosed() else { return }

        if PowerManagement.sleepSystem() {
            logger.notice("sleeping because the lid is closed on battery")
        } else {
            logger.fault("sleep request was refused with the lid closed on battery")
        }
    }

    private func decodeRequest(_ message: xpc_object_t) -> HelperRequest? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, HelperWire.payloadKey, &length) else { return nil }
        return try? HelperWire.decode(HelperRequest.self, from: Data(bytes: bytes, count: length))
    }

    private func reply(to message: xpc_object_t, on peer: xpc_connection_t, with response: HelperResponse) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        send(response, in: reply, on: peer)
    }

    private func notifyAgent() {
        guard let agent else { return }
        send(.status(status()), in: xpc_dictionary_create(nil, nil, 0), on: agent)
    }

    private func send(_ response: HelperResponse, in dictionary: xpc_object_t, on peer: xpc_connection_t) {
        guard let data = try? HelperWire.encode(response) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            xpc_dictionary_set_data(dictionary, HelperWire.payloadKey, base, buffer.count)
        }
        xpc_connection_send_message(peer, dictionary)
    }
}
