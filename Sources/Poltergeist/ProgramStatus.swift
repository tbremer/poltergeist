import Foundation

/// opencode's terminal "program status" report (OSC 7501), emitted by its TUI
/// on stdout whenever its state changes — no configuration needed. Verified
/// against opencode 2.1.4:
///
///     ESC ] 7501 ; state=working : id=<session> : app=opencode : title=<b64> ESC \
///     ESC ] 7501 ; state=blocked : id=<session> : kind=permission|question
///                  : app=opencode : title=<b64> : msg=<b64> ESC \
///     ESC ] 7501 ; state=clear : id=<session> ESC \
///     ESC ] 7501 ; state=idle : app=opencode ESC \
///
/// Reports without an `id` summarize the whole TUI (it can show several
/// sessions); reports with one describe a single session. `ESC ] 7501 ; ? ST`
/// is a capability query, which we ignore. libghostty doesn't know OSC 7501 and
/// drops it, so we read it from the PTY output ourselves.
struct ProgramStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case idle, working, blocked, clear
    }

    var state: State
    var sessionID: String?
    var kind: String?
    var title: String?
    var message: String?

    /// Parses the payload between `7501;` and the terminator.
    init?(payload: String) {
        var fields: [String: String] = [:]
        for part in payload.split(separator: ":") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let raw = fields["state"], let state = State(rawValue: raw) else { return nil }
        self.state = state
        sessionID = fields["id"]
        kind = fields["kind"]
        title = fields["title"].flatMap(Self.decodeBase64)
        message = fields["msg"].flatMap(Self.decodeBase64)
    }

    private static func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Finds OSC 7501 reports in a PTY byte stream, carrying partial sequences
/// across reads. Used only from the PTY read queue.
final class ProgramStatusScanner: @unchecked Sendable {
    private static let introducer: [UInt8] = Array("\u{1B}]7501;".utf8)
    /// Longest report we'll buffer waiting for a terminator (msg is capped at
    /// 2 KiB of text upstream, so this is generous).
    private static let maxReportLength = 8192

    private var carry: [UInt8] = []

    func scan(_ data: Data) -> [ProgramStatus] {
        // Fast path: nothing pending and no ESC in this chunk.
        if carry.isEmpty, !data.contains(0x1B) { return [] }

        var bytes = carry
        bytes.append(contentsOf: data)
        carry = []

        var reports: [ProgramStatus] = []
        var index = 0
        while let start = Self.find(Self.introducer, in: bytes, from: index) {
            let payloadStart = start + Self.introducer.count
            guard let (payloadEnd, next) = Self.terminator(in: bytes, from: payloadStart) else {
                // Incomplete: keep it for the next read (unless it's runaway).
                if bytes.count - start <= Self.maxReportLength {
                    carry = Array(bytes[start...])
                }
                return reports
            }
            if let payload = String(bytes: bytes[payloadStart ..< payloadEnd], encoding: .utf8),
               let status = ProgramStatus(payload: payload) {
                reports.append(status)
            }
            index = next
        }
        // The introducer itself may be split across reads: keep a short tail
        // that could be its beginning.
        if let esc = bytes[max(index, bytes.count - Self.introducer.count)...].lastIndex(of: 0x1B) {
            let tail = Array(bytes[esc...])
            if Self.introducer.starts(with: tail) { carry = tail }
        }
        return reports
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard haystack.count - from >= needle.count else { return nil }
        var i = from
        while i <= haystack.count - needle.count {
            if haystack[i] == needle[0], Array(haystack[i ..< i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// End of payload and the index after the terminator (BEL or ESC \).
    private static func terminator(in bytes: [UInt8], from: Int) -> (Int, Int)? {
        var i = from
        while i < bytes.count {
            if bytes[i] == 0x07 { return (i, i + 1) }
            if bytes[i] == 0x1B {
                guard i + 1 < bytes.count else { return nil }
                if bytes[i + 1] == 0x5C { return (i, i + 2) }
                return (i, i + 1)  // malformed: another sequence began
            }
            i += 1
        }
        return nil
    }
}
