// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import Darwin
import Foundation
import Network
import Security
import UIKit

/// Experimental, app-owned helper only. Both processes attach to each other
/// using independent developer connections; neither process debugs itself.
@MainActor
final class AirRecordKeepAliveController: ObservableObject {
    static let shared = AirRecordKeepAliveController()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status = "백그라운드 유지 실험이 꺼져 있습니다."
    @Published private(set) var isConnected = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    var onLeaseLost: ((String) -> Void)?

    private let defaults: UserDefaults
    private static let enabledKey = "AirRecord.keepAlive.debugger.enabled"
    private var lease = AirRecordKeepAliveLease()
    private var session: UUID?
    private var nonce = ""
    private var listener: NWListener?
    private var connection: NWConnection?
    private var extensionHost: AirRecordKeepAliveExtension?
    private var requestID: UUID?
    private var pendingHello: AirRecordKeepAliveMessage?
    private var buffer = Data()
    private var worker: AirRecordDebugWorker?
    private var timer: Timer?
    private var beganAt: TimeInterval = 0
    private var configured = false
    private var helperLaunchStarted = false
    private var pairingData: Data?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var retiring: [UUID: () -> Void] = [:]
    private var cleanupSessions: Set<UUID> = []

    var isLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
    }

    var hasLiveLease: Bool {
        isConnected && connection != nil
            && lease.isValid(now: ProcessInfo.processInfo.systemUptime,
                             hostTraced: airrecord_process_is_traced())
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if isEnabled { status = "유지 설정이 저장돼 있습니다. 앱에서 연결을 시작하세요." }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { stop() }
    }

    func ensureStarted() async -> Bool {
        if isStopping { await withCheckedContinuation { cleanupWaiters.append($0) } }
        guard isEnabled else { return false }
        if hasLiveLease { return true }
        if isStarting {
            return await withCheckedContinuation { waiters.append($0) }
        }
        if session != nil {
            stop()
            if isStopping { await withCheckedContinuation { cleanupWaiters.append($0) } }
            guard isEnabled else { return false }
        }
        guard !isLiveContainer else {
            status = "LiveContainer에서는 Helper 확장이 등록되지 않습니다. SideStore 독립 설치가 필요합니다."
            return false
        }
        guard UIApplication.shared.applicationState == .active else {
            status = "AirRecord를 열어 Helper 연결을 먼저 시작하세요."
            return false
        }
        guard airrecord_process_allows_debugging() else {
            status = "현재 서명에 디버그 허용(get-task-allow)이 없습니다. SideStore 서명을 확인하세요."
            return false
        }
        guard !airrecord_process_is_traced() else {
            status = "다른 디버거가 연결되어 있습니다. 기존 연결을 종료한 뒤 다시 시도하세요."
            return false
        }
        guard let data = try? Data(contentsOf: PairingFileStore.storedURL), !data.isEmpty,
              data.count < AirRecordKeepAliveWire.maximumFrameBytes / 2,
              let plugin = Bundle.main.builtInPlugInsURL,
              let bundles = try? FileManager.default.contentsOfDirectory(at: plugin, includingPropertiesForKeys: nil),
              let helper = bundles.compactMap({ Bundle(url: $0) }).first(where: {
                  $0.object(forInfoDictionaryKey: "AirRecordKeepAliveHelper") as? Bool == true
              }), let identifier = helper.bundleIdentifier else {
            status = "페어링 파일 또는 Helper 확장이 없습니다. 확장 유지로 IPA를 설치하세요."
            return false
        }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            status = "Helper 인증 자료를 만들지 못했습니다."
            return false
        }
        let id = UUID()
        session = id
        nonce = random.map { String(format: "%02x", $0) }.joined()
        pairingData = data
        beganAt = ProcessInfo.processInfo.systemUptime
        lease.begin(id)
        isStarting = true
        status = "Helper와 양방향 개발자 연결을 준비합니다. 완료될 때까지 앱을 열어 두세요."
        do {
            extensionHost = try AirRecordKeepAliveExtension(bundleIdentifier: identifier)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, session: id) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else { self.fail("Helper 통신 포트를 열지 못했습니다."); return }
                        self.launchHelper(port: port.rawValue, session: id)
                    case .failed: self.fail("Helper 내부 통신을 시작하지 못했습니다.")
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkHealth(session: id) }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            fail("Helper를 실행하지 못했습니다. SideStore에서 확장을 유지했는지 확인하세요.")
            return false
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func launchHelper(port: UInt16, session id: UUID) {
        guard session == id, !helperLaunchStarted else { return }
        helperLaunchStarted = true
        extensionHost?.cancellationHandler = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                self.fail("시스템이 Helper 요청을 취소했습니다.")
            }
        }
        extensionHost?.interruptionHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                self.fail("Helper 실행이 중단됐습니다.")
            }
        }
        let item = NSExtensionItem()
        item.userInfo = ["hostPID": NSNumber(value: getpid()), "port": NSNumber(value: port),
                         "nonce": nonce, "session": id.uuidString]
        extensionHost?.begin(items: [item]) { [weak self] request, _ in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                guard let request else { self.fail("Helper 요청을 만들지 못했습니다."); return }
                self.requestID = request
                self.configureIfReady(session: id)
            }
        }
    }

    private func accept(_ candidate: NWConnection, session id: UUID) {
        guard session == id, connection == nil else { candidate.cancel(); return }
        connection = candidate
        candidate.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                switch state {
                case .ready: self.receive(session: id)
                case .failed, .cancelled: self.fail("Helper 내부 연결이 끊겼습니다.")
                default: break
                }
            }
        }
        candidate.start(queue: .main)
    }

    private func receive(session id: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                do {
                    if let data {
                        for message in try AirRecordKeepAliveWire.append(data, to: &self.buffer) {
                            self.received(message, session: id)
                            if self.session != id { return }
                        }
                    }
                    if complete || error != nil { self.fail("Helper 내부 연결이 종료됐습니다.") }
                    else { self.receive(session: id) }
                } catch { self.fail("Helper 응답 형식을 확인하지 못했습니다.") }
            }
        }
    }

    private func received(_ message: AirRecordKeepAliveMessage, session id: UUID) {
        guard message.session == id.uuidString, AirRecordKeepAliveWire.matchesNonce(message.nonce, nonce) else {
            fail("Helper 인증이 일치하지 않습니다."); return
        }
        switch message.type {
        case "hello":
            guard !configured, pendingHello == nil else { fail("중복 Helper 요청을 거절했습니다."); return }
            pendingHello = message
            configureIfReady(session: id)
        case "attached":
            guard configured, let pid = pendingHello?.helperPID, worker == nil, let pairingData else {
                fail("Helper 연결 순서가 일치하지 않습니다."); return
            }
            lease.hostDebuggerReported(id)
            let worker = AirRecordDebugWorker(targetPID: pid, pairingData: pairingData, onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    if case .attached = event { self.lease.helperDebuggerReported(id); self.checkHealth(session: id) }
                }
            }, onCompletion: { [weak self] failure in
                Task { @MainActor in
                    guard let self else { return }
                    if let cleanup = self.retiring.removeValue(forKey: id) { cleanup(); return }
                    guard self.session == id else { return }
                    let code = failure.map { " (코드 \($0.code))" } ?? ""
                    self.fail("Helper를 유지하는 디버거 연결이 종료됐습니다.\(code)")
                }
            })
            self.worker = worker
            worker.start()
        case "heartbeat":
            guard configured else { fail("인증 전 Helper 상태 응답을 거절했습니다."); return }
            lease.receivedHeartbeat(id, hostAttached: message.hostAttached == true,
                                    helperTraced: message.selfTraced == true,
                                    now: ProcessInfo.processInfo.systemUptime)
            checkHealth(session: id)
        case "error":
            fail("Helper 개발자 연결에 실패했습니다. (코드 \(message.errorCode ?? -1))")
        case "stopped": fail("Helper가 연결을 종료했습니다.")
        default: fail("알 수 없는 Helper 응답을 거절했습니다.")
        }
    }

    private func configureIfReady(session id: UUID) {
        guard session == id, !configured, let hello = pendingHello, let requestID,
              let extensionHost, let data = pairingData else { return }
        let registeredPID = extensionHost.pid(for: requestID)
        guard registeredPID > 1, UInt32(registeredPID) == hello.helperPID,
              registeredPID != getpid(), hello.allowsDebugging == true else {
            fail("등록된 Helper 프로세스 또는 디버그 서명을 확인하지 못했습니다."); return
        }
        configured = true
        listener?.cancel()
        listener = nil
        send(AirRecordKeepAliveMessage(type: "configure", session: id.uuidString, nonce: nonce,
                                      hostPID: UInt32(getpid()), pairing: data.base64EncodedString()))
    }

    private func send(_ message: AirRecordKeepAliveMessage) {
        guard let connection, let data = try? AirRecordKeepAliveWire.encode(message) else {
            fail("Helper 요청을 만들지 못했습니다."); return
        }
        let id = session
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    self.fail("Helper 요청 전송에 실패했습니다.")
                }
            }
        })
    }

    private func checkHealth(session id: UUID) {
        guard session == id else { return }
        let valid = lease.isValid(now: ProcessInfo.processInfo.systemUptime,
                                  hostTraced: airrecord_process_is_traced())
        if valid {
            if !isConnected {
                isConnected = true
                isStarting = false
                status = "앱·Helper의 실제 디버거 연결이 유지 중입니다. 장시간 실기기 검증은 필요합니다."
                finishWaiters(true)
            }
        } else if isConnected {
            fail("디버거 연결 또는 Helper 응답이 끊겨 감시를 중지했습니다.")
        } else if ProcessInfo.processInfo.systemUptime - beganAt > 60 {
            fail("Helper 연결 준비 시간이 끝났습니다. VPN·개발자 디스크·서명을 확인하세요.")
        }
    }

    private func finishWaiters(_ result: Bool) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    private func fail(_ message: String) {
        let wasConnected = isConnected
        // Revoke input before asynchronous debugger/extension cleanup begins.
        if wasConnected { onLeaseLost?(message) }
        stop()
        status = message
    }

    func stop() {
        // Invalidating the ID first makes late network/FFI callbacks harmless.
        let oldID = session
        session = nil
        lease.invalidate()
        isConnected = false
        isStarting = false
        timer?.invalidate()
        timer = nil
        finishWaiters(false)
        let oldWorker = worker
        worker = nil
        let oldConnection = connection
        let oldExtension = extensionHost
        let oldRequest = requestID
        connection = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        requestID = nil
        extensionHost = nil
        pendingHello = nil
        pairingData = nil
        buffer.removeAll(keepingCapacity: false)
        nonce = ""
        configured = false
        helperLaunchStarted = false
        status = isEnabled ? "백그라운드 유지 연결이 대기 중입니다." : "백그라운드 유지 실험이 꺼져 있습니다."
        guard let oldID else { return }
        isStopping = true
        cleanupSessions.insert(oldID)
        let finishTransport: () -> Void = { [weak self] in
            // Serialize normal teardown and retain the old extension until
            // both connections are released. Running targets are never
            // interrupted; debugserver detaches them on stream shutdown.
            oldConnection?.stateUpdateHandler = nil
            oldConnection?.cancel()
            Task { @MainActor [weak self] in
                for _ in 0..<32 {
                    if !airrecord_process_is_traced() { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if let oldRequest { oldExtension?.cancel(request: oldRequest) }
                self?.cleanupFinished(oldID)
            }
        }
        if let oldWorker {
            retiring[oldID] = finishTransport
            oldWorker.cancel()
        } else { finishTransport() }
    }

    private func cleanupFinished(_ id: UUID) {
        cleanupSessions.remove(id)
        guard cleanupSessions.isEmpty else { return }
        isStopping = false
        let pending = cleanupWaiters
        cleanupWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
#endif
