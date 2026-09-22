import Foundation

struct AnswerEngine {
    func answer(
        question: String,
        transcript: String,
        notes: String,
        prep: String = "",
        meetingType: MeetingType,
        userAsked: Bool,
        apiKey: String
    ) async throws -> String {
        let system = meetingType.quickSystemPrompt(userAsked: userAsked)
        let label = meetingType.askUserLabel
        let budget = meetingType.transcriptCharBudget
        let maxTokens = meetingType == .interview && userAsked ? 280 : 180
        let user = """
        CONTEXT / NOTES:
        \(notes.isEmpty ? "(none provided)" : notes)
        \(Self.prepBlock(prep, limit: 3_000))
        RECENT TRANSCRIPT:
        \(transcript.suffix(budget))

        \(label):
        \(question)
        """

        return try await send(system: system, user: user, maxTokens: maxTokens, apiKey: apiKey)
    }

    /// Second-stage answer grounded in snippets found in the local knowledge
    /// repo. Slower than the quick answer; updates the card when it lands.
    func sourcedAnswer(
        question: String,
        snippets: String,
        notes: String,
        transcript: String,
        prep: String = "",
        meetingType: MeetingType,
        userAsked: Bool,
        draft: String = "",
        proactive: Bool = false,
        apiKey: String
    ) async throws -> Reply {
        var system = meetingType.sourcedSystemPrompt(userAsked: userAsked, hasDraft: !draft.isEmpty)
        if proactive {
            // Nobody asked for this card, so a wrong or empty one costs more than none.
            system += """

            THIS IS A PROACTIVE CONTEXT CARD, not an answer to a question anyone asked. Override the \
            never-SKIP rule: reply exactly SKIP unless the snippets or prep contain specific facts about \
            the topic itself (status, config, decisions, limits, owners, dates). Adjacent or generic \
            material is SKIP. If you do answer: 2 to 4 sentences of facts, most recent first, each \
            with its file in parentheses. No deferrals, no "I'd confirm" — this card is for Me to read, not say.
            """
        }
        let label = proactive ? "TOPIC" : meetingType.askUserLabel
        let budget = min(meetingType.transcriptCharBudget, 4_000)
        let snippetBudget = meetingType.snippetCharBudget
        // 320 truncated ordinary 3-5 sentence answers mid-sentence on grok-4.6.
        let maxTokens = 480
        let user = """
        \(label):
        \(question)

        RECENT CONVERSATION (for what the question refers to):
        \(transcript.suffix(budget))

        USER'S NOTES:
        \(notes.isEmpty ? "(none)" : String(notes.prefix(1200)))
        \(Self.prepBlock(prep, limit: 6_000))
        REPO/DOCS SNIPPETS:
        \(snippets.prefix(snippetBudget))
        \(draft.isEmpty ? "" : "\nCURRENT DRAFT ANSWER (from the quick pass):\n\(draft)")
        """

        return try await sendReply(system: system, user: user, maxTokens: maxTokens, apiKey: apiKey)
    }

    /// Prep docs the user attached for this call. Empty string when none so
    /// the surrounding prompt reads the same either way.
    static func prepBlock(_ prep: String, limit: Int) -> String {
        let text = prep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return "\nPREP DOCS FOR THIS CALL (uploaded by the user; trust above docs and playbook):\n\(text.prefix(limit))\n"
    }

    /// Structured output: the model must return {"answer": ...}. A constrained
    /// field leaves no room for the agent-style scratchpad grok-4.6 sometimes
    /// spills into free-text content, and cut latency ~14s -> ~4s in testing.
    private static let answerSchema: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "spoken_answer",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "answer": [
                        "type": "string",
                        "description": "The spoken-ready answer text exactly as the user should read it, or SKIP.",
                    ],
                    "sources": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "FILE paths of the snippets this answer actually relies on, verbatim as given. Empty when the answer came from the transcript, prep, notes, or general knowledge.",
                    ],
                ],
                "required": ["answer", "sources"],
                "additionalProperties": false,
            ],
        ],
    ]

    struct Reply {
        let text: String
        /// Snippet files the model says it used; the grounding badge shows these,
        /// not every retrieval hit, so irrelevant hits don't masquerade as sources.
        let sources: [String]
    }

    private func send(system: String, user: String, maxTokens: Int, apiKey: String) async throws -> String {
        try await sendReply(system: system, user: user, maxTokens: maxTokens, apiKey: apiKey).text
    }

    private func sendReply(system: String, user: String, maxTokens: Int, apiKey: String) async throws -> Reply {
        let payload: [String: Any] = [
            "model": "grok-4.6",
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "reasoning_effort": "low",
            "response_format": Self.answerSchema,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        let data = try await GrokChat.post(payload, timeout: 30, apiKey: apiKey)
        let decoded = try JSONDecoder().decode(ChatJSON.self, from: data)
        let raw = decoded.choices.first?.message.content ?? ""
        let object = GrokChat.jsonObject(from: raw)
        let text = (object?["answer"] as? String ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased() == "SKIP" || text.uppercased().hasPrefix("SKIP\n") { return Reply(text: "", sources: []) }
        let sources = (object?["sources"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Reply(text: text, sources: sources.filter { !$0.isEmpty })
    }
}

private struct ChatJSON: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
