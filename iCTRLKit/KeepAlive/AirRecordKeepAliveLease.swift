// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Evidence for one live two-process debugger session. A stale callback, a
/// persistent JIT flag, or a single attach acknowledgement cannot grant a lease.
struct AirRecordKeepAliveLease {
    enum Issue: Equatable {
        case missingEvidence, hostUntraced, helperUntraced, staleHeartbeat
        case challengePending, invalidTime
    }

    private(set) var session: UUID?
    private(set) var hostAttached = false
    private(set) var helperAttached = false
    private(set) var helperTraced = false
    // The peer's sampling time is used for freshness, not the time at which a
    // queued frame eventually reaches our receive callback.
    private(set) var heartbeat: TimeInterval?
    private var receivedAt: TimeInterval?
    private(set) var pendingID: UInt64?
    private(set) var pendingDeadline: TimeInterval?
    private(set) var sentAt: TimeInterval?
    private var nextID: UInt64 = 0

    private static let heartbeatWindow: TimeInterval = 6
    private static let recheckWindow: TimeInterval = 8

    mutating func begin(_ session: UUID) {
        self = Self()
        self.session = session
    }

    mutating func invalidate() { self = Self() }

    mutating func hostDebuggerReported(_ session: UUID) {
        guard self.session == session else { return }
        hostAttached = true
    }

    mutating func helperDebuggerReported(_ session: UUID) {
        guard self.session == session else { return }
        helperAttached = true
    }

    mutating func receivedHeartbeat(_ session: UUID, hostAttached: Bool,
                                    helperTraced: Bool, now: TimeInterval,
                                    sampledAt: TimeInterval? = nil) {
        let sampled = sampledAt ?? now
        guard self.session == session, now.isFinite, sampled.isFinite,
              now >= 0, sampled >= 0, sampled <= now,
              now - sampled <= Self.heartbeatWindow,
              receivedAt.map({ now >= $0 }) ?? true,
              heartbeat.map({ sampled >= $0 }) ?? true else { return }
        // Negative evidence revokes immediately; an earlier positive heartbeat
        // must never mask a debugger disconnect.
        self.hostAttached = hostAttached
        self.helperTraced = helperTraced
        heartbeat = sampled
        receivedAt = now
        // An unsolicited heartbeat never satisfies an outstanding challenge.
    }

    func heartbeatAge(now: TimeInterval) -> TimeInterval? {
        guard now.isFinite, now >= 0, let heartbeat else { return nil }
        let age = now - heartbeat
        return age.isFinite && age >= 0 ? age : nil
    }

    func issue(now: TimeInterval, hostTraced: Bool) -> Issue? {
        guard now.isFinite, now >= 0 else { return .invalidTime }
        guard session != nil else { return .missingEvidence }
        guard hostTraced else { return .hostUntraced }
        guard hostAttached, helperAttached, heartbeat != nil else { return .missingEvidence }
        guard helperTraced else { return .helperUntraced }
        guard let age = heartbeatAge(now: now),
              receivedAt.map({ now >= $0 }) ?? true else { return .invalidTime }
        if let sentAt, now < sentAt { return .invalidTime }
        if pendingID != nil { return .challengePending }
        return age <= Self.heartbeatWindow ? nil : .staleHeartbeat
    }

    func isValid(now: TimeInterval, hostTraced: Bool) -> Bool {
        issue(now: now, hostTraced: hostTraced) == nil
    }

    /// A second request cannot move an outstanding challenge's fixed deadline.
    /// The session identifier prevents reused sequence numbers after a restart
    /// from authenticating a response from an earlier helper request.
    mutating func beginRecheck(_ session: UUID, now: TimeInterval) -> UInt64? {
        guard self.session == session, pendingID == nil, now.isFinite, now >= 0,
              receivedAt.map({ now >= $0 }) ?? true,
              nextID < UInt64.max else { return nil }
        let deadline = now + Self.recheckWindow
        guard deadline.isFinite, deadline > now else { return nil }
        nextID += 1
        pendingID = nextID
        sentAt = now
        pendingDeadline = deadline
        return nextID
    }

    func recheckExpired(now: TimeInterval) -> Bool {
        guard pendingID != nil else { return false }
        guard now.isFinite, let sentAt, let pendingDeadline,
              now >= sentAt else { return true }
        return now >= pendingDeadline
    }

    /// Only a newly sampled response to this exact outstanding challenge can
    /// restore runtime. A positive but delayed ordinary heartbeat cannot do so.
    mutating func acceptPong(_ session: UUID, pingID: UInt64, sampledAt: TimeInterval,
                             hostAttached: Bool, helperTraced: Bool, hostTraced: Bool,
                             now: TimeInterval) -> Bool {
        guard self.session == session, pendingID == pingID,
              let sentAt, let pendingDeadline,
              now.isFinite, sampledAt.isFinite, now >= sentAt, now < pendingDeadline,
              sampledAt >= sentAt, sampledAt <= now,
              now - sampledAt <= Self.heartbeatWindow,
              receivedAt.map({ now >= $0 }) ?? true,
              hostAttached, helperAttached, helperTraced, hostTraced else { return false }
        self.hostAttached = true
        self.helperTraced = true
        heartbeat = max(heartbeat ?? sampledAt, sampledAt)
        receivedAt = now
        pendingID = nil
        self.sentAt = nil
        self.pendingDeadline = nil
        return true
    }
}
