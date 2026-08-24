import Foundation

struct SessionRecord: Identifiable, Equatable {
    let id: URL
    let startedAt: Date
    let title: String
    let preview: String
    let lineCount: Int
    let hasWrap: Bool

    var fileURL: URL { id }
    var wrapURL: URL {
        id.deletingPathExtension().appendingPathExtension("wrap.md")
    }
}

enum CommitmentKind: String, Equatable {
    case commitment = "Commitment"
    case openQuestion = "Open question"
    case decision = "Decision"
}

struct CallCommitment: Identifiable, Equatable {
    let id: UUID
    let kind: CommitmentKind
    let speaker: String
    let text: String
    let at: Date

    init(id: UUID = UUID(), kind: CommitmentKind, speaker: String, text: String, at: Date) {
        self.id = id
        self.kind = kind
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

struct CallWrap: Equatable {
    let summary: String
    let followUpDraft: String
    let commitments: [CallCommitment]
}

/// Lists and reads session markdown under Application Support. Pure disk
/// reads — never shares locks with the live TranscriptStore writer.
enum SessionLibrary {
    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "'call-'yyyy-MM-dd_HH-mm-ss'.md'"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func list() -> [SessionRecord] {
        let dir = TranscriptStore.sessionsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("call-") }
            .filter { !$0.lastPathComponent.hasSuffix(".wrap.md") }
            .compactMap { url -> SessionRecord? in
                guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                let dialogue = lines.filter { $0.hasPrefix("- **") }
                let preview = dialogue.suffix(2)
                    .map { String($0).replacingOccurrences(of: "- **", with: "") }
                    .joined(separator: " · ")
                let started = nameFormatter.date(from: url.lastPathComponent) ?? Date.distantPast
                let wrapExists = FileManager.default.fileExists(
                    atPath: url.deletingPathExtension().appendingPathExtension("wrap.md").path
                )
                return SessionRecord(
                    id: url,
                    startedAt: started,
                    title: displayFormatter.string(from: started),
                    preview: String(preview.prefix(180)),
                    lineCount: dialogue.count,
                    hasWrap: wrapExists
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func readTranscript(_ session: SessionRecord) -> String {
        (try? String(contentsOf: session.fileURL, encoding: .utf8)) ?? ""
    }

    static func readWrap(_ session: SessionRecord) -> String? {
        guard session.hasWrap else { return nil }
        return try? String(contentsOf: session.wrapURL, encoding: .utf8)
    }
}
