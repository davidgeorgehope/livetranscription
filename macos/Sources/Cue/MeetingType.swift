import Foundation

enum MeetingType: String, CaseIterable, Codable, Identifiable {
    case technical
    case sales
    case interview
    case internalSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .technical: return "Technical"
        case .sales: return "Sales"
        case .interview: return "Interview"
        case .internalSync: return "Internal"
        }
    }

    /// Auto-open SAY THIS cards from remote STT questions.
    var autoAnswerRemoteQuestions: Bool {
        switch self {
        case .technical, .sales, .internalSync: return true
        case .interview: return false
        }
    }

    /// Whether the analyst should propose proactive context lookups
    /// (customer, feature, system, incident named in passing).
    var wantsLookups: Bool {
        switch self {
        case .technical, .internalSync: return true
        case .sales, .interview: return false
        }
    }

    /// What counts as a question worth carding, for the analyst prompt.
    var questionScope: String {
        switch self {
        case .sales:
            return "Real asks from Them that Me is expected to answer: product, capability, pricing, process, " +
                "timeline, \"can you / do you / how does it\"."
        case .technical:
            return "Real technical or factual asks from Them that Me is expected to answer: how it works, " +
                "does it support X, limits, auth, networking, data handling, APIs, deployment."
        case .internalSync:
            return "Any factual or technical question raised in the meeting — by anyone, including Me — " +
                "that nobody has answered yet and that docs, prep, or past calls could settle. Not " +
                "opinion polls, not \"what do we think\", not scheduling."
        case .interview:
            return "Questions the candidate asked the interviewer that need a factual answer."
        }
    }

    /// Prefer live/session transcript snippets over monorepo keyword hits.
    var prefersTranscriptGrounding: Bool {
        switch self {
        case .interview: return true
        case .technical, .sales, .internalSync: return false
        }
    }

    /// How many transcript characters to pass into answer prompts.
    var transcriptCharBudget: Int {
        switch self {
        case .interview: return 12_000
        case .internalSync: return 6_000
        case .technical: return 5_000
        case .sales: return 3_500
        }
    }

    /// Rolling dialogue window size (words) kept for question context.
    var recentWindowWordBudget: Int {
        switch self {
        case .interview: return 1_200
        case .internalSync: return 600
        case .technical: return 600
        case .sales: return 400
        }
    }

    /// Docs/snippet characters for the sourced pass. Technical asks need room for
    /// a config block or two, not just a sentence.
    var snippetCharBudget: Int {
        switch self {
        case .technical: return 11_000
        case .interview: return 9_000
        case .sales, .internalSync: return 7_000
        }
    }

    var emptyStateCopy: String {
        switch self {
        case .technical:
            return "Technical questions land here as precise answers with the doc or file they came from. Or Ask Cue below."
        case .sales:
            return "Customer questions land here as short answers you can read out. Or Ask Cue below."
        case .interview:
            return "Remote questions stay quiet in Interview mode. Ask Cue for follow-ups, signal, or eval notes."
        case .internalSync:
            return "Unanswered questions and things named in passing (a customer, a system, an incident) land here with what we already know. Or Ask Cue below."
        }
    }

    func quickSystemPrompt(userAsked: Bool) -> String {
        switch self {
        case .technical:
            let who = userAsked ? "The user typed a question for help." : "Someone on the call just asked a technical question."
            let skipRule = userAsked
                ? "- Always answer. Never reply SKIP."
                : "- Only reply SKIP if this is clearly not a question (banter, filler, the user talking to themselves)."
            return """
            You are a live copilot for a solutions architect on a technical call (architecture, security, \
            integration, deployment, API/SDK). \(who) Give a spoken-ready answer for the next 5 seconds.

            Rules:
            - 2 to 4 short sentences. No preamble. Precise over polished: name the mechanism, the setting, \
            the limit, the port — whatever the question actually turns on.
            - Shape: sentence one is the direct answer (yes / no / partly / "today X, not Y"). Then how it \
            works. At most ONE hedge in the whole answer — never stack "generally", "typically", \
            "internally", "not committed" across sentences.
            - Prefer facts from PREP and NOTES, then what was already said in the RECENT TRANSCRIPT.
            - If the transcript already answered it (even partially), state that fact; do not stall.
            - Do not invent limits, defaults, version numbers, or security claims that are not in prep/notes/transcript. \
            If you are working from general knowledge, say so in two words ("generally," "by default,") and keep it short.
            - Distinguish what ships today from what is internal or roadmap; never present internal as shipped.
            - Sources in order: transcript, PREP, NOTES, then general engineering and public product knowledge \
            (marked "generally"). A deferral is the last resort, only for facts nobody on our side could know \
            right now (their contract, an unpublished number) — and even then say what IS known first and name \
            the one thing to confirm. Never a bare "I'll get back to you".
            \(skipRule)
            """
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
                - Deferrals are a last resort: say what IS known from any source first, then name the one \
                thing to confirm. Never a bare "I'll get back to you".
                """
            }
            return """
            You are a live sales/customer-call copilot sitting next to the user.
            A customer just asked a question. Give the user a spoken-ready answer they can say in the next 5 seconds.

            Rules:
            - 2 to 4 short sentences. No preamble.
            - Prefer facts from NOTES, then from what was already said in the RECENT TRANSCRIPT \
            (setup steps, decisions, names, what the user already committed to on this call).
            - If the transcript already answered the question (even partially), say that fact — \
            do not stall with “let me confirm” / “I don’t want to guess.”
            - Do not invent prices, SLAs, legal commitments, or product claims that are not in notes/transcript.
            - For process/UI/setup questions, a clear next step from the conversation is useful — give it.
            - Only reply SKIP if this is clearly not a customer question (banter, the user talking to themselves, \
            or pure filler with no ask).
            - Deferrals are a last resort: say what IS known from any source first, then name the one \
            thing to confirm. Not SKIP.
            """
        case .interview:
            if userAsked {
                return """
                You are a live interviewer copilot. The interviewer typed a request during a hiring interview.
                Write for the interviewer: eval signal, synthesis, gaps, or a sharp follow-up — not a customer pitch.

                Rules:
                - 3 to 6 short sentences or bullets. No preamble, no hedging filler.
                - Prefer concrete evidence from RECENT TRANSCRIPT (names, metrics, claims, architecture choices).
                - Quote or paraphrase specific candidate claims when summarizing; do not invent them.
                - If suggesting a question to ask the candidate, prefix with "Ask:".
                - Never reply SKIP. Never say you lack context if the transcript has relevant substance.
                - Avoid deferrals like "I'd need more info" when the transcript already covers the topic.
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

    func sourcedSystemPrompt(userAsked: Bool, hasDraft: Bool = false) -> String {
        switch self {
        case .technical:
            let skipRule = hasDraft
                ? "- A CURRENT DRAFT ANSWER is provided. Return the single best spoken answer: keep what "
                    + "is right in the draft, correct it with facts from snippets, and make it more specific — "
                    + "never vaguer. Never reply SKIP. Do not replace a substantive draft with a deferral."
                : "- Always answer. Sources in order: snippets, prep, notes, transcript, then general "
                    + "engineering and public product knowledge marked \"generally\". Never reply SKIP. Defer "
                    + "only on facts nobody on our side could know right now, and even then state what IS "
                    + "known first and name the one thing to confirm."
            return """
            You are a live copilot for a solutions architect on a technical call. \
            \(userAsked ? "The user asked a question" : "Someone on the call asked a technical question") \
            and internal docs, code, and playbook snippets that may answer it are provided. \
            Give the user a spoken-ready, technically precise answer.

            Rules:
            - 2 to 5 short sentences the user can say out loud. Sentence one is the direct answer \
            (yes / no / partly / "today X, not Y"), then the mechanism or concrete value (setting name, \
            limit, port, protocol, flow), then at most ONE caveat. Never stack hedges — pick the one \
            that matters and drop the rest. Plain words over product jargon.
            - Trust order for PRODUCT BEHAVIOUR when sources disagree: what was said on THIS call > \
            product-docs/ (public docs, what we commit to externally) > grok-bot-internal/ (internal FAQ \
            and decks: accurate, but internal-only — state the fact in your own words, never as something \
            the customer can read) > internal-docs/ and code > playbook/ entries (dated) > NOTES. For THIS \
            CUSTOMER's history, promises, and constraints, PREP DOCS FOR THIS CALL win.
            - Code and internal docs describe how it is built, not always what is shipped or supported. \
            When a snippet is an internal spec, a route list, a feature flag, or a test, say the fact \
            but mark it: "internally" / "not something I would commit to yet" — never present it as GA.
            - Playbook entries may list PITFALLS — things Cue has said before that were wrong. Never repeat one.
            - Only use a snippet if it clearly addresses this question. Do not stretch an adjacent doc into an answer.
            - Do not invent product-specific limits, defaults, versions, SLAs, or compliance claims absent from \
            snippets/prep/notes/transcript. General engineering facts (how SAML, SCIM, VPC peering, OAuth, \
            key rotation work) and public product behaviour are fair game — mark them "generally" / "by default".
            - When a claim comes from a file, cite it in parentheses with the path, e.g. (internal-docs/foo.md).
            - If snippets are irrelevant but the transcript already answered it, say that briefly.
            \(skipRule)
            """
        case .sales:
            let skipRule = hasDraft
                ? "- A CURRENT DRAFT ANSWER is provided. Return the single best spoken answer: keep what "
                    + "is right in the draft, add or correct it with facts from snippets, notes, or the "
                    + "transcript, and make it more specific — never vaguer. Never reply SKIP. Do not replace a "
                    + "substantive draft with a deferral."
                : "- Always answer from snippets, notes, or transcript. Never reply SKIP. If none of them "
                    + "settle it, say what IS known first and name the one thing to confirm — never a bare deferral."
            return """
            You are a live call copilot. \(userAsked ? "The user asked a question" : "The customer asked a question") \
            and internal docs/snippets that may answer it are provided. Give the user a spoken-ready answer.

            Rules:
            - 2 to 5 short sentences the user can say out loud.
            - Trust order when sources disagree: what was said on THIS call > PREP DOCS FOR THIS CALL \
            > product-docs/ (public docs) > grok-bot-internal/ (internal FAQ; state facts, never as customer-readable) \
            > playbook/ entries (how reps actually answer, dated) > NOTES > other docs.
            - Playbook entries may list PITFALLS — things Cue has said before that were wrong. \
            Never repeat a pitfall. If an entry says "as of" a date, you may say "as of <month>".
            - Only use a snippet if it clearly addresses this question. Do not stretch a doc that \
            is about something adjacent (an internal spec, a route list, a telemetry README) into \
            a product answer — that produces confident wrong answers.
            - Do not invent prices, SLAs, or product claims absent from snippets/notes/transcript.
            - When a claim comes from a file, cite it in parentheses, e.g. (playbook/foo.md).
            - If snippets are irrelevant but the transcript already answered it, say that briefly.
            \(skipRule)
            """
        case .interview:
            let skipRule = userAsked
                ? "- Always answer. Never reply SKIP. Never defer if transcript/snippets have substance."
                : "- Only reply SKIP if nothing helps the interviewer."
            return """
            You are a live interviewer copilot. Snippets may include live-dialogue / session transcript \
            and docs. Write for the interviewer (signal, synthesis, gaps, follow-ups) — not a pitch.

            Rules:
            - 3 to 6 short sentences or bullets with concrete evidence.
            - Prefer live-dialogue / call-* snippets and NOTES over unrelated repo docs.
            - Cite files in parentheses when used (e.g. live-dialogue, call-….md).
            - Do not invent candidate or product claims.
            - Prefix suggested candidate questions with "Ask:".
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

    /// Meeting-specific slant for the coaching part of the analyst pass.
    var analystFocus: String {
        switch self {
        case .technical:
            return """
            This is a technical call: Me is a solutions architect; Them are engineers, security, or IT \
            evaluating or deploying the product. Questions worth carding are technical asks — how does X \
            work, does it support Y, what happens when Z, limits, auth/SSO, networking, data handling, \
            APIs, deployment. "Objections" are technical blockers or risks (a missing integration, a \
            compliance gap, an architecture mismatch). Observation types: blocker | risk | follow_up. \
            Priority: blockers > risks > things Me should verify before committing. Suggested questions \
            are discovery asks about their environment. Use PREP and NOTES for their stack and open items. \
            Do not coach on sales technique.
            """
        case .sales:
            return """
            This is a customer call: Me is selling. Objections are pushback on price, fit, security, \
            timeline, or competitors. Observation types: opportunity | warning. Priority: objections > \
            opportunities > questions to ask. Use NOTES for competitors, goals, and topics to steer to.
            """
        case .interview:
            return """
            This is a hiring interview: Me is the interviewer, Them is the candidate. "Objections" are \
            red flags or concerns worth probing. Suggested questions are follow-ups to the candidate. \
            Observation types: strength | missing_signal | warning. Priority: missing signal and red \
            flags > follow-ups > strengths. Use NOTES for role requirements. Do not invent candidate claims.
            """
        case .internalSync:
            return """
            This is an internal sync. "Objections" are risks or blockers. Suggested questions are \
            clarify-asks. Observation types: decision | owner | warning. Priority: decisions, owners, \
            risks > clarify-asks. Do not invent owners or decisions.
            """
        }
    }

    var wrapFlavor: String {
        switch self {
        case .technical:
            return "You write a post-call wrap for a solutions architect (what they asked, what was answered, what needs verifying, technical follow-ups with owners)."
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
        case .technical: return "TECHNICAL ASK"
        case .sales: return "CUSTOMER / USER ASK"
        case .interview: return "INTERVIEWER ASK"
        case .internalSync: return "MEETING ASK"
        }
    }
}

enum AnswerOrigin: String, Equatable {
    case remoteQuestion
    case userAsk
    /// Proactive "what we know about X" card from an analyst lookup.
    case lookup
}
