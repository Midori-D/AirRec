// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import SwiftUI

/// A single wrapping text preserves Dynamic Type and one VoiceOver reading.
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
