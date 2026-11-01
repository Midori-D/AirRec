// Copyright 2026 CallTap contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import CallKit
import Darwin
import Foundation
import UIKit

/// Reads the existing lock state; this never unlocks, synthesizes input, or
/// starts XCTest. A registration/read failure is treated as locked.
private final class AirRecordLockState: @unchecked Sendable {
    private let token: Int32

    init() {
        var value: Int32 = -1
        let result = notify_register_check("com.apple.springboard.lockstate", &value)
        token = result == 0 ? value : -1
    }

    var isUnlocked: Bool {
        guard token >= 0 else { return false }
        var state = UInt64.max
        return notify_get_state(token, &state) == 0 && state == 0
    }

    deinit {
        if token >= 0 { _ = notify_cancel(token) }
    }
}

/// The worker's synchronous callbacks access only this locked state. CallKit
/// snapshots are updated on the main actor; UIKit is never read on the worker.
private final class AirRecordAutomationGate: @unchecked Sendable {
    struct Inspection {
        let generation: UInt64
        let callID: UUID
        let mayOpenMore: Bool
    }

    private let lock = NSLock()
    private let lockState = AirRecordLockState()
    private var enabled = false
    private var generation: UInt64 = 0
    private var calls: [AirRecordCallState] = []
    private var policy = AirRecordPolicy()
    private var moreReservations: Set<UUID> = []
    private var deadlines: [UUID: TimeInterval] = [:]

    func update(_ calls: [AirRecordCallState]) {
        lock.lock()
        defer { lock.unlock() }
        self.calls = calls
        let active = Set(calls.filter { !$0.hasEnded }.map(\.id))
        moreReservations.formIntersection(active)
        deadlines = deadlines.filter { active.contains($0.key) }
    }

    func start(preservingWindows: Bool = false) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        enabled = true
        if !preservingWindows {
            policy.resume()
            deadlines.removeAll()
        }
        return generation
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        enabled = false
        generation &+= 1
    }

    func decision() -> (AirRecordPolicy.Decision, Inspection?) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let decision = policy.decision(calls: calls, enabled: enabled, now: now)
        guard case .inspect(let id) = decision else { return (decision, nil) }
        if deadlines[id] == nil { deadlines[id] = now + 20 }
        return (decision, Inspection(generation: generation, callID: id,
                                     mayOpenMore: !moreReservations.contains(id)))
    }

    private func permitsLocked(_ inspection: Inspection) -> Bool {
        let active = calls.filter { !$0.hasEnded }
        return enabled && generation == inspection.generation
            && active.count == 1 && active[0].id == inspection.callID
            && active[0].hasConnected && !active[0].isOnHold
            && deadlines[inspection.callID].map { ProcessInfo.processInfo.systemUptime <= $0 } == true
            && lockState.isUnlocked
    }

    func permits(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return permitsLocked(inspection)
    }

    func reserveMore(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permitsLocked(inspection), !moreReservations.contains(inspection.callID) else { return false }
        guard let deadline = policy.reserveMenuWindow(for: inspection.callID, calls: calls,
                                                       now: ProcessInfo.processInfo.systemUptime) else { return false }
        deadlines[inspection.callID] = deadline
        // Reservation remains spent even if the subsequent request is ambiguous.
        moreReservations.insert(inspection.callID)
        return true
    }

    func reserveStart(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permitsLocked(inspection) else { return false }
        return policy.reserveStart(for: inspection.callID, calls: calls)
    }

    func isCurrent(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && generation == inspection.generation
    }

    func startWasReserved(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return policy.reservedStarts.contains(inspection.callID)
    }

    func markAlreadyRecording(_ inspection: Inspection) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, generation == inspection.generation else { return }
        policy.markAlreadyRecording(inspection.callID)
    }
}

