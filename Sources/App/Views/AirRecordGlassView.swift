// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION // AIRRECORD_AUTOMATION 조건이 있을 경우 아래 코드를 빌드에 포함함
import SwiftUI

private enum AirRecordTab: Hashable {
    case home, settings, activity, contact
}

@MainActor
struct AirRecordGlassView: View {
    @StateObject private var monitor = AirRecordMonitor.shared
    @StateObject private var standby = AirRecordLocationKeepAlive.shared
    @StateObject private var standbyAlert = AirRecordStandbyAlert.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab = AirRecordTab.home
    @State private var showCompactHomeTitle = false
    @State private var showMount = false
    @State private var shortcutOpeningError: String?

    // 앱 대표 색상
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
        // Liquid Glass
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showMount) { DDIMountView() }
        .task { await monitor.resumeIfEnabled() }
        .task(id: scenePhase) {
            if scenePhase == .active { await standbyAlert.refreshPermission() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await monitor.resumeIfEnabled() } }
            if phase == .background { monitor.appDidEnterBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.resumeIfEnabled() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            monitor.appDidEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            standbyAlert.reportTermination()
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
                .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                    showCompactHomeTitle = !isVisible
                }
            monitoringCard
            standbySummary
            // 추후 구현...
            AirRecordShortcutStatusView(accent: accent)
            AirRecordShortcutStatusView(accent: accent, kind: .end)
            AirRecordPlannedFeatureView(title: "AirRec 수신 자동화", systemImage: "phone.arrow.down.left", accent: accent)
            AirRecordPlannedFeatureView(title: "AirRec 수신종료 자동화", systemImage: "phone.down.fill", accent: accent)
            AirRecordPlannedFeatureView(title: "AirRec 메모 이름 수정", systemImage: "note.text", accent: accent)
            AirRecordPlannedFeatureView(title: "AirBeep (통화 녹음 고지 제거)", systemImage: "speaker.slash", accent: accent)
            AirRecordPlannedFeatureView(title: "AirBeep2 (통화 녹음 카운트다운 제거)", systemImage: "timer", accent: accent)
        }
        .navigationTitle(showCompactHomeTitle ? "AirRec" : "")
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
                Text("AirRec")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
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
                    Text(monitor.isRunning ? "AirRec 일하는 중 🧐" : "AirRec 쉬는 중 😴")
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
        if monitor.activationError != nil { return "AirRec 404 Error" }
        if monitor.isPreparing { return "AirRec 연결 중" }
        if monitor.isRunning { return "AirRec 활성화됨" }
        return monitor.isEnabled ? "AirRec 404 Error" : "AirRec 비활성화됨"
    }

    @ViewBuilder
    private var monitoringControls: some View {
        if monitor.isRunning && monitor.activationError == nil {
            Button(role: .destructive) { monitor.stop() } label: {
                Label("AirRec 비활성화", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        } else {
            Button { Task { await monitor.start() } } label: {
                HStack(spacing: 8) {
                    if monitor.isPreparing { ProgressView().controlSize(.small) }
                    Text(monitor.isPreparing ? "연결 중…" : "AirRec 활성화")
                        .fontWeight(.semibold)
                    if !monitor.isPreparing { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(monitor.isPreparing)
            if monitor.activationError == nil && monitor.isPreparing {
                Button("AirRec 비활성화", role: .destructive) { monitor.stop() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var standbySummary: some View {
        AirRecordCard {
            AirRecordStatusRow(title: "백그라운드 AirRec", systemImage: "location.fill",
                               isConfirmed: standby.isRunning && monitor.isRunning, accent: accent,
                               accessibilityValue: standby.isRunning && monitor.isRunning ? "활성화됨" : "비활성화됨")
        }
    }

    private var settingsScreen: some View {
        AirRecordPage(accent: accent) {
            preparationCard
            backgroundCard
            shortcutCard
            AirRecordVersionLabel(version: version)
                .font(.footnote)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
    }

    private var preparationCard: some View {
        AirRecordCard {
            AirRecordHeading("AirRec 초기 설정", systemImage: "checklist", tint: accent)
            Divider()
            Text("처음 설치했다면 페어링 파일과 개발자 디스크(DDI)를 준비하고 LocalDevVPN을 연결한 뒤 AirRec을 활성화하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showMount = true } label: {
                Label("DDI 연결", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Divider()
            DisclosureGroup("AirRec 초기 설정이란?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AirRec이 이 아이폰의 개발자 서비스에 연결할 수 있도록 페어링 파일과 개발자 디스크를 준비하는 과정입니다.")
                    AirRecordInfoRow("1. 페어링 파일 가져오기", value: "iLoader 또는 idevice_pair 등으로 준비한 RemotePairing 파일을 선택하세요. 개인 페어링 파일은 다른 사람에게 공유하지 마세요.")
                    AirRecordInfoRow("2. 개발자 디스크 다운로드", value: "다운로드한 파일은 다음 연결에도 다시 사용합니다. 다운로드 시간은 네트워크 상태에 따라 달라집니다.")
                    AirRecordInfoRow("3. LocalDevVPN 연결", value: "LocalDevVPN을 연결해 주세요.")
                    AirRecordInfoRow("4. 개발자 디스크 연결", value: "‘개발자 디스크 연결’을 누르고 연결 성공을 확인한 뒤 홈에서 AirRec을 활성화하세요.")
                    AirRecordInfoRow("DDI 파일은 어디에 저장되나요?", value: "다운로드한 파일은 AirRec 앱 데이터에 저장됩니다. AirRec을 삭제하면 다운로드한 파일도 지워집니다.")
                    AirRecordInfoRow("앱을 재설치하고 DDI를 내려받으면 용량이 늘어나나요?", value: "재설치 때마다 앱에 파일이 쌓이지는 않습니다.")
                    AirRecordInfoRow("iOS 업데이트 후 용량이 늘 수 있나요?", value: "iOS 26.3 이하에서 26.4 이상으로 업데이트한 뒤 새 개발자 디스크를 내려받으면, 이전 파일도 앱에 남아 용량이 늘 수 있습니다.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var backgroundCard: some View {
        AirRecordCard {
            AirRecordHeading("백그라운드 AirRec", systemImage: "location.fill", tint: accent)
            Divider()
            Toggle("백그라운드 AirRec 활성화", isOn: Binding(
                get: { standby.isEnabled },
                set: { enabled in Task { await monitor.setLocationStandbyEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(monitor.isPreparing || (standby.isLiveContainer && !standby.isEnabled))
            Text("화면을 끄거나 다른 앱을 쓰는 동안에도 통화 연결을 감시합니다. 위치 권한이 필요하며, AirRec은 위치 업데이트 시각만 확인합니다. 위치 권한은 ‘앱을 사용하는 동안 허용’을 권장합니다. ‘정확한 위치’는 꺼도 됩니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standby.isLiveContainer {
                Label("백그라운드 기능은 SideStore에 독립 설치한 앱에서 사용하세요.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            locationPermissionStatuses
            if standby.isEnabled {
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
            Divider()
            Toggle("AirRec 종료 알림", isOn: Binding(
                get: { standbyAlert.isEnabled },
                set: { enabled in Task { await standbyAlert.setEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(standbyAlert.isRequestingPermission || standby.isLiveContainer)
            Text("종료 신호를 받으면 바로 알립니다. 백그라운드 감시를 약 3분 동안 확인하지 못하면 상태 확인 알림을 보냅니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standbyAlert.canRequestPermission {
                Button("알림 허용", systemImage: "bell.badge") {
                    Task { _ = await standbyAlert.requestPermission() }
                }
                .font(.subheadline.weight(.semibold))
                .disabled(standbyAlert.isRequestingPermission || standby.isLiveContainer)
            } else if standbyAlert.needsPermission {
                Text("아래의 ‘AirRec 설정 열기’를 탭해 알림과 배너를 허용해 주세요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            Button { openAppSettings() } label: {
                Label("AirRec 설정 열기", systemImage: "arrow.up.forward.app")
            }
            .font(.subheadline.weight(.semibold))
            Divider()
            backgroundDetails
        }
    }

    private var locationPermissionStatuses: some View {
        let canReadPermissions = !standby.isLiveContainer
        let showAlwaysInIndicatorSettings = standby.isEnabled && standby.indicatorMinimizationEnabled
            && standby.hasAlwaysAuthorization && canReadPermissions
        let reducedAccuracy = standby.isPreciseLocationEnabled.map { !$0 }
        return VStack(alignment: .leading, spacing: 8) {
            if !showAlwaysInIndicatorSettings {
                locationPermissionRow("앱을 사용하는 동안", confirmed: canReadPermissions ? standby.hasWhenInUseAuthorization : nil,
                                      confirmedText: "허용 확인됨", unconfirmedText: "선택 안 됨")
            }
            locationPermissionRow("정확한 위치", confirmed: canReadPermissions ? reducedAccuracy : nil,
                                  confirmedText: "꺼짐", unconfirmedText: "켜짐")
        }
    }

    private func locationPermissionRow(_ title: String, confirmed: Bool?,
                                       confirmedText: String, unconfirmedText: String) -> some View {
        let state: String
        switch confirmed {
        case .some(true): state = confirmedText
        case .some(false): state = unconfirmedText
        case .none: state = "확인 불가"
        }
        let showCheck = confirmed == true
        return Label("\(title) \(state)", systemImage: showCheck ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(showCheck ? Color.green : Color.red)
    }

    @ViewBuilder
    private var indicatorPermissionControls: some View {
        if standby.hasAlwaysAuthorization {
            locationPermissionRow("항상 허용", confirmed: standby.isLiveContainer ? nil : true,
                                  confirmedText: "확인됨", unconfirmedText: "선택 안 됨")
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
    }

    private var backgroundDetails: some View {
        DisclosureGroup("백그라운드 AirRec이란?") {
            VStack(alignment: .leading, spacing: 12) {
                AirRecordInfoRow("어떤 기능인가요?", value: "다른 앱을 사용하거나 화면이 꺼진 동안에도 통화 상태를 확인할 수 있도록 AirRec의 대기를 유지합니다.")
                AirRecordInfoRow("위치 권한은 왜 필요한가요?", value: "iOS의 백그라운드 위치 기능을 이용합니다. 위치 업데이트는 받지만 좌표는 읽거나 저장·전송하지 않고, 업데이트 시각만 확인합니다.")
                AirRecordInfoRow("어떻게 시작하나요?", value: "이 옵션을 켜고 홈에서 AirRec을 활성화하세요. ‘앱을 사용하는 동안 허용’을 선택한 뒤 연결 준비가 끝날 때까지 앱을 열어 두세요.")
                AirRecordInfoRow("‘항상 허용’도 필요한가요?", value: "기본 대기에는 정밀 위치나 ‘항상 허용’이 필요하지 않습니다. ‘다이내믹 아일랜드 위치 표시 숨기기’를 사용하려면 ‘항상 허용’이 필요합니다. 표시 여부는 iOS가 관리하므로 모든 위치·개인정보 표시가 사라지는 것은 아닙니다.")
                AirRecordInfoRow("사용할 때 알아두세요", value: "위치 사용 표시와 배터리 소모가 생길 수 있습니다. iOS가 실행을 중단할 수 있으며, 앱을 강제 종료하거나 기기를 재부팅했다면 다시 열어 활성화하세요. AirRec을 비활성화하면 위치 업데이트도 중지합니다.")
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
            AirRecordHeading("AirRec 자동화", systemImage: "square.stack.3d.up", tint: accent)
            Divider()
            Stepper(value: Binding(
                get: { monitor.outgoingDelaySeconds },
                set: { monitor.setOutgoingDelaySeconds($0) }
            ), in: AirRecordPolicy.outgoingDelayRange) {
                Text("발신 녹음 대기 \(monitor.outgoingDelaySeconds)초")
                    .font(.subheadline.weight(.semibold))
            }
            Text("새로 연결되는 발신 통화에 적용됩니다. 0초로 설정하면 추가 대기 없이 녹음을 준비합니다.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Link(destination: URL(string: "https://www.icloud.com/shortcuts/b888fa97da424299aa6cc67cbc4c7402")!) {
                Label("AirRec(발신) 단축어 추가", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Divider()
            Button("추가한 단축어 열기", systemImage: "arrow.up.forward.app") { openOutgoingShortcut() }
                .font(.subheadline.weight(.semibold))
            if let shortcutOpeningError {
                Text(shortcutOpeningError).font(.footnote).foregroundStyle(.orange)
            }
            Divider()
            Button {} label: {
                HStack(spacing: 10) {
                    Label("AirRec(수신) 단축어 추가", systemImage: "plus.circle")
                    Spacer(minLength: 8)
                    Text("준비 중").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(true)
            Divider()
            Button("실시간 현황 설정 열기", systemImage: "livephoto") { openAppSettings() }
                .font(.subheadline.weight(.semibold))
            Text("다이내믹 아일랜드 진행 표시는 iOS의 ‘실시간 현황’ 설정에서 관리합니다. 단축어에서 표시되는 경우 설정의 ‘단축어’ 항목도 확인해 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("AirRec 자동화란?") {
                VStack(alignment: .leading, spacing: 12) {
                    if standby.isLiveContainer {
                        Text("AirRec을 SideStore에 독립 설치한 뒤 단축어 동작을 사용하세요.")
                    }
                    AirRecordInfoRow("1. 준비하기", value: "AirRec 초기 설정을 마치고 백그라운드 AirRec과 홈의 AirRec을 활성화하세요. 단축어를 추가한 뒤, 단축어 앱의 자동화에서 ‘전화 앱이 열릴 때’ LocalDevVPN을 연결하고 ‘AirRec(발신)’을 실행하도록 설정하세요.")
                    AirRecordInfoRow("감시 상태 확인", value: "LocalDevVPN 연결 다음, Wi-Fi 조건문 앞에 ‘상태 확인’을 추가하세요. 결과가 ‘아니요’면 이 단축어를 중단하세요. iOS 알림을 허용하면 AirRec이 앱을 다시 열라는 알림을 즉시 요청합니다.")
                    AirRecordInfoRow("2. Wi-Fi 확인하기", value: "Wi-Fi 네트워크 이름이 있으면 셀룰러 설정을 그대로 두세요. 이름이 비어 있을 때만 AirRec의 ‘발신’ 동작을 실행하세요.")
                    AirRecordInfoRow("3. 발신을 감지하면 데이터 끄기", value: "‘발신’의 최대 대기 시간에 1~180초를 입력할 수 있습니다. 기본값은 20초이며, 25초를 넘기면 대기 중 iOS 진행 표시가 나타날 수 있습니다. 결과가 ‘예’일 때만 ‘셀룰러 데이터 끄기 → 발신종료 → 셀룰러 데이터 켜기’를 실행하세요.")
                    AirRecordInfoRow("4. 통화가 끝나면 데이터 복구하기", value: "‘발신종료’는 활성 통화가 모두 끝날 때까지 기다립니다. 기본 60분, 최대 180분이며 대기 중 진행 표시가 나타납니다. 시간 초과에도 데이터를 복구하도록 ‘켜기’는 종료 결과와 관계없이 실행하세요. 단축어가 중단됐다면 데이터를 직접 켜 주세요.")
                    AirRecordInfoRow("발신 녹음은 언제 시작하나요?", value: "발신 통화가 연결되면 설정한 시간만큼 기다린 뒤 ‘더 보기’를 엽니다. 음성사서함도 통화 연결로 인식될 수 있으니, 녹음을 원하지 않으면 대기 중에 전화를 끊어 주세요.")
                    AirRecordInfoRow("수신 시험하기", value: "단축어 앱에서 AirRec의 ‘수신’ 동작을 실행한 뒤 다른 전화기로 걸어 보세요. 기본 20초 동안 응답 전의 수신 통화를 감지하면 ‘예’를 반환합니다. 자동으로 단축어를 시작할 수신 트리거는 아직 없습니다.")
                    AirRecordInfoRow("기존 단축어 연결", value: "새 번들 ID로 설치한 후 기존 동작이 실행되지 않으면 단축어에서 AirRec의 ‘발신’과 ‘발신종료’를 다시 선택하세요.")
                    AirRecordInfoRow("첫 통화 확인", value: "발신 감지는 단축어에서 따로 시험할 수 있습니다. 실제 녹음은 전화 화면의 타이머와 메모 앱에서 확인하세요. 전화 앱을 닫아도 통화는 이어질 수 있으므로 앱이 닫힐 때 VPN을 끄도록 설정하면 녹음 준비가 끊길 수 있습니다.")
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

    private var activityScreen: some View {
        AirRecordPage(accent: accent) {
            AirRecordCard {
                AirRecordHeading("최근 실행 기록", systemImage: "clock.arrow.circlepath", tint: accent)
                if monitor.recentEvents.isEmpty {
                    ContentUnavailableView("아직 기록이 없습니다", systemImage: "clock",
                                           description: Text("AirRec을 활성화하면 실행 상태가 여기에 표시됩니다."))
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
