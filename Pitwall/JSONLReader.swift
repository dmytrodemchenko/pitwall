import Foundation

final class JSONLReader<T> {
    let url: URL
    private let parse: (Data) -> T?
    private(set) var offset: UInt64 = 0
    private var fileID: Int?
    private var partial = Data()

    init(url: URL, parse: @escaping (Data) -> T?) {
        self.url = url
        self.parse = parse
    }

    func readNew() -> [T] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let id = attrs?[.systemFileNumber] as? Int
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        if id != fileID || size < offset {
            offset = 0
            partial = Data()
            fileID = id
        }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        partial.append(data)

        var lines = partial.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        partial = Data(lines.removeLast())
        return lines.compactMap { parse(Data($0)) }
    }
}

typealias EventLogReader = JSONLReader<HookEvent>

extension JSONLReader where T == HookEvent {
    convenience init(url: URL) { self.init(url: url, parse: HookEvent.parse) }
}

enum EventLogRotation {
    static let keep: TimeInterval = 7 * 86400, maxSize = 20 << 20

    @discardableResult
    static func rotate(_ url: URL, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) > SessionStore.timeout,
              let data = try? Data(contentsOf: url) else { return false }
        let cutoff = now - keep
        let lines = data.split(separator: UInt8(ascii: "\n"))
        guard let first = lines.first, timestamp(first).map({ $0 < cutoff }) ?? true || data.count > maxSize else { return false }

        var kept = Data()
        for line in lines where timestamp(line).map({ $0 >= cutoff }) ?? false {
            kept.append(line)
            kept.append(UInt8(ascii: "\n"))
        }
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: kept, attributes: [.posixPermissions: 0o600]) else { return false }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard size == data.count, rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }

    private struct Stamp: Decodable { let timestamp: Date }
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func timestamp(_ line: Data.SubSequence) -> Date? {
        (try? decoder.decode(Stamp.self, from: Data(line)))?.timestamp
    }
}
