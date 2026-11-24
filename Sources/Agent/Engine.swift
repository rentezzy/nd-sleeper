import Config
import Core
import Foundation
import os

public final class Engine: @unchecked Sendable {
    private static let sourceStartTimeout: Duration = .seconds(2)

    private let queue = DispatchQueue(label: ServiceIdentifier.agent)
    private let logger = Logger(subsystem: ServiceIdentifier.logSubsystem, category: "agent")
    private let journal = JournalRecorder()
    private let sources: [any ActivitySource]
    private let startedAt = Date()
    private let startedInstant = ContinuousClock.now
    private var config: ConfigStatus
    private var policy: PolicyState
    private var snapshots: [String: SourceSnapshot] = [:]
    private var lastCosts: [String: SourceCost] = [:]
    private var sourcesRunning = false
    private var startBatch: StartBatch?
    private var lifecycle: Task<Void, Never>?
    private var sourceGeneration = 0
    private var refreshGeneration = 0
    private var counters = ResourceCounters.zero
    private var journaledCounters = ResourceCounters.zero
    private var eventRate = RateAnomalyDetector(counter: "events", window: .seconds(60), limit: 300)
    private var helperStatus: HelperStatus?

    private lazy var sensors = Sensors(queue: queue) { [weak self] event in
        self?.sensorFired(event)
    }
    private lazy var timekeeper = Timekeeper(queue: queue) { [weak self] key, instant in
        self?.timerFired(key, at: instant)
    }
    private lazy var helper = HelperClient(queue: queue) { [weak self] notice in
        self?.helperNotice(notice)
    }
    private lazy var control = ControlServer { [weak self] request, reply in
        guard let self else { return }
        queue.async { self.handle(request, reply: reply) }
    }

    public init(sources: [any ActivitySource] = [T3ActivitySource()]) {
        let config = Self.loadConfig()
        self.sources = sources
        self.config = config
        policy = PolicyState(readings: SystemReader.readAll(), settings: config.settings)
    }

    private static func loadConfig() -> ConfigStatus {
        switch ConfigLoader.load() {
        case let .success(status): status
        case let .failure(error): ConfigStatus(settings: .defaults, source: .defaults, error: error.message)
        }
    }

    public func run() -> Never {
        queue.async { self.start() }
        dispatchMain()
    }

    private func start() {
        logger.notice("agent \(BuildInfo.version, privacy: .public) started")
        sensors.apply([.powerSource, .systemPower])
        journal.started(
            StartupDiagnostics(
                version: BuildInfo.version,
                darkWakeAPI: sensors.detectsDarkWake,
                sources: sources.map(\.descriptor.name)
            ),
            config: config
        )
        if let error = config.error {
            journal.error("using defaults because \(error)")
        }
        do {
            try control.start()
        } catch {
            journal.error("control socket unavailable")
        }
        helper.send(.readStatus) { [weak self] response in
            self?.helperReplied(response)
        }
        refresh(.started)
    }

    private func feed(_ event: PolicyEvent) {
        counters.events += 1
        if let anomaly = eventRate.record(at: .now) {
            journal.write(JournalEntry(time: Date(), kind: .anomaly, anomaly: anomaly))
        }

        let (next, actions) = Policy.reduce(policy, event, now: .now)
        policy = next
        actions.forEach(execute)
    }

    private func sensorFired(_ event: SensorEvent) {
        let readings = policy.inputs.readings
        switch event {
        case .powerSourceChanged:
            refresh(.powerChanged)
        case .systemPower(.willSleep):
            break
        case .systemPower(.fullWake):
            journal.wake(.full)
            timekeeper.rearmAll()
            refresh(.woke)
        case .systemPower(.darkWake):
            journal.wake(.dark)
            timekeeper.rearmAll()
            refresh(.darkWoke)
        case .lidChanged:
            let lid = SystemReader.lid()
            if lid != readings.lid {
                feed(.lidChanged(lid))
            }
        case .thermalChanged:
            let thermal = SystemReader.thermal()
            if thermal != readings.thermal {
                feed(.thermalChanged(thermal))
            }
        case .batteryChanged:
            if let percent = SystemReader.batteryPercent(), percent != readings.batteryPercent {
                feed(.batteryChanged(percent: percent))
            }
        }
    }

