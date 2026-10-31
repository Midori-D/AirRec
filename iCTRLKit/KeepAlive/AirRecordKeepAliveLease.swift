// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Evidence for one live two-process debugger session. A stale callback, a
/// persistent JIT flag, or a single attach acknowledgement cannot grant a lease.
struct AirRecordKeepAliveLease {
    private(set) var session: UUID?
    private var hostAttached = false
    private var helperAttached = false
    private var helperTraced = false
    private var heartbeat: TimeInterval?

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
                                    helperTraced: Bool, now: TimeInterval) {
        guard self.session == session, now.isFinite,
              heartbeat.map({ now >= $0 }) ?? true else { return }
        // Negative evidence revokes immediately; an earlier positive heartbeat
        // must never mask a debugger disconnect.
        self.hostAttached = hostAttached
        self.helperTraced = helperTraced
        heartbeat = now
    }

    func isValid(now: TimeInterval, hostTraced: Bool) -> Bool {
        guard session != nil, hostAttached, helperAttached, helperTraced,
              hostTraced, now.isFinite, let heartbeat else { return false }
        let age = now - heartbeat
        return age >= 0 && age <= 6
    }
}
