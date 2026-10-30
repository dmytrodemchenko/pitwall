import Foundation

final class EventLogWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        start()
    }

    deinit { source?.cancel() }

    private func start() {
        source?.cancel()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let fd = open(fileExists ? url.path : dir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: fileExists ? [.write, .extend, .delete, .rename] : .write,
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            if !fileExists || !events.isDisjoint(with: [.delete, .rename]) { self.start() }
            self.onChange()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
}
