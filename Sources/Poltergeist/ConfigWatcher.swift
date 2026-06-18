import Foundation

/// Watches a directory for changes and fires `onChange` (on a background queue).
///
/// We watch the directory (not the file) so atomic saves — editors that replace
/// `config.json` via rename — are still detected reliably.
final class ConfigWatcher: @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?

    private let directory: URL
    private let queue = DispatchQueue(label: "sh.poltergeist.config.watch")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.onChange?() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.descriptor, fd >= 0 { close(fd) }
            self?.descriptor = -1
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
