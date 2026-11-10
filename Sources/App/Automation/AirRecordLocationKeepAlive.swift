// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import CoreLocation
import Foundation
import UIKit

/// Each manager gets its own immutable session token. Queued callbacks from an
/// old manager can therefore never authorize or resume a newer monitoring run.
private final class AirRecordLocationDelegate: NSObject, CLLocationManagerDelegate {
    let session: UUID
    let authorization: @MainActor @Sendable (UUID) -> Void
    let sample: @MainActor @Sendable (UUID, Date?) -> Void
    let failure: @MainActor @Sendable (UUID, Int) -> Void
    let paused: @MainActor @Sendable (UUID) -> Void

    init(session: UUID,
         authorization: @escaping @MainActor @Sendable (UUID) -> Void,
         sample: @escaping @MainActor @Sendable (UUID, Date?) -> Void,
         failure: @escaping @MainActor @Sendable (UUID, Int) -> Void,
         paused: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.session = session
        self.authorization = authorization
        self.sample = sample
        self.failure = failure
        self.paused = paused
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let id = session, callback = authorization
        Task { @MainActor in callback(id) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Deliberately read only freshness metadata. Coordinates, accuracy,
        // altitude, speed, and movement history are never inspected or retained.
        let timestamp = locations.last?.timestamp
        let id = session, callback = sample
        Task { @MainActor in callback(id, timestamp) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as NSError).domain == kCLErrorDomain ? (error as NSError).code : -1
        let id = session, callback = failure
        Task { @MainActor in callback(id, code) }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        let id = session, callback = paused
        Task { @MainActor in callback(id) }
    }
}

/// Optional foreground-started location session used for extended standby.
/// This is not a guarantee against iOS termination, force quit, or suspension.
@MainActor
final class AirRecordLocationKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AirRecordLocationKeepAlive()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var status = "백그라운드 AirRec 꺼짐"
    @Published private(set) var backgroundRefreshStatusText = "확인 중"
    @Published private(set) var lowPowerModeEnabled = false
    @Published private(set) var indicatorMinimizationEnabled: Bool
    @Published private(set) var authorizationText = "위치 권한 확인 중"
    @Published private(set) var isPreciseLocationEnabled: Bool?
    @Published private(set) var indicatorStatusText = "기본 위치 표시 모드"

    var hasAlwaysAuthorization: Bool { indicatorPolicy.authorization == .always }
    var hasWhenInUseAuthorization: Bool { indicatorPolicy.authorization == .whenInUse }

    var onStopped: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onReady: (() -> Void)?

