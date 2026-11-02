// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import Foundation

/// A receipt is evidence of this action running, not of its caller's name.
/// Exact name checks use only the catalog explicitly passed by Shortcuts.
@MainActor
final class AirRecordShortcutPresence: ObservableObject {
    static let shared = AirRecordShortcutPresence()
    static let targetName = "AirRecord(발신)"

    @Published private(set) var lastActionRunAt: Date?
    @Published private(set) var lastEndActionRunAt: Date?
    @Published private(set) var lastNameCheckAt: Date?
    @Published private(set) var lastNameCheckFound: Bool?
    @Published private(set) var verificationNote: String?

    private let defaults: UserDefaults
    private static let actionKey = "AirRecord.shortcuts.outgoing.lastActionRunAt"
    private static let endActionKey = "AirRecord.shortcuts.callEnd.lastActionRunAt"
    private static let checkKey = "AirRecord.shortcuts.outgoing.lastNameCheckAt"
    private static let foundKey = "AirRecord.shortcuts.outgoing.lastNameCheckFound"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let checkedAt = defaults.object(forKey: Self.checkKey) as? Date
        lastActionRunAt = defaults.object(forKey: Self.actionKey) as? Date
        lastEndActionRunAt = defaults.object(forKey: Self.endActionKey) as? Date
        lastNameCheckAt = checkedAt
        lastNameCheckFound = checkedAt == nil ? nil : defaults.object(forKey: Self.foundKey) as? Bool
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

    @discardableResult
    func verify(names: [String]) -> Bool {
        guard names.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            verificationNote = "확인할 단축어 이름 목록을 연결해 주세요."
            return false
        }
        let found = names.contains(Self.targetName)
        let now = Date()
        lastNameCheckFound = found
        lastNameCheckAt = now
        verificationNote = nil
        // No shortcut catalog or individual names are stored or logged.
        defaults.set(found, forKey: Self.foundKey)
        defaults.set(now, forKey: Self.checkKey)
        airRecordLog("Shortcut catalog check: found=\(found)")
        return found
    }
}
#endif
