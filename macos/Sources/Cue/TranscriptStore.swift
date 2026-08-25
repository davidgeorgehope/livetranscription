import Foundation

/// Appends each finalized transcript line to a per-session markdown file.
/// Markdown so the SourceSearch pipeline can treat past calls as part of
/// the knowledge base alongside repo docs.
final class TranscriptStore {
    private let queue = DispatchQueue(label: "cue.transcript-store")
    private var handle: FileHandle?
    private let timeFormatter: DateFormatter
    let fileURL: URL

    static var sessionsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cue/sessions", isDirectory: true)
    }

    init?() {
        let dir = Self.sessionsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileURL = dir.appendingPathComponent("call-\(nameFormatter.string(from: Date())).md")

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        let headerFormatter = DateFormatter()
        headerFormatter.dateStyle = .full
        headerFormatter.timeStyle = .short
        let header = "# Call transcript — \(headerFormatter.string(from: Date()))\n\n"
        guard FileManager.default.createFile(atPath: fileURL.path, contents: Data(header.utf8)),
              let handle = try? FileHandle(forWritingTo: fileURL)
        else { return nil }
        _ = try? handle.seekToEnd()
        self.handle = handle
    }

    func append(speaker: String, text: String, at date: Date) {
        queue.async { [self] in
            let line = "- **\(speaker)** (\(timeFormatter.string(from: date))): \(text)\n"
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    func close() {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }
}
