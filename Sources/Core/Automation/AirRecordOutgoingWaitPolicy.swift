// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Observes call direction only. A separate instance belongs to each wait.
struct AirRecordOutgoingWaitPolicy {
    struct Call: Equatable {
        let isOutgoing: Bool
        let hasEnded: Bool
        let isOnHold: Bool
    }

    enum Result: Equatable {
        case outgoing, multipleCalls, held, cancelled, timedOut, invalidClock

        var detectedOutgoing: Bool { self == .outgoing }
    }

    enum Decision: Equatable { case waiting, finished(Result) }

    static let defaultTimeout: TimeInterval = 20
    static let maximumTimeout: TimeInterval = 25

    let deadline: TimeInterval
    private var lastObservedAt: TimeInterval
    private var terminal: Result?

    static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(maximumTimeout, max(1, value)) : defaultTimeout
    }

    init(startedAt: TimeInterval, timeout: TimeInterval) {
        deadline = startedAt + Self.boundedTimeout(timeout)
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
        guard active.count <= 1 else { return finish(.multipleCalls) }
        guard let call = active.first else { return .waiting }
        guard !call.isOnHold else { return finish(.held) }
        return call.isOutgoing ? finish(.outgoing) : .waiting
    }

    private mutating func finish(_ result: Result) -> Decision {
        terminal = result
        return .finished(result)
    }
}
