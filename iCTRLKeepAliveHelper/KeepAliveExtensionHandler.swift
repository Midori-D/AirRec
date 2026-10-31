// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import Darwin
import Foundation
import Network

/// An app-owned, non-UI request. No pairing file is written by this process.
/// The host verifies this process's registered PID before sending pairing data.
final class KeepAliveExtensionHandler: NSObject, NSExtensionRequestHandling {
    private struct Bootstrap {
        let hostPID: UInt32
        let port: UInt16
        let nonce: String
        let session: String

        init?(_ context: NSExtensionContext) {
            guard context.inputItems.count == 1,
                  let item = context.inputItems.first as? NSExtensionItem,
                  let info = item.userInfo,
                  let host = info["hostPID"] as? NSNumber,
                  host.int64Value > 1, host.uint64Value <= UInt64(Int32.max),
                  UInt32(host.uint64Value) != UInt32(getpid()),
                  let port = info["port"] as? NSNumber,
                  port.int64Value > 0, port.uint64Value <= UInt64(UInt16.max),
                  let nonce = info["nonce"] as? String,
                  AirRecordKeepAliveWire.isValidNonce(nonce),
                  let session = info["session"] as? String,
                  UUID(uuidString: session) != nil else { return nil }
            hostPID = UInt32(host.uint64Value)
            self.port = UInt16(port.uint64Value)
            self.nonce = nonce
            self.session = session
        }
    }
    private enum State { case connecting, awaitingConfiguration, attaching, attached, stopping, finished }
    private let queue = DispatchQueue(label: "airrecord.keepalive.helper.ipc")
    private var context: NSExtensionContext?
    private var bootstrap: Bootstrap?
    private var connection: NWConnection?
    private var state = State.connecting
    private var buffer = Data()
    private var worker: AirRecordDebugWorker?
    private var handshakeTimeout: DispatchWorkItem?
    private var cleanupTimeout: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?
    private var mutualTraceObserved = false
    // Deliberately scoped to the pending request; finish() breaks this cycle.
    private var requestLifetime: KeepAliveExtensionHandler?

    func beginRequest(with context: NSExtensionContext) {
        queue.async { [self] in
            guard self.context == nil else {
                context.cancelRequest(withError: Self.fixedError(1))
                return
            }
            self.context = context
            requestLifetime = self
            guard let bootstrap = Bootstrap(context),
                  let port = NWEndpoint.Port(rawValue: bootstrap.port) else {
                finish(errorCode: 2)
                return
            }
            self.bootstrap = bootstrap
            let timeout = DispatchWorkItem { [weak self] in self?.stop(errorCode: 3) }
            handshakeTimeout = timeout
            queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            // Literal loopback only; no caller-selected address or DNS lookup.
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard self.state == .connecting else { return }
                    self.state = .awaitingConfiguration
                    self.send(self.message("hello", helperPID: UInt32(getpid()),
                                           allowsDebugging: airrecord_process_allows_debugging()))
                    self.receive()
                case .failed, .cancelled:
                    self.stop(errorCode: 4)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receive() {
        guard state != .finished, state != .stopping else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.state != .finished, self.state != .stopping else { return }
            do {
                if let data {
                    for message in try AirRecordKeepAliveWire.append(data, to: &self.buffer) {
                        self.received(message)
                        if self.state == .finished || self.state == .stopping { return }
                    }
                }
                if complete || error != nil { self.stop(errorCode: 4) }
                else { self.receive() }
            } catch { self.stop(errorCode: 5) }
        }
    }

    private func received(_ message: AirRecordKeepAliveMessage) {
        guard let bootstrap, message.session == bootstrap.session,
              AirRecordKeepAliveWire.matchesNonce(message.nonce, bootstrap.nonce) else {
            stop(errorCode: 6)
            return
        }
        switch message.type {
        case "configure":
            guard state == .awaitingConfiguration, worker == nil,
                  message.hostPID == bootstrap.hostPID,
                  airrecord_process_allows_debugging(), !airrecord_process_is_traced(),
                  let encoded = message.pairing,
                  encoded.utf8.count <= (AirRecordKeepAliveWire.maximumPairingBytes * 4 / 3) + 4,
                  let pairing = Data(base64Encoded: encoded), !pairing.isEmpty,
                  pairing.count <= AirRecordKeepAliveWire.maximumPairingBytes else {
                stop(errorCode: 7)
                return
            }
            state = .attaching
            let worker = AirRecordDebugWorker(targetPID: bootstrap.hostPID, pairingData: pairing,
                onEvent: { [weak self] event in
                    self?.queue.async { [weak self] in self?.workerEvent(event) }
                }, onCompletion: { [weak self] failure in
                    self?.queue.async { [weak self] in self?.workerFinished(failure) }
                })
            self.worker = worker
            worker.start()
        case "stop":
            stop(errorCode: nil)
        default:
            stop(errorCode: 8)
        }
    }

    private func workerEvent(_ event: AirRecordDebugWorker.Event) {
        guard state != .finished, state != .stopping else { return }
        switch event {
        case .attached:
            guard state == .attaching else { stop(errorCode: 9); return }
            state = .attached
            handshakeTimeout?.cancel()
            // If the host cannot complete the reverse attach, release its
            // debugger rather than leaving a one-sided session alive forever.
            let mutualTimeout = DispatchWorkItem { [weak self] in
                guard let self, self.state == .attached, !self.mutualTraceObserved else { return }
                self.stop(errorCode: 14)
            }
            handshakeTimeout = mutualTimeout
            queue.asyncAfter(deadline: .now() + 20, execute: mutualTimeout)
            send(message("attached"))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, self.state == .attached else { return }
                let traced = airrecord_process_is_traced()
                if self.mutualTraceObserved && !traced {
                    self.stop(errorCode: 15)
                    return
                }
                if traced {
                    self.mutualTraceObserved = true
                    self.handshakeTimeout?.cancel()
                    self.handshakeTimeout = nil
                }
                self.send(self.message("heartbeat", hostAttached: true,
                                       selfTraced: traced))
            }
            heartbeat = timer
            timer.resume()
        case .cleanedUp:
            // Completion follows on the same callback queue. No new request is
            // accepted after the debugger cleanup event.
            stop(errorCode: 10)
        }
    }

