import Foundation
import UIKit

/// Keeps one append-only file per launch so a new process cannot overwrite earlier runs.
final class AppLog {
    static let shared = AppLog()

    private static let monitorPrefix = " AirRec: "
    private static let legacyArchiveKey = "AirRecord.activity.legacyArchiveComplete"
    private let queue = DispatchQueue(label: "com.airrecord.applog")
    private let handle: FileHandle?
    private let formatter = DateFormatter()

    private init() {
        formatter.dateFormat = "HH:mm:ss.SSS"
        guard let directory = Self.logDirectory else {
            handle = nil
            return
        }

        Self.archiveLegacyMonitorEvents(in: directory)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString
        let fileName = "AirRec-\(stamp.string(from: Date()))-\(suffix).log"
        let url = directory.appendingPathComponent(fileName)
        do {
            try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            handle = try FileHandle(forWritingTo: url)
        } catch {
            handle = nil
            NSLog("AirRec log file unavailable: %@", (error as NSError).domain)
        }
        write(header())
    }

    private static var logDirectory: URL? {
        let files = FileManager.default
        guard let documents = files.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let directory = documents.appendingPathComponent("Logs", isDirectory: true)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            NSLog("AirRec log directory unavailable: %@", (error as NSError).domain)
            return nil
        }
    }

    private static var legacyFiles: [URL] {
        let files = FileManager.default
        guard let library = files.urls(for: .libraryDirectory, in: .userDomainMask).first else { return [] }
        let directory = library.appendingPathComponent("Logs/AirRecord", isDirectory: true)
        let urls = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func legacyMonitorLines(in file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") else { return nil }
            let message = line[line.index(after: closingBracket)...]
            guard message.hasPrefix(monitorPrefix) else { return nil }
            return String(line)
        }
    }

    static func legacyRecentMonitorEvents(limit: Int) -> [String] {
        var recent: [String] = []
        for file in legacyFiles.reversed() {
            let remaining = limit - recent.count
            guard remaining > 0 else { break }
            let lines = legacyMonitorLines(in: file)
            recent.append(contentsOf: lines.suffix(remaining).reversed().map {
                $0.replacingOccurrences(of: monitorPrefix, with: " ")
            })
        }
        return Array(recent.reversed())
    }

    private static func archiveLegacyMonitorEvents(in directory: URL) {
        let files = FileManager.default
        guard !UserDefaults.standard.bool(forKey: legacyArchiveKey) else { return }
        let sources = legacyFiles
        guard !sources.isEmpty else { return }
        let archive = directory.appendingPathComponent("Previous Runs", isDirectory: true)
        do {
            try files.createDirectory(at: archive, withIntermediateDirectories: true)
            for source in sources {
                let target = archive.appendingPathComponent(source.lastPathComponent)
                guard !files.fileExists(atPath: target.path) else { continue }
                // Older technical logs include raw network details. Only copy
                // the monitor history; the original files remain in Library.
                let lines = legacyMonitorLines(in: source)
                guard !lines.isEmpty else { continue }
                let data = Data((lines.joined(separator: "\n") + "\n").utf8)
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            UserDefaults.standard.set(true, forKey: legacyArchiveKey)
        } catch {
            NSLog("AirRec legacy log archive incomplete: %@", (error as NSError).domain)
        }
    }

    private func header() -> String {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
        ── AirRec app log ─────────────────────────────
        started : \(Date())
        device  : \(DeviceInfo.modelIdentifier) · \(device.systemName) \(device.systemVersion)
        app     : \(version) (\(build))
        ──────────────────────────────────────────────
        """
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        #if DEBUG
        print(line)
        #endif
        write(line)
    }

    private func write(_ text: String) {
        guard let handle else { return }
        let data = Data((text + "\n").utf8)
        queue.async {
            do {
                try handle.write(contentsOf: data)
            } catch {
                NSLog("AirRec log write failed: %@", (error as NSError).domain)
            }
        }
    }
}

func airRecordLog(_ message: String) { AppLog.shared.log(message) }
