public enum Policy {
    public static func reduce(
        _ state: PolicyState,
        _ event: PolicyEvent,
        now clockNow: MonotonicInstant
    ) -> (state: PolicyState, actions: [PolicyAction]) {
        let now = firedAt(event).map { max(clockNow, $0) } ?? clockNow
        let applied = apply(event, to: state.inputs, now: now)
        let previous = previousOutputs(state.outputs, after: event)

        let decided = settle(applied.inputs, now: now, deciding: true)
        let held = settle(applied.inputs, now: now, deciding: false)
        let waiting = needsReconcile(event, inputs: state.inputs, previous: previous, decided: decided, held: held)
        let chosen = waiting ? held : decided

        let inputs = withReconcilePending(chosen.inputs, waiting)
        let outputs = waiting ? keepingDecision(of: previous, in: chosen.outputs) : chosen.outputs
        let reason = chosen.reason
            ?? enteredStress(from: previous, to: outputs, inputs: inputs)
            ?? applied.reason

        let actions = diff(
            from: previous,
            to: outputs,
            previousInputs: state.inputs,
            nextInputs: inputs,
            resendFlag: helperDisagrees(event, with: outputs, hadOutputs: state.outputs != nil),
            reason: reason
        )
        let reconcile: [PolicyAction] = waiting && !state.inputs.reconcilePending ? [.requestReconcile] : []
        return (PolicyState(inputs: inputs, outputs: outputs), reconcile + actions)
    }

    private static func apply(
        _ event: PolicyEvent,
        to inputs: PolicyInputs,
        now: MonotonicInstant
    ) -> (inputs: PolicyInputs, reason: TransitionReason) {
        var next = inputs
        switch event {
        case let .reconcile(readings, agentsWorking, cause):
            next.readings = readings
            next.agentsWorking = agentsWorking
            if cause == .started || cause == .woke {
                next.sleepRequest = nil
            }
            return (next, reason(for: cause))
        case let .lidChanged(lid):
            next.readings.lid = lid
            guard lid == .open else { return (next, .lidClosed) }
            next.sleepRequest = nil
            return (next, .lidOpened)
        case let .thermalChanged(level):
            next.readings.thermal = level
            return (next, .thermalChanged)
        case let .batteryChanged(percent):
            next.readings.batteryPercent = percent
            return (next, .batteryChanged)
        case let .activityChanged(isWorking):
            next.agentsWorking = isWorking
            return (next, isWorking ? .agentsStarted : .agentsStopped)
        case let .command(command):
            return apply(command, to: next, now: now)
        case let .deadlineFired(kind, _):
            guard kind == .sleepRetry, inputs.sleepRequest != nil else { return (next, reason(for: kind)) }
            next.sleepRequest = SleepRequest(requestedAt: now, retryAt: nil)
            return (next, .sleepRetry)
        case .helperFlagObserved:
            return (next, .helperFlagMismatch)
        case let .settingsChanged(settings):
            next.lidWindowEndsAt = inputs.lidWindowEndsAt.map {
                $0 - inputs.settings.windowDuration + settings.windowDuration
            }
            next.settings = settings
            return (next, .settingsChanged)
        }
    }

    private static func apply(
        _ command: PolicyCommand,
        to inputs: PolicyInputs,
        now: MonotonicInstant
    ) -> (inputs: PolicyInputs, reason: TransitionReason) {
        var next = inputs
        next.holdCapEndsAt = nil
        next.sleepRequest = nil
        switch command {
        case let .setOverride(request):
            next.override = override(for: request, now: now)
            next.lidWindowEndsAt = nil
            return (next, .overrideSet)
        case .auto:
            next.override = nil
            return (next, .overrideCleared)
        case .sleepNow:
            next.override = nil
            next.sleepRequest = newSleepRequest(now: now)
            return (next, .sleepCommand)
        }
    }

    private static func override(for request: OverrideRequest, now: MonotonicInstant) -> Override {
        switch request {
        case let .hold(duration, force):
            Override(mode: .hold(force: force), expiresAt: duration.map { now + $0 })
        case let .normal(duration):
            Override(mode: .normal, expiresAt: duration.map { now + $0 })
        }
    }

