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

struct AirRecordDiagnosticAttempt: Codable, Equatable {
    enum Direction: String, Codable {
        case incoming, outgoing

        var title: String { self == .incoming ? "수신" : "발신" }
    }

    enum LockState: String, Codable {
        case locked, unlocked, unknown

        init(_ state: AirRecordDeviceLockState?) {
            switch state {
            case .locked: self = .locked
            case .unlocked: self = .unlocked
            case nil: self = .unknown
            }
        }

        var title: String {
            switch self {
            case .locked: return "잠김"
            case .unlocked: return "잠금 해제"
            case .unknown: return "확인 불가"
            }
        }
    }

    enum Stage: String, Codable {
        case callState = "call_state"
        case pairing
        case developerConnection = "developer_connection"
        case callScreen = "call_screen"
        case recordButton = "record_button"
        case recording

        var title: String {
            switch self {
            case .callState: return "통화 및 잠금 상태 확인"
            case .pairing: return "페어링 파일 확인"
            case .developerConnection: return "기기 개발자 연결"
            case .callScreen: return "통화 화면 확인"
            case .recordButton: return "통화 녹음 버튼 확인"
            case .recording: return "녹음 시작"
            }
        }
    }

    enum Result: String, Codable {
        case waiting, blocked, failed
        case timedOut = "timed_out"
        case submittedUnconfirmed = "submitted_unconfirmed"
        case confirmed
        case alreadyRecording = "already_recording"

        var title: String {
            switch self {
            case .waiting: return "대기 중 마지막 확인"
            case .blocked: return "검사 조건 미충족"
            case .failed: return "실패"
            case .timedOut: return "준비 시간 초과"
            case .submittedUnconfirmed: return "녹음 요청 후 시작 미확인"
            case .confirmed: return "녹음 시작 확인"
            case .alreadyRecording: return "이미 녹음 중"
            }
        }
    }

    let callDirection: Direction
    let lockState: LockState
    let stage: Stage
    let resultCode: Result

    enum CodingKeys: String, CodingKey {
        case callDirection = "call_direction"
        case lockState = "lock_state"
        case stage
        case resultCode = "result_code"
    }
}

struct AirRecordDiagnosticSnapshot: Codable, Equatable {
    let device: AirRecordDiagnosticDevice
    let attempt: AirRecordDiagnosticAttempt
}

struct AirRecordDiagnosticReport: Encodable, Identifiable {
    let schemaVersion = 1
    let reportID = UUID()
    let modelIdentifier: String
    let iosVersion: String
    let appVersion: String
    let appBuild: String
    let lastAttempt: AirRecordDiagnosticAttempt?
    var worksWell: Bool?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportID = "report_uuid"
        case modelIdentifier = "model_identifier"
        case iosVersion = "ios_version"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case lastAttempt = "last_attempt"
        case worksWell = "works_well"
    }

    var id: UUID { reportID }

    @MainActor
    init(snapshot: AirRecordDiagnosticSnapshot?) {
        let device = snapshot?.device ?? .current
        modelIdentifier = device.modelIdentifier
        iosVersion = device.iosVersion
        appVersion = device.appVersion
        appBuild = device.appBuild
        lastAttempt = snapshot?.attempt
    }
}

enum AirRecordDiagnosticUpload {
    static let endpoint = URL(string: "https://butz.bar/api/airrec/v1/diagnostics/index.php")!

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
