// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import CallKit
import Foundation

/// The cancellation handler can run off the main actor, before its cleanup
/// task gets actor time. Publish cancellation before another call event wins.
private final class AirRecordOutgoingWaitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Independent of recording preparation, VPN, saved settings, and the monitor.
/// CallKit does not identify the calling app, so this can also detect VoIP calls.
@MainActor
enum AirRecordOutgoingCallWaiter {
    static func wait(timeout: TimeInterval = AirRecordOutgoingWaitPolicy.defaultTimeout) async -> Bool {
        let cancellation = AirRecordOutgoingWaitCancellation()
        let request = Request(timeout: timeout, cancellation: cancellation)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation, cancelled: Task.isCancelled)
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in request.cancel() }
        }
    }

    @MainActor
    private final class Request: NSObject, CXCallObserverDelegate {
        private let observer = CXCallObserver()
        private let cancellation: AirRecordOutgoingWaitCancellation
        private var policy: AirRecordOutgoingWaitPolicy
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var started = false

        init(timeout: TimeInterval, cancellation: AirRecordOutgoingWaitCancellation) {
            self.cancellation = cancellation
            policy = AirRecordOutgoingWaitPolicy(
                startedAt: ProcessInfo.processInfo.systemUptime, timeout: timeout)
            super.init()
        }

        func start(_ continuation: CheckedContinuation<Bool, Never>, cancelled: Bool) {
            guard !started else {
                continuation.resume(returning: false)
                return
            }
            started = true
            self.continuation = continuation
            if cancelled || cancellation.isCancelled {
                evaluate(cancelled: true)
                return
            }
            // Register before reading the snapshot: a call arriving between
            // registration and this read is seen by either path (or both).
            observer.setDelegate(self, queue: .main)
            evaluate()
            guard self.continuation != nil else { return }
            let deadline = policy.deadline
            timeoutTask = Task { @MainActor [weak self] in
                // Include time queued for the actor in the original budget.
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                do {
                    try await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded(.up)))
                } catch {
                    return
                }
                self?.evaluate()
            }
        }

        func cancel() {
            cancellation.cancel()
            if started { evaluate(cancelled: true) }
        }

        nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
            // Re-read on the actor rather than carrying a possibly stale call
            // across the hop. Finished requests have no continuation to resume.
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        private func evaluate(cancelled: Bool = false) {
            guard let continuation else { return }
            let calls = observer.calls.map {
                AirRecordOutgoingWaitPolicy.Call(isOutgoing: $0.isOutgoing,
                                                hasEnded: $0.hasEnded,
                                                isOnHold: $0.isOnHold)
            }
            let decision = policy.decision(now: ProcessInfo.processInfo.systemUptime,
                                           calls: calls, cancelled: cancelled || cancellation.isCancelled)
            guard case .finished(let result) = decision else { return }
            self.continuation = nil
            observer.setDelegate(nil, queue: nil)
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: result.detectedOutgoing)
        }
    }
}
#endif
