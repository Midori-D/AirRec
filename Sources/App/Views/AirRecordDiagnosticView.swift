// AirRec, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import SwiftUI

@MainActor
struct AirRecordDiagnosticView: View {
    let report: AirRecordDiagnosticReport
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @State private var worksWell: Bool?
    @State private var includeIPAddress = false
    @State private var apiKey = AirRecordDiagnosticUpload.bundledAPIKey
    @State private var hasAttemptedSend = false
    @State private var isSending = false
    @State private var wasSent = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            AirRecordPage(accent: accent) {
                AirRecordCard {
                    AirRecordHeading("수집 목적", systemImage: "stethoscope", tint: accent)
                    Text("기종과 iOS 버전에 따라 자동 녹음이 어느 단계에서 멈추는지 확인하는 데 사용합니다.")
                        .font(.subheadline)
                    AirRecordInfoRow("수집 장소", value: AirRecordDiagnosticUpload.endpoint.absoluteString)
                        .textSelection(.enabled)
                }
                AirRecordCard {
                    AirRecordHeading("전송 항목", systemImage: "list.bullet.clipboard", tint: accent)
                    AirRecordInfoRow("기종 식별자", value: report.modelIdentifier)
                    AirRecordInfoRow("iOS 버전", value: report.iosVersion)
                    AirRecordInfoRow("AirRec 버전과 빌드", value: "\(report.appVersion) (\(report.appBuild))")
                    if let attempt = report.lastAttempt {
                        Divider()
                        AirRecordInfoRow("통화 방향과 검사 당시 잠금 상태",
                                         value: "\(attempt.callDirection.title) · \(attempt.lockState.title)")
                        AirRecordInfoRow("마지막 단계와 결과",
                                         value: "\(attempt.stage.title) · \(attempt.resultCode.title)")
                    }
                    Divider()
                    AirRecordInfoRow("보고서 번호", value: report.reportID.uuidString)
                        .textSelection(.enabled)
                    Text("보고서 번호는 재전송 시 중복 접수를 막는 데 사용합니다. 전송 형식 버전도 함께 보냅니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                AirRecordCard {
                    Text("AirRec이 잘 작동하나요?")
                        .font(.headline)
                    HStack(spacing: 12) {
                        answerButton("예", answer: true)
                        answerButton("아니오", answer: false)
                    }
                    .accessibilityElement(children: .contain)
                    .disabled(hasAttemptedSend)
                }
                AirRecordCard {
                    Toggle("접속 IP 주소 저장에 동의", isOn: $includeIPAddress)
                        .font(.headline)
                        .disabled(hasAttemptedSend)
                    Text("동의하면 진단 서버가 요청을 받은 시점의 접속 IP 주소를 보고서와 함께 저장합니다. 같은 네트워크에서 접수된 보고서를 비교하는 데 사용합니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                AirRecordCard {
                    if wasSent {
                        Label("진단 보고서를 접수했습니다.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("‘동의하고 전송’을 누르면 위의 진단 정보와 응답이 AirRec 운영 서버에 저장됩니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                        SecureField("진단 전송 키", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(isSending)
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.red)
                        }
                        Button {
                            Task { await send() }
                        } label: {
                            Group {
                                if isSending { ProgressView() }
                                else { Text(errorMessage == nil ? "동의하고 전송" : "다시 전송") }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(worksWell == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    }
                }
            }
            .navigationTitle("진단 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .disabled(isSending)
                }
            }
        }
        .tint(accent)
        .interactiveDismissDisabled(isSending)
    }

    private func answerButton(_ title: String, answer: Bool) -> some View {
        let selected = worksWell == answer
        return Button {
            worksWell = answer
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(selected ? accent : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func send() async {
        guard let worksWell, !isSending, !wasSent else { return }
        var submission = report
        submission.worksWell = worksWell
        submission.consentsToIPCollection = includeIPAddress ? true : nil
        // Keep the same payload and report ID on retry.
        hasAttemptedSend = true
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await AirRecordDiagnosticUpload.send(submission, apiKey: apiKey)
            apiKey = ""
            wasSent = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
