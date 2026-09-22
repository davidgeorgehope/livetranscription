import Foundation

/// Fires a Grok Bot automation's webhook trigger to ask for a pre-call brief.
///
/// The trigger is async on the server: it returns a run id and the agent does
/// its work afterwards. The prompt tells it to write the brief into
/// `PrepStore.inbox`, which `PrepInboxWatcher` picks up and attaches — so the
/// request should go out minutes before the call, never at Listen.
///
/// Two automations, from `.env` / environment:
///   GROK_BOT_HOOK_URL / GROK_BOT_HOOK_KEY — pre-call brief (writes into PREP)
///   GROK_BOT_SUM_URL  / GROK_BOT_SUM_KEY  — post-call summary and follow-ups
enum GrokBotHook {
    struct Config {
        let url: URL
        let key: String
    }

    static var config: Config? { config(url: "GROK_BOT_HOOK_URL", key: "GROK_BOT_HOOK_KEY") }
    static var wrapConfig: Config? { config(url: "GROK_BOT_SUM_URL", key: "GROK_BOT_SUM_KEY") }

    private static func config(url urlName: String, key keyName: String) -> Config? {
        func read(_ name: String) -> String? {
            if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty { return env }
            return DotEnv.value(for: name)
        }
        guard let raw = read(urlName), let url = URL(string: raw),
              let key = read(keyName), !key.isEmpty else { return nil }
        return Config(url: url, key: key)
    }

    static var isConfigured: Bool { config != nil }
    static var isWrapConfigured: Bool { wrapConfig != nil }

    struct Response: Decodable {
        let success: Bool
        let runUuid: String?
        let backgroundComposerId: String?
        let error: String?
    }

    /// - Parameter topic: who/what the call is about, in the user's words.
    ///   Empty means "my next calendar meeting" — the bot has calendar access.
    static func requestBrief(topic: String) async throws -> Response {
        guard let config else { throw HookError.notConfigured }
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let callLine = topic.isEmpty
            ? "My next calendar meeting (starting within ~2 hours). Use the calendar to identify it."
            : topic
        let slug = (topic.isEmpty ? "next-meeting" : topic).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(50)
        let target = PrepStore.inbox.appendingPathComponent("\(slug.isEmpty ? "brief" : String(slug)).md").path
        let context = """
        Prepare a one-page pre-call brief for Cue, my live call copilot.

        CALL: \(callLine)

        Search my threads, notes, and past conversations about this customer and these people. Write the brief as markdown. Start with a title line, then exactly these two lines from the calendar event (Cue uses them to know when the call ends):
        meeting_start: <ISO 8601 with offset, e.g. 2026-09-18T16:00:00-04:00>
        meeting_end: <ISO 8601 with offset>
        Then a human "**When:**" line, then these sections, each 2-6 bullets, facts only, no filler:
        - Who is on the call (names, roles) and what they care about
        - Their stack and how they use us today
        - What we promised or agreed last time (dates, owners)
        - Open objections and how we planned to handle them
        - Pricing or terms I am allowed to quote
        - Anything I must NOT say

        DELIVERY: this path is on my Mac, not in your sandbox. Use your local computer tool to write it there, as a UTF-8 markdown file, creating the folder if needed:
        \(target)

        Do not post anywhere else. If you find nothing, still write the file with a short note saying so.
        """

        return try await fire(config, body: [
            "context": context,
            "source": "cue",
            "topic": topic.isEmpty ? "next meeting" : topic,
            "deliver_to": target,
        ])
    }

    struct WrapPayload {
        var title: String
        var startedAt: Date
        var endedAt: Date
        var meetingType: String
        var summary: String
        var followUpDraft: String
        var commitments: [String]
        var prepDocs: [String]
        var transcriptPath: String?
        var wrapPath: String?
        var transcript: String
    }

    /// Hands the finished call to the summary automation. The bot has a local
    /// computer tool, so the full transcript goes by path; an inline excerpt
    /// covers the case where it can't reach the Mac.
    static func sendWrap(_ p: WrapPayload) async throws -> Response {
        guard let config = wrapConfig else { throw HookError.notConfigured }
        let when = DateFormatter()
        when.dateStyle = .full
        when.timeStyle = .short
        let minutes = Int(p.endedAt.timeIntervalSince(p.startedAt) / 60)
        let excerptLimit = 24_000
        let excerpt = p.transcript.count > excerptLimit
            ? String(p.transcript.prefix(excerptLimit)) + "\n… (truncated; full transcript in the file above)"
            : p.transcript
        let context = """
        A call I was on just ended. Cue, my live call copilot, captured it. Do the post-call work your instructions describe: the meeting summary, the follow-ups, and anything that should be filed for the next call with these people.

        CALL: \(p.title)
        WHEN: \(when.string(from: p.startedAt)) → \(when.string(from: p.endedAt)) (\(minutes) min)
        TYPE: \(p.meetingType)
        PREP USED: \(p.prepDocs.isEmpty ? "(none)" : p.prepDocs.joined(separator: ", "))

        FILES ON MY MAC (read these with your local computer tool for the full detail):
        transcript: \(p.transcriptPath ?? "(not saved)")
        wrap: \(p.wrapPath ?? "(not written)")

        CUE'S FIRST-PASS SUMMARY:
        \(p.summary.isEmpty ? "(none)" : p.summary)

        COMMITMENTS, DECISIONS, OPEN QUESTIONS CUE HEARD:
        \(p.commitments.isEmpty ? "(none)" : p.commitments.map { "- " + $0 }.joined(separator: "\n"))

        CUE'S FOLLOW-UP DRAFT (a starting point, not the final word):
        \(p.followUpDraft.isEmpty ? "(none)" : p.followUpDraft)

        TRANSCRIPT (Me = me, Them = everyone else on the call):
        \(excerpt)
        """
        return try await fire(config, body: [
            "context": context,
            "source": "cue",
            "topic": p.title,
            "transcript_path": p.transcriptPath ?? "",
            "wrap_path": p.wrapPath ?? "",
            "started_at": ISO8601DateFormatter().string(from: p.startedAt),
            "ended_at": ISO8601DateFormatter().string(from: p.endedAt),
        ])
    }

    private static func fire(_ config: Config, body: [String: Any]) async throws -> Response {
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        guard (200..<300).contains(status), let decoded, decoded.success else {
            let detail = decoded?.error ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw HookError.rejected(status: status, detail: detail)
        }
        return decoded
    }

    enum HookError: LocalizedError {
        case notConfigured
        case rejected(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Set the Grok Bot webhook URL and key in .env (GROK_BOT_HOOK_* for briefs, GROK_BOT_SUM_* for wraps)."
            case let .rejected(status, detail):
                return "Grok Bot webhook returned \(status)\(detail.isEmpty ? "" : ": \(detail)")"
            }
        }
    }
}

/// Watches `PrepStore.inbox` and reports when new files land, so a brief the
/// bot writes gets attached the moment it arrives rather than at Listen.
final class PrepInboxWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        PrepStore.prepare()
        fd = open(PrepStore.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleSweep() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    /// Writers may land a file in several chunks; wait for quiet before reading.
    private func scheduleSweep() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
}
