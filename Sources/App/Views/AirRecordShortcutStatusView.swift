// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION // AIRRECORD_AUTOMATION 조건이 있을 경우 아래 코드를 빌드에 포함함
import SwiftUI
import Foundation

@MainActor
struct AirRecordShortcutStatusView: View {
    enum Kind { case outgoing, end, incoming, incomingEnd }

    let accent: Color
    var kind: Kind = .outgoing
    var incomingNotificationAt: Date? = nil
    @StateObject private var presence = AirRecordShortcutPresence.shared

    private var lastEventAt: Date? {
        switch kind {
        case .outgoing: return presence.lastActionRunAt
        case .end: return presence.lastEndActionRunAt
        case .incoming: return incomingNotificationAt
        case .incomingEnd: return presence.lastIncomingEndActionRunAt
        }
    }

    private var title: String {
        switch kind {
        case .outgoing: return "AirRec 발신 자동화"
        case .end: return "AirRec 발신종료 자동화"
        case .incoming: return "AirRec 수신 자동화"
        case .incomingEnd: return "AirRec 수신종료 자동화"
        }
    }

    private var systemImage: String {
        switch kind {
        case .outgoing: return "phone.arrow.up.right"
        case .end, .incomingEnd: return "phone.down.fill"
        case .incoming: return "phone.arrow.down.left"
        }
    }

    var body: some View {
        let eventName = kind == .incoming ? "수신 알림 요청" : "자동화 실행"
        AirRecordCard {
            AirRecordStatusRow(title: title, systemImage: systemImage,
                               isConfirmed: lastEventAt != nil, accent: accent,
                               accessibilityValue: lastEventAt == nil ? "\(eventName) 기록 없음" : "\(eventName) 기록 확인됨")
            if let used = lastEventAt {
                Text("최근 \(eventName): \(used.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(kind == .incoming ? "수신 알림을 보내면 체크가 표시됩니다." : "자동화를 실행하면 체크가 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
