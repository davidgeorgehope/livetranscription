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

struct AnalysisResult {
    struct DetectedQuestion: Equatable {
        /// Self-contained restatement, pronouns resolved, so retrieval and
        /// the answer prompt don't depend on the surrounding transcript.
        let question: String
        let open: Bool
        /// Spoken-ready first draft from notes + transcript only. Saves a
        /// second round-trip before the card can appear; the docs-grounded
        /// pass still runs afterwards.
        let quickAnswer: String
    }

    struct Lookup: Equatable {
        /// Short display name, e.g. "Illumina GHES PrivateLink".
        let topic: String
        /// Why it matters right now, one clause.
        let why: String
        /// Retrieval keywords, separate from the display name.
        let query: String
    }

    var questions: [DetectedQuestion] = []
    var lookups: [Lookup] = []
    var coaching: [CoachingNote] = []
    var commitments: [CallCommitment] = []
}

/// Single rolling pass over the live transcript. The model, not a regex,
/// decides what counts as a question worth answering, what needs coaching,
/// and what was committed to. Runs after every new line (debounced), so it
/// sees the dialogue with a marker at where the previous pass left off.
struct ConversationAnalyst {
    static let newMarker = ">>> NEW SINCE LAST PASS (judge these; earlier lines are context)"

    func analyze(
        dialogue: String,
        notes: String,
        prep: String = "",
        alreadyCaptured: [String],
        meetingType: MeetingType,
        apiKey: String
    ) async throws -> AnalysisResult {
        let system = """
        You are the live analyst inside a call copilot. "Me" is the person you work for; "Them" is \
        everyone else on the call. Speech-to-text is punctuation-poor and splits sentences across \
        lines — judge by meaning, not by question marks.

        Return only valid JSON:
        {
          "questions_for_me": [{"question": "self-contained restatement", "status": "open|answered", \
        "quick_answer": "what Me can say right now"}],
          "lookups": [{"topic": "short name", "why": "why facts about it help Me right now", \
        "query": "3-8 retrieval keywords"}],
          "objections": [{"detected": "what they pushed back on", "response": "suggested response"}],
          "suggested_questions": [{"question": "question Me should ask now", "reason": "why"}],
          "observations": [{"type": "label", "content": "notable observation"}],
          "commitments": [{"speaker": "Me|Them", "text": "concrete follow-up someone committed to"}],
          "open_questions": [{"speaker": "Me|Them", "text": "ask still hanging with no answer"}],
          "decisions": [{"speaker": "Me|Them", "text": "outcome that was agreed"}]
        }

        questions_for_me:
        - \(meetingType.questionScope) Not rhetorical, not banter, not call logistics \
        ("can you hear me", "share your screen").
        - Rewrite each so it stands alone: resolve "it / that / this / they" to what is actually \
        being discussed, keep their specific wording. One question per entry.
        - status "answered" when Me already gave a substantive answer in the transcript; else "open".
        - Only include questions that are in, or completed by, the lines after the marker.
        - quick_answer (open questions only, else ""): 2 to 3 short spoken-ready sentences Me can say \
        in the next few seconds. Sources in order: what was said on this call, PREP, NOTES, then your \
        own knowledge of engineering and of public product behaviour — mark that with one word \
        ("generally," / "by default,"). Never invent prices, SLAs, legal commitments, or unreleased \
        features. Deferring is a last resort, only for facts nobody on our side could know right now \
        (this customer's contract, an unpublished number): even then say what IS known first and name \
        the one thing to confirm. Never "SKIP", never a bare "I'll check" or "I don't know".

        lookups\(meetingType.wantsLookups ? "" : " (always [] for this meeting type)"):
        - Things named in the lines after the marker that the discussion now depends on facts about: \
        a customer or account, a product feature, an internal system or service, an integration, an \
        incident, an acronym. Only when having what we already know on screen would help Me in the \
        next minute. Not things Me is currently explaining. Not generic words. Usually empty.
        - topic: 2-5 word display name. query: retrieval keywords including proper nouns and aliases.

        objections / suggested_questions / observations: high bar. Most passes return empty arrays. \
        Do not coach on things Me already handled well. \(meetingType.analystFocus)

        commitments / open_questions / decisions: concrete, from the lines after the marker only. \
        No inventing.

        Never repeat anything listed under ALREADY CAPTURED. Empty arrays are the normal result.
        """

        let captured = alreadyCaptured.isEmpty
            ? "(nothing yet)"
            : alreadyCaptured.map { "- \($0)" }.joined(separator: "\n")
        let user = """
        NOTES / CALL CONTEXT:
        \(notes.isEmpty ? "(none)" : String(notes.prefix(1500)))
        \(AnswerEngine.prepBlock(prep, limit: 4_000))
        ALREADY CAPTURED (do not repeat):
        \(captured)

        TRANSCRIPT:
        \(dialogue)
        """

        // Low effort: measured 7–11s vs 31–40s at default with identical
        // extraction on the same transcripts. This pass gates card latency.
        let content = try await GrokChat.complete(
            system: system, user: user, maxTokens: 900, temperature: 0.2,
            reasoningEffort: "low", timeout: 40, apiKey: apiKey
        )
        guard let obj = GrokChat.jsonObject(from: content) else { return AnalysisResult() }
        return Self.parse(obj)
    }

    private static func parse(_ obj: [String: Any]) -> AnalysisResult {
        var result = AnalysisResult()
        let now = Date()

        for item in obj["questions_for_me"] as? [[String: Any]] ?? [] {
            guard let q = item["question"] as? String, !q.isEmpty else { continue }
            let status = (item["status"] as? String ?? "open").lowercased()
            let quick = (item["quick_answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result.questions.append(.init(question: q, open: status != "answered", quickAnswer: quick))
        }
        for item in obj["lookups"] as? [[String: Any]] ?? [] {
            guard let topic = (item["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !topic.isEmpty else { continue }
            result.lookups.append(.init(
                topic: topic,
                why: (item["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                query: (item["query"] as? String ?? topic).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        for item in obj["objections"] as? [[String: Any]] ?? [] {
            if let detected = item["detected"] as? String, !detected.isEmpty {
                result.coaching.append(CoachingNote(
                    kind: .objection, content: detected, suggestion: item["response"] as? String, at: now
                ))
            }
        }
        for item in obj["suggested_questions"] as? [[String: Any]] ?? [] {
            if let question = item["question"] as? String, !question.isEmpty {
                result.coaching.append(CoachingNote(
                    kind: .ask, content: question, suggestion: item["reason"] as? String, at: now
                ))
            }
        }
        for item in obj["observations"] as? [[String: Any]] ?? [] {
            if let content = item["content"] as? String, !content.isEmpty {
                let type = item["type"] as? String ?? "note"
                result.coaching.append(CoachingNote(
                    kind: .observation, content: "[\(type)] \(content)", suggestion: nil, at: now
                ))
            }
        }
        let kinds: [(String, CommitmentKind)] = [
            ("commitments", .commitment),
            ("open_questions", .openQuestion),
            ("decisions", .decision),
        ]
        for (key, kind) in kinds {
            for item in obj[key] as? [[String: Any]] ?? [] {
                if let text = item["text"] as? String, !text.isEmpty {
                    result.commitments.append(CallCommitment(
                        kind: kind, speaker: item["speaker"] as? String ?? "Unknown", text: text, at: now
                    ))
                }
            }
        }
        return result
    }
}
