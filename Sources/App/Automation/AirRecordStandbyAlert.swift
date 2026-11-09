// AirRec, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import Foundation
import UserNotifications

@MainActor
final class AirRecordStandbyAlert: ObservableObject {
    static let shared = AirRecordStandbyAlert()

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: AirRecordStandbyAlert.preferenceKey)
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var needsPermission = false

    private static let preferenceKey = "AirRecord.standbyAlert.enabled"
    private static let notificationID = "AirRecord.standbyAlert"
    private static let statusNotificationID = "AirRecord.monitoringStatus"
    private static let statusReminderKey = "AirRecord.monitoringStatus.reminder"
    private static let graceSeconds = 180
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var deadline: ContinuousClock.Instant?

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isRequestingPermission else { return }
        if enabled {
            isRequestingPermission = true
            defer { isRequestingPermission = false }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            needsPermission = !granted
            guard granted else { return }
        } else {
            disarm()
            resetStatusReminder()
            needsPermission = false
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        await refreshPermission()
    }

    func refreshPermission() async {
        guard isEnabled || needsPermission else { return }
        let settings = await center.notificationSettings()
        guard !Task.isCancelled, !isRequestingPermission, isEnabled || needsPermission else { return }
        needsPermission = settings.alertSetting != .enabled
    }

    func remindToOpenAirRec() async {
        guard isEnabled, !Task.isCancelled, defaults.string(forKey: Self.statusReminderKey) == nil else { return }
        let token = UUID().uuidString
        defaults.set(token, forKey: Self.statusReminderKey)
        let request = notification(id: Self.statusNotificationID, title: "AirRec을 열어 주세요",
                                   body: "통화 감시가 대기 중이에요. AirRec을 열어 자동 녹음을 준비해 주세요.", delay: 1)
        do {
            try await center.add(request)
        } catch {
            if defaults.string(forKey: Self.statusReminderKey) == token {
                defaults.removeObject(forKey: Self.statusReminderKey)
            }
            airRecordLog("AirRec monitoring reminder failed: \(error.localizedDescription)")
        }
    }

    func resetStatusReminder() {
        guard defaults.string(forKey: Self.statusReminderKey) != nil else { return }
        defaults.removeObject(forKey: Self.statusReminderKey)
        center.removePendingNotificationRequests(withIdentifiers: [Self.statusNotificationID])
    }

    func arm() {
        guard isEnabled, deadline == nil else { return }
        scheduleCheck()
    }

    func refresh() {
        guard isEnabled else { return }
        // Recover a missed background transition. Once a check is due, keep it
        // one-shot until the app returns to the foreground and disarms it.
        if let deadline, ContinuousClock.now >= deadline { return }
        scheduleCheck()
    }

    func reportTermination() {
        guard let deadline, ContinuousClock.now < deadline else { return }
        self.deadline = nil
        schedule(title: "AirRec이 꺼졌어요", body: "자동 녹음을 다시 준비하려면 AirRec을 열어 주세요.", delay: 1)
    }

    func disarm() {
        deadline = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func scheduleCheck() {
        deadline = ContinuousClock.now.advanced(by: .seconds(Self.graceSeconds))
        schedule(title: "AirRec 상태를 확인해 주세요",
                 body: "백그라운드에서 AirRec의 동작을 확인하지 못했어요. 앱을 열어 주세요.",
                 delay: TimeInterval(Self.graceSeconds))
    }

    private func schedule(title: String, body: String, delay: TimeInterval) {
        // The same identifier replaces the pending check or termination alert.
        let request = notification(id: Self.notificationID, title: title, body: body, delay: delay)
        center.add(request) { error in
            if let error { airRecordLog("AirRec standby notification failed: \(error.localizedDescription)") }
        }
    }

    private func notification(id: String, title: String, body: String, delay: TimeInterval) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
#endif