    private func timerFired(_ key: TimerKey, at instant: MonotonicInstant) {
        switch key {
        case let .policy(kind):
            feed(.deadlineFired(kind, scheduledFor: instant))
        case .sourceStaleness:
            activityMayHaveChanged()
        }
    }

    private func refresh(_ cause: ReconcileCause) {
        refreshGeneration += 1
        reconcileWhenReady(cause, generation: refreshGeneration)
    }

    private func reconcileWhenReady(_ cause: ReconcileCause, generation: Int) {
        guard generation == refreshGeneration else { return }

        let needsVerdict = SystemReader.power() == .battery
            && !(cause == .darkWoke && policy.inputs.sleepRequest != nil)
        let sourcesReady = sourcesRunning && startBatch == nil
        guard !needsVerdict || sourcesReady else {
            startSources { [weak self] in self?.reconcileWhenReady(cause, generation: generation) }
            return
        }

        let agentsWorking = sourcesRunning ? verdict().isWorking : policy.inputs.agentsWorking
        feed(.reconcile(SystemReader.readAll(), agentsWorking: agentsWorking, cause: cause))
        if policy.outputs?.demand.contains(.agentActivity) != true {
            stopSources()
        }
    }

    private func execute(_ action: PolicyAction) {
        switch action {
        case let .setFlag(request):
            counters.flagChanges += 1
            helper.send(helperRequest(for: request)) { [weak self] response in
                self?.helperReplied(response)
            }
        case .sleepNow:
            helper.send(.sleepNow) { [weak self] response in
                self?.helperReplied(response)
            }
        case .requestReconcile:
            refresh(.refresh)
        case let .setDemand(demand):
            sensors.apply(demand)
            if demand.contains(.agentActivity) {
                startSources { [weak self] in self?.activityMayHaveChanged() }
            } else {
                stopSources()
            }
        case let .scheduleDeadline(kind, at):
            timekeeper.schedule(.policy(kind), at: at)
        case let .cancelDeadline(kind):
            timekeeper.cancel(.policy(kind))
        case let .record(transition):
            record(transition)
        }
    }

    private func helperRequest(for flag: FlagRequest) -> HelperRequest {
        let now = ContinuousClock.now
        switch flag {
        case .off:
            return .setFlagOff
        case let .on(.automatic(window, windowEndsAt)):
            return .setFlagOn(.automatic(window: windowEndsAt.map { $0 - now } ?? window))
        case let .on(.timedHold(endsAt)):
            return .setFlagOn(.timedHold(remaining: endsAt - now))
        case let .on(.untimedHold(capEndsAt)):
            return .setFlagOn(.untimedHold(remaining: capEndsAt.map { $0 - now }))
        }
    }

    private func helperReplied(_ response: HelperResponse?) {
        switch response {
        case let .status(status):
            helperStatus = status
            journal.helperEvents(from: status)
        case let .failed(reason, status):
            helperStatus = status
            journal.helperEvents(from: status)
            journal.error("helper: \(reason)")
        case nil:
            helperStatus = nil
            journal.error("helper unreachable")
        }
    }

    private func helperNotice(_ notice: HelperNotice) {
        switch notice {
        case let .status(status):
            helperStatus = status
            journal.helperEvents(from: status)
            if let flagOn = status.flagOn {
                feed(.helperFlagObserved(isOn: flagOn))
            }
        case .reconnected:
            helper.send(.readStatus) { [weak self] response in
                guard let self else { return }
                helperReplied(response)
                if case let .status(status) = response, let flagOn = status.flagOn {
                    feed(.helperFlagObserved(isOn: flagOn))
                }
            }
        case .unavailable:
            helperStatus = nil
            journal.error("helper connection invalidated")
        }
    }

