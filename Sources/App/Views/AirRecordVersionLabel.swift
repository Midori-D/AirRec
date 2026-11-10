// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION // AIRRECORD_AUTOMATION 조건이 있을 경우 아래 코드를 빌드에 포함함
import SwiftUI

// 알파버전 텍스트
struct AirRecordVersionLabel: View {
    let version: String

    private var styledVersion: AttributedString {
        var text = AttributedString(version)
        text.foregroundColor = .secondary
        if let alpha = text.range(of: "알파") {
            text[alpha].foregroundColor = .red
        }
        return text
    }

    var body: some View {
        Text(styledVersion)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