    var isLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
    }

    private let defaults: UserDefaults
    private static let enabledKey = "AirRecord.locationStandby.enabled"
    private static let indicatorKey = "AirRecord.locationStandby.indicatorMinimizationEnabled"
    private var policy = AirRecordLocationSessionPolicy()
    private var indicatorPolicy = AirRecordLocationIndicatorPolicy()
    private var manager: CLLocationManager?
    private var delegateProxy: AirRecordLocationDelegate?
    // This manager only observes/requests permission. It never starts location
    // updates, reads a sample, or owns a monitoring-session generation.
    private lazy var permissionManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.showsBackgroundLocationIndicator = true
        manager.delegate = self
        return manager
    }()
    private var permissionWhenInUseRequestSent = false
    private var backgroundPermissionRequestPending = false
    private var alwaysRequestAttempted = false
    private var authorizationHint: String?
    private var updatesStarted = false
    private var authorizationRequested = false
    private var startupDeadline: TimeInterval = 0
    private var lastTransientError = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        indicatorMinimizationEnabled = defaults.bool(forKey: Self.indicatorKey)
        super.init()
        indicatorPolicy.setMinimizationEnabled(indicatorMinimizationEnabled)
        refreshEnvironment()
        if isEnabled { status = "백그라운드 AirRec 설정 유지 · 활성화 대기" }
    }

    /// Saves only the user's explicit preference. Starting and permissions are
    /// separate so a launch or background Shortcut cannot silently request them.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            stop()
            status = "백그라운드 AirRec 꺼짐"
        } else if !isRunning {
            status = "백그라운드 AirRec 준비 중"
        }
    }

    /// The background toggle is an explicit permission action even when the
    /// main feature is OFF or developer-connection prerequisites are missing.
    /// This preflight never starts location updates or requests Always access.
    func requestBackgroundAuthorizationIfNeeded(monitoringEnabled: Bool) -> AirRecordBackgroundPermissionPolicy.Plan {
        refreshAuthorizationPresentation()
        let purpose = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String ?? ""
        let plan = AirRecordBackgroundPermissionPolicy.plan(
            trigger: isEnabled ? .enabledByUser : .disabledByUser,
            monitoringEnabled: monitoringEnabled,
            authorization: backgroundPermissionAuthorization,
            requestPending: permissionWhenInUseRequestSent || authorizationRequested,
            isForeground: UIApplication.shared.applicationState == .active,
            isLiveContainer: isLiveContainer,
            hasUsageDescription: !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        switch plan.action {
        case .requestWhenInUse:
            backgroundPermissionRequestPending = true
            permissionWhenInUseRequestSent = true
            authorizationHint = nil
            status = "위치 권한 대기 · ‘앱을 사용하는 동안 허용’을 선택해 주세요."
            refreshAuthorizationPresentation()
            onEvent?("백그라운드 AirRec 위치 권한 요청")
            permissionManager.requestWhenInUseAuthorization()
        case .waitForDecision:
            backgroundPermissionRequestPending = true
            status = "위치 권한 선택 대기"
        case .showSettings:
            authorizationHint = "권한 창을 다시 표시할 수 없는 상태입니다. iOS 설정에서 위치 권한을 확인하세요."
            status = "위치 권한 없음 · iOS 설정에서 허용해 주세요."
            refreshAuthorizationPresentation()
        case .requireForeground:
            status = "위치 권한 필요 · AirRec을 열고 다시 켜 주세요."
        case .unsupportedEnvironment:
            status = "백그라운드 위치 권한 · SideStore 독립 설치 필요"
        case .missingUsageDescription:
            status = "위치 권한 설정 누락 · 새 IPA를 설치해 주세요."
        case .none:
            if isEnabled && !isRunning {
                status = "위치 권한 확인 · AirRec 연결 대기"
            }
        }
        return plan
    }

    /// Continue only the explicit caller's still-current activation. The wait is
    /// bounded and does not rely solely on a permission-sheet lifecycle event.
    func waitForBackgroundAuthorizationDecision(while shouldContinue: @MainActor () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while shouldContinue() && isEnabled && !Task.isCancelled {
            refreshAuthorizationPresentation()
            switch backgroundPermissionAuthorization {
            case .authorized:
                if UIApplication.shared.applicationState == .active { return true }
            case .denied, .restricted, .unknown:
                authorizationHint = "iOS 설정에서 위치 권한을 확인하세요. 기본 권한 요청으로 ‘항상 허용’을 자동 요청하지 않습니다."
                status = "위치 권한 미확인 · iOS 설정에서 확인해 주세요."
                refreshAuthorizationPresentation()
                return false
            case .notDetermined:
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                status = "위치 준비 시간 초과 · 권한 확인 후 홈에서 다시 활성화해 주세요."
                return false
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return false }
        }
        return false
    }

    private var backgroundPermissionAuthorization: AirRecordBackgroundPermissionPolicy.Authorization {
        switch permissionManager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    /// Changing this preference only updates the current manager's presentation
    /// request; it never restarts location, monitoring, or a call reservation.
    func setIndicatorMinimizationEnabled(_ enabled: Bool) {
        indicatorMinimizationEnabled = enabled
        defaults.set(enabled, forKey: Self.indicatorKey)
        indicatorPolicy.setMinimizationEnabled(enabled)
        refreshAuthorizationPresentation()
        onEvent?(enabled
                 ? "위치 표시 숨기기 설정 켜짐"
                 : "위치 표시 숨기기 설정 꺼짐")
    }

    /// Called only by an explicit foreground button. Authorization callbacks,
    /// launch/resume, and the runtime preparation loop never call this method.
    func requestAlwaysAuthorization() {
        guard UIApplication.shared.applicationState == .active else {
            authorizationHint = "추가 권한은 AirRec 화면을 연 상태에서 버튼을 눌러 요청하세요."
            refreshAuthorizationPresentation()
            return
        }
        guard !isLiveContainer else {
            authorizationHint = "추가 권한은 SideStore에 독립 설치한 AirRec에서 요청하세요."
            refreshAuthorizationPresentation()
            return
        }
        let current = permissionManager.authorizationStatus
        switch current {
        case .notDetermined:
            let purpose = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String ?? ""
            guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                authorizationHint = "위치 권한 설정 누락 · 새 IPA를 설치해 주세요."
                refreshAuthorizationPresentation()
                return
            }
            authorizationHint = "먼저 ‘앱을 사용하는 동안 허용’을 선택하세요. 이후 추가 권한 버튼을 다시 누르거나 iOS 설정에서 확인하세요."
            guard !permissionWhenInUseRequestSent, !authorizationRequested else {
                refreshAuthorizationPresentation()
                return
            }
            permissionWhenInUseRequestSent = true
            refreshAuthorizationPresentation()
            permissionManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            let purpose = Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") as? String ?? ""
            guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                authorizationHint = "이 설치에는 추가 위치 권한 설명이 없습니다. 새 IPA를 설치하세요."
                refreshAuthorizationPresentation()
                return
            }
            guard !alwaysRequestAttempted else {
                authorizationHint = "추가 권한을 이미 요청했습니다. 창이 나타나지 않거나 ‘한 번 허용’을 선택했다면 iOS 설정에서 현재 권한을 확인하세요."
                refreshAuthorizationPresentation()
                return
            }
            alwaysRequestAttempted = true
            authorizationHint = "추가 권한 요청을 보냈습니다. iOS가 창을 표시하지 않을 수 있으며, 현재 권한이 유지되면 iOS 설정에서 확인하세요."
            refreshAuthorizationPresentation()
            permissionManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            authorizationHint = nil
            refreshAuthorizationPresentation()
        case .denied, .restricted:
            authorizationHint = "iOS 설정에서 위치 권한을 확인하세요. 앱에서 추가 권한 창을 다시 열 수 없는 상태입니다."
            refreshAuthorizationPresentation()
        @unknown default:
            authorizationHint = "현재 권한을 확인할 수 없습니다. iOS 설정에서 확인하세요."
            refreshAuthorizationPresentation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Ignore the delivered manager's cached argument. Read current status on
        // the main actor, and never create or revive a runtime session here.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasBackgroundRequest = self.backgroundPermissionRequestPending
            self.refreshAuthorizationPresentation()
            // Permission-only completion changes presentation, never execution.
            // A stop invalidates this intent before a late callback can act.
            if wasBackgroundRequest && self.backgroundPermissionAuthorization != .notDetermined {
                self.backgroundPermissionRequestPending = false
                if self.isEnabled && self.policy.session == nil {
                    if self.backgroundPermissionAuthorization == .authorized {
                        self.status = "위치 권한 확인 · AirRec 연결 대기"
                    } else {
                        self.authorizationHint = "iOS 설정에서 위치 권한을 확인하세요. 앱에서 권한 창을 반복 표시하지 않습니다."
                        self.status = "위치 권한 없음 · iOS 설정에서 허용해 주세요."
                        self.refreshAuthorizationPresentation()
                    }
                }
            }
            if let id = self.policy.session {
                self.authorizationChanged(for: id)
            }
        }
    }

    /// A new standard-location session must start in the foreground. An
    /// existing ready session may be reused by a background Shortcut.
    func startIfEnabled() async -> Bool {
        guard isEnabled, !Task.isCancelled else { return false }
        guard !isLiveContainer else {
            fail("백그라운드 AirRec · SideStore 독립 설치 필요")
            return false
        }
        if isRunning && policy.isReady { return true }

        if policy.session == nil {
            guard UIApplication.shared.applicationState == .active else {
                status = "백그라운드 준비 · AirRec을 열어 주세요."
                return false
            }
            let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
            let purpose = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String ?? ""
            guard modes.contains("location"), !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("백그라운드 위치 설정 누락 · 새 IPA를 독립 설치해 주세요.")
                return false
            }

            let id = policy.begin()
            startupDeadline = ProcessInfo.processInfo.systemUptime + 45
            lastTransientError = false
            let proxy = AirRecordLocationDelegate(
                session: id,
                authorization: { [weak self] in self?.authorizationChanged(for: $0) },
                sample: { [weak self] in self?.receivedSample(for: $0, timestamp: $1) },
                failure: { [weak self] in self?.receivedFailure(for: $0, code: $1) },
                paused: { [weak self] in self?.receivedPause(for: $0) })
            let locationManager = CLLocationManager()
            locationManager.delegate = proxy
            locationManager.activityType = .other
            locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.allowsBackgroundLocationUpdates = true
            manager = locationManager
            delegateProxy = proxy
            reportEnvironment()
            authorizationChanged(for: id)
        }

        guard let id = policy.session else { return false }
        while isEnabled && policy.matches(id) {
            if Task.isCancelled {
                fail("백그라운드 준비 취소 · 설정 유지")
                return false
            }
            // Closing the system permission sheet can deliver authorization
            // while UIApplication is briefly inactive. Start only after the
            // foreground becomes active; do not misclassify that as background.
            if !updatesStarted, UIApplication.shared.applicationState == .active {
                authorizationChanged(for: id)
            }
            guard policy.matches(id), isEnabled else { return false }
            if isRunning && policy.isReady { return true }
            if ProcessInfo.processInfo.systemUptime >= startupDeadline {
                fail("위치 서비스 응답 시간 초과 · 권한과 위치 서비스를 확인해 주세요.")
                return false
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch {
                if policy.matches(id) { fail("백그라운드 준비 취소 · 설정 유지") }
                return false
            }
        }
        return false
    }

    /// Ends the runtime session while retaining the explicit saved preference.
    /// Owner-initiated cleanup does not recursively call onStopped.
    func stop() {
        endSession()
        status = isEnabled ? "백그라운드 AirRec 중지됨" : "백그라운드 AirRec 꺼짐"
    }

    private func authorizationChanged(for id: UUID) {
        guard isEnabled, policy.matches(id), let manager else { return }
        // Apply immediately even to an already-started session: revoking Always
        // must restore the indicator before the updatesStarted early return.
        refreshAuthorizationPresentation()
        switch manager.authorizationStatus {
        case .notDetermined:
            guard UIApplication.shared.applicationState != .background else {
                fail("위치 권한 필요 · AirRec을 열고 허용해 주세요.")
                return
            }
            guard UIApplication.shared.applicationState == .active else {
                status = "위치 권한 요청 · AirRec 화면 대기"
                return
            }
            status = "위치 권한 요청 · ‘앱을 사용하는 동안 허용’을 선택해 주세요."
            guard !authorizationRequested, !permissionWhenInUseRequestSent else { return }
            authorizationRequested = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !updatesStarted else { return }
            guard UIApplication.shared.applicationState != .background else {
                fail("위치 서비스 시작 중단 · AirRec을 다시 열어 주세요.")
                return
            }
            guard UIApplication.shared.applicationState == .active else {
                status = "위치 권한 확인 · AirRec 화면 대기"
                return
            }
            updatesStarted = true
            status = "위치 서비스 첫 응답 대기"
            manager.startUpdatingLocation()
        case .denied, .restricted:
            fail("위치 권한 없음 · iOS 설정에서 허용해 주세요.")
        @unknown default:
            fail("위치 권한 미확인 · 백그라운드 AirRec 중지")
        }
    }

    private func receivedSample(for id: UUID, timestamp: Date?) {
        guard isEnabled, updatesStarted, policy.matches(id), let timestamp, let manager else { return }
        refreshAuthorizationPresentation()
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            authorizationChanged(for: id)
            return
        }
        let wasReady = policy.isReady
        guard policy.receivedSample(for: id, now: Date().timeIntervalSince1970,
                                    sampledAt: timestamp.timeIntervalSince1970) else { return }
        isRunning = true
        lastTransientError = false
        if !wasReady {
            status = "백그라운드 AirRec 활성화됨"
            onEvent?(status)
            onReady?()
        }
    }

    private func receivedFailure(for id: UUID, code: Int) {
        guard isEnabled, policy.matches(id) else { return }
        if code == CLError.locationUnknown.rawValue {
            if !lastTransientError {
                lastTransientError = true
                onEvent?("위치 신호 일시 미확인")
            }
            return
        }
        fail(code == CLError.denied.rawValue
             ? "위치 접근 중단 · 권한을 확인해 주세요."
             : "위치 서비스 오류 · AirRec을 다시 열어 주세요.")
    }

    private func receivedPause(for id: UUID) {
        guard policy.pause(for: id) else { return }
        fail("iOS가 위치 서비스 일시 중지 · AirRec을 다시 열어 주세요.")
    }

    func refreshEnvironment() {
        refreshAuthorizationPresentation()
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: backgroundRefreshStatusText = "사용 가능"
        case .denied: backgroundRefreshStatusText = "꺼짐 또는 저전력 모드로 제한됨"
        case .restricted: backgroundRefreshStatusText = "시스템에서 제한됨"
        @unknown default: backgroundRefreshStatusText = "상태를 확인할 수 없음"
        }
    }

    private func refreshAuthorizationPresentation() {
        // Query a retained manager now rather than trusting an authorization
        // value captured in a queued callback from an earlier session.
        let locationManager = manager ?? permissionManager
        let current = locationManager.authorizationStatus
        if current != .notDetermined { permissionWhenInUseRequestSent = false }
        let authorization: AirRecordLocationIndicatorPolicy.Authorization
        let label: String
        switch current {
        case .notDetermined: authorization = .notDetermined; label = "위치 권한: 아직 선택하지 않음"
        case .authorizedWhenInUse: authorization = .whenInUse; label = "위치 권한: 앱을 사용하는 동안 허용"
        case .authorizedAlways: authorization = .always; label = "위치 권한: 항상 허용"
        case .denied: authorization = .denied; label = "위치 권한: 허용 안 됨"
        case .restricted: authorization = .restricted; label = "위치 권한: 시스템에서 제한됨"
        @unknown default: authorization = .unknown; label = "위치 권한: 확인할 수 없음"
        }
        if current == .authorizedAlways { authorizationHint = nil }
        indicatorPolicy.updateAuthorization(authorization)
        let preciseLocationEnabled: Bool?
        if authorization == .whenInUse || authorization == .always {
            switch locationManager.accuracyAuthorization {
            case .fullAccuracy: preciseLocationEnabled = true
            case .reducedAccuracy: preciseLocationEnabled = false
            @unknown default: preciseLocationEnabled = nil
            }
        } else {
            preciseLocationEnabled = nil
        }
        if isPreciseLocationEnabled != preciseLocationEnabled {
            isPreciseLocationEnabled = preciseLocationEnabled
        }
        let showsIndicator = indicatorPolicy.showsBackgroundLocationIndicator
        manager?.showsBackgroundLocationIndicator = showsIndicator
        authorizationText = label + (authorizationHint.map { " · " + $0 } ?? "")
        if !indicatorMinimizationEnabled {
            indicatorStatusText = "기본 위치 표시 모드 · 위치 사용 표시는 iOS가 관리합니다."
        } else if !showsIndicator {
            indicatorStatusText = manager == nil
                ? "최소화 설정 저장됨 · 위치 세션 시작 시 표시 끄기를 요청합니다."
                : "위치 표시 끄기 요청 · 실제 표시와 장시간 유지는 실기기 확인이 필요합니다."
        } else {
            indicatorStatusText = "위치 표시 유지 · 실제 ‘항상 허용’ 권한이 확인되기 전에는 끄지 않습니다."
        }
    }

    private func reportEnvironment() {
        refreshEnvironment()
        if lowPowerModeEnabled {
            onEvent?("저전력 모드 켜짐")
        }
        if UIApplication.shared.backgroundRefreshStatus != .available {
            onEvent?("백그라운드 앱 새로 고침: " + backgroundRefreshStatusText)
        }
    }

    private func fail(_ message: String) {
        // Revoke readiness and tell the monitoring owner before withdrawing the
        // location session that may currently supply its background runtime.
        policy.stop()
        isRunning = false
        status = message
        onStopped?(message)
        endSession()
        status = message
        onEvent?(message)
    }

    private func endSession() {
        backgroundPermissionRequestPending = false
        policy.stop()
        isRunning = false
        updatesStarted = false
        authorizationRequested = false
        startupDeadline = 0
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        delegateProxy = nil
        refreshAuthorizationPresentation()
    }
}
#endif
