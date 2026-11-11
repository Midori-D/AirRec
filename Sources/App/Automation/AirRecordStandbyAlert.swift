// AirRec, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import Foundation
import UIKit
import UserNotifications

private let statusNotificationID = "AirRecord.monitoringStatus"
private let incomingNotificationIDPrefix = "AirRecord.incomingCall."

final class AirRecordNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        guard application.applicationState != .active,
              sceneSessions.contains(where: { $0.role == .windowApplication }),
              !application.openSessions.contains(where: {
                  $0.role == .windowApplication && !sceneSessions.contains($0)
              }),
              AirRecordMonitor.shared.isRunning else { return }
        AirRecordStandbyAlert.shared.reportTermination()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        guard AirRecordMonitor.shared.isEnabled else { return }
        AirRecordStandbyAlert.shared.reportTermination()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        if identifier == statusNotificationID { return [.banner, .list, .sound] }
        if identifier.hasPrefix(incomingNotificationIDPrefix) { return [.banner, .list] }
        return []
    }
}

@MainActor
final class AirRecordStandbyAlert: ObservableObject {
    static let shared = AirRecordStandbyAlert()
    static let incomingNotificationTitle = "AirRec 수신 감지"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: AirRecordStandbyAlert.preferenceKey)
    @Published private(set) var isIncomingEnabled = UserDefaults.standard.bool(forKey: AirRecordStandbyAlert.incomingPreferenceKey)
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var hasAlertPermission: Bool?
    @Published private(set) var canRequestPermission = false

    private static let preferenceKey = "AirRecord.standbyAlert.enabled"
    private static let incomingPreferenceKey = "AirRecord.incomingAlert.enabled"
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

    func setIncomingEnabled(_ enabled: Bool) async {
        guard enabled != isIncomingEnabled, !isRequestingPermission else { return }
        if enabled, !(await requestPermission()) { return }
        isIncomingEnabled = enabled
        defaults.set(enabled, forKey: Self.incomingPreferenceKey)
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
        hasAlertPermission = settings.alertSetting == .enabled
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

    func notifyIncomingCall(_ callID: UUID) async -> Bool {
        let settings = await center.notificationSettings()
        guard isIncomingEnabled, !Task.isCancelled else { return false }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return false
        }

        let content = UNMutableNotificationContent()
        content.title = Self.incomingNotificationTitle
        let request = UNNotificationRequest(identifier: incomingNotificationIDPrefix + callID.uuidString,
                                            content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            airRecordLog("AirRec incoming notification failed: \(error.localizedDescription)")
            return false
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
        guard isEnabled else { return }
        let now = ContinuousClock.now
        if let deadline, now >= deadline { return }

        // Treat the check as due so a second lifecycle callback or heartbeat
        // cannot overwrite this notification before iOS displays it.
        deadline = now
        schedule(title: "AirRec을 다시 열어 주세요", body: "AirRec이 종료됐어요. 자동 녹음을 다시 준비해 주세요.",
                 delay: 1, waitForSubmission: true)
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

    private func schedule(title: String, body: String, delay: TimeInterval, waitForSubmission: Bool = false) {
        // The same identifier replaces the pending check or termination alert.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = notification(id: Self.notificationID, title: title, body: body, trigger: trigger)
        let submission = waitForSubmission ? DispatchSemaphore(value: 0) : nil
        center.add(request) { error in
            submission?.signal()
            if let error { airRecordLog("AirRec standby notification failed: \(error.localizedDescription)") }
        }
        if let submission {
            // UIKit can exit as soon as its delegate returns. Allow a short
            // handoff to the notification service without blocking indefinitely.
            _ = submission.wait(timeout: .now() + .milliseconds(350))
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
