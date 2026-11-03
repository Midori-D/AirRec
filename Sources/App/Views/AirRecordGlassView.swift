// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import SwiftUI

private enum AirRecordTab: Hashable {
    case home, settings, activity, contact
}

/// Navigation stays separate from monitoring: switching tabs never changes a
/// location session, a pending recording reservation, or the saved preference.
@MainActor
struct AirRecordGlassView: View {
    @StateObject private var monitor = AirRecordMonitor.shared
    @StateObject private var standby = AirRecordLocationKeepAlive.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab = AirRecordTab.home
    @State private var showMount = false
    @State private var shortcutOpeningError: String?

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.52, blue: 0.65)
            : Color(red: 0.76, green: 0.20, blue: 0.36)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "Ver v\(name) 빌드 \(build) - 알파"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("홈", systemImage: "waveform", value: AirRecordTab.home) {
                NavigationStack { homeScreen }
            }
            Tab("설정", systemImage: "slider.horizontal.3", value: AirRecordTab.settings) {
                NavigationStack { settingsScreen }
            }
            Tab("기록", systemImage: "clock.arrow.circlepath", value: AirRecordTab.activity) {
                NavigationStack { activityScreen }
            }
            Tab("문의", systemImage: "bubble.left.and.bubble.right", value: AirRecordTab.contact) {
                NavigationStack {
                    AirRecordContactView(accent: accent, version: version,
                                         diagnosticSummary: monitor.diagnosticSummary,
                                         isSelected: selectedTab == .contact)
                }
            }
        }
        .tint(accent)
        // The system draws the floating Liquid Glass tab bar, including its
        // accessibility, contrast, and Reduce Transparency adaptations.
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showMount) { DDIMountView() }
        .task { await monitor.resumeIfEnabled() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await monitor.resumeIfEnabled() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.resumeIfEnabled() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in
            standby.refreshEnvironment()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            standby.refreshEnvironment()
        }
    }

    private var homeScreen: some View {
        AirRecordPage(accent: accent) {
            brandHeader
            monitoringCard
            standbySummary
            AirRecordShortcutStatusView(accent: accent)
            AirRecordShortcutStatusView(accent: accent, kind: .end)
            AirRecordPlannedFeatureView(title: "AirRecord 수신 자동화", systemImage: "phone.arrow.down.left", accent: accent)
            AirRecordPlannedFeatureView(title: "AirRecord 수신종료 자동화", systemImage: "phone.down.fill", accent: accent)
            AirRecordPlannedFeatureView(title: "AirRecord 메모 이름 수정", systemImage: "note.text", accent: accent)
            AirRecordPlannedFeatureView(title: "AirBeep (통화 녹음 고지 제거)", systemImage: "speaker.slash", accent: accent)
            AirRecordPlannedFeatureView(title: "AirBeep2 (통화 녹음 카운트다운 제거)", systemImage: "timer", accent: accent)
        }
        .navigationTitle("AirRecord")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image("AirRecordMark")
                    .resizable().scaledToFit()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("AirRecord")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                AirRecordVersionLabel(version: version)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var monitoringCard: some View {
        AirRecordCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: monitor.isRunning ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(monitor.isRunning ? Color.green : accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(monitoringTitle)
                        .font(.title2.weight(.bold))
                    Text(monitor.isRunning ? "AirRecord 일하는 중 🧐" : "AirRecord 쉬는 중 😴")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if monitor.activationError != nil || monitor.isPreparing || (monitor.isEnabled && !monitor.isRunning) {
                Text(monitor.status)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            monitoringControls
        }
    }

    private var monitoringTitle: String {
        if monitor.activationError != nil { return "AirRecord 404 Error" }
        if monitor.isPreparing { return "AirRecord 연결 중" }
        if monitor.isRunning { return "AirRecord 활성화됨" }
        return monitor.isEnabled ? "AirRecord 404 Error" : "AirRecord 비활성화됨"
    }

    @ViewBuilder
    private var monitoringControls: some View {
        if monitor.isRunning && monitor.activationError == nil {
            Button(role: .destructive) { monitor.stop() } label: {
                Label("AirRecord 비활성화", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        } else {
            Button { Task { await monitor.start() } } label: {
                HStack(spacing: 8) {
                    if monitor.isPreparing { ProgressView().controlSize(.small) }
                    Text(monitor.isPreparing ? "연결 중…" : "AirRecord 활성화")
                        .fontWeight(.semibold)
                    if !monitor.isPreparing { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(monitor.isPreparing)
            if monitor.activationError == nil && monitor.isPreparing {
                Button("AirRecord 비활성화", role: .destructive) { monitor.stop() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var standbySummary: some View {
        AirRecordCard {
            AirRecordStatusRow(title: "백그라운드 AirRecord", systemImage: "location.fill",
                               isConfirmed: standby.isRunning && monitor.isRunning, accent: accent,
                               accessibilityValue: standby.isRunning && monitor.isRunning ? "활성화됨" : "비활성화됨")
        }
    }

    private var settingsScreen: some View {
        AirRecordPage(accent: accent) {
            preparationCard
            backgroundCard
            shortcutCard
            guidanceCard
            AirRecordVersionLabel(version: version)
                .font(.footnote)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
    }

    private var preparationCard: some View {
        AirRecordCard {
            AirRecordHeading("초기 설정", systemImage: "checklist", tint: accent)
            Text("LocalDevVPN 연결과 개발자 디스크 준비를 마친 뒤 AirRecord를 활성화하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showMount = true } label: {
                Label("페어링 파일 · 개발자 디스크", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var backgroundCard: some View {
        AirRecordCard {
            AirRecordHeading("백그라운드 AirRecord", systemImage: "location.fill", tint: accent)
            Toggle("백그라운드 AirRecord 활성화", isOn: Binding(
                get: { standby.isEnabled },
                set: { enabled in Task { await monitor.setLocationStandbyEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(monitor.isPreparing || (standby.isLiveContainer && !standby.isEnabled))
            Text("백그라운드에서도 AirRecord를 유지하기 위해 위치 권한을 사용합니다. 좌표는 저장·전송하지 않습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standby.isLiveContainer {
                Label("백그라운드 기능은 SideStore에 독립 설치한 앱에서 사용하세요.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if standby.isEnabled {
                if !monitor.isEnabled {
                    Label("홈에서 AirRecord를 활성화하면 적용됩니다.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Divider()
                Toggle("다이내믹 아일랜드 위치 표시 숨기기", isOn: Binding(
                    get: { standby.indicatorMinimizationEnabled },
                    set: { standby.setIndicatorMinimizationEnabled($0) }
                ))
                .font(.headline)
                .disabled(monitor.isPreparing || standby.isLiveContainer)
                if standby.indicatorMinimizationEnabled {
                    indicatorPermissionControls
                }
            }
            backgroundDetails
        }
    }

    @ViewBuilder
    private var indicatorPermissionControls: some View {
        if standby.hasAlwaysAuthorization {
            Label("항상 허용 확인됨", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(.green)
        } else {
            Text("위치 표시를 숨기려면 위치 권한을 ‘항상 허용’으로 설정해야 합니다.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { standby.requestAlwaysAuthorization() } label: {
                Label("항상 허용 요청", systemImage: "hand.raised")
            }
            .font(.subheadline.weight(.semibold))
            .disabled(monitor.isPreparing || standby.isLiveContainer)
            Text("권한 창이 나타나지 않으면 iOS 설정에서 변경해 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Divider()
        Button { openAppSettings() } label: {
            Label("위치 권한 설정 열기", systemImage: "arrow.up.forward.app")
        }
        .font(.subheadline.weight(.semibold))
    }

    private var backgroundDetails: some View {
        DisclosureGroup("백그라운드 AirRecord란?") {
            VStack(alignment: .leading, spacing: 12) {
                AirRecordInfoRow("어떤 기능인가요?", value: "다른 앱을 사용하거나 화면이 꺼진 동안에도 통화 상태를 확인할 수 있도록 AirRecord의 대기를 유지합니다.")
                AirRecordInfoRow("위치 권한은 왜 필요한가요?", value: "iOS의 백그라운드 위치 기능을 이용합니다. 위치 업데이트는 받지만 좌표는 읽거나 저장·전송하지 않고, 업데이트 시각만 확인합니다.")
                AirRecordInfoRow("어떻게 시작하나요?", value: "이 옵션을 켜고 홈에서 AirRecord를 활성화하세요. ‘앱을 사용하는 동안 허용’을 선택한 뒤 연결 준비가 끝날 때까지 앱을 열어 두세요.")
                AirRecordInfoRow("‘항상 허용’도 필요한가요?", value: "기본 대기에는 정밀 위치나 ‘항상 허용’이 필요하지 않습니다. ‘다이내믹 아일랜드 위치 표시 숨기기’를 사용하려면 ‘항상 허용’이 필요합니다. 표시 여부는 iOS가 관리하므로 모든 위치·개인정보 표시가 사라지는 것은 아닙니다.")
                AirRecordInfoRow("사용할 때 알아두세요", value: "위치 사용 표시와 배터리 소모가 생길 수 있습니다. iOS가 실행을 중단할 수 있으며, 앱을 강제 종료하거나 기기를 재부팅했다면 다시 열어 활성화하세요. AirRecord를 비활성화하면 위치 업데이트도 중지합니다.")
                Divider()
                AirRecordInfoRow("현재 대기 상태", value: standby.status)
                AirRecordInfoRow("현재 위치 권한", value: standby.authorizationText)
                Text(standby.indicatorStatusText)
                if !standby.isEnabled {
                    Text("백그라운드 기능을 켜기 전에 위치 권한을 준비할 수 있습니다.")
                    indicatorPermissionControls
                }
            }
            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
        }
        .font(.subheadline)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var shortcutCard: some View {
        AirRecordCard {
            AirRecordHeading("단축어 자동화", systemImage: "square.stack.3d.up", tint: accent)
            Text("기존 발신 단축어를 열어 자동화 동작을 확인하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("단축어 열기", systemImage: "arrow.up.forward.app") { openOutgoingShortcut() }
                .font(.subheadline.weight(.semibold))
            if let shortcutOpeningError {
                Text(shortcutOpeningError).font(.footnote).foregroundStyle(.orange)
            }
            DisclosureGroup("자동화 연결 방법") {
                VStack(alignment: .leading, spacing: 10) {
                    if standby.isLiveContainer {
                        Text("아래 단축어 동작은 SideStore 독립 설치 후 사용하세요.")
                    }
                    Text("‘전화 앱이 열릴 때’ LocalDevVPN을 연결하는 기존 자동화를 사용하세요. 감시를 다시 준비해야 한다면 VPN 연결 뒤에 ‘통화 감시 재개’ 또는 ‘녹음 시작 대기’를 연결할 수 있습니다.")
                    Text("위치 대기는 AirRecord 화면에서 먼저 준비해야 합니다. 단축어는 준비된 위치 세션을 유지하며 감시를 재개합니다. 위치 대기가 꺼져 있으면 짧은 감시 시간만 준비합니다.")
                    Text("전화 수신 자체를 감지하는 자동화는 아닙니다. 단축어 완료는 실제 녹음 시작 확인과 다릅니다.")
                    Text("이 동작 직후나 ‘전화 앱이 닫힐 때’에 VPN 끄기를 붙이지 마세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
            DisclosureGroup("발신 · 먼저 시험하기") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("‘발신’은 기본 20초, 최대 25초 동안 발신 시작을 기다립니다. 발신하면 즉시 참, 발신 없이 시간이 지나면 거짓을 반환합니다.")
                    Text("이미 단일 발신 중이면 즉시 참을 반환합니다. FaceTime 등 CallKit을 사용하는 통화 앱의 발신도 감지될 수 있습니다.")
                    Text("단축어에서 AirRecord의 ‘발신’을 추가하고, 결과가 참일 때만 셀룰러 데이터를 끄는 등 다음 동작을 실행하도록 조건문을 설정하세요.")
                    Text("발신 대기 시험에는 VPN·페어링·위치 대기나 홈의 AirRecord 활성화가 필요하지 않습니다. 이 동작 자체는 데이터를 끄거나 녹음을 시작하지 않습니다.")
                    Text("전화 앱을 열고 대기 시간이 지난 뒤 발신하면 이번 실행에서는 감지하지 않습니다.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
            DisclosureGroup("발신종료 · 데이터 복구") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("‘발신종료’는 모든 활성 통화가 끝날 때까지 기다립니다. 기본 최대 대기는 60분이며 180분까지 설정할 수 있습니다. 전화를 직접 끊는 동작은 아닙니다.")
                    Text("이미 통화가 없으면 즉시 참을 반환하고, 시간 초과나 중단으로 대기를 끝내면 거짓을 반환합니다. 대기 중에는 시스템 진행 표시가 나타납니다.")
                    Text("셀룰러 데이터를 끈 뒤 ‘발신종료 → 셀룰러 데이터 켜기’를 연결하세요. 일반적인 시간 초과에도 데이터를 복구하려면 종료 결과가 거짓이어도 데이터 켜기가 실행되도록 설정하세요.")
                    Text("단축어 전체를 취소하거나 iOS가 실행을 중단하면 다음 데이터 켜기가 실행되지 않을 수 있습니다. 이때는 셀룰러 데이터를 직접 켜 주세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private func openOutgoingShortcut() {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: AirRecordShortcutPresence.targetName)]
        guard let url = components.url else { return }
        shortcutOpeningError = nil
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in
                if !opened { shortcutOpeningError = "단축어 앱을 열지 못했습니다." }
                // Opening the editor does not prove that the shortcut exists.
            }
        }
    }

    private var guidanceCard: some View {
        AirRecordCard {
            AirRecordHeading("사용 안내", systemImage: "heart.text.clipboard", tint: accent)
            DisclosureGroup("첫 통화와 실행 유지") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("잠금을 해제한 기본 통화 화면에서 먼저 확인하세요. 녹음 요청 후 실제 녹음 타이머와 저장 결과를 확인해 주세요.")
                    Text("AirRecord 설정은 저장됩니다. iOS가 실행을 중단하면 감시는 일시 정지되며, 앱에 돌아오면 연결을 확인하고 재개합니다. 무제한 실행을 보장하지 않습니다.")
                    Text("LocalDevVPN은 실행 중에도 연결되어 있어야 합니다. 강제 종료·재부팅 후에는 앱을 다시 열어 준비하세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
            DisclosureGroup("녹음 안내음") {
                Text("안내음은 iOS와 기존 AirBeep 설정을 따릅니다. AirRecord는 안내음 파일을 변경하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var activityScreen: some View {
        AirRecordPage(accent: accent) {
            AirRecordCard {
                AirRecordHeading("최근 실행 기록", systemImage: "clock.arrow.circlepath", tint: accent)
                Text("연결·대기·녹음 시작 요청의 상태를 확인합니다.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if monitor.recentEvents.isEmpty {
                    ContentUnavailableView("아직 기록이 없습니다", systemImage: "clock",
                                           description: Text("AirRecord를 활성화하면 실행 상태가 여기에 표시됩니다."))
                } else {
                    ForEach(Array(monitor.recentEvents.enumerated().reversed()), id: \.offset) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(accent.opacity(0.6)).frame(width: 7, height: 7)
                                .padding(.top, 7).accessibilityHidden(true)
                            Text(entry.element)
                                .font(.subheadline).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                        if entry.offset != 0 { Divider() }
                    }
                }
            }
            AirRecordCard {
                DisclosureGroup("상태 정보 자세히 보기") {
                    Text(monitor.diagnosticSummary)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                ShareLink(item: monitor.diagnosticSummary) {
                    Label("상태 기록 공유", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .navigationTitle("기록")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct AirRecordPage<Content: View>: View {
    let accent: Color
    let content: Content

    init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 28)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .background {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                LinearGradient(colors: [accent.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .center)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
}

struct AirRecordCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct AirRecordHeading: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Home status cards share typography and spacing without adding card padding.
struct AirRecordStatusRow: View {
    let title: String
    let systemImage: String
    let isConfirmed: Bool
    let accent: Color
    let accessibilityValue: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: isConfirmed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isConfirmed ? Color.green : Color.secondary)
                .accessibilityHidden(true)
        }
        .font(.headline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isHeader)
    }
}

struct AirRecordInfoRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) { self.title = title; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
