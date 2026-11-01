// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Tracks execution readiness for one location-manager generation. This policy
/// receives timestamps only; authorization and location coordinates stay outside
/// it. The controller must verify authorization before submitting a sample.
struct AirRecordLocationSessionPolicy {
    private(set) var session: UUID?
    private(set) var isReady = false
    private(set) var lastSampledAt: TimeInterval?
    private var lastReceivedAt: TimeInterval?

    private static let maximumSampleAge: TimeInterval = 60

    /// Starting a new manager always requires its own fresh sample. Permission
    /// approval, a previous ready run, or a queued old callback cannot grant it.
    mutating func begin() -> UUID {
        self = Self()
        let id = UUID()
        session = id
        return id
    }

    mutating func stop() { self = Self() }

    func matches(_ id: UUID) -> Bool { session == id }

    /// Pause invalidates the execution generation. Restarting it requires a new
    /// foreground manager start; this does not alter a user's saved preference.
    @discardableResult
    mutating func pause(for id: UUID) -> Bool {
        guard matches(id) else { return false }
        stop()
        return true
    }

    /// Times use the same clock (the controller supplies Date epoch seconds).
    /// A recent cached location may establish readiness, but an older delivery
    /// cannot be made fresh merely by arriving in a new callback.
    @discardableResult
    mutating func receivedSample(for id: UUID, now: TimeInterval,
                                sampledAt: TimeInterval) -> Bool {
        guard matches(id), now.isFinite, sampledAt.isFinite,
              now >= 0, sampledAt >= 0, sampledAt <= now,
              now - sampledAt <= Self.maximumSampleAge,
              lastReceivedAt.map({ now >= $0 }) ?? true,
              lastSampledAt.map({ sampledAt >= $0 }) ?? true else { return false }
        lastReceivedAt = now
        lastSampledAt = sampledAt
        isReady = true
        return true
    }
}