    private func workerFinished(_ failure: AirRecordDebugWorker.Failure?) {
        guard state != .finished else { return }
        worker = nil
        if state == .stopping {
            if let cleanupCode {
                sendAndFinish(message("error", errorCode: cleanupCode), errorCode: cleanupCode)
            } else { sendAndFinish(message("stopped"), errorCode: nil) }
        } else {
            stop(errorCode: failure?.code ?? 11)
        }
    }

    private var cleanupCode: Int32?
    private func stop(errorCode: Int32?) {
        guard state != .finished, state != .stopping else { return }
        state = .stopping
        cleanupCode = errorCode
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        heartbeat?.cancel()
        heartbeat = nil
        buffer.removeAll(keepingCapacity: false)
        guard let worker else {
            if let errorCode { sendAndFinish(message("error", errorCode: errorCode), errorCode: errorCode) }
            else { sendAndFinish(message("stopped"), errorCode: nil) }
            return
        }
        worker.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            // The debugger's detach-on-error setting is installed before
            // attach. Closing a lost IPC request never issues kill/exit.
            self?.finish(errorCode: 12)
        }
        cleanupTimeout = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func message(_ type: String, helperPID: UInt32? = nil,
                         allowsDebugging: Bool? = nil, hostAttached: Bool? = nil,
                         selfTraced: Bool? = nil, errorCode: Int32? = nil) -> AirRecordKeepAliveMessage {
        AirRecordKeepAliveMessage(type: type, session: bootstrap?.session ?? "",
                                  nonce: bootstrap?.nonce ?? "", helperPID: helperPID,
                                  allowsDebugging: allowsDebugging, hostAttached: hostAttached,
                                  selfTraced: selfTraced, errorCode: errorCode)
    }

    private func send(_ message: AirRecordKeepAliveMessage) {
        guard let connection, let data = try? AirRecordKeepAliveWire.encode(message) else {
            stop(errorCode: 13)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.stop(errorCode: 4) }
        })
    }

    private func sendAndFinish(_ message: AirRecordKeepAliveMessage, errorCode: Int32?) {
        guard let connection, let data = try? AirRecordKeepAliveWire.encode(message) else {
            finish(errorCode: errorCode)
            return
        }
        // Bound a peer that no longer reads without leaving the request alive.
        if cleanupTimeout == nil {
            let timeout = DispatchWorkItem { [weak self] in self?.finish(errorCode: errorCode) }
            cleanupTimeout = timeout
            queue.asyncAfter(deadline: .now() + 2, execute: timeout)
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish(errorCode: errorCode)
        })
    }

    private func finish(errorCode: Int32?) {
        guard state != .finished else { return }
        state = .finished
        handshakeTimeout?.cancel(); handshakeTimeout = nil
        cleanupTimeout?.cancel(); cleanupTimeout = nil
        heartbeat?.cancel(); heartbeat = nil
        worker?.cancel(); worker = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        buffer.removeAll(keepingCapacity: false)
        bootstrap = nil
        let requestContext = context
        context = nil
        if let errorCode { requestContext?.cancelRequest(withError: Self.fixedError(errorCode)) }
        else { requestContext?.completeRequest(returningItems: [], completionHandler: nil) }
        requestLifetime = nil
    }

    private static func fixedError(_ code: Int32) -> NSError {
        NSError(domain: "AirRecordKeepAliveHelper", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "AirRecord Helper 연결이 종료됐습니다."])
    }
}
#endif
