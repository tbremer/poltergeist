import Foundation
import Darwin
import CPty

/// Owns a pseudo-terminal and the child process attached to it, and drives the
/// GhosttyKit `.inMemory` backend:
///
/// - PTY output is delivered to `onOutput` (call `InMemoryTerminalSession.receive`).
/// - Terminal-produced input is sent in with `write(_:)`.
/// - Grid changes are applied with `handleResize(...)`.
///
/// The child is spawned lazily on the first non-empty resize, because the
/// GhosttyKit surface drops received bytes until it is attached (and the first
/// resize tells us both that it is ready and what size to use).
final class PTYProcess: @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32, UInt64) -> Void)?

    private let readQueue = DispatchQueue(label: "sh.poltergeist.pty.read")
    private let writeQueue = DispatchQueue(label: "sh.poltergeist.pty.write")

    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var startedAt = Date()
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    // Launch configuration (set once before the first resize).
    private var executable = "/bin/zsh"
    private var argv: [String] = ["-zsh"]
    private var environment: [String: String] = [:]
    private var cwd: String?

    func configure(executable: String, argv: [String], environment: [String: String], cwd: String?) {
        lock.lock(); defer { lock.unlock() }
        self.executable = executable
        self.argv = argv
        self.environment = environment
        self.cwd = cwd
    }

    /// Starts the child on the first non-empty size, then applies window-size
    /// changes (SIGWINCH) on subsequent calls.
    func handleResize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        guard columns > 0, rows > 0 else { return }
        lock.lock()
        let needsStart = !started
        if needsStart { started = true }
        let fd = masterFD
        lock.unlock()

        if needsStart {
            start(columns: columns, rows: rows, widthPixels: widthPixels, heightPixels: heightPixels)
        } else if fd >= 0 {
            _ = cpty_set_winsize(fd, rows, columns, widthPixels, heightPixels)
        }
    }

    func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let fd = self.currentFD()
            guard fd >= 0 else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard var base = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let n = Darwin.write(fd, base, remaining)
                    if n > 0 {
                        base = base.advanced(by: n)
                        remaining -= n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    func terminate() {
        lock.lock()
        let p = pid
        lock.unlock()
        if p > 0 { kill(p, SIGHUP) }
        finishExit(code: 129)
    }

    /// Names (`p_comm`, ≤16 chars) of the processes in the PTY's foreground
    /// process group — the shell itself, or whatever job it's running in the
    /// foreground. `nil` if the child hasn't started or has exited.
    func foregroundProcessNames() -> [String]? {
        let fd = currentFD()
        guard fd >= 0 else { return nil }
        let pgid = tcgetpgrp(fd)
        guard pgid > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Headroom in case the group grows between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 4)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).map { proc in
            withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }

    // MARK: - Private

    private func currentFD() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return masterFD
    }

    private func start(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargv.append(nil)
        var cenv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer {
            for p in cargv where p != nil { free(p) }
            for p in cenv where p != nil { free(p) }
        }

        var master: Int32 = -1
        let childPid: pid_t
        if let cwd {
            childPid = cpty_spawn(executable, cargv, cenv, cwd, rows, columns, widthPixels, heightPixels, &master)
        } else {
            childPid = cpty_spawn(executable, cargv, cenv, nil, rows, columns, widthPixels, heightPixels, &master)
        }

        guard childPid > 0, master >= 0 else {
            onExit?(127, 0)
            return
        }

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.masterFD
            self.masterFD = -1
            self.lock.unlock()
            if fd >= 0 { close(fd) }
        }
        let es = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: readQueue)
        es.setEventHandler { [weak self] in self?.reapChild() }

        lock.lock()
        pid = childPid
        masterFD = master
        startedAt = Date()
        readSource = rs
        exitSource = es
        lock.unlock()

        rs.resume()
        es.resume()
    }

    private func readAvailable() {
        let fd = currentFD()
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            onOutput?(Data(buffer[0 ..< n]))
            return
        }
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
        // EOF (all slaves closed) or fatal error: stop reading and try to reap.
        readSource?.cancel()
        reapChild()
    }

    private func reapChild() {
        lock.lock()
        let p = pid
        lock.unlock()
        guard p > 0 else { return }

        var status: Int32 = 0
        let r = waitpid(p, &status, WNOHANG)
        guard r == p else { return } // not exited yet; the exit source will fire
        finishExit(code: Self.exitCode(from: status))
    }

    private func finishExit(code: Int32) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let started = startedAt
        let rs = readSource
        let es = exitSource
        lock.unlock()

        let ms = UInt64(max(0, Date().timeIntervalSince(started) * 1000))
        es?.cancel()
        rs?.cancel()
        onExit?(code, ms)
    }

    /// Decode a waitpid status into an exit code (signal terminations map to
    /// 128 + signal, matching shell conventions).
    private static func exitCode(from status: Int32) -> Int32 {
        let wstatus = status & 0x7F
        if wstatus == 0 {
            return (status >> 8) & 0xFF // WEXITSTATUS
        } else if wstatus != 0x7F {
            return 128 + wstatus // terminated by signal
        }
        return -1
    }
}
