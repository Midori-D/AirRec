// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// A bounded observation of a call starting or ringing.
struct AirRecordCallWaitPolicy {
    enum Target: Equatable { case outgoing, incomingRinging }

    struct Call: Equatable {
        let isOutgoing: Bool
        let hasConnected: Bool
        let hasEnded: Bool
        let isOnHold: Bool
    }

    enum Result: Equatable {
        case detected, multipleCalls, held, cancelled, timedOut, invalidClock

        var didDetectCall: Bool { self == .detected }
    }

    enum Decision: Equatable { case waiting, finished(Result) }

    static let defaultTimeout: TimeInterval = 20

    let startedAt: TimeInterval
    let deadline: TimeInterval
    private let target: Target
    private var lastObservedAt: TimeInterval
    private var terminal: Result?

    static func boundedTimeout(_ value: TimeInterval, target: Target = .outgoing) -> TimeInterval {
        let maximum: TimeInterval = target == .outgoing ? 180 : 25
        return value.isFinite ? min(maximum, max(1, value)) : defaultTimeout
    }

    init(startedAt: TimeInterval, timeout: TimeInterval, target: Target = .outgoing) {
        self.startedAt = startedAt
        self.target = target
        deadline = startedAt + Self.boundedTimeout(timeout, target: target)
        lastObservedAt = startedAt
    }

    mutating func decision(now: TimeInterval, calls: [Call], cancelled: Bool = false) -> Decision {
        if let terminal { return .finished(terminal) }
        if cancelled { return finish(.cancelled) }
        guard now.isFinite, lastObservedAt.isFinite, deadline.isFinite,
              now >= 0, now >= lastObservedAt else { return finish(.invalidClock) }
        lastObservedAt = now
        // A late observer callback cannot turn an expired wait into success.
        guard now < deadline else { return finish(.timedOut) }
        let active = calls.filter { !$0.hasEnded }
        if target == .incomingRinging {
            // A ringing call can arrive during an unrelated connected call.
            let ringing = active.contains { !$0.isOutgoing && !$0.hasConnected && !$0.isOnHold }
            return ringing ? finish(.detected) : .waiting
        }
        guard active.count <= 1 else { return finish(.multipleCalls) }
        guard let call = active.first else { return .waiting }
        guard !call.isOnHold else { return finish(.held) }
        return call.isOutgoing ? finish(.detected) : .waiting
    }

    private mutating func finish(_ result: Result) -> Decision {
        terminal = result
        return .finished(result)
    }
}
