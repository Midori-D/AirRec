// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import Foundation

/// Receipts record that each action was invoked, not its result or caller name.
@MainActor
final class AirRecordShortcutPresence: ObservableObject {
    static let shared = AirRecordShortcutPresence()

    @Published private(set) var lastActionRunAt: Date?
    @Published private(set) var lastEndActionRunAt: Date?
    @Published private(set) var lastIncomingEndActionRunAt: Date?

    private let defaults: UserDefaults
    private static let actionKey = "AirRecord.shortcuts.outgoing.lastActionRunAt"
    private static let endActionKey = "AirRecord.shortcuts.callEnd.lastActionRunAt"
    private static let incomingEndActionKey = "AirRecord.shortcuts.incomingCallEnd.lastActionRunAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastActionRunAt = defaults.object(forKey: Self.actionKey) as? Date
        lastEndActionRunAt = defaults.object(forKey: Self.endActionKey) as? Date
        lastIncomingEndActionRunAt = defaults.object(forKey: Self.incomingEndActionKey) as? Date
    }

    func recordActionRun() {
        let now = Date()
        lastActionRunAt = now
        defaults.set(now, forKey: Self.actionKey)
    }

    func recordEndActionRun() {
        let now = Date()
        lastEndActionRunAt = now
        defaults.set(now, forKey: Self.endActionKey)
    }

    func recordIncomingEndActionRun() {
        let now = Date()
        lastIncomingEndActionRunAt = now
        defaults.set(now, forKey: Self.incomingEndActionKey)
    }
}
#endif