    private func startSources(then completion: @escaping () -> Void) {
        if let startBatch {
            startBatch.add(completion)
            return
        }
        guard !sourcesRunning else {
            completion()
            return
        }
        sourcesRunning = true
        sourceGeneration += 1
        let generation = sourceGeneration
        let batch = StartBatch(remaining: sources.count) { [weak self] in
            self?.startBatch = nil
        }
        batch.add(completion)
        startBatch = batch

        let (queue, sources, previous) = (queue, sources, lifecycle)
        lifecycle = Task {
            await previous?.value
            for source in sources {
                let report = await source.start { report in
                    queue.async { self.sourceReported(source.descriptor, report, generation: generation) }
                }
                queue.async {
                    self.sourceReported(source.descriptor, report, generation: generation, notify: batch.isDone)
                    batch.finishOne()
                }
            }
        }
        queue.asyncAfter(deadline: .now() + Self.sourceStartTimeout.seconds) { [weak self] in
            guard let self, generation == sourceGeneration, !batch.isDone else { return }
            sources
                .filter { snapshots[$0.descriptor.name] == nil }
                .forEach { source in
                    snapshots[source.descriptor.name] = SourceSnapshot(
                        descriptor: source.descriptor,
                        report: ActivityReport(sessions: [], health: .unavailable("start_timeout"), cost: .zero),
                        updatedAt: .now
                    )
                }
            batch.finishAll()
        }
        batch.finishIfEmpty()
    }

    private func stopSources() {
        guard sourcesRunning else { return }

        sourcesRunning = false
        sourceGeneration += 1
        snapshots = [:]
        let batch = startBatch
        startBatch = nil
        batch?.finishAll()
        timekeeper.cancel(.sourceStaleness)
        let (sources, previous) = (sources, lifecycle)
        lifecycle = Task {
            await previous?.value
            for source in sources {
                await source.stop()
            }
        }
    }

    private func sourceReported(
        _ descriptor: ActivitySourceDescriptor,
        _ report: ActivityReport,
        generation: Int,
        notify: Bool = true
    ) {
        guard generation == sourceGeneration else { return }

        let previousCost = lastCosts[descriptor.name] ?? .zero
        let restarted = report.cost.queries < previousCost.queries
        counters.sourceQueries += restarted ? report.cost.queries : report.cost.queries - previousCost.queries
        counters.sourceQueryNanos += restarted ? report.cost.queryNanos : report.cost.queryNanos - previousCost.queryNanos
        lastCosts[descriptor.name] = report.cost
        journal.sourceHealth(descriptor.name, report.health)
        snapshots[descriptor.name] = SourceSnapshot(descriptor: descriptor, report: report, updatedAt: .now)

        if notify {
            activityMayHaveChanged()
        }
    }

    private func verdict() -> ActivityVerdict {
        ActivityAggregator.combine(Array(snapshots.values), now: .now)
    }

    private func activityMayHaveChanged() {
        guard sourcesRunning else { return }

        let snapshotList = Array(snapshots.values)
        if let next = ActivityAggregator.nextStaleness(snapshotList, now: .now) {
            timekeeper.schedule(.sourceStaleness, at: next)
        } else {
            timekeeper.cancel(.sourceStaleness)
        }
        let isWorking = verdict().isWorking
        if isWorking != policy.inputs.agentsWorking {
            feed(.activityChanged(isWorking: isWorking))
        }
    }

    private func record(_ transition: Transition) {
        let current = currentCounters()
        journal.write(JournalEntry(
            time: Date(),
            kind: .transition,
            from: transition.from,
            to: transition.to,
            reason: transition.reason,
            flagOn: transition.flag.isOn,
            readings: JournalReadings(policy.inputs.readings, agentsWorking: policy.inputs.agentsWorking),
            counters: current.delta(since: journaledCounters)
        ))
        journaledCounters = current
    }

    private func currentCounters() -> ResourceCounters {
        let sample = ResourceSampler.sample()
        var current = counters
        current.cpuNanos = sample?.cpuNanos ?? 0
        current.wakeups = sample?.wakeups ?? 0
        return current
    }

