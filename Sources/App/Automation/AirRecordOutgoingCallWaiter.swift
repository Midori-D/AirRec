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
    static func wait(timeout: TimeInterval = AirRecordOutgoingWaitPolicy.defaultTimeout,
                     onProgress: (@MainActor @Sendable (TimeInterval) -> Void)? = nil) async -> Bool {
        let cancellation = AirRecordOutgoingWaitCancellation()
        let request = Request(timeout: timeout, cancellation: cancellation, onProgress: onProgress)
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
        private let onProgress: (@MainActor @Sendable (TimeInterval) -> Void)?
        private var policy: AirRecordOutgoingWaitPolicy
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var started = false

        init(timeout: TimeInterval, cancellation: AirRecordOutgoingWaitCancellation,
             onProgress: (@MainActor @Sendable (TimeInterval) -> Void)?) {
            self.cancellation = cancellation
            self.onProgress = onProgress
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
            // Short waits only need a deadline timer. Long-running intents
            // refresh progress every second without delaying CallKit callbacks.
            let interval: TimeInterval = onProgress == nil ? .infinity : 1
            timeoutTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let remaining = self?.remainingBudget else { return }
                    guard remaining > 0 else {
                        self?.evaluate()
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64((min(interval, remaining) * 1_000_000_000).rounded(.up)))
                    } catch { return }
                    self?.evaluate()
                }
            }
        }

        private var remainingBudget: TimeInterval? {
            guard continuation != nil else { return nil }
            return max(0, policy.deadline - ProcessInfo.processInfo.systemUptime)
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
            let now = ProcessInfo.processInfo.systemUptime
            let decision = policy.decision(now: now, calls: calls,
                                           cancelled: cancelled || cancellation.isCancelled)
            switch decision {
            case .waiting:
                onProgress?(now - policy.startedAt)
            case .finished(let result):
                self.continuation = nil
                observer.setDelegate(nil, queue: nil)
                timeoutTask?.cancel()
                timeoutTask = nil
                continuation.resume(returning: result.detectedOutgoing && !cancellation.isCancelled)
            }
        }
    }
}
#endif
