import Foundation
import Observation

struct GitInfo: Equatable {
    let branch: String
    let changed: Int

    var summary: String { "\(branch) · " + (changed == 0 ? "no changes" : "\(changed) changed") }
}

enum Git {
    static func status(of folder: String, timeout: TimeInterval = 2) -> GitInfo? {
        guard let branch = run(["-C", folder, "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout),
              let porcelain = run(["--no-optional-locks", "-C", folder, "status", "--porcelain"], timeout: timeout)
        else { return nil }
        return parse(branch: branch, porcelain: porcelain)
    }

    static func parse(branch: String, porcelain: String) -> GitInfo {
        GitInfo(branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
                changed: porcelain.split(whereSeparator: \.isNewline).count)
    }

    static func run(_ arguments: [String], executable: String = "/usr/bin/git", timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let kill = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        kill.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor @Observable
final class GitStatusStore {
    var info: [String: GitInfo] = [:]
    @ObservationIgnored var interval: TimeInterval = 5
    @ObservationIgnored var lookup: @Sendable (String) -> GitInfo? = { Git.status(of: $0) }
    @ObservationIgnored private var lastRun: [String: Date] = [:]
    @ObservationIgnored private var scheduled = Set<String>()
    @ObservationIgnored private let queue = DispatchQueue(label: "Pitwall.git", qos: .utility)

    func hasChecked(_ folder: String) -> Bool { lastRun[folder] != nil }

    func refresh(_ folder: String) {
        guard !scheduled.contains(folder) else { return }
        let wait = lastRun[folder].map { $0.addingTimeInterval(interval).timeIntervalSinceNow } ?? 0
        if wait > 0 {
            scheduled.insert(folder)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.scheduled.remove(folder)
                self?.refresh(folder)
            }
            return
        }
        lastRun[folder] = Date()
        let lookup = lookup
        queue.async {
            let result = lookup(folder)
            DispatchQueue.main.async { self.info[folder] = result }
        }
    }
}
