import AppKit
import Foundation
import SwiftUI
import Combine
import AVFoundation

@available(macOS 14.2, *)
@MainActor
final class AppModel: ObservableObject {
    enum Phase: String {
        case idle
        case listening
        case paused
        case error
    }

    @Published var phase: Phase = .idle
    @Published var statusLine = "Idle"
    @Published var level: Float = 0
    @Published var livePartial = ""
    @Published var transcript: [TranscriptLine] = []
    @Published var cues: [AnswerCard] = []
    @Published var coaching: [CoachingNote] = []
    @Published var commitments: [CallCommitment] = []
    @Published var sessions: [SessionRecord] = []
    @Published var selectedSession: SessionRecord?
    @Published var selectedSessionBody = ""
    @Published var selectedSessionWrap: String?
    @Published var latestWrap: CallWrap?
    @Published var showWrapSheet = false
    @Published var wrapInFlight = false

    // Call boundaries. Another app holding the mic is the strongest signal we
    // have for "on a call" without touching the meeting apps themselves.
    enum CallHint: Equatable {
        case callStarted(app: String)
        case callEnding(reason: String, stopAt: Date)
        case callMaybeOver(reason: String)
    }
    @Published private(set) var callHint: CallHint?
    @Published var autoStartOnCallStart = true
    @Published var autoStopOnCallEnd = true
    @Published var sendWrapToGrokBot = true
    enum WrapSendState: Equatable {
        case idle, sending, sent, failed(String)
    }
    @Published private(set) var wrapSend: WrapSendState = .idle
    let presence = CallPresence()
    private var presenceSink: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var boundaryTimer: Timer?
    private var endCountdown: Task<Void, Never>?
    private var sessionStartedAt: Date?
    private var lastLineAt = Date()
    private var callAppSeenThisSession = false
    private var lastCallApp: String?
    private var micReleasedAt: Date?
    private var dismissedStartHintFor: String?
    private var callSchedule: PrepStore.Schedule?
    private var lastWrapPayload: GrokBotHook.WrapPayload?
    private var dayCalendarAskedAt: Date?
    /// The calendar slot Cue last listened to or was told to skip; auto-start leaves it alone.
    private var handledMeeting: PrepStore.Schedule?
    private static let isReplayLaunch = !(ProcessInfo.processInfo.environment["CUE_REPLAY_FILE"] ?? "").isEmpty
    private static let micReleaseGrace: TimeInterval = 15
    private static let autoStopCountdown: TimeInterval = 30
    /// A shorter drop than this is the app hiccupping, not leaving the meeting.
    private static let minHopGap: TimeInterval = 5
    @Published var contextNotes = ""
    @Published var apiKeyField = ""
    @Published var coachingEnabled = true
    @Published var sourceSearchEnabled = true
    @Published var sourceRoot = ""
    /// Extra markdown folders Cue should search (one path per line). Use this
    /// to pull in Grok Bot exports or any other local docs dump.
    @Published var extraSourceRoots = ""
    @Published var saveTranscripts = true
    @Published var meetingType: MeetingType = .technical
    @Published var askDraft = ""
    @Published var errorMessage: String?
    @Published var lastQuestion: String?
    @Published private(set) var prepDocs: [PrepStore.Doc] = []
    @Published private(set) var briefRequestInFlight = false
    @Published private(set) var briefPending: String?
    private var inboxWatcher: PrepInboxWatcher?

    private let keychain = KeychainStore(service: "com.davidgeorgehope.cue")
    private let capture = DualCapture()
    private let sttCustomer = GrokSTTClient()
    private let sttMe = GrokSTTClient()
    private let answers = AnswerEngine()
    private let analyst = ConversationAnalyst()
    private let wrapEngine = CallWrapEngine()
    private var recentWindow = ""
    private var transcriptStore: TranscriptStore?
    /// Rolling analysis: debounce so a sentence split across STT chunks is
    /// judged whole; if lines land mid-pass, run again when it finishes.
    private var analysisDebounce: Task<Void, Never>?
    @Published private(set) var analysisInFlight = false
    @Published private(set) var draftsInFlight = 0
    private var analysisPending = false
    private var lookedUp = Set<String>()
    private var lastAnalyzedLineID: UUID?
    // Cadence. A 1.2s pause is a breath, not a turn; 3s is where the other
    // side has usually finished a thought. The hard cadence keeps continuous
    // talk covered, the floor stops back-to-back passes over a few words.
    private static let analysisDebounceSeconds: Double = 3.0
    private static let analysisMaxIntervalSeconds: Double = 15
    private static let analysisMinGapSeconds: Double = 6
    private static let analysisMinNewWords = 12
    private var lastAnalysisStartedAt = Date.distantPast
    /// Grok STT often revises one growing string per socket; we only ingest the
    /// suffix since the last commit so the transcript does not repeat itself.
    private var sttCommittedPrefix: [AudioSource: String] = [:]

