import Foundation

/// A bounded, on-disk-backed capture of a session's raw terminal output.
///
/// Raw PTY bytes are appended as they arrive (capped to the most recent
/// `capacity` bytes) and flushed to disk. On the next launch the saved bytes
/// are replayed into a fresh surface to reconstruct visible history.
///
/// Thread-safe: `append` is called from the PTY read queue while `flush`/
/// `delete` may be called from the main actor.
final class Scrollback: @unchecked Sendable {
    /// Bytes that existed on disk when this object was created — replayed into
    /// the surface once it attaches.
    let loadedHistory: Data

    private let url: URL
    private let capacity: Int
    private let lock = NSLock()
    private var buffer: Data
    private var dirty = false

    init(url: URL, capacity: Int = 512 * 1024) {
        self.url = url
        self.capacity = capacity

        let existing = (try? Data(contentsOf: url)) ?? Data()
        let capped = existing.count > capacity ? Data(existing.suffix(capacity)) : existing
        loadedHistory = capped
        buffer = capped
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > capacity {
            buffer = Data(buffer.suffix(capacity))
        }
        dirty = true
    }

    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = buffer
        dirty = false
        lock.unlock()
        try? snapshot.write(to: url, options: .atomic)
    }

    func delete() {
        lock.lock(); defer { lock.unlock() }
        buffer = Data()
        dirty = false
        try? FileManager.default.removeItem(at: url)
    }
}