    private struct Settled {
        let inputs: PolicyInputs
        let outputs: PolicyOutputs
        let reason: TransitionReason?
    }

    private static func settle(_ inputs: PolicyInputs, now: MonotonicInstant, deciding: Bool) -> Settled {
        let expired = expireOverride(inputs, now: now)
        let capped = applyHoldBatteryCap(expired.inputs, now: now)
        let unstressed = endStressedHold(capped.inputs)
        let windowed = trackLidWindow(unstressed.inputs, now: now, mayStart: deciding)
        let slept = deciding ? requestSleepIfNeeded(windowed, now: now) : (inputs: windowed, reason: nil)
        return Settled(
            inputs: slept.inputs,
            outputs: derive(slept.inputs),
            reason: slept.reason ?? unstressed.reason ?? capped.reason ?? expired.reason
        )
    }

    private static func expireOverride(
        _ inputs: PolicyInputs,
        now: MonotonicInstant
    ) -> (inputs: PolicyInputs, reason: TransitionReason?) {
        guard let expiresAt = inputs.override?.expiresAt, expiresAt <= now else { return (inputs, nil) }

        var next = inputs
        next.override = nil
        return (next, .overrideExpired)
    }

    private static func applyHoldBatteryCap(
        _ inputs: PolicyInputs,
        now: MonotonicInstant
    ) -> (inputs: PolicyInputs, reason: TransitionReason?) {
        var next = inputs
        guard case .hold = inputs.override?.mode,
              inputs.override?.expiresAt == nil,
              inputs.readings.power == .battery
        else {
            next.holdCapEndsAt = nil
            return (next, nil)
        }

        let capEndsAt = inputs.holdCapEndsAt ?? now + SafetyLimit.untimedBatteryHoldCap
        guard capEndsAt <= now else {
            next.holdCapEndsAt = capEndsAt
            return (next, nil)
        }

        next.override = nil
        next.holdCapEndsAt = nil
        return (next, .holdCapReached)
    }

    private static func endStressedHold(_ inputs: PolicyInputs) -> (inputs: PolicyInputs, reason: TransitionReason?) {
        guard case .hold(force: false) = inputs.override?.mode,
              let stress = stressReason(inputs)
        else { return (inputs, nil) }

        var next = inputs
        next.override = nil
        return (next, stress)
    }

    private static func trackLidWindow(_ inputs: PolicyInputs, now: MonotonicInstant, mayStart: Bool) -> PolicyInputs {
        var next = inputs
        guard isLidClosedOnBattery(inputs.readings) else {
            next.lidWindowEndsAt = nil
            return next
        }
        guard mayStart, inputs.override == nil, inputs.lidWindowEndsAt == nil else { return next }

        next.lidWindowEndsAt = now + inputs.settings.windowDuration
        return next
    }

    private static func requestSleepIfNeeded(
        _ inputs: PolicyInputs,
        now: MonotonicInstant
    ) -> (inputs: PolicyInputs, reason: TransitionReason?) {
        guard inputs.override == nil,
              isLidClosedOnBattery(inputs.readings),
              inputs.sleepRequest == nil
        else { return (inputs, nil) }

        let stress = stressReason(inputs)
        let windowOpen = inputs.lidWindowEndsAt.map { now < $0 } ?? false
        guard stress != nil || !windowOpen || !inputs.agentsWorking else { return (inputs, nil) }

        var next = inputs
        next.sleepRequest = newSleepRequest(now: now)
        return (next, stress ?? (windowOpen ? nil : .windowExpired))
    }

    private static func newSleepRequest(now: MonotonicInstant) -> SleepRequest {
        SleepRequest(requestedAt: now, retryAt: now + SafetyLimit.sleepRequestRetry)
    }

