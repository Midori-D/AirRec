// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if CALLTAP_RAWAX
import Foundation

/// Only fixed control messages cross the authenticated loopback connection.
/// Pairing data is sent after the host verifies the OS-reported helper PID.
struct AirRecordKeepAliveMessage: Codable {
    var type: String
    var session: String
    var nonce: String
    var helperPID: UInt32?
    var hostPID: UInt32?
    var allowsDebugging: Bool?
    var pairing: String?
    var hostAttached: Bool?
    var selfTraced: Bool?
    var errorCode: Int32?

    init(type: String, session: String, nonce: String,
         helperPID: UInt32? = nil, hostPID: UInt32? = nil,
         allowsDebugging: Bool? = nil, pairing: String? = nil,
         hostAttached: Bool? = nil, selfTraced: Bool? = nil,
         errorCode: Int32? = nil) {
        self.type = type; self.session = session; self.nonce = nonce
        self.helperPID = helperPID; self.hostPID = hostPID
        self.allowsDebugging = allowsDebugging; self.pairing = pairing
        self.hostAttached = hostAttached; self.selfTraced = selfTraced
        self.errorCode = errorCode
    }
}

enum AirRecordKeepAliveWire {
    static let maximumFrameBytes = 131_072
    static let maximumPairingBytes = 65_536

    enum Failure: Error { case oversizedFrame, invalidFrame }

    static func encode(_ message: AirRecordKeepAliveMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw Failure.oversizedFrame }
        data.append(10)
        return data
    }

    /// Supports split/coalesced TCP reads without allowing an unbounded buffer.
    static func append(_ data: Data, to buffer: inout Data) throws -> [AirRecordKeepAliveMessage] {
        // A read is capped by the caller. Reject a single unexpectedly large
        // input before allocating a second copy of it in the receive buffer.
        guard data.count <= maximumFrameBytes + 1 else { throw Failure.oversizedFrame }
        buffer.append(data)
        var messages: [AirRecordKeepAliveMessage] = []
        while let newline = buffer.firstIndex(of: 10) {
            let length = buffer.distance(from: buffer.startIndex, to: newline)
            guard length > 0, length <= maximumFrameBytes else { throw Failure.invalidFrame }
            let frame = Data(buffer[..<newline])
            let end = buffer.index(after: newline)
            buffer.removeSubrange(..<end)
            do { messages.append(try JSONDecoder().decode(AirRecordKeepAliveMessage.self, from: frame)) }
            catch { throw Failure.invalidFrame }
            guard messages.count <= 64 else { throw Failure.invalidFrame }
        }
        guard buffer.count <= maximumFrameBytes else { throw Failure.oversizedFrame }
        return messages
    }

    static func isValidNonce(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func matchesNonce(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == 64, rhs.utf8.count == 64 else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs.utf8, rhs.utf8) { difference |= left ^ right }
        return difference == 0
    }
}
#endif
