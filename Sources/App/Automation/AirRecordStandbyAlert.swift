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
    private static let graceSeconds = 180
    private let center = UNUserNotificationCenter.current()
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
            needsPermission = false
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
    }

    func arm() {
        guard isEnabled, deadline == nil else { return }
        scheduleCheck()
    }

    func refresh() {
        guard let deadline, ContinuousClock.now < deadline else { return }
        scheduleCheck()
    }

    func reportTermination() {
        guard let deadline, ContinuousClock.now < deadline else { return }
        self.deadline = nil
        schedule(title: "AirRec이 꺼졌어요", body: "자동 녹음을 다시 준비하려면 AirRec을 열어 주세요.", trigger: nil)
    }

    func disarm() {
        deadline = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func scheduleCheck() {
        deadline = ContinuousClock.now.advanced(by: .seconds(Self.graceSeconds))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(Self.graceSeconds), repeats: false)
        schedule(title: "AirRec 상태를 확인해 주세요",
                 body: "백그라운드에서 AirRec의 동작을 확인하지 못했어요. 앱을 열어 주세요.", trigger: trigger)
    }

    private func schedule(title: String, body: String, trigger: UNNotificationTrigger?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // The same identifier replaces the pending check or termination alert.
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }
}
#endif
