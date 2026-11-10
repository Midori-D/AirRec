// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
import Combine
import SwiftUI
import UIKit

@main
struct AirRecordApp: App {
    @UIApplicationDelegateAdaptor(AirRecordNotificationDelegate.self) private var notificationDelegate
    @StateObject private var permission = NetworkPermission()
    @State private var showPermissionAlert = false
    @State private var sharedPairing: SharedPairingResult?

    private struct SharedPairingResult: Identifiable {
        let id = UUID()
        let fileName: String
        let error: String?
    }

    init() {
        // 로그 저장
        airRecordLog("App launched")
    }

    var body: some Scene {
        WindowGroup {
            AirRecordGlassView()
                // .plist 파일 저장
                .onOpenURL { url in
                    guard url.isFileURL else { return } // 파일 URL이 아닌 경우 무시
                    let name = url.lastPathComponent
                    do {
                        try PairingFileStore.importShared(from: url)
                        airRecordLog("Pairing file received via share: \(name)")
                        sharedPairing = SharedPairingResult(fileName: name, error: nil)
                    } catch {
                        airRecordLog("Shared file \(name) rejected: \(error.localizedDescription)")
                        sharedPairing = SharedPairingResult(fileName: name, error: error.localizedDescription)
                    }
                }
                // 결과 알림
                .alert(item: $sharedPairing) { result in
                    if let error = result.error {
                        return Alert(title: Text(L10n.t(.pairingRejectedTitle)),
                                     message: Text("\(result.fileName)\n\n\(error)"),
                                     dismissButton: .default(Text(L10n.t(.doneButton))))
                    }
                    return Alert(title: Text(L10n.t(.pairingReceivedTitle)),
                                 message: Text(String(format: L10n.t(.pairingReceivedBody), result.fileName)),
                                 dismissButton: .default(Text(L10n.t(.doneButton))))
                }
                // 로컬 네트워크 권한 확인
                .task { permission.probe() }
                .onReceive(permission.$networkData.combineLatest(permission.$localNetwork)) { _ in
                    if !permission.denied.isEmpty { showPermissionAlert = true }
                }
                .alert(L10n.t(.networkPermissionTitle), isPresented: $showPermissionAlert) {
                    Button(L10n.t(.openSettings)) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    Button(L10n.t(.laterButton), role: .cancel) {}
                } message: {
                    Text(String(format: L10n.t(.networkPermissionBody), permission.denied.joined(separator: ", ")))
                }
        }
    }
}
