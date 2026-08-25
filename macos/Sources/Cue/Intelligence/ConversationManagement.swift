import Foundation

/// Extracts commitments, open questions, and decisions from recent dialogue.
/// Selective: empty arrays are the common case.
struct CommitmentExtractor {
    func extract(dialogue: String, apiKey: String) async throws -> [CallCommitment] {
        let system = """
        You extract conversation management items from a live customer call transcript. \
        Be selective. Most passes return empty arrays.

        Return only valid JSON:
        {
          "commitments": [{"speaker": "who", "text": "what they committed to do"}],
          "open_questions": [{"speaker": "who", "text": "unanswered question still hanging"}],
          "decisions": [{"speaker": "who", "text": "decision that was agreed"}]
        }

        Rules:
        - Commitments are concrete follow-ups ("I'll send the security packet", "we'll schedule a load test").
        - Open questions are customer or seller asks that were not answered yet.
        - Decisions are agreed outcomes, not mere discussion.
        - Prefer short spoken-ready text. No inventing.
        """

        let user = """
        RECENT DIALOGUE:
        \(dialogue.suffix(2800))
        """

        let payload: [String: Any] = [
            "model": "grok-4.6",
            "temperature": 0.2,
            "max_tokens": 500,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "bad response"
            throw NSError(domain: "Commitments", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let decoded = try JSONDecoder().decode(ChatJSON.self, from: data)
        guard var content = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else { return [] }

        if content.hasPrefix("```") {
            content = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let jsonData = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return [] }

        let now = Date()
        var result: [CallCommitment] = []
        for item in obj["commitments"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String, !text.isEmpty {
                result.append(CallCommitment(
                    kind: .commitment,
                    speaker: item["speaker"] as? String ?? "Unknown",
                    text: text,
                    at: now
                ))
            }
        }
        for item in obj["open_questions"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String, !text.isEmpty {
                result.append(CallCommitment(
                    kind: .openQuestion,
                    speaker: item["speaker"] as? String ?? "Unknown",
                    text: text,
                    at: now
                ))
            }
        }
        for item in obj["decisions"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String, !text.isEmpty {
                result.append(CallCommitment(
                    kind: .decision,
                    speaker: item["speaker"] as? String ?? "Unknown",
                    text: text,
                    at: now
                ))
            }
        }
        return Array(result.prefix(6))
    }
}

struct CallWrapEngine {
    func wrap(dialogue: String, commitments: [CallCommitment], notes: String, apiKey: String) async throws -> CallWrap {
        let system = """
        You write a post-call wrap for the seller. Return only valid JSON:
        {
          "summary": "5-8 sentence narrative of what happened and where things stand",
          "follow_up": "a short follow-up email draft the seller can send, with subject line on first line as Subject: ..."
        }
        Use only the dialogue and listed commitments. Do not invent product claims.
        """

        let commitmentBlock = commitments.isEmpty
            ? "(none captured)"
            : commitments.map { "- [\($0.kind.rawValue)] \($0.speaker): \($0.text)" }.joined(separator: "\n")

        let user = """
        NOTES:
        \(notes.isEmpty ? "(none)" : String(notes.prefix(1200)))

        COMMITMENTS / OPEN QUESTIONS / DECISIONS:
        \(commitmentBlock)

        TRANSCRIPT:
        \(dialogue.suffix(6000))
        """

        let payload: [String: Any] = [
            "model": "grok-4.6",
            "temperature": 0.3,
            "max_tokens": 900,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 40

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "bad response"
            throw NSError(domain: "Wrap", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let decoded = try JSONDecoder().decode(ChatJSON.self, from: data)
        guard var content = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else {
            return CallWrap(summary: "", followUpDraft: "", commitments: commitments)
        }
        if content.hasPrefix("```") {
            content = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let jsonData = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
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

private struct ChatJSON: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
