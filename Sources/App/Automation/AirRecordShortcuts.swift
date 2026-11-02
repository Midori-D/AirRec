// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import AppIntents
import Foundation

private struct AirRecordShortcutError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Resumes the user's existing auto-start choice from a Shortcuts automation.
/// Kept in the main app process so it shares the UI's observer and reservations.
struct ResumeAirRecordMonitoringIntent: AppIntent {
    static var title: LocalizedStringResource = "통화 감시 재개"
    static var description: IntentDescription = "LocalDevVPN 연결 후 AirRecord의 켜져 있는 자동 시작 설정을 재개합니다. 자동 시작이 꺼져 있으면 변경하지 않습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try Task.checkCancellation()
        let monitor = AirRecordMonitor.shared
        let ready = await monitor.resumeFromShortcut()
        try Task.checkCancellation()
        guard ready else {
            throw AirRecordShortcutError(message: monitor.status)
        }
        return .result(value: "통화 감시 준비 완료")
    }
}

/// Shortcuts owns the cellular switches on both sides of this action. Returning
/// a result for ordinary failures lets its following restore action run.
struct WaitForAirRecordRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "녹음 시작 대기"
    static var description: IntentDescription = "셀룰러 데이터 끄기와 VPN 연결 다음에 사용하세요. 감시를 재개하고 녹음 처리 결과를 기다린 뒤 다음 단축어 동작으로 넘어갑니다. 뒤에 셀룰러 데이터 켜기를 추가하세요."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(초)", default: 45)
    var waitSeconds: Int

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<String> {
        let summary = await AirRecordMonitor.shared.waitForRecordingFromShortcut(
            timeout: TimeInterval(waitSeconds))
        return .result(value: summary)
    }
}

/// A CallKit observation only; the shortcut chooses what to do with the Bool.
struct WaitForAirRecordOutgoingCallIntent: AppIntent {
    static var title: LocalizedStringResource = "통화 발신 대기"
    static var description: IntentDescription = "발신이 시작될 때까지 기본 20초, 최대 25초 기다립니다. 이미 단일 발신 중이면 즉시 참을, 발신 없이 시간이 지나면 거짓을 반환합니다. FaceTime 등 CallKit 발신도 감지될 수 있습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(초)", default: 20)
    var waitSeconds: Int

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<Bool> {
        airRecordLog("Outgoing wait intent: started")
        let outgoing = await AirRecordOutgoingCallWaiter.wait(timeout: TimeInterval(waitSeconds))
        let detected = outgoing && !Task.isCancelled
        airRecordLog("Outgoing wait intent: result=\(detected)")
        return .result(value: detected)
    }
}

struct AirRecordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeAirRecordMonitoringIntent(),
            phrases: ["\(.applicationName) 통화 감시 재개"],
            shortTitle: "통화 감시 재개",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: WaitForAirRecordRecordingIntent(),
            phrases: ["\(.applicationName) 녹음 시작 대기"],
            shortTitle: "녹음 시작 대기",
            systemImageName: "phone.badge.waveform"
        )
        AppShortcut(
            intent: WaitForAirRecordOutgoingCallIntent(),
            phrases: ["\(.applicationName) 통화 발신 대기"],
            shortTitle: "통화 발신 대기",
            systemImageName: "phone.arrow.up.right"
        )
    }
}
#endif
