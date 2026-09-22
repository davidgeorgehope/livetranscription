import Foundation

/// Thin xAI chat-completions client shared by the intelligence passes.
enum GrokChat {
    static let model = "grok-4.6"

    static func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double = 0.2,
        reasoningEffort: String? = nil,
        timeout: TimeInterval = 25,
        apiKey: String
    ) async throws -> String {
        var payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let reasoningEffort {
            payload["reasoning_effort"] = reasoningEffort
        }
        let data = try await post(payload, timeout: timeout, apiKey: apiKey)
        let decoded = try JSONDecoder().decode(ChatJSON.self, from: data)
        return decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Transport

    struct UpstreamError: LocalizedError {
        let status: Int
        let body: String
        /// xAI's "at capacity" / restart responses: worth a short retry, and a
        /// signal to slow the analysis cadence rather than pile on.
        var isCapacity: Bool {
            status == 429 || status == 503 || status == 529
                || body.contains("resource-exhausted") || body.contains("shutting down")
        }
        var isRetryable: Bool { isCapacity || status == 500 || status == 502 }
        var errorDescription: String? {
            isCapacity ? "xAI at capacity (\(status))" : "xAI \(status): \(body.prefix(160))"
        }
    }

    /// Set when xAI reports capacity trouble; callers that run on a cadence
    /// (the analyst) wait it out instead of hammering. Main-actor because
    /// AppModel reads it when scheduling.
    @MainActor static var saturatedUntil: Date?
    @MainActor static var isSaturated: Bool { (saturatedUntil ?? .distantPast) > Date() }
    private static let saturationHold: TimeInterval = 20
    private static let retryDelays: [TimeInterval] = [1.5, 4]

    /// POST to chat/completions. Immediate rejections (429/5xx) are retried
    /// twice with short backoff; timeouts are not — a request that already
    /// burned `timeout` seconds is too late for a live answer.
    static func post(_ payload: [String: Any], timeout: TimeInterval, apiKey: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = timeout

        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) { return data }
            let error = UpstreamError(status: status, body: String(data: data, encoding: .utf8) ?? "")
            if error.isCapacity {
                await MainActor.run { saturatedUntil = Date().addingTimeInterval(saturationHold) }
            }
            guard error.isRetryable, attempt < retryDelays.count else { throw error }
            try await Task.sleep(for: .seconds(retryDelays[attempt]))
            attempt += 1
        }
    }

    /// Parse a JSON object the model returned, tolerating a ```json fence.
    static func jsonObject(from content: String) -> [String: Any]? {
        var text = content
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private struct ChatJSON: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }
}
