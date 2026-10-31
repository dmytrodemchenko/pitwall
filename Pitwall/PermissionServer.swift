import Foundation

enum PermissionDecision: String {
    case allow, deny
}

struct PermissionRequest: Equatable {
    let sessionId: String
    let toolName: String
    let summary: String
    let isComplete: Bool
    let cwd: String?

    static func parse(_ line: Data) -> PermissionRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let session = json["session_id"] as? String, let tool = json["tool_name"] as? String else { return nil }
        let (summary, isComplete) = summarize(json["tool_input"] as? [String: Any] ?? [:])
        return PermissionRequest(sessionId: session, toolName: tool, summary: summary, isComplete: isComplete,
                                 cwd: json["cwd"] as? String)
    }

    static func summarize(_ input: [String: Any]) -> (text: String, isComplete: Bool) {
        let keys = ["command", "file_path", "notebook_path", "path", "url", "pattern", "query", "description", "prompt"]
        let shown = keys.first { input[$0] is String } ?? input.keys.sorted().first { input[$0] is String }
        let text = shown.flatMap { input[$0] as? String } ?? ""
        let hidden = input.contains { key, value in
            key != shown && key != "description" && (value is String || value is [Any] || value is [String: Any])
        }
        let lines = text.split(whereSeparator: \.isNewline)
        var line = lines.first.map(String.init) ?? ""
        let cut = line.count > 120
        if cut { line = line.prefix(119) + "…, \(text.count) characters" }
        let more = lines.count - 1
        if more > 0 { line += " (+\(more) more line\(more == 1 ? "" : "s"))" }
        return (line, !cut && more == 0 && !hidden)
    }
}

final class PendingPermission {
    let id = UUID().uuidString
    let request: PermissionRequest
    var onCancel: () -> Void = {}
    private(set) var isDone = false
    private let send: (PermissionDecision?) -> Void

    fileprivate init(request: PermissionRequest, send: @escaping (PermissionDecision?) -> Void) {
        self.request = request
        self.send = send
    }

    func reply(_ decision: PermissionDecision?) {
        guard !isDone else { return }
        isDone = true
        send(decision)
    }

    fileprivate func cancel() {
        guard !isDone else { return }
        isDone = true
        onCancel()
    }
}

final class PermissionServer {
    let path: String
    var onRequest: (PendingPermission) -> Void = { _ in }
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var pending: PendingPermission?

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    init(path: String) {
        self.path = path
    }

    deinit { stop() }

    func hasPending(session: String) -> Bool {
        connections.values.contains { $0.pending.map { !$0.isDone && $0.request.sessionId == session } ?? false }
    }

    func start() throws {
        var addr = sockaddr_un()
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else { throw POSIXError(.ENAMETOOLONG) }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBytes { dst.copyMemory(from: $0) }
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        for c in connections.values { finish(c, nil) }
        unlink(path)
    }

    private func acceptAll(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            let connection = Connection(fd: fd, source: source)
            connections[fd] = connection
            source.setEventHandler { [weak self, weak connection] in
                if let self, let connection { self.read(connection) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
        }
    }

    private func read(_ c: Connection) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(c.fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else {
            let pending = c.pending
            finish(c, nil)
            pending?.cancel()
            return
        }
        guard c.pending == nil else { return }
        c.buffer.append(contentsOf: chunk[..<n])
        guard let newline = c.buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            if c.buffer.count > 1 << 20 { finish(c, nil) }
            return
        }
        guard let request = PermissionRequest.parse(c.buffer[..<newline]) else {
            finish(c, nil)
            return
        }
        let pending = PendingPermission(request: request) { [weak self, weak c] decision in
            if let self, let c { self.finish(c, decision) }
        }
        c.pending = pending
        onRequest(pending)
    }

    private func finish(_ c: Connection, _ decision: PermissionDecision?) {
        guard connections.removeValue(forKey: c.fd) != nil else { return }
        if let decision {
            let line = Array("\(decision.rawValue)\n".utf8)
            _ = line.withUnsafeBytes { Darwin.write(c.fd, $0.baseAddress, $0.count) }
        }
        c.source.cancel()
    }
}