    private static func derive(_ inputs: PolicyInputs) -> PolicyOutputs {
        let base: Set<DemandInput> = [.powerSource, .systemPower]

        if let sleepRequest = inputs.sleepRequest {
            return PolicyOutputs(
                phase: .sleepRequested,
                flag: .off,
                demand: base.union([.lid]),
                deadlines: sleepRequest.retryAt.map { [.sleepRetry: $0] } ?? [:]
            )
        }

        if let override = inputs.override {
            return derive(override, inputs: inputs, base: base)
        }

        guard inputs.readings.power == .battery else {
            return PolicyOutputs(
                phase: .pluggedIn,
                flag: .on(.automatic(window: inputs.settings.windowDuration, windowEndsAt: nil)),
                demand: base,
                deadlines: [:]
            )
        }

        if stressReason(inputs) != nil {
            return PolicyOutputs(
                phase: .batteryStressed,
                flag: .off,
                demand: base.union([.lid, .thermal]),
                deadlines: [:]
            )
        }

        let watching = base.union([.lid, .thermal, .agentActivity])
        guard inputs.readings.lid == .closed, let windowEndsAt = inputs.lidWindowEndsAt else {
            return PolicyOutputs(
                phase: .batteryLidOpen,
                flag: inputs.agentsWorking ? .on(.automatic(window: inputs.settings.windowDuration, windowEndsAt: nil)) : .off,
                demand: watching,
                deadlines: [:]
            )
        }

        return PolicyOutputs(
            phase: .batteryLidClosedWorking,
            flag: .on(.automatic(window: inputs.settings.windowDuration, windowEndsAt: windowEndsAt)),
            demand: watching.union([.batteryPercent]),
            deadlines: [.lidClosedWindow: windowEndsAt]
        )
    }

    private static func derive(_ override: Override, inputs: PolicyInputs, base: Set<DemandInput>) -> PolicyOutputs {
        let expiry = override.expiresAt.map { [DeadlineKind.overrideExpiry: $0] } ?? [:]

        guard case let .hold(force) = override.mode else {
            return PolicyOutputs(phase: .normalOverride, flag: .off, demand: [.systemPower], deadlines: expiry)
        }

        let batteryGuard = override.expiresAt.map { BatteryGuard.timedHold(endsAt: $0) }
            ?? .untimedHold(capEndsAt: inputs.holdCapEndsAt)
        let cap = inputs.holdCapEndsAt.map { [DeadlineKind.holdBatteryCap: $0] } ?? [:]
        let batteryDemand: Set<DemandInput> = force ? [.lid] : [.lid, .thermal, .batteryPercent]
        return PolicyOutputs(
            phase: .holdOverride,
            flag: .on(batteryGuard),
            demand: inputs.readings.power == .battery ? base.union(batteryDemand) : base,
            deadlines: expiry.merging(cap) { first, _ in first }
        )
    }

    private static func needsReconcile(
        _ event: PolicyEvent,
        inputs: PolicyInputs,
        previous: PolicyOutputs?,
        decided: Settled,
        held: Settled
    ) -> Bool {
        if case .reconcile = event { return false }
        if case .command(.sleepNow) = event { return false }
        guard let previous else { return false }

        let demandGrew = [decided, held].contains { !$0.outputs.demand.isSubset(of: previous.demand) }
        return inputs.reconcilePending
            || demandGrew
            || turnsFlagOnWithStaleBattery(decided, previous: previous)
            || changesSettingsWithStaleBattery(event, decided: decided, previous: previous)
    }

    private static func turnsFlagOnWithStaleBattery(_ decided: Settled, previous: PolicyOutputs) -> Bool {
        let readings = decided.inputs.readings
        let forced = decided.inputs.override?.mode == .hold(force: true)
        return decided.outputs.flag.isOn
            && !previous.flag.isOn
            && readings.power == .battery
            && !previous.demand.contains(.batteryPercent)
            && !forced
    }

    private static func changesSettingsWithStaleBattery(
        _ event: PolicyEvent,
        decided: Settled,
        previous: PolicyOutputs
    ) -> Bool {
        guard case .settingsChanged = event else { return false }
        let forced = decided.inputs.override?.mode == .hold(force: true)
        return decided.inputs.readings.power == .battery
            && !previous.demand.contains(.batteryPercent)
            && !forced
    }

    private static func withReconcilePending(_ inputs: PolicyInputs, _ pending: Bool) -> PolicyInputs {
        var next = inputs
        next.reconcilePending = pending
        return next
    }

    private static func keepingDecision(of previous: PolicyOutputs?, in outputs: PolicyOutputs) -> PolicyOutputs {
        guard let previous else { return outputs }

        return PolicyOutputs(
            phase: previous.phase,
            flag: previous.flag,
            demand: outputs.demand,
            deadlines: outputs.deadlines
        )
    }

