import Foundation
import PDFKit

/// Per-call prep documents: briefs, last-call notes, pricing you may quote.
///
/// Layout under Application Support/Cue/prep/:
///   inbox/    drop zone for automations (a Grok Bot task writing a brief);
///             swept into `current/` on the next Listen
///   current/  attached to the upcoming or active call, as extracted text
///   <call>/   archived with the session on Stop; stays searchable
///
/// Files are stored as extracted markdown so ripgrep and the prompts see
/// text, not PDF bytes. The original filename is kept in the header.
enum PrepStore {
    struct Doc: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cue/prep", isDirectory: true)
    }
    static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    static var current: URL { root.appendingPathComponent("current", isDirectory: true) }

    /// Formats `textutil` converts natively; PDF goes through PDFKit.
    static let textutilExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "html", "htm", "odt", "webarchive"]
    static let plainExtensions: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml"]

    static func prepare() {
        for dir in [inbox, current] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func currentDocs() -> [Doc] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: current, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Doc.init)
    }

    /// Extract text and add to `current/`. Returns the stored doc, or nil if
    /// the file had no extractable text.
    @discardableResult
    static func attach(_ source: URL) -> Doc? {
        prepare()
        guard let text = extractText(from: source)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let body = "# Prep: \(source.lastPathComponent)\n\n\(text)\n"
        // Automations sometimes write the same brief twice (write, then a
        // verify/rewrite). Same bytes already attached → refresh that doc, not a "-2".
        if let twin = currentDocs().first(where: { (try? String(contentsOf: $0.url, encoding: .utf8)) == body }) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: twin.url.path)
            return twin
        }
        var target = current.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = current.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        guard (try? body.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        return Doc(url: target)
    }

    static func remove(_ doc: Doc) {
        try? FileManager.default.removeItem(at: doc.url)
    }

    /// Move whatever an automation dropped in `inbox/` into `current/`.
    static func sweepInbox() -> [Doc] {
        prepare()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let before = Set(currentDocs().map(\.url))
        var attached: [Doc] = []
        for url in urls {
            if let doc = attach(url) {
                if !before.contains(doc.url) { attached.append(doc) }
                try? FileManager.default.removeItem(at: url)
            }
        }
        return attached
    }

    /// Archive `current/` next to the finished session so past prep stays
    /// searchable and the next call starts clean.
    static func archive(forSession sessionFile: URL?) {
        let docs = currentDocs()
        guard !docs.isEmpty else { return }
        let name = sessionFile?.deletingPathExtension().lastPathComponent
            ?? "call-\(ISO8601DateFormatter().string(from: Date()))"
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for doc in docs {
            try? FileManager.default.moveItem(at: doc.url, to: dir.appendingPathComponent(doc.url.lastPathComponent))
        }
    }

    /// Everything attached, concatenated for prompt injection.
    struct Schedule: Equatable {
        let title: String
        let start: Date
        let end: Date
    }

    /// When the upcoming call runs, read off the attached brief. Prefers the
    /// `meeting_start:` / `meeting_end:` lines the bot is asked to write;
    /// otherwise Apple's date detector reads the human "When:" line, which
    /// carries the range as a duration. nil when no doc states a time.
    static func currentSchedule(now: Date = Date()) -> Schedule? {
        let iso = ISO8601DateFormatter()
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        var found: [Schedule] = []
        for doc in currentDocs() {
            guard let text = try? String(contentsOf: doc.url, encoding: .utf8) else { continue }
            let head = String(text.prefix(1_500))
            let lines = head.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let title = lines.first { $0.hasPrefix("# ") && !$0.hasPrefix("# Prep:") }
                .map { String($0.dropFirst(2)) } ?? doc.name

            var start: Date?
            var end: Date?
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "meeting_start" { start = iso.date(from: parts[1]) }
                if parts[0] == "meeting_end" { end = iso.date(from: parts[1]) }
            }
            if let start, let end, end > start {
                found.append(Schedule(title: title, start: start, end: end))
                continue
            }
            guard let detector else { continue }
            let clean = head.replacingOccurrences(of: "·", with: ",").replacingOccurrences(of: "**", with: "")
            let range = NSRange(location: 0, length: (clean as NSString).length)
            if let m = detector.matches(in: clean, range: range).first(where: { $0.date != nil && $0.duration > 0 }),
               let date = m.date {
                found.append(Schedule(title: title, start: date, end: date.addingTimeInterval(m.duration)))
            }
        }
        // Several briefs: the one whose window is live or nearest to now.
        return found.min { distance(now, to: $0) < distance(now, to: $1) }
    }

    private static func distance(_ now: Date, to s: Schedule) -> TimeInterval {
        if now >= s.start && now <= s.end { return 0 }
        return min(abs(now.timeIntervalSince(s.start)), abs(now.timeIntervalSince(s.end)))
    }

    static func currentText(limit: Int) -> String {
        var out = ""
        for doc in currentDocs() {
            guard let text = try? String(contentsOf: doc.url, encoding: .utf8) else { continue }
            out += text + "\n\n"
            if out.count >= limit { break }
        }
        return String(out.prefix(limit))
    }

    // MARK: - Extraction

    static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return PDFDocument(url: url)?.string
        }
        if textutilExtensions.contains(ext) {
            return textutil(url)
        }
        if plainExtensions.contains(ext) || ext.isEmpty {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // Unknown extension: try plain text, then textutil.
        return (try? String(contentsOf: url, encoding: .utf8)) ?? textutil(url)
    }

    private static func textutil(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