@MainActor
final class AirRecordMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = AirRecordMonitor()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var status = "자동 시작이 꺼져 있습니다."
    @Published private(set) var recentEvents: [String] = []

    var diagnosticSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return (["AirRecord \(version)", "자동 시작 설정: \(isEnabled ? "켜짐" : "꺼짐")",
                 "감시 상태: \(isRunning ? "실행 중" : "대기/중지")",
                 "장시간 대기 설정: \(standby.isEnabled ? "켜짐" : "꺼짐")",
                 "위치 대기: \(standby.status)",
                 "위치 권한: \(standby.authorizationText)",
                 "위치 표시: \(standby.indicatorStatusText)",
                 "백그라운드 앱 새로 고침: \(standby.backgroundRefreshStatusText)",
                 "저전력 모드: \(standby.lowPowerModeEnabled ? "켜짐" : "꺼짐")",
                 "마지막 실행 점검: \(lastStandbyCheck.map { $0.formatted(date: .omitted, time: .standard) } ?? "없음")"] + recentEvents).joined(separator: "\n")
    }

    private let observer = CXCallObserver()
    private let gate = AirRecordAutomationGate()
    private let standby = AirRecordLocationKeepAlive.shared
    private var timer: Timer?
    private var standbyTimer: Timer?
    private var lastStandbyCheck: Date?
    private var workerIsRunning = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var preparationID = UUID()
    private var shortcutPreparation: Task<Bool, Never>?
    private var shortcutPreparationID: UUID?
    private let defaults: UserDefaults
    private static let enabledKey = "CallTap.RawAX.autoStartEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        super.init()
        standby.onStopped = { [weak self] message in
            guard let self, self.isRunning || self.isPreparing else { return }
            self.pause(message: message + " 자동 시작 설정은 유지됩니다.")
        }
        standby.onEvent = { [weak self] message in self?.recordEvent("위치 대기: " + message) }
        if isEnabled { status = "자동 시작 설정이 유지되어 있습니다. 연결을 확인하면 재개합니다." }
    }

    func start() async {
        if shortcutPreparation != nil {
            pause(message: "앱에서 통화 감시 준비를 다시 시작합니다.")
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        await prepare()
    }

    func resumeIfEnabled() async {
        standby.refreshEnvironment()
        guard isEnabled, UIApplication.shared.applicationState == .active else { return }
        noteStandbyProgress()
        await prepare()
    }

    func setLocationStandbyEnabled(_ enabled: Bool) async {
        // Revoke any in-flight input before changing execution support. The
        // call policy retains all recording reservations across this restart.
        pause(message: "장시간 대기 설정을 변경합니다.")
        standby.setEnabled(enabled)
        guard !Task.isCancelled else { return }
        let request = preparationID
        // Ask on this explicit toggle before checking the main switch, pairing,
        // or VPN. Permission-only preparation never turns the main switch on.
        let plan = standby.requestBackgroundAuthorizationIfNeeded(monitoringEnabled: isEnabled)
        if plan.requiresPermissionDecision && isEnabled {
            setStatus(standby.status)
            let ready = await standby.waitForBackgroundAuthorizationDecision {
                self.preparationID == request && self.isEnabled && self.standby.isEnabled
            }
            // Off/Stop, another activation, or cancellation supersedes this
            // caller; its late permission result must not start a new engine.
            guard preparationID == request, isEnabled, standby.isEnabled, !Task.isCancelled else { return }
            if ready { await prepare() }
            else { setStatus(standby.status) }
        } else if plan.shouldPrepareMonitoring {
            await prepare()
        } else if isEnabled && enabled {
            setStatus(standby.status)
        }
    }

    /// A user-configured Shortcut may rearm this process without switching
    /// away from Phone. It does not turn a saved OFF preference back on.
    func resumeFromShortcut() async -> Bool {
        guard isEnabled, !Task.isCancelled else {
            if !isEnabled { setStatus("앱에서 자동 시작을 먼저 켜 주세요.") }
            return false
        }
        let request: UUID
        let preparation: Task<Bool, Never>
        if let existing = shortcutPreparation, let id = shortcutPreparationID {
            request = id
            preparation = existing
        } else {
            request = UUID()
            let task = Task { @MainActor in
                guard self.isEnabled, !Task.isCancelled else { return false }
                // Refresh even a running lease: it may be about to expire.
                // The same gate/policy retains all prior one-shot reservations.
                self.pause(message: "단축어에서 VPN 연결과 통화 감시를 다시 준비합니다.",
                           preservingShortcutPreparation: true, preservingLocation: true)
                await self.prepare(retryTunnelFor: 8)
                return self.isEnabled && self.isRunning && !Task.isCancelled
            }
            shortcutPreparationID = request
            shortcutPreparation = task
            preparation = task
        }
        let ready = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.shortcutPreparationID == request else { return }
                self.pause(message: "단축어의 감시 준비를 취소했습니다. 자동 시작 설정은 유지됩니다.")
            }
        }
        if Task.isCancelled, shortcutPreparationID == request {
            pause(message: "단축어의 감시 준비를 취소했습니다. 자동 시작 설정은 유지됩니다.")
        }
        if shortcutPreparationID == request {
            shortcutPreparation = nil
            shortcutPreparationID = nil
        }
        return ready && isEnabled && isRunning && !Task.isCancelled
    }

    private func prepare(retryTunnelFor: TimeInterval = 8) async {
        guard isEnabled, !isRunning, !isPreparing else { return }
        isPreparing = true
        let request = UUID()
        preparationID = request
        defer {
            // A canceled foreground task must release preparation and location
            // support, without allowing an old task to stop a newer request.
            if preparationID == request && isPreparing && Task.isCancelled {
                pause(message: "통화 감시 준비를 취소했습니다. 자동 시작 설정은 유지됩니다.")
            }
        }
        setStatus("페어링 파일과 기기 연결을 확인하고 있습니다.")
        guard PairingFileStore.exists else {
            isPreparing = false
            setStatus("실행 준비에서 페어링 파일을 먼저 가져오세요.")
            return
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, retryTunnelFor)
        var probe: LocalDevVPN.TunnelProbe
        repeat {
            guard preparationID == request, isPreparing, isEnabled, !Task.isCancelled else { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let timeout = retryTunnelFor > 0 ? min(1.5, max(0.1, remaining)) : 1.5
            probe = await LocalDevVPN.probeTunnel(timeout: timeout)
            guard preparationID == request, isPreparing else { return }
            if probe == .reachable || probe == .localNetworkDenied { break }
            if retryTunnelFor <= 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { break }
        } while true
        guard preparationID == request, isPreparing else { return }
        guard isEnabled, !Task.isCancelled else { isPreparing = false; return }
        switch probe {
        case .reachable: break
        case .localNetworkDenied:
            isPreparing = false
            setStatus("설정에서 AirRecord의 로컬 네트워크 접근을 허용하세요.")
            return
        case .unreachable:
            isPreparing = false
            setStatus("LocalDevVPN을 연결한 뒤 다시 시작하세요.")
            return
        }

        if standby.isEnabled {
            setStatus("위치 서비스로 장시간 대기를 준비하고 있습니다.")
            let ready = await standby.startIfEnabled()
            guard preparationID == request, isPreparing, isEnabled, !Task.isCancelled else { return }
            guard ready, standby.isRunning else {
                isPreparing = false
                setStatus(standby.status)
                return
            }
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AirRecord AX") { [weak self] in
            // UIKit invokes expiration on the main actor. End its assertion
            // synchronously, and never let an old expiration pause a new run.
            guard let self, self.preparationID == request else { return }
            self.endBackgroundLease()
            if self.standby.isEnabled && self.standby.isRunning {
                self.recordEvent("일반 백그라운드 시간은 끝났으며 위치 대기 세션을 유지합니다.")
                return
            }
            self.pause(message: "자동 시작 설정은 켜져 있습니다. iOS가 감시를 일시 중단했으며 앱으로 돌아오면 자동 재개합니다.")
            if UIApplication.shared.applicationState == .active {
                Task { await self.resumeIfEnabled() }
            }
        }
        guard backgroundTask != .invalid || (standby.isEnabled && standby.isRunning) else {
            isPreparing = false
            setStatus("백그라운드 실행 시간을 받지 못했습니다. 잠시 후 다시 켜 주세요.")
            return
        }

        observer.setDelegate(self, queue: .main)
        updateCalls()
        _ = gate.start()
        isPreparing = false
        isRunning = true
        startStandbyChecks()
        setStatus(waitingStatus)
        evaluate()
    }

    func stop() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        pause(message: "자동 시작을 껐습니다. 이미 시작된 기본 녹음은 통화 화면에서 중지할 수 있습니다.")
    }

    private func pause(message: String, preservingShortcutPreparation: Bool = false,
                       preservingLocation: Bool = false) {
        if !preservingShortcutPreparation {
            // Revoke the ID before cancellation: an old cancellation handler
            // must never match and pause a later manual or foreground run.
            let previous = shortcutPreparation
            shortcutPreparation = nil
            shortcutPreparationID = nil
            previous?.cancel()
        }
        preparationID = UUID()
        gate.stop() // Invalidates worker callbacks before touching UI/task state.
        isRunning = false
        isPreparing = false
        timer?.invalidate()
        timer = nil
        standbyTimer?.invalidate()
        standbyTimer = nil
        observer.setDelegate(nil, queue: nil)
        endBackgroundLease()
        if !preservingLocation { standby.stop() }
        setStatus(message)
        // Never join a blocking network worker on the main actor. Its callbacks
        // now refuse input, and the client's bounded operation closes normally.
    }

    private func endBackgroundLease() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private var waitingStatus: String {
        (standby.isEnabled && standby.isRunning) ? "통화 연결을 기다립니다. 위치 서비스를 이용한 장시간 대기 중입니다."
            : "통화 연결을 기다립니다. 백그라운드 허용 시간 안에서 동작합니다."
    }

    private func startStandbyChecks() {
        standbyTimer?.invalidate()
        standbyTimer = nil
        guard standby.isEnabled, standby.isRunning else { return }
        lastStandbyCheck = Date()
        // Diagnostic only. This timer does not request background runtime or
        // treat a stationary location-update interval as a session failure.
        let check = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.noteStandbyProgress() }
        }
        standbyTimer = check
        RunLoop.main.add(check, forMode: .common)
    }

    private func noteStandbyProgress() {
        guard isRunning, standby.isEnabled else { return }
        let now = Date()
        if let lastStandbyCheck, now.timeIntervalSince(lastStandbyCheck) > 75 {
            recordEvent("대기 실행 점검에 \(Int(now.timeIntervalSince(lastStandbyCheck)))초 공백이 있었습니다. 공백 중 감시 여부는 확인되지 않았습니다.")
        }
        lastStandbyCheck = now
        if !standby.isRunning {
            pause(message: "위치 대기 세션이 중지되어 통화 감시를 일시 중지했습니다. 자동 시작 설정은 유지됩니다.")
        }
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in self?.evaluate() }
    }

    private func updateCalls() {
        gate.update(observer.calls.map {
            AirRecordCallState(id: $0.uuid, hasConnected: $0.hasConnected,
                             hasEnded: $0.hasEnded, isOnHold: $0.isOnHold)
        })
    }

    private func evaluate() {
        guard isRunning else { return }
        if standby.isEnabled && !standby.isRunning {
            pause(message: standby.status + " 자동 시작 설정은 유지됩니다.")
            return
        }
        updateCalls()
        guard !workerIsRunning else { return }
        let (decision, inspection) = gate.decision()
        if case .inspect = decision {
            setInspectionPolling(true)
        } else {
            setInspectionPolling(false)
        }
        switch decision {
        case .inspect:
            guard let inspection else { return }
            guard gate.permits(inspection) else {
                setStatus("잠금을 해제하고 기본 통화 화면을 열어 두세요.")
                return
            }
            inspect(inspection)
        case .expired:
            setStatus("이번 통화의 준비 시간이 끝났습니다. 자동으로 다시 누르지 않습니다.")
        case .multipleCalls:
            setStatus("활성 통화가 여럿이어서 자동 시작을 건너뜁니다.")
        case .held:
            setStatus("보류 중인 통화에서는 자동 시작하지 않습니다.")
        case .connecting:
            setStatus("통화가 연결되기를 기다립니다.")
        case .noCall:
            setStatus(waitingStatus)
        default: break
        }
    }

    private func setInspectionPolling(_ enabled: Bool) {
        guard enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func inspect(_ inspection: AirRecordAutomationGate.Inspection) {
        workerIsRunning = true
        let gate = self.gate
        let pairingPath = PairingFileStore.storedURL.path
        // At most one worker exists, including across stop/start. A dedicated
        // thread avoids the small Swift concurrency worker stack used by FFI.
        let thread = Thread { [weak self] in
            let result: Result<AirRecordAXOutcome, Error>
            do {
                result = .success(try AirRecordAXClient.inspectAndAct(
                    pairingPath: pairingPath, mayOpenMore: inspection.mayOpenMore,
                    shouldContinue: { gate.permits(inspection) },
                    reserveMore: { gate.reserveMore(inspection) },
                    reserveStart: { gate.reserveStart(inspection) }))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                self?.didInspect(result, inspection: inspection)
            }
        }
        thread.name = "airrecord.ax.inspect"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func didInspect(_ result: Result<AirRecordAXOutcome, Error>,
                            inspection: AirRecordAutomationGate.Inspection) {
        workerIsRunning = false
        guard gate.isCurrent(inspection), isRunning else {
            if isRunning { evaluate() }
            return
        }
        switch result {
        case .success(.waiting(let detail)):
            setStatus(detail)
        case .success(.openedMore):
            setStatus("더 보기를 열었습니다. 보이는 통화 녹음 항목을 확인합니다.")
        case .success(.startSubmitted):
            setStatus("녹음 요청은 전달됐지만 시작 표식을 자동 확인하지 못했습니다. 실제 타이머를 확인하세요. 이번 통화에는 다시 누르지 않습니다.")
        case .success(.alreadyRecording):
            gate.markAlreadyRecording(inspection)
            setStatus("이미 녹음 중이어서 자동 시작을 건너뛰었습니다.")
        case .success(.recordingConfirmed):
            gate.markAlreadyRecording(inspection)
            setStatus("기본 전화 화면에서 녹음 중 상태를 확인했습니다.")
        case .failure(let error):
            // Never emit native exception text: it can contain private UI text.
            if gate.startWasReserved(inspection) {
                setStatus("녹음 시작 요청의 결과를 확인하지 못했습니다. 이번 통화에는 다시 누르지 않습니다.")
            } else {
                setStatus("통화 화면 검사에 실패했습니다. 준비 시간 안에서 다시 확인합니다.")
            }
            if let detail = AirRecordAXClient.diagnostic(for: error) {
                recordEvent("접근성 검사: \(detail)")
            }
        }
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
        recordEvent(value)
    }

    private func recordEvent(_ value: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        recentEvents.append("[\(time)] \(value)")
        if recentEvents.count > 12 { recentEvents.removeFirst(recentEvents.count - 12) }
        airRecordLog("AirRecord: \(value)")
    }
}
#endif
