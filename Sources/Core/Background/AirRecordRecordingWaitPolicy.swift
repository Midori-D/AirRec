// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Observation only. Native results are supplied after the blocking AX call has
/// returned; a recording-start reservation is deliberately not an input.
struct AirRecordRecordingWaitPolicy {
    enum NativeOutcome: Equatable {
        case confirmed, alreadyRecording, submittedUnconfirmed, failedAfterReservation
    }
    struct NativeResult {
        let outcome: NativeOutcome
        let generation: UInt64
    }
    enum Result: Equatable {
        case native(NativeOutcome, reused: Bool)
        case stopped, superseded, cancelled, timedOut, invalidClock
        case callEnded, callChanged, multipleCalls, preparationFailed
    }
    enum Decision: Equatable { case waiting, finished(Result) }

    let deadline: TimeInterval
    private(set) var callID: UUID?
    private(set) var generation: UUID?
    private var preparationComplete = false
    private var lastObservedAt: TimeInterval
    private var terminal: Result?

    static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(60, max(1, value)) : 45
    }

    init(startedAt: TimeInterval, timeout: TimeInterval, initialGeneration: UUID) {
        deadline = startedAt + Self.boundedTimeout(timeout)
        lastObservedAt = startedAt
        generation = initialGeneration
    }

    mutating func decision(now: TimeInterval, calls: [AirRecordCallState], enabled: Bool,
                           currentGeneration: UUID, ownedGeneration: UUID,
                           preparationResult: Bool?, nativeResult: NativeResult?,
                           currentNativeGeneration: UInt64?, nativeWorkInFlight: Bool,
                           cancelled: Bool) -> Decision {
        if let terminal { return .finished(terminal) }
        if cancelled { return finish(.cancelled) }
        guard now.isFinite, lastObservedAt.isFinite, deadline.isFinite,
              now >= 0, now >= lastObservedAt else { return finish(.invalidClock) }
        lastObservedAt = now
        guard enabled else { return finish(.stopped) }
        // The owner's pause -> prepare transition is allowed only while its
        // existing Shortcut preparation is pending. Once ready, it is fixed.
        guard currentGeneration == ownedGeneration else { return finish(.superseded) }
        if preparationComplete && generation != ownedGeneration { return finish(.superseded) }
        if !preparationComplete { generation = ownedGeneration }
        guard now < deadline else { return finish(.timedOut) }

        let active = calls.filter { !$0.hasEnded }
        if active.count > 1 { return finish(.multipleCalls) }
        if let callID {
            guard let call = active.first else { return finish(.callEnded) }
            guard call.id == callID else { return finish(.callChanged) }
        } else if let call = active.first {
            callID = call.id
        }
        if preparationResult == false { return finish(.preparationFailed) }
        guard preparationResult == true else { return .waiting }
        preparationComplete = true
        guard let call = active.first, call.id == callID,
              call.hasConnected, !call.isOnHold,
              let nativeResult, !nativeWorkInFlight else { return .waiting }
        return finish(.native(nativeResult.outcome,
                              reused: currentNativeGeneration != nativeResult.generation))
    }

    private mutating func finish(_ result: Result) -> Decision {
        terminal = result
        return .finished(result)
    }
}
