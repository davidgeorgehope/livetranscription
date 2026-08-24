import Foundation

struct CoachingNote: Identifiable, Equatable {
    enum Kind: String {
        case objection = "Objection"
        case ask = "Ask this"
        case observation = "Note"
    }

    let id = UUID()
    let kind: Kind
    let content: String
    let suggestion: String?
    let at: Date
}

/// Periodic selective coaching pass over recent dialogue, ported from the
/// Python v1 coaching engine: only objections needing a response, genuinely
/// useful questions to ask, and important observations.
struct CoachingEngine {
    func analyze(dialogue: String, notes: String, apiKey: String) async throws -> [CoachingNote] {
        let system = """
        You are a real-time meeting coach for the "Me" speaker on a live customer call. \
        Analyze the recent dialogue and provide ONLY high-priority coaching. Be very selective: \
        most passes should return empty arrays. Do NOT coach on things already handled well.

        Return only valid JSON:
        {
          "objections": [{"detected": "objection raised", "response": "suggested response"}],
          "suggested_questions": [{"question": "question to ask now", "reason": "why"}],
          "observations": [{"type": "opportunity|warning", "content": "notable observation"}]
        }

        Rules:
        - Empty arrays for categories with nothing important.
        - Prioritize: objections > opportunities > questions.
        - Do NOT suggest questions just to fill space.
        - If the user's notes list topics, competitors, or goals, use them.
        """

        let user = """
        USER'S NOTES / CALL CONTEXT:
        \(notes.isEmpty ? "(none provided)" : notes)

        RECENT DIALOGUE (Customer = them, Me = the user you are coaching):
        \(dialogue.suffix(2400))
        """

        let payload: [String: Any] = [
            "model": "grok-4.6",
            "temperature": 0.3,
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
            throw NSError(domain: "Coaching", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
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

        var result: [CoachingNote] = []
        let now = Date()
        for item in obj["objections"] as? [[String: Any]] ?? [] {
            if let detected = item["detected"] as? String, !detected.isEmpty {
                result.append(CoachingNote(kind: .objection, content: detected, suggestion: item["response"] as? String, at: now))
            }
        }
        for item in obj["suggested_questions"] as? [[String: Any]] ?? [] {
            if let question = item["question"] as? String, !question.isEmpty {
                result.append(CoachingNote(kind: .ask, content: question, suggestion: item["reason"] as? String, at: now))
            }
        }
        for item in obj["observations"] as? [[String: Any]] ?? [] {
            if let content = item["content"] as? String, !content.isEmpty {
                let type = item["type"] as? String ?? "opportunity"
                result.append(CoachingNote(kind: .observation, content: "[\(type)] \(content)", suggestion: nil, at: now))
            }
        }
        return Array(result.prefix(3))
    }
}

private struct ChatJSON: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
