// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import Darwin
import Foundation
import IDevice

/// A single worker owns every Rust handle from creation through cleanup.
/// It never attaches to its own process or accepts an arbitrary target command.
final class AirRecordDebugWorker: @unchecked Sendable {
    enum Event { case attached, cleaningUp }
    struct Failure: LocalizedError {
        enum Stage: String { case target, pairing, tunnel, debugger, internalFailure }
        let stage: Stage
        let code: Int32
        var errorDescription: String? { "개발자 유지 연결 실패 (\(stage.rawValue), \(code))." }
    }

    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var attachedReported = false
    private var cleanupReported = false
    private var pairingData: Data?
    private let targetPID: UInt32
    private let onEvent: (Event) -> Void
    private let onCompletion: (Failure?) -> Void

    init(targetPID: UInt32, pairingData: Data,
         onEvent: @escaping (Event) -> Void,
         onCompletion: @escaping (Failure?) -> Void) {
        self.targetPID = targetPID; self.pairingData = pairingData
        self.onEvent = onEvent; self.onCompletion = onCompletion
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "airrecord.debug.keepalive"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .utility
        thread.start()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var mayContinue: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled
    }

    private func callback(_ event: UInt32) -> Bool {
        lock.lock()
        let allowed = !cancelled
        let report: Event?
        switch event {
        case 0: report = nil
        case 1:
            if allowed && !attachedReported { attachedReported = true; report = .attached }
            else { report = nil }
        case 2:
            if !cleanupReported { cleanupReported = true; report = .cleaningUp }
            else { report = nil }
        default:
            lock.unlock()
            return false
        }
        lock.unlock()
        if let report {
            let receiver = onEvent
            DispatchQueue.main.async { receiver(report) }
        }
        return event == 2 || allowed
    }

    private static let ffiCallback: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Bool = { context, event in
        guard let context else { return false }
        return Unmanaged<AirRecordDebugWorker>.fromOpaque(context).takeUnretainedValue().callback(event)
    }

    private func run() {
        let failure: Failure?
        do {
            try connectAndHold()
            failure = nil
        } catch let error as Failure {
            failure = mayContinue ? error : nil
        } catch {
            failure = mayContinue ? Failure(stage: .internalFailure, code: 0) : nil
        }
        lock.lock()
        pairingData = nil
        lock.unlock()
        let receiver = onCompletion
        DispatchQueue.main.async { receiver(failure) }
    }

    private func connectAndHold() throws {
        guard targetPID > 1, targetPID != UInt32(getpid()) else { throw Failure(stage: .target, code: 0) }
        guard mayContinue else { return }
        lock.lock()
        let bytes = pairingData
        pairingData = nil
        lock.unlock()
        guard let bytes, !bytes.isEmpty, bytes.count <= AirRecordKeepAliveWire.maximumPairingBytes else {
            throw Failure(stage: .pairing, code: 0)
        }
        var pairing: OpaquePointer?
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw Failure(stage: .pairing, code: 0)
            }
            try check(.pairing) { rp_pairing_file_from_bytes(base, UInt(raw.count), &pairing) }
        }
        guard let pairing else { throw Failure(stage: .pairing, code: 0) }
        defer { rp_pairing_file_free(pairing) }
        guard mayContinue else { return }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(49152).bigEndian
        guard "10.7.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw Failure(stage: .tunnel, code: 0)
        }
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { socket in
                try check(.tunnel) {
                    tunnel_create_rppairing(socket, idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                                           "AirRecord KeepAlive", pairing, nil, nil, &adapter, &handshake)
                }
            }
        }
        guard mayContinue else { return }
        guard let adapter, let handshake else { throw Failure(stage: .tunnel, code: 0) }
        try withExtendedLifetime(self) {
            try check(.debugger) {
                calltap_debug_keepalive(adapter, handshake, targetPID, Self.ffiCallback,
                                        Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private func check(_ stage: Failure.Stage,
                       _ operation: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error = operation() else { return }
        let code = error.pointee.code
        idevice_error_free(error)
        // Remote exception text and pairing contents never reach logs or UI.
        throw Failure(stage: stage, code: Int32(code))
    }
}
#endif
