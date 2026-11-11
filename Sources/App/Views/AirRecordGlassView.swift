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
    @State private var showLiveContainerNotice = false
    @State private var didShowLiveContainerNotice = false

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
        .alert("LiveContainer 사용 안내", isPresented: $showLiveContainerNotice) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("AirRec을 SideStore에 독립 설치한 뒤 단축어 동작을 사용하세요.")
        }
        .task { await monitor.resumeIfEnabled() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if standby.isLiveContainer, !didShowLiveContainerNotice {
                didShowLiveContainerNotice = true
                showLiveContainerNotice = true
            }
            await standbyAlert.refreshPermission()
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
            AirRecordShortcutStatusView(accent: accent, kind: .incoming)
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
            outgoingDelayCard
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
            Text("AirRec 활성화를 위해 개발자 디스크(DDI) 연결이 필요합니다.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showMount = true } label: {
                Label("개발자 디스크(DDI) 연결", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Divider()
            DisclosureGroup("AirRec 초기 설정이란?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AirRec이 이 아이폰의 개발자 서비스에 연결할 수 있도록 페어링 파일과 개발자 디스크를 준비하는 과정입니다.")
                    AirRecordInfoRow("Q. 페어링 파일은 어디서 가져오나요?", value: "iLoader에서 ‘페어링 파일 관리’를 선택한 뒤 .plist 확장자 파일을 기기로 가져오세요.")
                    AirRecordInfoRow("Q. DDI 파일은 어디에 저장되나요?", value: "다운로드한 파일은 AirRec 앱 데이터에 저장됩니다. AirRec을 삭제하면 다운로드한 파일도 지워집니다.")
                    AirRecordInfoRow("Q. 앱을 재설치하고 DDI를 내려받으면 용량이 늘어나나요?", value: "재설치 때마다 앱에 파일이 쌓이지는 않습니다.")
                    AirRecordInfoRow("Q. 페어링 파일을 불러오려는데 응답이 없어요.", value: "파일 앱에서 .plist 파일을 길게 누른 뒤 ‘공유’ → ‘AirRec’을 선택하세요.")
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
            Text("백그라운드에서도 통화 연결 상태를 계속 확인합니다.\n위치 권한은 ‘앱을 사용하는 동안만 허용’으로 설정하세요. ‘정확한 위치’는 꺼도 됩니다.")
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
            Toggle("AirRec 비활성화 시 알림", isOn: Binding(
                get: { standbyAlert.isEnabled },
                set: { enabled in Task { await standbyAlert.setEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(standbyAlert.isRequestingPermission || standby.isLiveContainer)
            Text("AirRec이 작동하지 않을 때 알립니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standbyAlert.hasAlertPermission == true && !standby.isLiveContainer {
                Label("알림 허용됨", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.green)
            } else if standbyAlert.hasAlertPermission == false {
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
                Text("다른 앱을 사용하거나 화면이 꺼진 동안에도 통화 상태를 확인할 수 있도록 AirRec의 대기를 유지합니다.")
                AirRecordInfoRow("Q. 위치 권한은 왜 필요한가요?", value: "iOS의 백그라운드 위치 기능으로 대기 상태를 유지합니다. 위치 업데이트는 받지만 좌표는 읽거나 저장·전송하지 않고 업데이트 시각만 확인합니다.")
                AirRecordInfoRow("Q. 배터리가 빨리 소모될 수 있나요?", value: "위치 사용 표시가 나타나거나 배터리가 더 빨리 소모될 수 있습니다.")
                AirRecordInfoRow("Q. 알림은 언제 오나요?", value: "백그라운드 감시가 확인되지 않거나 단축어의 ‘상태 확인’에서 통화 감시가 준비되지 않았을 때 알림을 보냅니다.")
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
            AirRecordHeading("AirRec 단축어 자동화", systemImage: "square.stack.3d.up", tint: accent)
            Divider()
            Link(destination: URL(string: "https://www.icloud.com/shortcuts/b362f158794f4d75870615194748b582")!) {
                Label("AirRec(발신) 단축어 추가", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            shortcutPermissionHint
            shortcutExampleLink("AirRec(발신)", imageName: "AirRecOutgoingShortcutExample")
            Divider()
            incomingNotificationControls
            Divider()
            Link(destination: URL(string: "https://www.icloud.com/shortcuts/17467870cbcd41c3a06912673661a8a4")!) {
                Label("AirRec(수신) 단축어 추가", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            shortcutPermissionHint
            shortcutExampleLink("AirRec(수신)", imageName: "AirRecIncomingShortcutExample")
            Divider()
            Button { openAppSettings() } label: {
                settingsActionLabel("AirRec 단축어 자동화 시 다이내믹 아일랜드 표시 숨기기")
            }
            .buttonStyle(.plain)
            Text("AirRec 단축어 자동화 중 다이내믹 아일랜드 진행 표시가 불편하면 설정에서 꺼 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Link(destination: URL(string: "shortcuts://")!) {
                Label("단축어 탭 열기", systemImage: "arrow.up.forward.app")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accent)
            .buttonStyle(.plain)
            Divider()
            DisclosureGroup("AirRec 단축어 자동화란?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wi-Fi와 LocalDevVPN 연결 상태에 따라 AirRec의 동작이 달라질 수 있습니다. 단축어로 필요한 연결 동작을 자동화할 수 있습니다.")
                    AirRecordInfoRow("1. AirRec(발신) 작동 원리", value: "전화 앱 열림 → LocalDevVPN 연결 → AirRec 상태 확인 → 발신 감지 → 셀룰러 데이터 끄기 → 통화 녹음 → 통화 종료 감지 → 셀룰러 데이터 켜기 → LocalDevVPN 연결 해제(선택 사항)")
                    AirRecordInfoRow("2. AirRec(수신) 작동 원리", value: "AirRec 수신 감지 → 수신 알림 → 단축어 자동화 → LocalDevVPN 연결")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            DisclosureGroup("AirRec(발신) 단축어 로직 설명") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("전화 앱이 열릴 시 단축어가 실행됩니다. 셀룰러가 꺼질 경우 LocalDevVPN이 정상 작동하므로 이를 이용합니다.")
                    AirRecordInfoRow("1. 전화 앱이 열립니다.", value: "LocalDevVPN이 자동으로 연결됩니다.")
                    AirRecordInfoRow("2. AirRec이 상태를 확인합니다.", value: "AirRec이 준비되지 않았으면 알림을 보냅니다.")
                    AirRecordInfoRow("3. AirRec이 발신을 대기합니다.", value: "발신 대기 기본값은 20초입니다. 아래 시간 설정에서 변경 할 수 있습니다.")
                    AirRecordInfoRow("4. AirRec이 발신을 감지합니다.", value: "발신이 감지되면 셀룰러가 꺼지고 통화 녹음이 시작됩니다. 와이파이 상태에서는 실행되지 않습니다.")
                    AirRecordInfoRow("5. AirRec이 통화 종료를 감지합니다.", value: "통화 종료 기본값은 60분입니다. 아래 시간 설정에서 변경 할 수 있습니다. 통화 종료가 감지되면 셀룰러가 켜지고 통화 녹음이 종료됩니다. 와이파이 상태에서는 실행되지 않습니다.")
                    AirRecordInfoRow("6. LocalDevVPN 연결을 해제합니다.(선택)", value: "사용자가 직접 단축어를 수정하여 LocalDevVPN 연결 해제를 추가할 수 있습니다. 단축어를 수정하지 않으면 LocalDevVPN은 계속 연결된 상태로 유지됩니다.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            DisclosureGroup("AirRec(수신) 단축어 로직 설명") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AirRec이 활성화된 상태에서 전화가 오면 통화당 한 번 알림을 보냅니다.")
                    AirRecordInfoRow("1. 알림 자동화 만들기", value: "단축어에서 ‘알림’ 자동화를 만들고 앱을 AirRec으로 선택하세요. 제목에 ‘수신’이 포함되도록 설정하고 ‘즉시 실행’을 선택하세요.")
                    AirRecordInfoRow("2. VPN 동작 추가하기", value: "동작으로 ‘Enable LocalDevVPN’을 추가하세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            DisclosureGroup("단축어 종류 설명") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AirRec 단축어는 크게 수신, 발신, 공통으로 나뉩니다.")
                    AirRecordInfoRow("상태확인", value: "구현중...")
                    AirRecordInfoRow("발신", value: "구현중...")
                    AirRecordInfoRow("발신종료", value: "구현중...")
                    AirRecordInfoRow("수신", value: "구현중...")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var incomingNotificationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("전화 수신 알림", isOn: Binding(
                get: { standbyAlert.isIncomingEnabled },
                set: { enabled in Task { await standbyAlert.setIncomingEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(standbyAlert.isRequestingPermission || standby.isLiveContainer)
            Text("전화가 오면 ‘\(AirRecordStandbyAlert.incomingNotificationTitle)’ 알림을 보냅니다. 이 알림으로 LocalDevVPN 연결을 자동화할 수 있어요.")
                .font(.footnote).foregroundStyle(.secondary)
            if standbyAlert.hasAlertPermission == false && !standbyAlert.canRequestPermission && !standby.isLiveContainer {
                Button { openAppSettings() } label: {
                    Label("AirRec 설정 열기", systemImage: "arrow.up.forward.app")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var shortcutPermissionHint: some View {
        Text("**중요** · 처음 사용하기 전에 아래 **‘단축어 탭 열기’를 누른 뒤 단축어를 직접 한 번 실행**해 필요한 권한을 허용해 주세요.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func shortcutExampleLink(_ title: String, imageName: String) -> some View {
        NavigationLink {
            ScrollView {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 540)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .accessibilityLabel("\(title) 단축어 구성 화면")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            settingsActionLabel("\(title) 구성 예시", systemImage: "chevron.right", titleColor: accent)
        }
        .buttonStyle(.plain)
    }

    private var outgoingDelayCard: some View {
        AirRecordCard {
            AirRecordHeading("발신 대기 시간 설정", systemImage: "timer", tint: accent)
            Divider()
            Stepper(value: Binding(
                get: { monitor.outgoingDelaySeconds },
                set: { monitor.setOutgoingDelaySeconds($0) }
            ), in: AirRecordPolicy.outgoingDelayRange) {
                Text("연결 후 녹음 대기 \(monitor.outgoingDelaySeconds)초")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("발신 녹음 대기 시간")
            .accessibilityValue("\(monitor.outgoingDelaySeconds)초")
            Text("새로 연결되는 발신 통화에 적용됩니다. 0초로 설정하면 추가 대기 없이 녹음을 준비합니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if let destination = outgoingShortcutEditorURL {
                Divider()
                shortcutWaitLink("발신 단축어 최대 대기 시간", destination: destination)
                Text("전화를 걸기 시작할 때까지 기다리는 시간입니다. ‘AirRec(발신)’의 ‘발신’에서 1~180초로 설정할 수 있으며, 기본값은 20초입니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Divider()
                shortcutWaitLink("발신종료 단축어 최대 대기 시간", destination: destination)
                Text("통화가 끝날 때까지 기다리는 시간입니다. ‘AirRec(발신)’의 ‘발신종료’에서 분 단위로 설정하세요. 기본값은 60분입니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var outgoingShortcutEditorURL: URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: "AirRec(발신)")]
        return components.url
    }

    private func shortcutWaitLink(_ title: String, destination: URL) -> some View {
        Link(destination: destination) {
            settingsActionLabel(title)
        }
        .buttonStyle(.plain)
    }

    private func settingsActionLabel(_ title: String, systemImage: String = "arrow.up.forward.app",
                                     titleColor: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(titleColor)
            Spacer(minLength: 8)
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
        }
        .font(.headline)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
                Button("모든 기록 초기화", systemImage: "trash", role: .destructive) {
                    monitor.clearRecentEvents()
                }
                .buttonStyle(.bordered)
                .disabled(monitor.recentEvents.isEmpty)
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
