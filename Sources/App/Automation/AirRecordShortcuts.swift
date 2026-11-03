// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import AppIntents
import Foundation

/// Bridges the system's synchronous cancellation callback to this invocation's
/// observer task, including cancellation before that task is installed.
private final class AirRecordCallEndIntentTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Bool, Never>?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ task: Task<Bool, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = task
        lock.unlock()
        pending?.cancel()
    }

    func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}

/// A CallKit observation only; the shortcut chooses what to do with the Bool.
struct WaitForAirRecordOutgoingCallIntent: AppIntent {
    static var title: LocalizedStringResource = "발신"
    static var description: IntentDescription = "발신이 시작될 때까지 기본 20초, 최대 25초 기다립니다. 이미 단일 발신 중이면 즉시 참을, 발신 없이 시간이 지나면 거짓을 반환합니다. FaceTime 등 CallKit 발신도 감지될 수 있습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(초)", default: 20)
    var waitSeconds: Int

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<Bool> {
        AirRecordShortcutPresence.shared.recordActionRun()
        airRecordLog("Outgoing wait intent: started")
        let outgoing = await AirRecordOutgoingCallWaiter.wait(timeout: TimeInterval(waitSeconds))
        let detected = outgoing && !Task.isCancelled
        airRecordLog("Outgoing wait intent: result=\(detected)")
        return .result(value: detected)
    }
}

/// Observes completion; never hangs up or changes cellular data itself.
struct WaitForAirRecordCallEndIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource = "발신종료"
    static var description: IntentDescription = "발신 자동화에서 사용합니다. 진행 중인 모든 활성 통화가 끝날 때까지 기다립니다. 이미 통화가 없으면 즉시 참, 시간 초과·중단이면 거짓을 반환합니다. 기본 60분, 최대 180분이며 대기 중 시스템 진행 표시가 나타납니다. 다음에 셀룰러 데이터 켜기를 연결하세요. 통화를 직접 끊지는 않습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(분)", default: 60)
    var waitMinutes: Int

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<Bool> {
        AirRecordShortcutPresence.shared.recordEndActionRun()
        let seconds = AirRecordCallEndWaitPolicy.boundedTimeout(TimeInterval(waitMinutes) * 60)
        let displayProgress = progress
        displayProgress.totalUnitCount = Int64(seconds.rounded(.up))
        displayProgress.completedUnitCount = 0
        displayProgress.localizedDescription = "발신종료 대기"
        displayProgress.localizedAdditionalDescription = "모든 통화가 끝나면 다음 동작을 실행합니다."
        let cancellation = AirRecordCallEndIntentTask()
        defer { cancellation.clear() }
        airRecordLog("Call end wait intent: started")
        do {
            let ended = try await performBackgroundTask {
                let pending = Task { @MainActor in
                    guard !Task.isCancelled, !cancellation.isCancelled else { return false }
                    return await AirRecordCallEndWaiter.wait(timeout: seconds) { elapsed in
                        // Progress measures elapsed observation time, not the
                        // unknown duration or completion percentage of a call.
                        displayProgress.completedUnitCount = min(
                            displayProgress.totalUnitCount, Int64(max(0, elapsed).rounded(.down)))
                        displayProgress.localizedAdditionalDescription = "경과 \(Int(elapsed))초 · 최대 \(Int(seconds / 60))분 대기"
                    }
                }
                cancellation.install(pending)
                let value = await withTaskCancellationHandler {
                    await pending.value
                } onCancel: {
                    cancellation.cancel()
                }
                cancellation.clear()
                return value && !cancellation.isCancelled && !Task.isCancelled
            } onCancel: { _ in
                cancellation.cancel()
            }
            let confirmed = ended && !cancellation.isCancelled && !Task.isCancelled
            displayProgress.localizedDescription = confirmed ? "발신종료 확인됨" : "발신종료 대기 중단됨"
            if confirmed { displayProgress.completedUnitCount = displayProgress.totalUnitCount }
            airRecordLog("Call end wait intent: result=\(confirmed)")
            return .result(value: confirmed)
        } catch {
            cancellation.cancel()
            displayProgress.localizedDescription = "발신종료 대기 중단됨"
            airRecordLog("Call end wait intent: interrupted")
            return .result(value: false)
        }
    }
}

struct AirRecordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WaitForAirRecordOutgoingCallIntent(),
            phrases: ["\(.applicationName) 발신"],
            shortTitle: "발신",
            systemImageName: "phone.arrow.up.right"
        )
        AppShortcut(
            intent: WaitForAirRecordCallEndIntent(),
            phrases: ["\(.applicationName) 발신종료"],
            shortTitle: "발신종료",
            systemImageName: "phone.down"
        )
    }
}
#endif