    private func handle(_ request: ControlRequest, reply: @escaping @Sendable (ControlResponse) -> Void) {
        switch request {
        case let .status(includeMetrics):
            replyWithStatus(includeMetrics: includeMetrics, reply: reply)
        case let .setOverride(override):
            guard isWithinLimit(override) else {
                reply(.failed("durations are limited to \(DurationText.format(SafetyLimit.maxOverrideDuration))"))
                return
            }
            feed(.command(.setOverride(override)))
            reply(.ok)
        case .auto:
            feed(.command(.auto))
            reply(.ok)
        case .sleepNow:
            feed(.command(.sleepNow))
            reply(.ok)
        case .reload:
            reload(reply: reply)
        }
    }

    private func reload(reply: @escaping @Sendable (ControlResponse) -> Void) {
        switch ConfigLoader.load() {
        case let .success(status):
            config = status
            journal.configReloaded(status)
            feed(.settingsChanged(status.settings))
            reply(.config(status))
        case let .failure(error):
            reply(.failed(error.message))
        }
    }

    private func isWithinLimit(_ request: OverrideRequest) -> Bool {
        let duration = switch request {
        case let .hold(duration, _): duration
        case let .normal(duration): duration
        }
        return duration.map { $0 > .zero && $0 <= SafetyLimit.maxOverrideDuration } ?? true
    }

    private func replyWithStatus(includeMetrics: Bool, reply: @escaping @Sendable (ControlResponse) -> Void) {
        let (sources, queue) = (sources, queue)
        Task {
            let notes = await Self.notes(from: sources)
            queue.async {
                self.helper.send(.readStatus) { response in
                    self.helperReplied(response)
                    reply(self.statusResponse(notes: notes, includeMetrics: includeMetrics))
                }
            }
        }
    }

    private static func notes(from sources: [any ActivitySource]) async -> [String: String] {
        var notes: [String: String] = [:]
        for source in sources {
            notes[source.descriptor.name] = await source.statusNote()
        }
        return notes
    }

    private func statusResponse(notes: [String: String], includeMetrics: Bool) -> ControlResponse {
        guard let outputs = policy.outputs else { return .failed("still starting") }

        let inputs = policy.inputs
        let now = ContinuousClock.now
        let remaining = { (instant: MonotonicInstant?) in instant.map { max(0, ($0 - now).seconds) } }
        let override = inputs.override.map { override in
            OverrideStatus(mode: override.mode, remainingSeconds: remaining(override.expiresAt ?? inputs.holdCapEndsAt))
        }
        let helper = HelperConnection(
            connected: helperStatus != nil,
            version: helperStatus?.version,
            deadlineRemainingSeconds: helperStatus?.deadlineRemainingSeconds
        )
        return .status(StatusReport(
            agentVersion: BuildInfo.version,
            startedAt: startedAt,
            uptimeSeconds: (now - startedInstant).seconds,
            darkWakeDetection: sensors.detectsDarkWake,
            config: config,
            helper: helper,
            phase: outputs.phase,
            power: inputs.readings.power,
            lid: inputs.readings.lid,
            batteryPercent: inputs.readings.batteryPercent,
            thermal: inputs.readings.thermal,
            flagDesired: outputs.flag.isOn,
            flagActual: helperStatus?.flagOn,
            override: override,
            lidWindowRemainingSeconds: remaining(inputs.lidWindowEndsAt),
            sources: verdict().sources,
            sourceNotes: notes,
            sourceDisplayNames: Dictionary(uniqueKeysWithValues: sources.map { ($0.descriptor.name, $0.descriptor.displayName) }),
            metrics: includeMetrics ? currentCounters() : nil
        ))
    }
}

private final class StartBatch: @unchecked Sendable {
    private var remaining: Int
    private var onDone: (() -> Void)?
    private var completions: [() -> Void] = []

    init(remaining: Int, onDone: @escaping () -> Void) {
        self.remaining = remaining
        self.onDone = onDone
    }

    var isDone: Bool {
        onDone == nil
    }

    func add(_ completion: @escaping () -> Void) {
        completions.append(completion)
    }

    func finishOne() {
        remaining -= 1
        finishIfEmpty()
    }

    func finishIfEmpty() {
        guard remaining <= 0 else { return }
        finishAll()
    }

    func finishAll() {
        guard let onDone else { return }

        self.onDone = nil
        let waiting = completions
        completions = []
        onDone()
        waiting.forEach { $0() }
    }
}
