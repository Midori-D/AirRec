// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION // AIRRECORD_AUTOMATION 조건이 있을 경우 아래 코드를 빌드에 포함함
import SwiftUI

/// 추후에 구현할 액션 목록 (로드맵)
struct AirRecordPlannedFeatureView: View {
    let title: String
    let systemImage: String
    let accent: Color

    var body: some View {
        AirRecordCard {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.headline)
            Label("구현 중...", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