    init() {
        if let envNotes = ProcessInfo.processInfo.environment["CUE_CONTEXT"], !envNotes.isEmpty {
            contextNotes = envNotes
        } else {
            contextNotes = UserDefaults.standard.string(forKey: "cue.context") ?? ""
        }
        coachingEnabled = UserDefaults.standard.object(forKey: "cue.coaching") as? Bool ?? true
        sourceSearchEnabled = UserDefaults.standard.object(forKey: "cue.sourceSearch") as? Bool ?? true
        sourceRoot = UserDefaults.standard.string(forKey: "cue.sourceRoot") ?? ""
        extraSourceRoots = UserDefaults.standard.string(forKey: "cue.extraSourceRoots") ?? ""
        saveTranscripts = UserDefaults.standard.object(forKey: "cue.saveTranscripts") as? Bool ?? true
        autoStartOnCallStart = UserDefaults.standard.object(forKey: "cue.autoStartListen") as? Bool ?? true
        autoStopOnCallEnd = UserDefaults.standard.object(forKey: "cue.autoStop") as? Bool ?? true
        sendWrapToGrokBot = UserDefaults.standard.object(forKey: "cue.sendWrap") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "cue.meetingType"),
           let stored = MeetingType(rawValue: raw) {
            meetingType = stored
        }
        CueKnowledge.prepare()
        PrepStore.prepare()
        prepDocs = PrepStore.currentDocs()
        let watcher = PrepInboxWatcher { [weak self] in self?.sweepPrepInbox() }
        watcher.start()
        inboxWatcher = watcher
        if let file = ProcessInfo.processInfo.environment["CUE_REPLAY_FILE"], !file.isEmpty {
            let speed = Double(ProcessInfo.processInfo.environment["CUE_REPLAY_SPEED"] ?? "") ?? 3
            let type = MeetingType(rawValue: ProcessInfo.processInfo.environment["CUE_REPLAY_TYPE"] ?? "")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let type { self?.setMeetingType(type) }
                self?.startReplay(file: URL(fileURLWithPath: (file as NSString).expandingTildeInPath), speed: speed)
            }
        }
        // A slow bot may deliver while Cue is closed; pick that up on launch.
        sweepPrepInbox()
        presence.start()
        presenceSink = presence.$activeApp
            .removeDuplicates()
            .sink { [weak self] app in self?.presenceChanged(app) }
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCallBoundary() }
        }
        refreshDayCalendarIfStale()
        // Cue stays running overnight; waking is when the new day's calendar should be fetched.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDayCalendarIfStale() }
        }
        wireSTT()
        refreshSessions()
        Task { @MainActor [weak self] in
            self?.loadKey()
            if ProcessInfo.processInfo.environment["CUE_AUTOSTART"] == "1" {
                FileHandle.standardError.write(Data("cue: autostart requested hasKey=\(self?.hasKey ?? false)\n".utf8))
                self?.start()
            }
        }
    }

    func refreshSessions() {
        sessions = SessionLibrary.list()
    }

    func openSession(_ session: SessionRecord) {
        selectedSession = session
        selectedSessionBody = SessionLibrary.readTranscript(session)
        selectedSessionWrap = SessionLibrary.readWrap(session)
    }

    func dismissSession() {
        selectedSession = nil
        selectedSessionBody = ""
        selectedSessionWrap = nil
    }

    /// The Settings field only ever shows the explicit Keychain override, so
    /// an empty field means "using `.env`" and Save can't accidentally pin
    /// the `.env` key into Keychain.
    func loadKey() {
        if let stored = keychain.read(account: "xai"), !stored.isEmpty {
            apiKeyField = stored
        }
    }

    /// Resolution: Settings/Keychain override → process env → `.env` file.
    var resolvedAPIKey: String {
        let override = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], !env.isEmpty {
            return env
        }
        return DotEnv.value(for: "XAI_API_KEY") ?? ""
    }

    var hasKey: Bool { !resolvedAPIKey.isEmpty }

    /// - Parameter persistAPIKey: When true (Settings Save), write/clear Keychain
    ///   override. When false (`start()`), leave Keychain alone so `.env` stays
    ///   the default source.
    func saveSettings(persistAPIKey: Bool = true) {
        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if persistAPIKey {
            if trimmed.isEmpty {
                // Clear override so next load falls back to process env / `.env`.
                keychain.delete(account: "xai")
            } else {
                keychain.write(account: "xai", value: trimmed)
            }
        }
        UserDefaults.standard.set(contextNotes, forKey: "cue.context")
        UserDefaults.standard.set(coachingEnabled, forKey: "cue.coaching")
        UserDefaults.standard.set(sourceSearchEnabled, forKey: "cue.sourceSearch")
        UserDefaults.standard.set(sourceRoot, forKey: "cue.sourceRoot")
        UserDefaults.standard.set(extraSourceRoots, forKey: "cue.extraSourceRoots")
        UserDefaults.standard.set(saveTranscripts, forKey: "cue.saveTranscripts")
        UserDefaults.standard.set(autoStartOnCallStart, forKey: "cue.autoStartListen")
        UserDefaults.standard.set(autoStopOnCallEnd, forKey: "cue.autoStop")
        UserDefaults.standard.set(sendWrapToGrokBot, forKey: "cue.sendWrap")
        UserDefaults.standard.set(meetingType.rawValue, forKey: "cue.meetingType")
    }

    func setMeetingType(_ type: MeetingType) {
        meetingType = type
        UserDefaults.standard.set(type.rawValue, forKey: "cue.meetingType")
    }

    /// Clear the previous call's cards, notes, and transcript without starting
    /// capture — for tidying the board between calls, or before a Listen you
    /// want to start from a clean screen.
    func newCall() {
        guard phase != .listening else { return }
        livePartial = ""
        transcript = []
        recentWindow = ""
        cues = []
        coaching = []
        commitments = []
        lastQuestion = nil
        latestWrap = nil
        showWrapSheet = false
        errorMessage = nil
        transcriptStore = nil
        resetAnalysis()
        lookedUp.removeAll()
        sweepPrepInbox()
        statusLine = prepDocs.isEmpty
            ? "New call — add prep or just Listen"
            : "New call — \(prepDocs.count) prep doc\(prepDocs.count == 1 ? "" : "s") attached, ready to Listen"
    }

    var hasCallContent: Bool {
        !cues.isEmpty || !coaching.isEmpty || !commitments.isEmpty || !transcript.isEmpty
    }

    func toggleListen() {
        switch phase {
        case .listening:
            stop()
        default:
            start()
        }
    }

    func menuToggleListen() {
        FileHandle.standardError.write(Data("cue: menuToggleListen phase=\(phase.rawValue) hasKey=\(hasKey)\n".utf8))
        toggleListen()
    }

    func start() {
        saveSettings(persistAPIKey: false)
        guard hasKey else {
            errorMessage = "Add an xAI API key in Settings or set XAI_API_KEY in .env."
            phase = .error
            return
        }
        errorMessage = nil
        livePartial = ""
        sttCommittedPrefix.removeAll()
        transcript = []
        recentWindow = ""
        cues = []
        coaching = []
        commitments = []
        lastQuestion = nil
        resetAnalysis()
        latestWrap = nil
        showWrapSheet = false
        sweepPrepInbox()
        if saveTranscripts {
            transcriptStore = TranscriptStore()
        }
        lookedUp.removeAll()
        lastAnalysisStartedAt = Date()
        sessionStartedAt = Date()
        lastLineAt = Date()
        callSchedule = PrepStore.currentSchedule()
        refreshDayCalendarIfStale()
        autoRequestBrief()
        lastCallApp = presence.activeApp
        callAppSeenThisSession = presence.activeApp != nil
        micReleasedAt = nil
        endCountdown?.cancel()
        callHint = nil
        wrapSend = .idle
        phase = .listening
        statusLine = "Connecting Grok Voice STT…"
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        capture.onPCM16 = { [weak self] source, data in
            switch source {
            case .system: self?.sttCustomer.sendPCM16(data)
            case .mic: self?.sttMe.sendPCM16(data)
            }
        }
        capture.onMicTrouble = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.phase == .listening else { return }
                self.errorMessage = message
            }
        }
        FileHandle.standardError.write(Data("cue: start() connecting STT\n".utf8))
        let key = resolvedAPIKey
        sttCustomer.start(apiKey: key, keyterms: keyterms(from: contextNotes))
        // In mic-only test mode the mic feeds the customer stream instead.
        if ProcessInfo.processInfo.environment["CUE_MIC_ONLY"] != "1" {
            sttMe.start(apiKey: key, keyterms: keyterms(from: contextNotes))
        }
        Task.detached { [weak self] in
            await self?.beginCapture()
        }
    }

    private func beginCapture() async {
        let granted = await requestMicIfNeeded()
        if !granted {
            await MainActor.run {
                stopSTT()
                phase = .error
                errorMessage = CaptureError.micPermission.localizedDescription
                statusLine = "Capture failed"
            }
            return
        }
        do {
            FileHandle.standardError.write(Data("cue: starting capture off-main\n".utf8))
            try capture.start()
            FileHandle.standardError.write(Data("cue: capture started\n".utf8))
        } catch {
            await MainActor.run {
                // The tap may already be running when the mic fails to start.
                capture.stop()
                stopSTT()
                phase = .error
                errorMessage = error.localizedDescription
                statusLine = "Capture failed"
            }
        }
    }

    private func stopSTT() {
        sttCustomer.stop()
        sttMe.stop()
    }

    private func requestMicIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Files the model claims it used, restricted to real retrieval hits so a
    /// hallucinated path can never show up in the grounding badge.
    nonisolated static func usedFiles(_ claimed: [String], from hits: [String]) -> [String] {
        var out: [String] = []
        for claim in claimed {
            if let hit = hits.first(where: { $0 == claim || $0.hasSuffix(claim) || claim.hasSuffix($0) }), !out.contains(hit) {
                out.append(hit)
            }
        }
        return out
    }

    // MARK: - Replay (test harness)

    /// Feed a saved Me/Them transcript through the live pipeline with its
    /// original timing scaled by `speed`. No audio, no STT; everything from
    /// ingest() onward — dedupe, analyst, cards, lookups, coaching — runs for
    /// real, so what appears on screen is what the call would have produced.
    /// Writes a report next to the transcript when it finishes.
    private var replayTask: Task<Void, Never>?
    private var replayStartedAt: Date?
    private var replaySpeed: Double = 1
    private var replayLineCount = 0

    struct ReplayLine {
        let offset: TimeInterval
        let speaker: Speaker
        let text: String
    }

    static func parseReplay(_ text: String) -> [ReplayLine] {
        // Session format: "- **Them** (HH:MM:SS): text" or "(MM:SS)".
        let pattern = try! NSRegularExpression(pattern: #"^- \*\*(Me|Them)\*\* \(([\d:]+)\):\s*(.*)$"#)
        var lines: [ReplayLine] = []
        var base: TimeInterval?
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard let m = pattern.firstMatch(in: line, range: range),
                  let sr = Range(m.range(at: 1), in: line), let tr = Range(m.range(at: 2), in: line),
                  let xr = Range(m.range(at: 3), in: line) else { continue }
            let parts = line[tr].split(separator: ":").compactMap { Double($0) }
            let secs = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
            if base == nil { base = secs }
            let content = line[xr].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            lines.append(.init(offset: secs - (base ?? 0), speaker: line[sr] == "Me" ? .me : .them, text: content))
        }
        return lines
    }

    func startReplay(file: URL, speed: Double) {
        guard phase != .listening else { return }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            errorMessage = "Replay: cannot read \(file.path)"
            return
        }
        let lines = Self.parseReplay(text)
        guard !lines.isEmpty else {
            errorMessage = "Replay: no Me/Them lines in \(file.lastPathComponent)"
            return
        }
        guard hasKey else {
            errorMessage = "Add an xAI API key in Settings or set XAI_API_KEY in .env."
            return
        }
        saveSettings(persistAPIKey: false)
        errorMessage = nil
        livePartial = ""
        transcript = []
        recentWindow = ""
        cues = []
        coaching = []
        commitments = []
        lastQuestion = nil
        resetAnalysis()
        latestWrap = nil
        showWrapSheet = false
        sweepPrepInbox()
        if saveTranscripts { transcriptStore = TranscriptStore() }
        lookedUp.removeAll()
        lastAnalysisStartedAt = Date()
        replaySpeed = max(speed, 0.1)
        replayStartedAt = Date()
        replayLineCount = lines.count
        phase = .listening
        statusLine = "Replaying \(file.lastPathComponent) at \(String(format: "%.0f", replaySpeed))x — \(lines.count) lines"
        Self.answerLog("replay START \(file.lastPathComponent) speed=\(replaySpeed) lines=\(lines.count)")

        replayTask = Task { [weak self] in
            guard let self else { return }
            let t0 = Date()
            for (i, line) in lines.enumerated() {
                let due = t0.addingTimeInterval(line.offset / self.replaySpeed)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                self.livePartial = ""
                self.ingest(line.text, from: line.speaker, at: Date())
                if i % 20 == 0 {
                    self.statusLine = "Replay \(i + 1)/\(lines.count) · \(Self.clock(line.offset))"
                }
            }
            // Let the last analysis, drafts, and lookups land before reporting.
            self.statusLine = "Replay finished — waiting for in-flight passes…"
            try? await Task.sleep(for: .seconds(45))
            if Task.isCancelled { return }
            self.writeReplayReport(for: file, lines: lines)
            self.stop()
        }
    }

    private static func clock(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Call-time offset for a wall-clock moment during the replay.
    private func callTime(_ date: Date) -> String {
        guard let start = replayStartedAt else { return "--:--" }
        return Self.clock(date.timeIntervalSince(start) * replaySpeed)
    }

    private func writeReplayReport(for file: URL, lines: [ReplayLine]) {
        var out = "# Cue replay — \(file.lastPathComponent)\n\n"
        out += "speed \(replaySpeed)x · meeting type \(meetingType.title) · \(lines.count) lines · "
        out += "\(cues.count) cards · \(coaching.count) coaching · \(commitments.count) tracked\n\n"
        out += "Knowledge roots:\n" + resolvedKnowledgeRoots().map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        out += "## Cards (in order of appearance)\n\n"
        for card in cues.reversed() {
            let kind: String
            switch card.origin {
            case .lookup: kind = "CONTEXT"
            case .userAsk: kind = "YOU ASKED"
            case .remoteQuestion: kind = "THEY ASKED"
            }
            let docs = card.sourceFiles.filter { $0 != "live-dialogue" }
            out += "### \(callTime(card.at)) · \(kind) · \(card.question)\n\n"
            out += card.displayAnswer + "\n\n"
            out += docs.isEmpty ? "_grounding: transcript only_ (\(card.sourceState))\n\n"
                : "_grounding: \(docs.joined(separator: ", "))_\n\n"
        }
        if !coaching.isEmpty {
            out += "## Coaching\n\n"
            for note in coaching.reversed() {
                out += "- \(callTime(note.at)) **\(note.kind.rawValue)** \(note.content)"
                if let s = note.suggestion, !s.isEmpty { out += " — _\(s)_" }
                out += "\n"
            }
            out += "\n"
        }
        if !commitments.isEmpty {
            out += "## Tracked\n\n"
            for item in commitments.reversed() {
                out += "- **\(item.kind.rawValue)** (\(item.speaker)) \(item.text)\n"
            }
            out += "\n"
        }
        let dest = file.deletingPathExtension().appendingPathExtension("report.md")
        try? out.write(to: dest, atomically: true, encoding: .utf8)
        Self.answerLog("replay REPORT \(dest.path)")
        statusLine = "Replay report: \(dest.lastPathComponent)"
    }

    func stop() {
        let wasReplay = replayTask != nil
        let startedAt = sessionStartedAt ?? Date()
        let endedAt = Date()
        let fullTranscript = transcript.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        let schedule = sessionMeeting()
        let prepNames = prepDocs.map(\.name)
        if !wasReplay, let schedule { handledMeeting = schedule }
        endCountdown?.cancel()
        endCountdown = nil
        callHint = nil
        replayTask?.cancel()
        replayTask = nil
        replayStartedAt = nil
        capture.stop()
        stopSTT()
        phase = .idle
        livePartial = ""
        level = 0
        sttCommittedPrefix.removeAll()
        resetAnalysis()

        let dialogue = recentWindow
        let captured = commitments
        let notes = contextNotes
        let prep = prepText
        let key = resolvedAPIKey
        let storeURL = transcriptStore?.fileURL
        let storeName = storeURL?.lastPathComponent
        PrepStore.archive(forSession: storeURL)
        prepDocs = PrepStore.currentDocs()

        if let store = transcriptStore {
            store.close()
            statusLine = "Saved: \(store.fileURL.lastPathComponent)"
        } else {
            statusLine = "Idle"
        }
        transcriptStore = nil
        refreshSessions()

        guard let storeURL, !dialogue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasKey else {
            return
        }
        wrapInFlight = true
        statusLine = "Writing call wrap…"
        Task {
            defer { wrapInFlight = false }
            let title = storeName ?? "call"
            var wrap: CallWrap?
            do {
                wrap = try await wrapEngine.wrap(
                    dialogue: dialogue,
                    commitments: captured,
                    notes: notes,
                    prep: prep,
                    meetingType: meetingType,
                    apiKey: key
                )
            } catch {
                statusLine = "Wrap failed: \(error.localizedDescription)"
                Self.answerLog("wrap failed: \(error.localizedDescription)")
            }
            if let wrap {
                CallWrapEngine.write(wrap, beside: storeURL, title: title)
                // After a split the next call is already live; don't cover it with a sheet.
                if phase != .listening {
                    latestWrap = wrap
                    showWrapSheet = true
                }
                refreshSessions()
                statusLine = "Wrap ready · \(storeURL.lastPathComponent)"
            }
            // Grok Bot writes its own summary from the transcript file, so a
            // failed first-pass wrap must not cost the hand-off.
            lastWrapPayload = GrokBotHook.WrapPayload(
                title: schedule?.title ?? prepNames.first ?? title,
                startedAt: startedAt,
                endedAt: endedAt,
                meetingType: meetingType.title,
                summary: wrap?.summary ?? "",
                followUpDraft: wrap?.followUpDraft ?? "",
                commitments: captured.map { "[\($0.kind.rawValue)] \($0.speaker): \($0.text)" },
                prepDocs: prepNames,
                transcriptPath: storeURL.path,
                wrapPath: wrap == nil ? nil : storeURL.deletingPathExtension().appendingPathExtension("wrap.md").path,
                transcript: fullTranscript
            )
            // Real calls only: a 30-second mic test shouldn't wake the bot.
            let words = fullTranscript.split(separator: " ").count
            if sendWrapToGrokBot, GrokBotHook.isWrapConfigured, !wasReplay, words >= 120 {
                sendWrapToBot()
            } else if !wasReplay {
                Self.answerLog("wrap hand-off skipped: enabled=\(sendWrapToGrokBot) configured=\(GrokBotHook.isWrapConfigured) words=\(words)")
            }
        }
    }

    // MARK: - Call boundaries & post-call hand-off

    var grokBotWrapConfigured: Bool { GrokBotHook.isWrapConfigured }
    var canSendWrap: Bool { lastWrapPayload != nil && GrokBotHook.isWrapConfigured }

    func sendWrapToBot() {
        guard let payload = lastWrapPayload, wrapSend != .sending else { return }
        wrapSend = .sending
        Task {
            do {
                let response = try await GrokBotHook.sendWrap(payload)
                wrapSend = .sent
                statusLine = "Grok Bot has the call — summary and follow-ups on the way"
                Self.answerLog("wrap hand-off sent run=\(response.runUuid ?? "?") title=\(payload.title)")
            } catch {
                wrapSend = .failed(error.localizedDescription)
                statusLine = "Grok Bot hand-off failed: \(error.localizedDescription)"
                Self.answerLog("wrap hand-off failed: \(error.localizedDescription)")
            }
        }
    }

    private func presenceChanged(_ app: String?) {
        Self.answerLog("presence app=\(app ?? "none") phase=\(phase.rawValue)")
        if phase == .listening {
            if let app {
                let hopped = micReleasedAt.map { Date().timeIntervalSince($0) >= Self.minHopGap } ?? false
                lastCallApp = app
                callAppSeenThisSession = true
                micReleasedAt = nil
                if hopped, replayTask == nil, let meeting = sessionMeeting(),
                   DayCalendar.isNextCall(at: Date(), after: meeting, in: DayCalendar.meetings()) {
                    splitForNextCall(app: app, after: meeting)
                    return
                }
                // They rejoined (or the app hiccupped): stand down without
                // disarming the mic rule, so the real end of this call still stops it.
                if case .callEnding = callHint { cancelEndCountdown() }
            } else if callAppSeenThisSession, micReleasedAt == nil {
                micReleasedAt = Date()
            }
            return
        }
        if let app {
            refreshDayCalendarIfStale()
            if app != dismissedStartHintFor, replayTask == nil {
                callHint = .callStarted(app: app)
            }
        } else {
            dismissedStartHintFor = nil
            if case .callStarted = callHint { callHint = nil }
        }
    }

    private func checkCallBoundary() {
        guard replayTask == nil else { return }
        guard phase == .listening else {
            autoStartIfScheduled()
            return
        }
        if case .callEnding = callHint { return }
        let now = Date()
        let quietFor = now.timeIntervalSince(lastLineAt)

        if let released = micReleasedAt, now.timeIntervalSince(released) >= Self.micReleaseGrace {
            beginEndCountdown(reason: "\(lastCallApp ?? "The meeting app") let go of the mic")
            return
        }
        let meeting = sessionMeeting()
        if let meeting, now > meeting.end.addingTimeInterval(60), quietFor >= 90 {
            beginEndCountdown(reason: "Past the scheduled end and nobody has spoken for 90s")
            return
        }
        // No app signal, no schedule: only suggest — a long pause is not proof.
        if !callAppSeenThisSession, meeting == nil, !transcript.isEmpty, quietFor >= 300,
           callHint == nil {
            callHint = .callMaybeOver(reason: "Nothing heard for 5 minutes")
        }
    }

    /// The meeting this session is for: today's calendar entry when Listen
    /// started, else the window the attached brief states.
    private func sessionMeeting() -> PrepStore.Schedule? {
        DayCalendar.meeting(at: sessionStartedAt ?? Date(), in: DayCalendar.meetings()) ?? callSchedule
    }

    /// Back-to-back calls: close this one the way Stop does (transcript, wrap,
    /// Grok Bot hand-off) and start the next without waiting for a countdown.
    private func splitForNextCall(app: String, after meeting: PrepStore.Schedule) {
        Self.answerLog("call split: \(app) took the mic back after \(meeting.title)")
        stop()
        start()
        // This runs inside the presence publisher's willSet, where
        // `presence.activeApp` still reads nil, so start() left the mic rule disarmed.
        lastCallApp = app
        callAppSeenThisSession = true
    }

    /// Starts Listen when a meeting app holds the mic during a calendar meeting
    /// Cue hasn't handled; calls that aren't on the calendar only get the banner.
    private func autoStartIfScheduled() {
        guard autoStartOnCallStart, phase == .idle, !Self.isReplayLaunch,
              let app = presence.activeApp,
              let meeting = DayCalendar.autoStartMeeting(at: Date(), in: DayCalendar.meetings(), skipping: handledMeeting)
        else { return }
        Self.answerLog("auto-start: \(app) has the mic during \(meeting.title)")
        start()
    }

    private func beginEndCountdown(reason: String) {
        guard autoStopOnCallEnd else {
            callHint = .callMaybeOver(reason: reason)
            return
        }
        let stopAt = Date().addingTimeInterval(Self.autoStopCountdown)
        Self.answerLog("call-end countdown: \(reason)")
        callHint = .callEnding(reason: reason, stopAt: stopAt)
        endCountdown?.cancel()
        endCountdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoStopCountdown))
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            Self.answerLog("call-end auto-stop")
            self.stop()
        }
    }

    /// User overrode an end-of-call hint: cancel the countdown. If the meeting
    /// app has let go, the mic rule re-arms when it picks the mic up again.
    func keepListening() {
        cancelEndCountdown()
        callAppSeenThisSession = presence.activeApp != nil
        lastLineAt = Date()
    }

    private func cancelEndCountdown() {
        endCountdown?.cancel()
        endCountdown = nil
        callHint = nil
        micReleasedAt = nil
    }

    func dismissCallHint() {
        if case .callStarted(let app) = callHint {
            dismissedStartHintFor = app
            // Not now also keeps auto-start off the meeting that's on.
            if let meeting = DayCalendar.meeting(at: Date(), in: DayCalendar.meetings()) { handledMeeting = meeting }
        }
        callHint = nil
    }

    // MARK: - Prep docs

    /// Attached prep, capped for prompts; read fresh so drops mid-call count.
    var prepText: String { PrepStore.currentText(limit: 8_000) }

    func attachPrep(_ urls: [URL]) {
        var added = 0
        for url in urls where PrepStore.attach(url) != nil { added += 1 }
        prepDocs = PrepStore.currentDocs()
        statusLine = added == urls.count
            ? "Attached \(added) prep doc\(added == 1 ? "" : "s")"
            : "Attached \(added) of \(urls.count) — some files had no readable text"
    }

    func removePrep(_ doc: PrepStore.Doc) {
        PrepStore.remove(doc)
        prepDocs = PrepStore.currentDocs()
    }

    /// Inbox watcher callback and Listen both land here.
    private func sweepPrepInbox() {
        let swept = PrepStore.sweepInbox()
        guard !swept.isEmpty else { return }
        prepDocs = PrepStore.currentDocs()
        briefPending = nil
        // The Listen-time brief lands mid-call; its meeting times are the fallback schedule.
        if phase == .listening { callSchedule = PrepStore.currentSchedule() }
        statusLine = swept.count == 1
            ? "Prep arrived: \(swept[0].name)"
            : "Attached \(swept.count) prep docs from inbox"
    }

    var grokBotHookConfigured: Bool { GrokBotHook.isConfigured }
    var grokBotCalendarConfigured: Bool { GrokBotHook.isCalendarConfigured }

    /// One line for the menu bar: what Cue is doing, or the next meeting on today's calendar.
    var menuBarStatus: String {
        switch phase {
        case .listening:
            return "Listening — \(sessionMeeting()?.title ?? "untitled call")"
        case .error:
            return "Stopped — open Cue to see why"
        case .idle, .paused:
            guard let next = DayCalendar.meetings().first(where: { $0.start > Date() }) else { return "Idle" }
            return "Idle · next: \(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)"
        }
    }

    func clearBriefPending() { briefPending = nil }

    /// Ask the Grok Bot automation for a pre-call brief. The bot writes it to
    /// the prep inbox; the watcher attaches it when it lands — mid-call is fine,
    /// every pass re-reads prep from disk. `quiet` is the Listen-time fire:
    /// no status noise, failures swallowed.
    func requestBrief(topic: String, quiet: Bool = false) {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !briefRequestInFlight else { return }
        briefRequestInFlight = true
        if !quiet { statusLine = "Asking Grok Bot for a brief…" }
        Task {
            defer { briefRequestInFlight = false }
            do {
                _ = try await GrokBotHook.requestBrief(topic: topic)
                briefPending = topic.isEmpty ? "next meeting" : topic
                Self.answerLog("brief requested (quiet=\(quiet)) topic=\(briefPending ?? "")")
                if !quiet { statusLine = "Grok Bot is preparing a brief — it lands in PREP when ready" }
            } catch {
                Self.answerLog("brief request failed (quiet=\(quiet)): \(error.localizedDescription)")
                if !quiet { statusLine = "Brief request failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Listen always asks the bot for a brief on the meeting the calendar says
    /// this is, unless that one is already on its way or a brief landed
    /// recently — asking twice just yields the same doc twice.
    private func autoRequestBrief() {
        guard GrokBotHook.isConfigured else { return }
        let topic = DayCalendar.meeting(at: Date(), in: DayCalendar.meetings()).map(Self.briefTopic) ?? ""
        guard briefPending != (topic.isEmpty ? "next meeting" : topic) else { return }
        let recent = PrepStore.currentDocs().contains { doc in
            let modified = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { Date().timeIntervalSince($0) < 30 * 60 } ?? false
        }
        guard !recent else { return }
        requestBrief(topic: topic, quiet: true)
    }

    private static func briefTopic(_ meeting: PrepStore.Schedule) -> String {
        let start = meeting.start.formatted(date: .abbreviated, time: .shortened)
        let end = meeting.end.formatted(date: .omitted, time: .shortened)
        return "\(meeting.title), \(start)–\(end)"
    }

    /// Asked at launch, at Listen, and when a meeting app takes the mic. The
    /// bot takes minutes and nothing waits on it: boundaries read the file fresh.
    private func refreshDayCalendarIfStale() {
        guard GrokBotHook.isCalendarConfigured, !Self.isReplayLaunch, DayCalendar.isStale() else { return }
        if let asked = dayCalendarAskedAt, Date().timeIntervalSince(asked) < 20 * 60 { return }
        dayCalendarAskedAt = Date()
        Task {
            do {
                let response = try await GrokBotHook.requestDay()
                Self.answerLog("calendar requested run=\(response.runUuid ?? "?")")
            } catch {
                Self.answerLog("calendar request failed: \(error.localizedDescription)")
            }
        }
    }

    func dismiss(_ card: AnswerCard) {
        cues.removeAll { $0.id == card.id }
    }

    /// Manual Ask Cue path. Same card pipeline as remote questions, but never
    /// SKIP-as-non-customer and tagged `.userAsk`.
    func ask(_ text: String? = nil) {
        let question = (text ?? askDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard hasKey else {
            errorMessage = "Add an xAI API key in Settings or set XAI_API_KEY in .env."
            return
        }
        // No transcript is fine: prep, notes, and the knowledge roots still
        // ground the answer. Ask is also a pre-call lookup tool.
        var context = askContext()
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context = "(not on a call — answer from prep, notes, and docs)"
        }
        askDraft = ""
        lastQuestion = question
        statusLine = "Ask Cue — drafting…"
        Task { await draftAnswer(for: question, origin: .userAsk, transcript: context) }
    }

    private func askContext() -> String {
        let budget = meetingType.transcriptCharBudget
        let recent = recentWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recent.isEmpty { return String(recent.suffix(budget)) }
        if let url = transcriptStore?.fileURL,
           let disk = try? String(contentsOf: url, encoding: .utf8) {
            let body = disk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return String(body.suffix(budget)) }
        }
        let session = selectedSessionBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !session.isEmpty { return String(session.suffix(budget)) }
        let joined = transcript
            .suffix(80)
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        return String(joined.suffix(budget))
    }

    private func wireSTT() {
        wire(sttCustomer, source: .system, drivesStatus: true)
        wire(sttMe, source: .mic, drivesStatus: false)
    }

    private func wire(_ stt: GrokSTTClient, source: AudioSource, drivesStatus: Bool) {
        stt.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                FileHandle.standardError.write(Data("cue: partial [\(source.rawValue)] \(text)\n".utf8))
                self.livePartial = "\(Speaker(source).rawValue): \(text)"
            }
        }
        stt.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let previous = self.sttCommittedPrefix[source] ?? ""
                let piece: String
                if !previous.isEmpty, trimmed.hasPrefix(previous) {
                    piece = String(trimmed.dropFirst(previous.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !previous.isEmpty, previous.hasPrefix(trimmed) {
                    // Shorter revision of the same buffer — wait for a longer form.
                    return
                } else {
                    piece = trimmed
                }
                self.sttCommittedPrefix[source] = trimmed
                guard !piece.isEmpty else { return }
                let speaker = Speaker(source)
                FileHandle.standardError.write(Data("cue: final [\(speaker.rawValue)] \(piece)\n".utf8))
                self.ingest(piece, from: speaker, at: Date())
            }
        }
        stt.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                if drivesStatus, self?.phase == .listening {
                    self?.statusLine = text
                }
            }
        }
        stt.onError = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.phase == .listening else { return }
                self.statusLine = "STT (\(source.rawValue)): \(text)"
            }
        }
    }

    private func ingest(_ raw: String, from speaker: Speaker, at date: Date) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.lowercased() != "(silence)" else { return }
        livePartial = ""

        // Text-level dedupe. Two sources of repeats:
        //  - echo: with AEC off the mic hears the speakers, so a remote sentence
        //    arrives again labelled Me (often in fragments). The late copy loses;
        //    if the late copy is the system tap, the earlier Me line was really
        //    Them — relabel it.
        //  - revisions: STT emits a growing sentence as several lines. Keep the
        //    longest under the first line's timestamp.
        if let idx = duplicateIndex(of: text, from: speaker, at: date) {
            let old = transcript[idx]
            let longer = old.text.count >= text.count ? old.text : text
            let label: Speaker = old.speaker == speaker ? speaker : (speaker == .them ? .them : old.speaker)
            if longer != old.text || label != old.speaker {
                transcript[idx] = TranscriptLine(speaker: label, text: longer, at: old.at)
                rebuildRecentWindow()
                // The session file is append-only; keep the fuller text on disk.
                if longer != old.text {
                    transcriptStore?.append(speaker: label.rawValue, text: longer, at: date)
                }
            }
            return
        }

        let line = TranscriptLine(speaker: speaker, text: text, at: date)
        transcript.append(line)
        lastLineAt = Date()
        if case .callMaybeOver = callHint { callHint = nil }
        if transcript.count > 80 { transcript.removeFirst(transcript.count - 80) }
        transcriptStore?.append(speaker: speaker.rawValue, text: text, at: line.at)

        recentWindow = (recentWindow + "\n\(speaker.rawValue): " + text)
            .split(separator: " ")
            .suffix(meetingType.recentWindowWordBudget)
            .joined(separator: " ")

        scheduleAnalysis()
    }

    /// Index of a recent line this text duplicates (same words, or one contained
    /// in the other), from either side, within the dedupe window.
    private func duplicateIndex(of text: String, from speaker: Speaker, at date: Date) -> Int? {
        let newTokens = Self.echoTokens(text)
        guard !newTokens.isEmpty else { return nil }
        // Wall-clock ingest dates compress under replay; keep the window in
        // call time so 3–4x does not collapse spaced acknowledgements.
        let window: TimeInterval = replayTask == nil ? 6 : 6 / replaySpeed
        for idx in transcript.indices.reversed() {
            let line = transcript[idx]
            if date.timeIntervalSince(line.at) > window { break }
            let oldTokens = Self.echoTokens(line.text)
            guard !oldTokens.isEmpty else { continue }
            let overlap = newTokens.intersection(oldTokens).count
            let smaller = min(newTokens.count, oldTokens.count)
            // Short fragments must be fully contained; longer lines need most words shared.
            let needed = smaller <= 3 ? smaller : Int((Double(smaller) * 0.75).rounded(.up))
            if overlap >= needed { return idx }
        }
        return nil
    }

    private static func echoTokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 })
    }

    private func rebuildRecentWindow() {
        recentWindow = transcript
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
            .split(separator: " ")
            .suffix(meetingType.recentWindowWordBudget)
            .joined(separator: " ")
    }

    private func resetAnalysis() {
        analysisDebounce?.cancel()
        analysisDebounce = nil
        analysisPending = false
        lastAnalyzedLineID = nil
    }

    private func scheduleAnalysis() {
        analysisDebounce?.cancel()
        // xAI said "at capacity": hold the cadence until the window passes
        // instead of adding to the pile. Lines keep accumulating meanwhile.
        if let until = GrokChat.saturatedUntil, until > Date() {
            let wait = until.timeIntervalSinceNow
            statusLine = "xAI at capacity — retrying in \(Int(wait.rounded(.up)))s"
            analysisDebounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait + 0.5))
                guard !Task.isCancelled else { return }
                Task { [weak self] in await self?.runAnalysis() }
            }
            return
        }
        // Continuous talk never yields a quiet gap, so also run on a cadence.
        let overdue = Date().timeIntervalSince(lastAnalysisStartedAt) >= Self.analysisMaxIntervalSeconds
        if overdue, !analysisInFlight {
            Task { [weak self] in await self?.runAnalysis() }
            return
        }
        analysisDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.analysisDebounceSeconds))
            guard !Task.isCancelled else { return }
            // Detach: the next line cancels this debounce task, and that
            // cancellation must not propagate into the in-flight analyst request.
            Task { [weak self] in await self?.runAnalysis() }
        }
    }

    /// Words added since the last pass; a direct question ("...?") counts as
    /// enough on its own so a short ask is never held back.
    private func newContentSinceLastPass() -> (words: Int, endsWithQuestion: Bool) {
        var words = 0
        var seen = lastAnalyzedLineID == nil
        for line in transcript {
            if seen { words += line.text.split(separator: " ").count }
            if !seen, line.id == lastAnalyzedLineID { seen = true }
        }
        if !seen { words = transcript.reduce(0) { $0 + $1.text.split(separator: " ").count } }
        let tail = transcript.last?.text.trimmingCharacters(in: .whitespaces) ?? ""
        return (words, tail.hasSuffix("?"))
    }

    private func runAnalysis() async {
        guard phase == .listening, hasKey, !transcript.isEmpty else { return }
        if analysisInFlight {
            analysisPending = true
            return
        }
        let fresh = newContentSinceLastPass()
        if fresh.words == 0 { return }
        let sinceLast = Date().timeIntervalSince(lastAnalysisStartedAt)
        let overdue = sinceLast >= Self.analysisMaxIntervalSeconds
        let enough = fresh.endsWithQuestion
            || (sinceLast >= Self.analysisMinGapSeconds && fresh.words >= Self.analysisMinNewWords)
            || (overdue && fresh.words >= 4)
        // Too soon or too little: wait for the next pause / cadence tick
        // rather than spending a pass on "Yeah." — unless it was a question.
        if !enough {
            analysisDebounce?.cancel()
            let wait = max(Self.analysisMinGapSeconds - sinceLast, Self.analysisDebounceSeconds)
            analysisDebounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                Task { [weak self] in await self?.runAnalysis() }
            }
            return
        }
        analysisInFlight = true
        lastAnalysisStartedAt = Date()
        defer { analysisInFlight = false }

        let dialogue = analysisDialogue()
        let lastID = transcript.last?.id
        let captured = cues.map { "Q: \($0.question)" }
            + coaching.map { "\($0.kind.rawValue): \($0.content)" }
            + commitments.map { "\($0.kind.rawValue): \($0.text)" }

        do {
            let result = try await analyst.analyze(
                dialogue: dialogue,
                notes: contextNotes,
                prep: prepText,
                alreadyCaptured: captured,
                meetingType: meetingType,
                apiKey: resolvedAPIKey
            )
            guard phase == .listening else { return }
            lastAnalyzedLineID = lastID
            Self.answerLog("analyst q=\(result.questions.count) open=\(result.questions.filter(\.open).count) lookups=\(result.lookups.count) coaching=\(result.coaching.count) tracked=\(result.commitments.count) lines=\(transcript.count)")
            apply(result)
        } catch {
            Self.answerLog("analyst FAIL \(error.localizedDescription)")
        }

        if analysisPending {
            analysisPending = false
            scheduleAnalysis()
        }
    }

    /// Transcript lines with a marker at where the previous pass stopped,
    /// trimmed to the meeting type's word budget.
    private func analysisDialogue() -> String {
        var lines: [String] = []
        var marked = lastAnalyzedLineID == nil
        if marked { lines.append(ConversationAnalyst.newMarker) }
        for line in transcript {
            lines.append("\(line.speaker.rawValue): \(line.text)")
            if !marked, line.id == lastAnalyzedLineID {
                lines.append(ConversationAnalyst.newMarker)
                marked = true
            }
        }
        // Marker line vanished from the window (very long gap): treat all as new.
        if !marked { lines.insert(ConversationAnalyst.newMarker, at: 0) }
        let words = lines.joined(separator: "\n").split(separator: " ")
        return words.suffix(meetingType.recentWindowWordBudget).joined(separator: " ")
    }

    private func apply(_ result: AnalysisResult) {
        for q in result.questions {
            FileHandle.standardError.write(Data("cue: question[\(q.open ? "open" : "answered")] \(q.question)\n".utf8))
            lastQuestion = q.question
            guard q.open, meetingType.autoAnswerRemoteQuestions else { continue }
            let dup = cues.contains { $0.question.localizedCaseInsensitiveCompare(q.question) == .orderedSame }
            if dup { continue }
            statusLine = "They asked — drafting…"
            let window = recentWindow
            Task {
                await draftAnswer(
                    for: q.question, origin: .remoteQuestion, transcript: window, quickAnswer: q.quickAnswer
                )
            }
        }

        if meetingType.wantsLookups {
            for lookup in result.lookups {
                let key = lookup.topic.lowercased()
                guard !lookedUp.contains(key) else { continue }
                lookedUp.insert(key)
                contextLookup(lookup, transcript: recentWindow)
            }
        }

        if coachingEnabled {
            let fresh = result.coaching.filter { note in
                !coaching.contains { $0.content == note.content }
            }
            if !fresh.isEmpty {
                coaching.insert(contentsOf: fresh, at: 0)
                if coaching.count > 10 { coaching.removeLast(coaching.count - 10) }
            }
        }

        let novel = result.commitments.filter { item in
            !commitments.contains {
                $0.kind == item.kind && $0.text.localizedCaseInsensitiveCompare(item.text) == .orderedSame
            }
        }
        if !novel.isEmpty {
            commitments.insert(contentsOf: novel, at: 0)
            if commitments.count > 16 { commitments.removeLast(commitments.count - 16) }
        }
    }

    /// - Parameter quickAnswer: when the analyst already drafted one, skip
    ///   the separate quick-answer call and go straight to the card.
    private func draftAnswer(
        for question: String,
        origin: AnswerOrigin,
        transcript: String,
        quickAnswer: String = ""
    ) async {
        let userAsked = origin == .userAsk
        let type = meetingType
        draftsInFlight += 1
        defer { draftsInFlight -= 1 }
        do {
            let answer = quickAnswer.isEmpty
                ? try await answers.answer(
                    question: question,
                    transcript: transcript,
                    notes: contextNotes,
                    prep: prepText,
                    meetingType: type,
                    userAsked: userAsked,
                    apiKey: resolvedAPIKey
                )
                : quickAnswer
            // Even when the quick model SKIPs, still open a card and run the
            // docs search — empty notes used to abort before grounding ran.
            let display = answer.isEmpty ? "Looking up in docs…" : answer
            let card = AnswerCard(question: question, answer: display, origin: origin, at: Date())
            cues.insert(card, at: 0)
            // Replays keep every card so the report covers the whole call.
            if replayTask == nil, cues.count > 12 { cues.removeLast(cues.count - 12) }
            statusLine = answer.isEmpty ? "Checking docs…" : "Answer ready"
            Self.answerLog("quick \(answer.isEmpty ? "SKIP" : "ok") origin=\(origin.rawValue) type=\(type.rawValue) q=\(question.prefix(80))")
            enrichWithSources(cardID: card.id, question: question, origin: origin, transcript: transcript)
        } catch {
            statusLine = "Answer failed: \(error.localizedDescription)"
            Self.answerLog("quick FAIL \(error.localizedDescription)")
        }
    }

    /// Roots Cue ripgreps for grounded answers: primary repo, optional extras
    /// (Grok Bot dumps, etc.), and past call sessions when saving is on.
    func resolvedKnowledgeRoots() -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let path = (raw as NSString).expandingTildeInPath
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path), !seen.contains(path)
            else { return }
            seen.insert(path)
            roots.append(path)
        }
        // Prep for this call, then the curated pack, so both outrank repo noise.
        add(PrepStore.root.path)
        add(CueKnowledge.directory.path)
        add(sourceRoot)
        // Prefer everysphere internal-docs when the primary root is the monorepo.
        let primary = (sourceRoot as NSString).expandingTildeInPath
        if primary.lowercased().contains("everysphere") {
            add((primary as NSString).appendingPathComponent("internal-docs"))
        }
        for line in extraSourceRoots.split(whereSeparator: \.isNewline) {
            add(String(line).trimmingCharacters(in: .whitespaces))
        }
        if saveTranscripts {
            add(TranscriptStore.sessionsDirectory.path)
        }
        return roots
    }

    /// Second stage: search the local knowledge repo for the question and,
    /// if snippets are found, update the card with a grounded answer.
    /// Proactive card for something named in passing. Retrieval gates it: no
    /// hits in prep/docs/playbook/past calls means no card, so this can't
    /// degrade into the model narrating trivia.
    private func contextLookup(_ lookup: AnalysisResult.Lookup, transcript dialogue: String) {
        guard sourceSearchEnabled else { return }
        let roots = resolvedKnowledgeRoots()
        let notes = contextNotes
        let prep = prepText
        let key = resolvedAPIKey
        let engine = answers
        let type = meetingType
        let question = lookup.why.isEmpty
            ? lookup.topic
            : "\(lookup.topic) — why it came up: \(lookup.why)"
        let liveSession = transcriptStore?.fileURL.lastPathComponent
        Task.detached(priority: .utility) { [weak self] in
            var search = SourceSearch(roots: roots)
            // The live session would only echo what was just said.
            search.excludeBasenames = Set([liveSession].compactMap { $0 })
            let hits = Array(search.search(question: lookup.query, context: lookup.topic).prefix(6))
            guard let self else { return }
            guard !hits.isEmpty else {
                await MainActor.run { Self.answerLog("lookup NO-HITS topic=\(lookup.topic) query=\(lookup.query)") }
                return
            }
            let snippets = hits.map { "FILE: \($0.file)\n\($0.snippet)" }.joined(separator: "\n\n---\n\n")
            let cardID = await MainActor.run { () -> UUID in
                var card = AnswerCard(question: lookup.topic, answer: "Pulling what we know…", origin: .lookup, at: Date())
                card.sourceState = .searching
                self.cues.insert(card, at: 0)
                self.statusLine = "Context: \(lookup.topic)"
                return card.id
            }
            do {
                let reply = try await engine.sourcedAnswer(
                    question: question, snippets: snippets, notes: notes,
                    transcript: dialogue, prep: prep, meetingType: type, userAsked: true,
                    draft: "", proactive: true, apiKey: key
                )
                let sourced = reply.text
                let used = Self.usedFiles(reply.sources, from: hits.map(\.file))
                await MainActor.run {
                    if sourced.isEmpty {
                        self.cues.removeAll { $0.id == cardID }
                        Self.answerLog("lookup DECLINED topic=\(lookup.topic)")
                    } else {
                        self.updateCard(cardID) {
                            $0.answer = sourced
                            $0.sourcedAnswer = sourced
                            $0.sourceFiles = used.isEmpty ? hits.map(\.file) : used
                            $0.sourceState = .done
                        }
                        Self.answerLog("lookup OK topic=\(lookup.topic) used=\(used.joined(separator: ",")) hits=\(hits.count)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.cues.removeAll { $0.id == cardID }
                    Self.answerLog("lookup FAIL \(error.localizedDescription)")
                }
            }
        }
    }

    private func enrichWithSources(
        cardID: UUID,
        question: String,
        origin: AnswerOrigin,
        transcript dialogue: String
    ) {
        guard sourceSearchEnabled else {
            updateCard(cardID) { card in
                if card.answer == "Looking up in docs…" {
                    card.answer = "No notes/docs configured — add call context in Settings."
                }
            }
            return
        }
        let roots = resolvedKnowledgeRoots()
        updateCard(cardID) { $0.sourceState = .searching }

        let notes = contextNotes
        let prep = prepText
        let key = resolvedAPIKey
        let engine = answers
        let type = meetingType
        let userAsked = origin == .userAsk
        let draft = cues.first { $0.id == cardID }.map { $0.isPlaceholder ? "" : $0.answer } ?? ""
        let preferTranscript = type.prefersTranscriptGrounding
        let sessionURL = transcriptStore?.fileURL
        // Sales: exclude live session from *repo* ranking to avoid echo.
        // Interview: include it — the call is the primary knowledge.
        let exclude = preferTranscript
            ? Set<String>()
            : Set([sessionURL?.lastPathComponent].compactMap { $0 })
        Task.detached(priority: .utility) { [weak self] in
            var search = SourceSearch(roots: roots)
            search.excludeBasenames = exclude

            var hits: [SourceHit] = []
            // Always ground in what was just said — sales setup answers live here.
            hits.append(contentsOf: search.dialogueSnippets(question: question, dialogue: dialogue))
            if preferTranscript || userAsked, let sessionURL {
                hits.append(contentsOf: search.transcriptSnippets(
                    question: question, fileURL: sessionURL, label: sessionURL.lastPathComponent
                ))
            }
            // Always pull curated docs / repo — sales Ask especially needs portal hits.
            let repoHits = search.search(question: question, context: dialogue)
            for hit in repoHits where !hits.contains(where: { $0.file == hit.file }) {
                hits.append(hit)
            }
            hits = Array(hits.prefix(6))
            let finalHits = hits

            guard let self else { return }
            // Run the sourced pass even with no hits: in evals it beats the
            // quick pass by ~0.5/3 from the transcript window alone.
            let snippets = finalHits.isEmpty
                ? "(no matching docs)"
                : finalHits.map { "FILE: \($0.file)\n\($0.snippet)" }.joined(separator: "\n\n---\n\n")
            do {
                let reply = try await engine.sourcedAnswer(
                    question: question, snippets: snippets, notes: notes,
                    transcript: dialogue, prep: prep, meetingType: type, userAsked: userAsked,
                    draft: draft, apiKey: key
                )
                let sourced = reply.text
                let used = Self.usedFiles(reply.sources, from: finalHits.map(\.file))
                await MainActor.run {
                    self.updateCard(cardID) {
                        // Badge shows what the answer relied on; if the model used none of the
                        // hits, the answer came from the call and that is what the badge says.
                        $0.sourceFiles = used.isEmpty ? ["live-dialogue"] : used
                        if sourced.isEmpty {
                            $0.sourceState = finalHits.isEmpty ? .empty : .declined
                            if $0.answer == "Looking up in docs…" {
                                $0.answer = finalHits.isEmpty
                                    ? "Nothing in docs on this — answer from the call and what you know."
                                    : "Docs matched but didn’t settle this — answer from the call and what you know."
                            }
                            Self.answerLog("sourced DECLINED q=\(question.prefix(80)) files=\(finalHits.map(\.file).joined(separator: ","))")
                        } else {
                            $0.sourcedAnswer = sourced
                            $0.sourceState = .done
                            if $0.answer == "Looking up in docs…" {
                                $0.answer = sourced
                            }
                            Self.answerLog("sourced OK q=\(question.prefix(80)) used=\(used.joined(separator: ",")) hits=\(finalHits.count)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateCard(cardID) { card in
                        card.sourceState = .failed
                        if card.answer == "Looking up in docs…" {
                            card.answer = "Couldn’t reach xAI for the docs pass — answer from the call."
                        }
                    }
                    Self.answerLog("sourced FAIL \(error.localizedDescription)")
                }
            }
        }
    }

    static func answerLog(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/cue-answers.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func updateCard(_ id: UUID, _ mutate: (inout AnswerCard) -> Void) {
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return }
        mutate(&cues[idx])
    }

    func dismissCoaching(_ note: CoachingNote) {
        coaching.removeAll { $0.id == note.id }
    }

    func dismissCommitment(_ item: CallCommitment) {
        commitments.removeAll { $0.id == item.id }
    }

    /// Names the transcriber should not have to guess at. Grok STT accepts up
    /// to 100 keyterms (≤50 chars each); the domain vocabulary goes first, then
    /// proper nouns and acronyms from the notes and this call's prep — the
    /// customer, their people, their stack — which are exactly what a generic
    /// model mishears ("Okta" → "ought to").
    static let domainKeyterms: [String] = [
        "Grok Bot", "Grokbot", "Cursor", "xAI", "SpaceXAI", "Anysphere", "Grok 4.6",
        "Cloud Agent", "Bugbot", "Auto Review", "Team Rules", "Legend",
        "Okta", "Entra", "SSO", "SCIM", "SAML", "OAuth", "IdP", "MFA",
        "MCP", "MCP server", "MCP gateway", "SDK", "API", "CLI", "webhook",
        "microVM", "Firecracker", "Temporal", "egress", "allowlist", "PrivateLink",
        "VPC", "VPN", "Tailscale", "Cloudflare", "Zscaler", "proxy", "Artifactory",
        "SOC 2", "BAA", "HIPAA", "GDPR", "TPRM", "SIEM", "OpenTelemetry", "Datadog", "Splunk",
        "GitHub", "GitLab", "Bitbucket", "Jira", "Slack", "Notion", "Google Drive", "Zoom",
        "AWS", "Azure", "GCP", "Kubernetes", "EKS", "AKS", "S3", "KMS", "BYOK",
        "Anthropic", "OpenAI", "Claude", "Codex", "Gemini",
    ]

    private func keyterms(from notes: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ term: String) {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 2, t.count <= 50, out.count < 100, seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        Self.domainKeyterms.forEach(add)
        // Proper nouns / acronyms: capitalised or all-caps tokens, optionally
        // two words ("Foot Locker"), excluding sentence-initial noise by
        // requiring a second sighting in the prep text.
        let pattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Za-z0-9&.-]{1,}(?:\s[A-Z][A-Za-z0-9&.-]{1,})?)\b"#)
        func candidates(_ text: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            let ns = text as NSString
            for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let term = ns.substring(with: m.range(at: 1))
                guard !Self.keytermStopwords.contains(term.lowercased()) else { continue }
                counts[term, default: 0] += 1
            }
            return counts
        }
        for (term, _) in candidates(notes).sorted(by: { $0.value > $1.value }) { add(term) }
        let prep = candidates(prepText).filter { $0.value >= 2 }
        for (term, _) in prep.sorted(by: { $0.value > $1.value }) { add(term) }
        return out
    }

    private static let keytermStopwords: Set<String> = [
        "the", "this", "that", "they", "them", "then", "there", "these", "those", "what", "when", "where",
        "which", "who", "why", "how", "yes", "no", "not", "and", "but", "for", "with", "from", "into",
        "our", "your", "their", "its", "his", "her", "we", "you", "it", "i", "me", "my",
        "say", "ask", "do", "don't", "be", "is", "are", "was", "were", "if", "so", "as", "at", "by", "on", "in", "of", "to",
        "top", "facts", "themes", "caveats", "weak", "spots", "they ask", "commitments", "part", "faq",
        "monday", "tuesday", "wednesday", "thursday", "friday", "today", "tomorrow",
    ]
}

