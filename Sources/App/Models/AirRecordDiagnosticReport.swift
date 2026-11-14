// AirRec, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Foundation
import UIKit

struct AirRecordDiagnosticDevice: Codable, Equatable {
    let modelIdentifier: String
    let iosVersion: String
    let appVersion: String
    let appBuild: String

    @MainActor
    static var current: Self {
        Self(modelIdentifier: DeviceInfo.modelIdentifier,
             iosVersion: UIDevice.current.systemVersion,
             appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
             appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
    }
}

@MainActor
enum AirRecordDiagnosticHistory {
    static let recordingConfirmation = "통화 녹음 시작 확인"

    private static let confirmedKey = "AirRecord.diagnostics.recordingEverConfirmed"
    private static let legacySnapshotKey = "AirRecord.diagnostics.latestAttempt"
    private static let legacyRecentEventsKey = "AirRecord.activity.recentEvents"

    static func recordConfirmation(defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: confirmedKey) {
            defaults.set(true, forKey: confirmedKey)
        }
    }

    static func hasRecordingConfirmation(defaults: UserDefaults = .standard) async -> Bool {
        if let confirmed = defaults.object(forKey: confirmedKey) as? Bool { return confirmed }
        let event = recordingConfirmation
        let recent = defaults.stringArray(forKey: legacyRecentEventsKey) ?? []
        let legacySnapshot = defaults.data(forKey: legacySnapshotKey)
        if recent.contains(where: { $0.hasSuffix("] " + event) }) ||
            legacySnapshot.flatMap({ try? JSONDecoder().decode(LegacySnapshot.self, from: $0) })?.attempt.result == "confirmed" {
            recordConfirmation(defaults: defaults)
            return true
        }

        let archived = await Task.detached(priority: .utility) {
            AppLog.hasMonitorEvent(event)
        }.value
        // A new confirmation may arrive while the older files are being read.
        let confirmed = archived || defaults.bool(forKey: confirmedKey)
        defaults.set(confirmed, forKey: confirmedKey)
        return confirmed
    }

    private struct LegacySnapshot: Decodable {
        let attempt: Attempt

        struct Attempt: Decodable {
            let result: String

            enum CodingKeys: String, CodingKey {
                case result = "result_code"
            }
        }
    }
}

struct AirRecordDiagnosticReport: Encodable, Identifiable {
    let schemaVersion = 1
    let reportID = UUID()
    let installationID: UUID
    let modelIdentifier: String
    let iosVersion: String
    let appVersion: String
    let appBuild: String
    let recordingEverConfirmed: Bool
    var worksWell: Bool?
    var consentsToIPCollection: Bool?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportID = "report_uuid"
        case installationID = "installation_id"
        case modelIdentifier = "model_identifier"
        case iosVersion = "ios_version"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case recordingEverConfirmed = "recording_ever_confirmed"
        case worksWell = "works_well"
        case consentsToIPCollection = "consents_to_ip_collection"
    }

    var id: UUID { reportID }

    @MainActor
    init(recordingEverConfirmed: Bool, defaults: UserDefaults = .standard) {
        let installationKey = "AirRecord.diagnostics.installationID"
        if let saved = defaults.string(forKey: installationKey), let id = UUID(uuidString: saved) {
            installationID = id
        } else {
            installationID = UUID()
            defaults.set(installationID.uuidString, forKey: installationKey)
        }
        self.recordingEverConfirmed = recordingEverConfirmed
        let device = AirRecordDiagnosticDevice.current
        modelIdentifier = device.modelIdentifier
        iosVersion = device.iosVersion
        appVersion = device.appVersion
        appBuild = device.appBuild
    }
}

enum AirRecordDiagnosticUpload {
    static let endpoint = URL(string: "https://butz.bar/api/airrec/v1/diagnostics/index.php")!

    static var bundledAPIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "AirRecDiagnosticAPIKey") as? String ?? ""
    }

    enum UploadError: LocalizedError {
        case serverUnavailable, rateLimited, rejected, invalidReceipt, connectionFailed
        case invalidAPIKey, unauthorized

        var errorDescription: String? {
            switch self {
            case .serverUnavailable: return "진단 서버에 접속할 수 없습니다. 잠시 후 다시 시도해 주세요."
            case .rateLimited: return "전송 요청이 많습니다. 잠시 후 다시 시도해 주세요."
            case .rejected: return "진단 서버가 보고서를 받지 못했습니다."
            case .invalidReceipt: return "서버의 접수 응답을 확인하지 못했습니다. 다시 시도해 주세요."
            case .connectionFailed: return "전송 연결에 실패했습니다. 인터넷 연결을 확인한 뒤 다시 시도해 주세요."
            case .invalidAPIKey: return "전송 키를 확인해 주세요."
            case .unauthorized: return "서버가 전송 키를 거부했습니다. 키를 확인한 뒤 다시 시도해 주세요."
            }
        }
    }

    private struct Receipt: Decodable {
        let success: Bool
        let reportID: UUID

        enum CodingKeys: String, CodingKey {
            case success
            case reportID = "report_uuid"
        }
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    static func send(_ report: AirRecordDiagnosticReport, apiKey: String) async throws {
        let request = try makeRequest(for: report, apiKey: apiKey)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: RedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UploadError.connectionFailed
        }
        try validateReceipt(data, response: response, reportID: report.reportID)
    }

    private static func makeRequest(for report: AirRecordDiagnosticReport, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw UploadError.invalidAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-AIRREC-KEY")
        request.httpBody = try JSONEncoder().encode(report)
        return request
    }

    private static func validateReceipt(_ data: Data, response: URLResponse, reportID: UUID) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidReceipt }
        switch http.statusCode {
        case 200, 201:
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  receipt.success, receipt.reportID == reportID else { throw UploadError.invalidReceipt }
        case 401: throw UploadError.unauthorized
        case 404, 405, 500...599: throw UploadError.serverUnavailable
        case 429: throw UploadError.rateLimited
        default: throw UploadError.rejected
        }
    }
}
#endif
