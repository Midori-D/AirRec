// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Completion means that no CallKit call is active, rather than that a
/// particular call has disappeared. A replacement or held call still blocks it.
struct AirRecordCallEndWaitPolicy {
    struct Call: Equatable {
        let hasEnded: Bool
    }

    enum Result: Equatable {
        case noActiveCalls, cancelled, timedOut, invalidClock

        var allCallsEnded: Bool { self == .noActiveCalls }
    }

    enum Decision: Equatable { case waiting, finished(Result) }

    static let defaultTimeout: TimeInterval = 60 * 60
    static let maximumTimeout: TimeInterval = 180 * 60

    let startedAt: TimeInterval
    let deadline: TimeInterval
    private var lastObservedAt: TimeInterval
    private var terminal: Result?

    static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(maximumTimeout, max(1, value)) : defaultTimeout
    }

    init(startedAt: TimeInterval, timeout: TimeInterval) {
        self.startedAt = startedAt
        deadline = startedAt + Self.boundedTimeout(timeout)
        lastObservedAt = startedAt
    }

    mutating func decision(now: TimeInterval, calls: [Call], cancelled: Bool = false) -> Decision {
        if let terminal { return .finished(terminal) }
        if cancelled { return finish(.cancelled) }
        guard now.isFinite, startedAt.isFinite, lastObservedAt.isFinite, deadline.isFinite,
              startedAt >= 0, now >= lastObservedAt else { return finish(.invalidClock) }
        lastObservedAt = now
        // A delayed callback must not convert an expired wait into success.
        guard now < deadline else { return finish(.timedOut) }
        // Connection, direction, and hold state do not change whether a call
        // still exists. Do not restore data while any call remains active.
        return calls.contains(where: { !$0.hasEnded }) ? .waiting : finish(.noActiveCalls)
    }

    private mutating func finish(_ result: Result) -> Decision {
        terminal = result
        return .finished(result)
    }
}
