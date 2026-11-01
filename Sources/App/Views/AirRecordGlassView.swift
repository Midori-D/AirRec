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

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.52, blue: 0.65)
            : Color(red: 0.76, green: 0.20, blue: 0.36)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "AirRecord \(name) 빌드 \(build)"
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
            AirRecordCard {
                AirRecordHeading("전화가 연결되면", systemImage: "phone.fill", tint: accent)
                Text("더 보기 → 통화 녹음을 순서대로 누릅니다. 녹음과 저장은 아이폰의 기본 기능이 처리합니다.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("첫 통화에서는 실제 녹음 타이머와 저장 결과를 확인해 주세요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
                Text(version)
                    .font(.subheadline).foregroundStyle(.secondary)
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
                    Text(monitor.isPreparing ? "연결 준비 중" : (monitor.isRunning ? "자동 녹음 대기" : "자동 시작을 준비하세요"))
                        .font(.title2.weight(.bold))
                    Text(monitor.isEnabled ? "자동 시작 설정 켜짐" : "자동 시작 설정 꺼짐")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Text(monitor.status)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            monitoringControls
        }
    }

    @ViewBuilder
    private var monitoringControls: some View {
        if monitor.isRunning {
            Button(role: .destructive) { monitor.stop() } label: {
                Label("자동 시작 끄기", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        } else {
            Button { Task { await monitor.start() } } label: {
                HStack(spacing: 8) {
                    if monitor.isPreparing { ProgressView().controlSize(.small) }
                    Text(monitor.isPreparing ? "준비 중…" : (monitor.isEnabled ? "연결 다시 확인" : "자동 시작 켜기"))
                        .fontWeight(.semibold)
                    if !monitor.isPreparing { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(monitor.isPreparing)
            if monitor.isEnabled || monitor.isPreparing {
                Button("자동 시작 끄기", role: .destructive) { monitor.stop() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var standbySummary: some View {
        AirRecordCard {
            AirRecordHeading("백그라운드 대기", systemImage: "location.circle", tint: accent)
            HStack(alignment: .firstTextBaseline) {
                Text(standby.isRunning ? "장시간 대기 준비됨" : (standby.isEnabled ? "장시간 대기 재개 필요" : "장시간 대기 꺼짐"))
                    .font(.headline)
                Spacer(minLength: 8)
                Image(systemName: standby.isRunning ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(standby.isRunning ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
            }
            Text(standby.isRunning ? "위치 세션으로 대기 중입니다. 실행 상태는 기록 탭에서 확인할 수 있습니다."
                 : "위치 서비스를 이용한 대기는 설정에서 켤 수 있습니다.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { selectedTab = .settings } label: {
                Label("대기 설정 보기", systemImage: "arrow.up.right")
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var settingsScreen: some View {
        AirRecordPage(accent: accent) {
            preparationCard
            locationCard
            indicatorCard
            systemSettingsCard
            shortcutCard
            guidanceCard
            Text(version)
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
    }

    private var preparationCard: some View {
        AirRecordCard {
            AirRecordHeading("실행 준비", systemImage: "checklist", tint: accent)
            Text("LocalDevVPN 연결과 개발자 디스크 준비를 마친 뒤 자동 시작을 켜세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showMount = true } label: {
                Label("페어링 파일 · 개발자 디스크", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var locationCard: some View {
        AirRecordCard {
            AirRecordHeading("장시간 대기", systemImage: "location.circle", tint: accent)
            Toggle("위치 서비스로 장시간 대기", isOn: Binding(
                get: { standby.isEnabled },
                set: { enabled in Task { await monitor.setLocationStandbyEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(monitor.isPreparing || (standby.isLiveContainer && !standby.isEnabled))
            Text(standby.status).font(.subheadline).foregroundStyle(.secondary)
            Text("좌표는 사용·저장·전송하지 않습니다. 위치 사용 표시와 배터리 소모가 생길 수 있습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standby.isLiveContainer {
                Label("장시간 대기는 SideStore에 독립 설치한 앱에서 사용하세요.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup("권한과 대기 방식 알아보기") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("이 옵션과 자동 시작을 켠 뒤 ‘앱을 사용하는 동안 허용’을 선택하세요. 준비가 완료될 때까지 앱을 열어 두세요.")
                    Text("기본 대기에는 정밀 위치나 ‘항상 허용’이 필요하지 않습니다. 위치 표시 최소화 옵션은 ‘항상 허용’을 별도로 사용합니다. 통화 녹음 자체에는 위치가 필요하지 않으며, 위치 업데이트로 앱의 대기 실행을 유지합니다.")
                    Text("자동 시작을 끄면 위치 업데이트도 중지합니다. 강제 종료·재부팅 후에는 앱을 다시 열어 준비하세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var indicatorCard: some View {
        AirRecordCard {
            AirRecordHeading("위치 사용 표시", systemImage: "location", tint: accent)
            Toggle("위치 표시 최소화(항상 허용)", isOn: Binding(
                get: { standby.indicatorMinimizationEnabled },
                set: { standby.setIndicatorMinimizationEnabled($0) }
            ))
            .font(.headline)
            .disabled(monitor.isPreparing || standby.isLiveContainer)
            AirRecordInfoRow("현재 위치 권한", value: standby.authorizationText)
            Text(standby.indicatorStatusText)
                .font(.subheadline).foregroundStyle(.secondary)
            Text("‘항상 허용’을 받은 뒤 백그라운드 위치 표시를 줄이도록 요청합니다. ‘앱을 사용하는 동안 허용’ 상태에서는 이 옵션만으로 표시를 숨길 수 없습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standby.indicatorMinimizationEnabled {
                Button { standby.requestAlwaysAuthorization() } label: {
                    Label("항상 허용 권한 요청", systemImage: "hand.raised")
                }
                .font(.subheadline.weight(.semibold))
                .disabled(monitor.isPreparing || standby.isLiveContainer)
            }
            Text("권한 창이 다시 나오지 않으면 아래의 iOS 설정 열기에서 변경하세요. 장시간 대기 효과는 실기기 확인이 필요하며, iOS의 모든 위치·개인정보 표시가 사라지는 기능은 아닙니다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var systemSettingsCard: some View {
        AirRecordCard {
            AirRecordHeading("iOS 백그라운드 설정", systemImage: "gearshape", tint: accent)
            AirRecordInfoRow("앱 새로 고침", value: standby.backgroundRefreshStatusText)
            Divider()
            AirRecordInfoRow("저전력 모드", value: standby.lowPowerModeEnabled ? "켜짐" : "꺼짐")
            Text("현재 앱은 주기 새로 고침을 사용하지 않습니다. 장시간 대기는 위치 세션으로 유지합니다. 새로 고침을 켜는 것만으로 지속 실행이나 통화 수신 시 실행을 보장하지 않습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("AirRecord의 iOS 설정 열기", systemImage: "arrow.up.forward.app")
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var shortcutCard: some View {
        AirRecordCard {
            AirRecordHeading("단축어 자동화", systemImage: "square.stack.3d.up", tint: accent)
            Text("전화 앱을 열 때, 감시도 함께 준비하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("자동화 연결 방법") {
                VStack(alignment: .leading, spacing: 10) {
                    if standby.isLiveContainer {
                        Text("아래 단축어 동작은 SideStore 독립 설치 후 사용하세요.")
                    }
                    Text("단축어에서 ‘전화 앱이 열릴 때’ 자동화를 만들고, ‘VPN 연결’ 다음에 AirRecord의 ‘통화 감시 재개’를 추가하세요.")
                    Text("위치 대기는 AirRecord 화면에서 먼저 준비해야 합니다. 단축어는 준비된 위치 세션을 유지하며 감시를 재개합니다. 위치 대기가 꺼져 있으면 짧은 감시 시간만 준비합니다.")
                    Text("전화 수신 자체를 감지하는 자동화는 아닙니다. 단축어 완료는 실제 녹음 시작 확인과 다릅니다.")
                    Text("이 동작 직후나 ‘전화 앱이 닫힐 때’에 VPN 끄기를 붙이지 마세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var guidanceCard: some View {
        AirRecordCard {
            AirRecordHeading("사용 안내", systemImage: "heart.text.clipboard", tint: accent)
            DisclosureGroup("첫 통화와 실행 유지") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("잠금을 해제한 기본 통화 화면에서 먼저 확인하세요. 녹음 요청 후 실제 녹음 타이머와 저장 결과를 확인해 주세요.")
                    Text("자동 시작 설정은 직접 끌 때까지 유지됩니다. iOS가 실행을 중단하면 감시는 일시 정지되며, 앱에 돌아오면 연결을 확인하고 재개합니다. 무제한 실행을 보장하지 않습니다.")
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
                                           description: Text("자동 시작을 준비하면 실행 상태가 여기에 표시됩니다."))
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
