import Foundation

struct AnswerEngine {
    func answer(question: String, transcript: String, notes: String, apiKey: String) async throws -> String {
        let system = """
        You are a live sales/customer-call copilot sitting next to the user.
        A customer just asked a question. Give the user a spoken-ready answer they can say in the next 5 seconds.

        Rules:
        - 2 to 4 short sentences. No preamble.
        - If the user's notes/context contain a fact, use it. Do not invent product claims, prices, SLAs, or legal commitments.
        - If you don't know, say exactly what to ask or defer: "I don't want to guess — I'll confirm and get you the precise number."
        - Prefer concrete, confident phrasing over marketing fluff.
        - If the question is not actually a customer question, reply with SKIP.
        """

        let user = """
        CONTEXT / NOTES:
        \(notes.isEmpty ? "(none provided)" : notes)

        RECENT TRANSCRIPT:
        \(transcript.suffix(1800))

        CUSTOMER QUESTION:
        \(question)
        """

        let payload: [String: Any] = [
            "model": "gpt-4.1-mini",
            "temperature": 0.2,
            "max_tokens": 180,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "bad response"
            throw NSError(domain: "Answer", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let decoded = try JSONDecoder().decode(ChatJSON.self, from: data)
        let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.uppercased() == "SKIP" { return "" }
        return text
    }
}

private struct ChatJSON: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
