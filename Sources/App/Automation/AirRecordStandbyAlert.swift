// AirRec, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import Foundation
import UIKit
import UserNotifications

private let statusNotificationID = "AirRecord.monitoringStatus"

final class AirRecordNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier == statusNotificationID else { return [] }
        return [.banner, .list, .sound]
    }
}

@MainActor
final class AirRecordStandbyAlert: ObservableObject {
    static let shared = AirRecordStandbyAlert()

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: AirRecordStandbyAlert.preferenceKey)
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var needsPermission = false
    @Published private(set) var canRequestPermission = false

    private static let preferenceKey = "AirRecord.standbyAlert.enabled"
    private static let notificationID = "AirRecord.standbyAlert"
    private static let graceSeconds = 180
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var deadline: ContinuousClock.Instant?

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isRequestingPermission else { return }
        if enabled {
            guard await requestPermission() else { return }
        } else {
            disarm()
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
    }

    func requestPermission() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        updatePermission(await center.notificationSettings())
        return granted
    }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        guard !Task.isCancelled, !isRequestingPermission else { return }
        updatePermission(settings)
    }

    private func updatePermission(_ settings: UNNotificationSettings) {
        needsPermission = settings.alertSetting != .enabled
        canRequestPermission = settings.authorizationStatus == .notDetermined
    }

    func remindToOpenAirRec() async {
        let settings = await center.notificationSettings()
        guard !Task.isCancelled else { return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default:
            airRecordLog("AirRec status notification skipped: iOS authorization \(settings.authorizationStatus.rawValue)")
            return
        }
        let request = notification(id: statusNotificationID, title: "AirRec을 열어 주세요",
                                   body: "통화 감시가 멈췄어요. AirRec을 열어 자동 녹음을 준비해 주세요.", trigger: nil)
        do {
            try await center.add(request)
            airRecordLog("AirRec status notification requested")
        } catch {
            airRecordLog("AirRec status notification failed: \(error.localizedDescription)")
        }
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
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = notification(id: Self.notificationID, title: title, body: body, trigger: trigger)
        center.add(request) { error in
            if let error { airRecordLog("AirRec standby notification failed: \(error.localizedDescription)") }
        }
    }

    private func notification(id: String, title: String, body: String, trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
#endif
