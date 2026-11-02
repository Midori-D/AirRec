// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import SwiftUI
import UIKit

@MainActor
struct AirRecordShortcutStatusView: View {
    let accent: Color
    @StateObject private var presence = AirRecordShortcutPresence.shared
    @State private var openingError: String?

    private var statusText: String {
        if let found = presence.lastNameCheckFound {
            return found ? "목록에서 확인됨" : "마지막 목록에서 찾지 못함"
        }
        return presence.lastActionRunAt == nil ? "연결 확인 필요" : "발신 동작 연결 확인됨"
    }

    private var statusSymbol: String {
        if let found = presence.lastNameCheckFound { return found ? "checkmark.circle.fill" : "xmark.circle" }
        return presence.lastActionRunAt == nil ? "questionmark.circle" : "checkmark.circle"
    }

    var body: some View {
        AirRecordCard {
            AirRecordHeading("AirRecord(발신)", systemImage: "square.stack.3d.up", tint: accent)
            Label(statusText, systemImage: statusSymbol)
                .font(.subheadline.weight(.medium))
            if let checked = presence.lastNameCheckAt {
                Text("목록 확인: \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let used = presence.lastActionRunAt {
                Text("발신 동작 실행: \(used.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if presence.lastNameCheckFound == nil && presence.lastActionRunAt != nil {
                Text("최근 실행 기준 · 단축어 이름은 아직 확인하지 않았습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("단축어 열기", systemImage: "arrow.up.forward.app") { openShortcut() }
                .font(.subheadline.weight(.semibold))
            if let note = presence.verificationNote ?? openingError {
                Text(note).font(.footnote).foregroundStyle(.orange)
            }
            DisclosureGroup("이름 확인 방법") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("확인용 단축어를 아래 세 동작으로 만들어 한 번 실행하세요.")
                    Text("1. 나의 단축어 가져오기\n2. 이름 가져오기\n3. AirRecord · 단축어 목록 확인")
                    Text("‘단축어 이름 목록’에 바로 앞의 이름 결과를 연결합니다. AirRecord(발신)이 있는지 확인한 시각과 결과만 저장합니다.")
                    Text("앱이 단축어 목록을 직접 읽는 방식이 아니므로, 단축어를 삭제하거나 이름을 바꿨다면 다시 확인하세요. 전체 이름 목록은 저장하지 않습니다.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
            }
            .font(.subheadline)
        }
    }

    private func openShortcut() {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: AirRecordShortcutPresence.targetName)]
        guard let url = components.url else { return }
        openingError = nil
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in
                if !opened { openingError = "단축어 앱을 열지 못했습니다." }
                // Opening the app is not evidence that the named shortcut exists.
            }
        }
    }
}
#endif
