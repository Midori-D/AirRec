// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import CallKit
import Foundation

private final class AirRecordCallEndWaitCancellation: @unchecked Sendable {
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

/// Observes all CallKit calls, including VoIP. This never ends a call or changes
/// recording, network settings, location sessions, or the monitor's preference.
@MainActor
enum AirRecordCallEndWaiter {
    static func wait(timeout: TimeInterval,
                     onProgress: @escaping @MainActor @Sendable (TimeInterval) -> Void) async -> Bool {
        let cancellation = AirRecordCallEndWaitCancellation()
        let request = Request(timeout: timeout, cancellation: cancellation, onProgress: onProgress)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation, cancelled: Task.isCancelled)
            }
        } onCancel: {
            // Mark before hopping to MainActor so an already queued call event
            // does not win solely because cancellation cleanup was queued later.
            cancellation.cancel()
            Task { @MainActor in request.cancel() }
        }
    }

    @MainActor
    private final class Request: NSObject, CXCallObserverDelegate {
        private let observer = CXCallObserver()
        private let cancellation: AirRecordCallEndWaitCancellation
        private let onProgress: @MainActor @Sendable (TimeInterval) -> Void
        private var policy: AirRecordCallEndWaitPolicy
        private var continuation: CheckedContinuation<Bool, Never>?
        private var pollingTask: Task<Void, Never>?
        private var started = false

        init(timeout: TimeInterval, cancellation: AirRecordCallEndWaitCancellation,
             onProgress: @escaping @MainActor @Sendable (TimeInterval) -> Void) {
            self.cancellation = cancellation
            self.onProgress = onProgress
            policy = AirRecordCallEndWaitPolicy(startedAt: ProcessInfo.processInfo.systemUptime,
                                                timeout: timeout)
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
            // Delegate registration precedes the first fresh snapshot. If the
            // call ended between Shortcuts actions, zero calls succeeds now.
            observer.setDelegate(self, queue: .main)
            evaluate()
            guard self.continuation != nil else { return }
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let remaining = self?.remainingBudget else { return }
                    guard remaining > 0 else {
                        self?.evaluate()
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64((min(1, remaining) * 1_000_000_000).rounded(.up)))
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
            // Do not carry event snapshots or call identifiers across the actor
            // hop. Another or replacement call may already have become active.
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        private func evaluate(cancelled: Bool = false) {
            guard let continuation else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let calls = observer.calls.map { AirRecordCallEndWaitPolicy.Call(hasEnded: $0.hasEnded) }
            let decision = policy.decision(now: now, calls: calls,
                                           cancelled: cancelled || cancellation.isCancelled)
            switch decision {
            case .waiting:
                // This is elapsed waiting time, never a claimed percentage of
                // completion of the user's call, whose duration is unknown.
                onProgress(max(0, now - policy.startedAt))
            case .finished(let result):
                self.continuation = nil
                observer.setDelegate(nil, queue: nil)
                pollingTask?.cancel()
                pollingTask = nil
                continuation.resume(returning: result.allCallsEnded && !cancellation.isCancelled)
            }
        }
    }
}
#endif