    private static func previousOutputs(_ outputs: PolicyOutputs?, after event: PolicyEvent) -> PolicyOutputs? {
        guard let outputs, case let .deadlineFired(kind, _) = event else { return outputs }

        return PolicyOutputs(
            phase: outputs.phase,
            flag: outputs.flag,
            demand: outputs.demand,
            deadlines: outputs.deadlines.filter { $0.key != kind }
        )
    }

    private static func helperDisagrees(_ event: PolicyEvent, with outputs: PolicyOutputs, hadOutputs: Bool) -> Bool {
        guard hadOutputs, case let .helperFlagObserved(isOn) = event else { return false }
        return isOn != outputs.flag.isOn
    }

    private static func diff(
        from previous: PolicyOutputs?,
        to next: PolicyOutputs,
        previousInputs: PolicyInputs,
        nextInputs: PolicyInputs,
        resendFlag: Bool,
        reason: TransitionReason
    ) -> [PolicyAction] {
        let sleepRequestedAt = nextInputs.sleepRequest?.requestedAt
        let sleepRequested = sleepRequestedAt != nil
            && (previous == nil || sleepRequestedAt != previousInputs.sleepRequest?.requestedAt)
        let unplugged = previousInputs.readings.power == .ac && nextInputs.readings.power == .battery
        let flagChanged = resendFlag || previous?.flag != next.flag || unplugged && next.flag.isOn
        let transitioned = previous?.phase != next.phase
            || flagChanged
            || sleepRequested
            || previousInputs.override != nextInputs.override

        let flag: [PolicyAction] = flagChanged && !sleepRequested ? [.setFlag(next.flag)] : []
        let sleep: [PolicyAction] = sleepRequested ? [.sleepNow] : []
        let demand: [PolicyAction] = previous?.demand != next.demand ? [.setDemand(next.demand)] : []
        let cancelled: [PolicyAction] = (previous?.deadlines ?? [:]).keys
            .filter { next.deadlines[$0] == nil }
            .sorted { $0.rawValue < $1.rawValue }
            .map { .cancelDeadline($0) }
        let scheduled: [PolicyAction] = next.deadlines
            .filter { previous?.deadlines[$0.key] != $0.value }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { .scheduleDeadline($0.key, at: $0.value) }
        let record: [PolicyAction] = transitioned
            ? [.record(Transition(
                from: previous?.phase,
                to: next.phase,
                reason: reason,
                flag: next.flag,
                override: nextInputs.override
            ))]
            : []

        return flag + sleep + demand + cancelled + scheduled + record
    }

    private static func isLidClosedOnBattery(_ readings: SystemReadings) -> Bool {
        readings.power == .battery && readings.lid == .closed
    }

    private static func stressReason(_ inputs: PolicyInputs) -> TransitionReason? {
        let readings = inputs.readings
        guard readings.power == .battery else { return nil }
        if let percent = readings.batteryPercent, percent <= inputs.settings.batteryFloor {
            return .batteryFloor
        }
        return readings.thermal >= .serious ? .thermalCutoff : nil
    }

    private static func enteredStress(
        from previous: PolicyOutputs?,
        to next: PolicyOutputs,
        inputs: PolicyInputs
    ) -> TransitionReason? {
        guard next.phase == .batteryStressed, previous?.phase != .batteryStressed else { return nil }
        return stressReason(inputs)
    }

    private static func firedAt(_ event: PolicyEvent) -> MonotonicInstant? {
        guard case let .deadlineFired(_, scheduledFor) = event else { return nil }
        return scheduledFor
    }

    private static func reason(for cause: ReconcileCause) -> TransitionReason {
        switch cause {
        case .started: .started
        case .powerChanged: .powerChanged
        case .woke: .woke
        case .darkWoke: .darkWoke
        case .refresh: .refreshed
        }
    }

    private static func reason(for kind: DeadlineKind) -> TransitionReason {
        switch kind {
        case .lidClosedWindow: .windowExpired
        case .overrideExpiry: .overrideExpired
        case .holdBatteryCap: .holdCapReached
        case .sleepRetry: .sleepRetry
        }
    }
}
