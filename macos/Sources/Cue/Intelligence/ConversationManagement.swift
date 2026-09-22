import Foundation

struct CallWrapEngine {
    func wrap(
        dialogue: String,
        commitments: [CallCommitment],
        notes: String,
        prep: String = "",
        meetingType: MeetingType = .sales,
        apiKey: String
    ) async throws -> CallWrap {
        let system = """
        \(meetingType.wrapFlavor) Return only valid JSON:
        {
          "summary": "5-8 sentence narrative of what happened and where things stand",
          "follow_up": "a short follow-up email draft the user can send, with subject line on first line as Subject: ..."
        }
        Use only the dialogue and listed commitments. Do not invent product claims.
        """

        let commitmentBlock = commitments.isEmpty
            ? "(none captured)"
            : commitments.map { "- [\($0.kind.rawValue)] \($0.speaker): \($0.text)" }.joined(separator: "\n")

        let user = """
        NOTES:
        \(notes.isEmpty ? "(none)" : String(notes.prefix(1200)))
        \(AnswerEngine.prepBlock(prep, limit: 3_000))
        COMMITMENTS / OPEN QUESTIONS / DECISIONS:
        \(commitmentBlock)

        TRANSCRIPT:
        \(dialogue.suffix(6000))
        """

        let content = try await GrokChat.complete(
            system: system, user: user, maxTokens: 900, temperature: 0.3, timeout: 40, apiKey: apiKey
        )
        guard !content.isEmpty else {
            return CallWrap(summary: "", followUpDraft: "", commitments: commitments)
        }
        guard let obj = GrokChat.jsonObject(from: content) else {
            return CallWrap(summary: content, followUpDraft: "", commitments: commitments)
        }
        return CallWrap(
            summary: obj["summary"] as? String ?? "",
            followUpDraft: obj["follow_up"] as? String ?? "",
            commitments: commitments
        )
    }

    static func markdown(for wrap: CallWrap, sessionTitle: String) -> String {
        var md = "# Call wrap — \(sessionTitle)\n\n"
        md += "## Summary\n\n\(wrap.summary)\n\n"
        if !wrap.commitments.isEmpty {
            md += "## Commitments & open questions\n\n"
            for c in wrap.commitments {
                md += "- **\(c.kind.rawValue)** (\(c.speaker)): \(c.text)\n"
            }
            md += "\n"
        }
        md += "## Follow-up draft\n\n\(wrap.followUpDraft)\n"
        return md
    }

    static func write(_ wrap: CallWrap, beside transcriptURL: URL, title: String) {
        let url = transcriptURL.deletingPathExtension().appendingPathExtension("wrap.md")
        let md = markdown(for: wrap, sessionTitle: title)
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }
}