/// Which side of the call a line came from. Cue deliberately stops here:
/// mic vs system tap is the only attribution it can actually stand behind.
/// Naming individual remote speakers needs diarization Cue doesn't have.
enum Speaker: String, Equatable {
    case them = "Them"
    case me = "Me"

    init(_ source: AudioSource) {
        self = source == .system ? .them : .me
    }
}

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    let at: Date
}

struct AnswerCard: Identifiable, Equatable {
    enum SourceState: Equatable {
        case none
        case searching
        case done
        case empty
        case declined
        case failed
    }

    let id = UUID()
    let question: String
    var answer: String
    var origin: AnswerOrigin = .remoteQuestion
    var sourcedAnswer: String?
    var sourceFiles: [String] = []
    var sourceState: SourceState = .none
    let at: Date

    /// The one answer to show: grounded when we have it, else the quick draft.
    var displayAnswer: String {
        if let sourcedAnswer, !sourcedAnswer.isEmpty { return sourcedAnswer }
        return answer
    }

    var isGrounded: Bool {
        sourceState == .done && !(sourcedAnswer ?? "").isEmpty && sourceFiles.contains { $0 != "live-dialogue" }
    }
    var isPlaceholder: Bool { answer == "Looking up in docs…" && sourceState == .searching }
}
