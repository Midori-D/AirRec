// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import SwiftUI

@MainActor
struct AirRecordContactView: View {
    let accent: Color
    let version: String
    let diagnosticSummary: String
    let isSelected: Bool
    @Environment(\.scenePhase) private var scenePhase

    private let profileURL = URL(string: "https://github.com/Midori-D")!
    private let projectURL = URL(string: "https://github.com/Midori-D/CallTap")!
    private let issuesURL = URL(string: "https://github.com/Midori-D/CallTap/issues")!

    var body: some View {
        AirRecordPage(accent: accent) {
            welcomeCard
            developerCard
            supportCard
            Text(version)
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .navigationTitle("문의")
        .navigationBarTitleDisplayMode(.large)
    }

    private var welcomeCard: some View {
        AirRecordCard {
            if let url = Bundle.main.url(forResource: "moon", withExtension: "gif") {
                AirRecordAnimatedGIF(url: url,
                                     isActive: isSelected && scenePhase == .active)
                    .aspectRatio(540.0 / 404.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
            }
            Text("함께 다듬는 AirRecord")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("사용 중 만난 불편이나 떠오른 아이디어를 편하게 남겨 주세요.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var developerCard: some View {
        AirRecordCard {
            AirRecordHeading("개발자", systemImage: "person.crop.circle", tint: accent)
            Text("Midori-D").font(.title2.weight(.semibold))
            contactLink("GitHub 프로필", systemImage: "person.crop.circle", destination: profileURL)
            Divider()
            contactLink("AirRecord 프로젝트", systemImage: "chevron.left.forwardslash.chevron.right", destination: projectURL)
        }
    }

    private var supportCard: some View {
        AirRecordCard {
            AirRecordHeading("문의 · 피드백", systemImage: "bubble.left.and.bubble.right", tint: accent)
            Text("GitHub Issues에 버전과 겪으신 현상을 함께 적어 주세요. 도움이 필요할 때 현재 상태 기록도 공유할 수 있습니다.")
                .font(.subheadline).foregroundStyle(.secondary)
            contactLink("문의와 제안 남기기", systemImage: "arrow.up.forward.app", destination: issuesURL)
            ShareLink(item: diagnosticSummary) {
                Label("현재 상태 기록 공유", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private func contactLink(_ title: String, systemImage: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}
#endif
