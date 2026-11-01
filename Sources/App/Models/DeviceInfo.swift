import Darwin
import Foundation
import UIKit

/// Device model used only in local diagnostic logs.
enum DeviceInfo {
    /// e.g. "iPhone17,2". `UIDevice.model` only ever says "iPhone", which
    /// doesn't distinguish the hardware people actually care about here.
    static var modelIdentifier: String {
        // On the simulator `utsname.machine` reports the *host* architecture
        // ("arm64"), not a device model — the real identifier is passed in the
        // environment instead. Without this the row reads "arm64", which is
        // both wrong and confusing next to a real device's "iPhone17,2".
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafeBytes(of: &sysinfo.machine) { buf in
            buf.prefix { $0 != 0 }.map { UInt8($0) }
        }
        let id = String(decoding: raw, as: UTF8.self)
        return id.isEmpty ? UIDevice.current.model : id
    }

}
