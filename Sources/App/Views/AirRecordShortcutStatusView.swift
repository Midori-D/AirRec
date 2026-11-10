// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION // AIRRECORD_AUTOMATION 조건이 있을 경우 아래 코드를 빌드에 포함함
import SwiftUI
import Foundation

@MainActor
struct AirRecordShortcutStatusView: View {
    enum Kind { case outgoing, end, incoming }

    let accent: Color
    var kind: Kind = .outgoing
    @StateObject private var presence = AirRecordShortcutPresence.shared

    private var lastActionRunAt: Date? {
        switch kind {
        case .outgoing: return presence.lastActionRunAt
        case .end: return presence.lastEndActionRunAt
        case .incoming: return presence.lastIncomingActionRunAt
        }
    }

    private var title: String {
        switch kind {
        case .outgoing: return "AirRec 발신 자동화"
        case .end: return "AirRec 발신종료 자동화"
        case .incoming: return "AirRec 수신 자동화"
        }
    }

    private var systemImage: String {
        switch kind {
        case .outgoing: return "phone.arrow.up.right"
        case .end: return "phone.down.fill"
        case .incoming: return "phone.arrow.down.left"
        }
    }

    var body: some View {
        AirRecordCard {
            AirRecordStatusRow(title: title, systemImage: systemImage,
                               isConfirmed: lastActionRunAt != nil, accent: accent,
                               accessibilityValue: lastActionRunAt == nil ? "자동화 실행 기록 없음" : "자동화 실행 기록 확인됨")
            if let used = lastActionRunAt {
                Text("최근 자동화 실행: \(used.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("자동화를 실행하면 체크가 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
