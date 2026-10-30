import Foundation

struct ContextUsage: Equatable {
    let tokens: Int
    let model: String
    let at: Date

    init(tokens: Int, model: String, at: Date) {
        self.tokens = tokens
        self.model = model
        self.at = at
    }

    init(_ entry: UsageEntry) {
        let t = entry.tokens
        self.init(tokens: t.input + t.cacheRead + t.cacheWrite5m + t.cacheWrite1h, model: entry.model, at: entry.timestamp)
    }

    func percent(of window: Int) -> Double { Double(tokens) / Double(max(window, 1)) * 100 }
}

struct ContextWindows: Decodable {
    let fallback: Int
    let models: [String: Int]

    enum CodingKeys: String, CodingKey { case fallback = "default", models }

    static let standard = ContextWindows(fallback: 200_000, models: [:])

    init(fallback: Int, models: [String: Int]) {
        self.fallback = fallback
        self.models = models
    }

    func window(for model: String) -> Int {
        models.filter { model.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value ?? fallback
    }

    static func decode(_ data: Data) -> ContextWindows? {
        try? JSONDecoder().decode(ContextWindows.self, from: data)
    }
}

enum ContextLevel: Equatable {
    case normal, warning, critical

    static let warnKey = "contextWarnPercent", alertKey = "contextAlertPercent"
    static let defaultWarn = 70.0, defaultAlert = 85.0

    init(percent: Double, warn: Double, alert: Double) {
        self = percent > alert ? .critical : percent >= warn ? .warning : .normal
    }

    static func thresholds(_ defaults: UserDefaults = .standard) -> (warn: Double, alert: Double) {
        let warn = defaults.object(forKey: warnKey) as? Double ?? defaultWarn
        let alert = defaults.object(forKey: alertKey) as? Double ?? defaultAlert
        return (warn, alert)
    }
}

enum ConfigFile {
    static func load<T>(userFile: URL, defaultFile: URL?, decode: (Data) -> T?) -> T? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userFile.path), let defaultFile {
            try? fm.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.copyItem(at: defaultFile, to: userFile)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userFile.path)
        }
        for url in [userFile, defaultFile].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let value = decode(data) { return value }
        }
        return nil
    }
}
