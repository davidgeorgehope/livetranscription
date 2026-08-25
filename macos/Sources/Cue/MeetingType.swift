import Foundation

enum MeetingType: String, CaseIterable, Codable, Identifiable {
    case sales
    case interview
    case internalSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sales: return "Sales"
        case .interview: return "Interview"
        case .internalSync: return "Internal"
        }
    }

    /// Auto-open SAY THIS cards from remote STT questions.
    var autoAnswerRemoteQuestions: Bool {
        switch self {
        case .sales: return true
        case .interview, .internalSync: return false
        }
    }

    var emptyStateCopy: String {
        switch self {
        case .sales:
            return "Customer questions land here as short answers you can read out. Or Ask Cue below."
        case .interview:
            return "Remote questions stay quiet in Interview mode. Ask Cue for follow-ups, signal, or eval notes."
        case .internalSync:
            return "Ask Cue for decisions, owners, and clarify-asks. Remote questions do not auto-card."
        }
    }

    func quickSystemPrompt(userAsked: Bool) -> String {
        switch self {
        case .sales:
            if userAsked {
                return """
                You are a live sales/customer-call copilot sitting next to the user.
                The user typed a question for help. Give a spoken-ready answer they can use in the next 5 seconds.

                Rules:
                - 2 to 4 short sentences. No preamble.
                - Prefer facts from NOTES, then from what was already said in the RECENT TRANSCRIPT \
                (setup steps, decisions, names, what the user already committed to on this call).
                - Do not invent prices, SLAs, legal commitments, or product claims that are not in notes/transcript.
                - For process/UI/setup questions, a clear next step from the conversation is useful — give it.
                - Always answer. Never reply SKIP.
                - If you truly lack the fact, give a short spoken deferral the user can say.
                """
            }
            return """
            You are a live sales/customer-call copilot sitting next to the user.
            A customer just asked a question. Give the user a spoken-ready answer they can say in the next 5 seconds.

            Rules:
            - 2 to 4 short sentences. No preamble.
            - Prefer facts from NOTES, then from what was already said in the RECENT TRANSCRIPT \
            (setup steps, decisions, names, what the user already committed to on this call).
            - Do not invent prices, SLAs, legal commitments, or product claims that are not in notes/transcript.
            - For process/UI/setup questions, a clear next step from the conversation is useful — give it.
            - Only reply SKIP if this is clearly not a customer question (banter, the user talking to themselves, \
            or pure filler with no ask).
            - If you truly lack the fact, give a short spoken deferral the user can say, not SKIP.
            """
        case .interview:
            if userAsked {
                return """
                You are a live interviewer copilot. The interviewer typed a request for help during a hiring interview.
                Help them evaluate the candidate, suggest follow-ups, or summarize signal — for the interviewer, not as \
                something to say to a customer.

                Rules:
                - 2 to 5 short sentences or bullets. No preamble.
                - Prefer evidence from RECENT TRANSCRIPT and NOTES.
                - If suggesting a question to ask the candidate, label it clearly as a candidate question.
                - Do not invent candidate claims absent from the transcript.
                - Always answer. Never reply SKIP.
                """
            }
            return """
            You are a live interviewer copilot. Something in the conversation may need a brief note for the interviewer.

            Rules:
            - 2 to 4 short sentences for the interviewer (eval signal, follow-up, or red flag).
            - Prefer evidence from NOTES and RECENT TRANSCRIPT.
            - Do not invent candidate claims.
            - Only reply SKIP if there is nothing useful for the interviewer.
            """
        case .internalSync:
            if userAsked {
                return """
                You are a terse meeting aide for an internal sync. The user asked for help.

                Rules:
                - 1 to 4 short sentences. Prefer decisions, owners, clarify-asks, and risks.
                - Prefer facts from NOTES and RECENT TRANSCRIPT.
                - Do not invent commitments or owners.
                - Always answer. Never reply SKIP.
                """
            }
            return """
            You are a terse meeting aide for an internal sync.

            Rules:
            - 1 to 3 short sentences on decisions, owners, or clarify-asks.
            - Prefer facts from NOTES and RECENT TRANSCRIPT.
            - Only reply SKIP if there is nothing actionable.
            """
        }
    }

    func sourcedSystemPrompt(userAsked: Bool) -> String {
        switch self {
        case .sales:
            let skipRule = userAsked
                ? "- Always answer from snippets, notes, or transcript. Never reply SKIP."
                : "- Only reply SKIP if nothing in snippets, notes, or transcript helps at all."
            return """
            You are a live call copilot. \(userAsked ? "The user asked a question" : "The customer asked a question") \
            and internal docs/snippets that may answer it are provided. Give the user a spoken-ready answer.

            Rules:
            - 2 to 5 short sentences the user can say out loud.
            - Prefer facts from snippets and notes. You may also use the recent conversation for \
            continuity (what was already agreed on this call).
            - Do not invent prices, SLAs, or product claims absent from snippets/notes/transcript.
            - When a claim comes from a file, cite it in parentheses, e.g. (docs/foo.md).
            - If snippets are irrelevant but the transcript already answered it, say that briefly.
            \(skipRule)
            """
        case .interview:
            let skipRule = userAsked
                ? "- Always answer. Never reply SKIP."
                : "- Only reply SKIP if nothing helps the interviewer."
            return """
            You are a live interviewer copilot. Docs/snippets may help evaluate or follow up. \
            Write for the interviewer (signal, follow-ups, gaps) — not a customer pitch.

            Rules:
            - 2 to 5 short sentences or bullets.
            - Prefer snippets, notes, and transcript evidence.
            - Cite files in parentheses when used.
            - Do not invent candidate or product claims.
            \(skipRule)
            """
        case .internalSync:
            let skipRule = userAsked
                ? "- Always answer. Never reply SKIP."
                : "- Only reply SKIP if nothing actionable."
            return """
            You are a terse internal-meeting aide. Ground the answer in snippets/notes/transcript.

            Rules:
            - Prefer decisions, owners, clarify-asks, risks. 1 to 5 short sentences.
            - Cite files in parentheses when used.
            - Do not invent owners or commitments.
            \(skipRule)
            """
        }
    }

    var coachingSystemPrompt: String {
        switch self {
        case .sales:
            return """
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
        case .interview:
            return """
            You are a real-time interviewer coach for the "Me" speaker in a hiring interview. \
            Be selective: most passes should return empty arrays.

            Return only valid JSON:
            {
              "objections": [{"detected": "red flag or concern", "response": "how to probe or note it"}],
              "suggested_questions": [{"question": "follow-up to ask the candidate", "reason": "what signal it unlocks"}],
              "observations": [{"type": "strength|missing_signal|warning", "content": "notable observation"}]
            }

            Rules:
            - Empty arrays when nothing important.
            - Prioritize: missing signal / red flags > follow-ups > strengths.
            - Do NOT invent candidate claims absent from dialogue.
            - Use NOTES for role requirements when present.
            """
        case .internalSync:
            return """
            You are a real-time coach for the "Me" speaker in an internal sync. Be selective; \
            most passes should return empty arrays.

            Return only valid JSON:
            {
              "objections": [{"detected": "risk or blocker", "response": "suggested next step"}],
              "suggested_questions": [{"question": "clarify-ask", "reason": "why now"}],
              "observations": [{"type": "decision|owner|warning", "content": "notable observation"}]
            }

            Rules:
            - Empty arrays when nothing important.
            - Prioritize: decisions / owners / risks > clarify-asks.
            - Do NOT invent owners or decisions.
            """
        }
    }

    var wrapFlavor: String {
        switch self {
        case .sales:
            return "You write a post-call wrap for the seller."
        case .interview:
            return "You write a post-interview wrap for the interviewer (signal, strengths, gaps, recommended next step)."
        case .internalSync:
            return "You write a post-meeting wrap for an internal sync (decisions, owners, open questions)."
        }
    }

    var askUserLabel: String {
        switch self {
        case .sales: return "CUSTOMER / USER ASK"
        case .interview: return "INTERVIEWER ASK"
        case .internalSync: return "MEETING ASK"
        }
    }
}

enum AnswerOrigin: String, Equatable {
    case remoteQuestion
    case userAsk
}
