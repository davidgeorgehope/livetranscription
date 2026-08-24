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
    @Published var contextNotes = ""
    @Published var apiKeyField = ""
    @Published var includeMic = true
    @Published var coachingEnabled = true
    @Published var sourceSearchEnabled = true
    @Published var sourceRoot = "~/Projects/everysphere"
    @Published var saveTranscripts = true
    @Published var errorMessage: String?
    @Published var lastQuestion: String?
    @Published var rosterState: RosterState = .meetingNotDetected

    private let keychain = KeychainStore(service: "com.davidgeorgehope.cue")
    private let capture = DualCapture()
    private let sttCustomer = GrokSTTClient()
    private let sttMe = GrokSTTClient()
    private let roster = ZoomRoster()
    private let answers = AnswerEngine()
    private let coach = CoachingEngine()
    private let commitmentExtractor = CommitmentExtractor()
    private let wrapEngine = CallWrapEngine()
    private let questions = QuestionDetector()
    private var recentWindow = ""
    private var lastAnswered = ""
    private var lastAnswerAt = Date.distantPast
    private var wordsSinceCoaching = 0
    private var lastCoachingAt = Date.distantPast
    private var coachingInFlight = false
    private var wordsSinceCommitments = 0
    private var lastCommitmentsAt = Date.distantPast
    private var commitmentsInFlight = false
    private var transcriptStore: TranscriptStore?
    private var utteranceStart: [AudioSource: Date] = [:]

    init() {
        if let envNotes = ProcessInfo.processInfo.environment["CUE_CONTEXT"], !envNotes.isEmpty {
            contextNotes = envNotes
        } else {
            contextNotes = UserDefaults.standard.string(forKey: "cue.context") ?? ""
        }
        includeMic = UserDefaults.standard.object(forKey: "cue.includeMic") as? Bool ?? true
        coachingEnabled = UserDefaults.standard.object(forKey: "cue.coaching") as? Bool ?? true
        sourceSearchEnabled = UserDefaults.standard.object(forKey: "cue.sourceSearch") as? Bool ?? true
        sourceRoot = UserDefaults.standard.string(forKey: "cue.sourceRoot") ?? "~/Projects/everysphere"
        saveTranscripts = UserDefaults.standard.object(forKey: "cue.saveTranscripts") as? Bool ?? true
        roster.onStateChange = { [weak self] state in
            self?.rosterState = state
        }
        wireSTT()
        refreshSessions()
        Task { @MainActor [weak self] in
            self?.loadKey()
            if ProcessInfo.processInfo.environment["CUE_AUTOSTART"] == "1" {
                FileHandle.standardError.write(Data("cue: autostart requested hasKey=\(self?.hasKey ?? false)\n".utf8))
                self?.includeMic = ProcessInfo.processInfo.environment["CUE_MIC_ONLY"] == "1"
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

    func loadKey() {
        if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], !env.isEmpty {
            apiKeyField = env
            return
        }
        if let stored = keychain.read(account: "xai") {
            apiKeyField = stored
        }
    }

    var hasKey: Bool { !apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func saveSettings() {
        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"] ?? ""
        if trimmed.isEmpty {
            // Never delete a stored xAI key from an empty field. Settings can
            // appear before loadKey() finishes, and that already wiped the item.
        } else if envKey.isEmpty {
            keychain.write(account: "xai", value: trimmed)
        }
        UserDefaults.standard.set(contextNotes, forKey: "cue.context")
        UserDefaults.standard.set(includeMic, forKey: "cue.includeMic")
        UserDefaults.standard.set(coachingEnabled, forKey: "cue.coaching")
        UserDefaults.standard.set(sourceSearchEnabled, forKey: "cue.sourceSearch")
        UserDefaults.standard.set(sourceRoot, forKey: "cue.sourceRoot")
        UserDefaults.standard.set(saveTranscripts, forKey: "cue.saveTranscripts")
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
        if apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadKey()
        }
        saveSettings()
        guard hasKey else {
            errorMessage = "Add an xAI API key in Settings first."
            phase = .error
            return
        }
        errorMessage = nil
        livePartial = ""
        utteranceStart.removeAll()
        transcript = []
        cues = []
        coaching = []
        wordsSinceCoaching = 0
        lastCoachingAt = Date.distantPast
        wordsSinceCommitments = 0
        lastCommitmentsAt = Date.distantPast
        commitments = []
        latestWrap = nil
        showWrapSheet = false
        if saveTranscripts {
            transcriptStore = TranscriptStore()
        }
        phase = .listening
        statusLine = "Connecting Grok Voice STT…"
        roster.start()
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        capture.onPCM16 = { [weak self] source, data in
            switch source {
            case .system: self?.sttCustomer.sendPCM16(data)
            case .mic: self?.sttMe.sendPCM16(data)
            }
        }
        FileHandle.standardError.write(Data("cue: start() connecting STT\n".utf8))
        sttCustomer.start(apiKey: apiKeyField, keyterms: keyterms(from: contextNotes))
        // In mic-only test mode the mic feeds the customer stream instead.
        if includeMic, ProcessInfo.processInfo.environment["CUE_MIC_ONLY"] != "1" {
            sttMe.start(apiKey: apiKeyField, keyterms: keyterms(from: contextNotes))
        }
        Task.detached { [weak self] in
            await self?.beginCapture()
        }
    }

    private func beginCapture() async {
        let wantMic = await MainActor.run { includeMic }
        if wantMic {
            let granted = await requestMicIfNeeded()
            if !granted {
                await MainActor.run {
                    stopSTT()
                    roster.stop()
                    phase = .error
                    errorMessage = CaptureError.micPermission.localizedDescription
                    statusLine = "Capture failed"
                }
                return
            }
        }
        do {
            FileHandle.standardError.write(Data("cue: starting capture off-main\n".utf8))
            try capture.start(includeMic: wantMic)
            FileHandle.standardError.write(Data("cue: capture started\n".utf8))
        } catch {
            await MainActor.run {
                stopSTT()
                roster.stop()
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

    func stop() {
        capture.stop()
        stopSTT()
        roster.stop()
        phase = .idle
        livePartial = ""
        level = 0
        utteranceStart.removeAll()

        let dialogue = recentWindow
        let captured = commitments
        let notes = contextNotes
        let key = apiKeyField
        let storeURL = transcriptStore?.fileURL
        let storeName = storeURL?.lastPathComponent

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
            do {
                let wrap = try await wrapEngine.wrap(
                    dialogue: dialogue,
                    commitments: captured,
                    notes: notes,
                    apiKey: key
                )
                let title = storeName ?? "call"
                CallWrapEngine.write(wrap, beside: storeURL, title: title)
                latestWrap = wrap
                showWrapSheet = true
                refreshSessions()
                statusLine = "Wrap ready · \(storeURL.lastPathComponent)"
            } catch {
                statusLine = "Wrap failed: \(error.localizedDescription)"
            }
        }
    }

    func dismiss(_ card: AnswerCard) {
        cues.removeAll { $0.id == card.id }
    }

    private func wireSTT() {
        wire(sttCustomer, source: .system, drivesStatus: true)
        wire(sttMe, source: .mic, drivesStatus: false)
    }

    private func wire(_ stt: GrokSTTClient, source: AudioSource, drivesStatus: Bool) {
        stt.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                let roleName = source == .system ? "Customer" : "Me"
                if self.utteranceStart[source] == nil {
                    self.utteranceStart[source] = Date()
                }
                FileHandle.standardError.write(Data("cue: partial [\(source.rawValue)] \(text)\n".utf8))
                self.livePartial = "\(roleName): \(text)"
            }
        }
        stt.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = Date()
                let start = self.utteranceStart.removeValue(forKey: source) ?? now.addingTimeInterval(-2)
                let label = self.roster.label(
                    for: source,
                    during: DateInterval(start: start, end: now)
                )
                FileHandle.standardError.write(Data("cue: final [\(label.displayName)] \(text)\n".utf8))
                self.ingest(text, from: label, at: now)
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

    private func ingest(_ raw: String, from label: SpeakerLabel, at date: Date) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.lowercased() != "(silence)" else { return }
        livePartial = ""

        let line = TranscriptLine(label: label, text: text, at: date)
        transcript.append(line)
        if transcript.count > 80 { transcript.removeFirst(transcript.count - 80) }
        transcriptStore?.append(speaker: label.displayName, text: text, at: line.at)

        recentWindow = (recentWindow + "\n\(label.displayName): " + text)
            .split(separator: " ")
            .suffix(280)
            .joined(separator: " ")

        wordsSinceCoaching += text.split(separator: " ").count
        wordsSinceCommitments += text.split(separator: " ").count
        maybeCoach()
        maybeExtractCommitments()

        guard label.role == .remote else { return }

        if let question = questions.detect(in: text, recent: recentWindow) {
            FileHandle.standardError.write(Data("cue: question \(question)\n".utf8))
            let normalized = question.lowercased()
            if normalized == lastAnswered, Date().timeIntervalSince(lastAnswerAt) < 20 {
                return
            }
            lastQuestion = question
            lastAnswered = normalized
            lastAnswerAt = Date()
            statusLine = "Customer asked — drafting…"
            Task { await draftAnswer(for: question) }
        }
    }

    private func draftAnswer(for question: String) async {
        do {
            let answer = try await answers.answer(
                question: question,
                transcript: recentWindow,
                notes: contextNotes,
                apiKey: apiKeyField
            )
            guard !answer.isEmpty else {
                statusLine = "Listening for customer questions…"
                return
            }
            let card = AnswerCard(question: question, answer: answer, at: Date())
            cues.insert(card, at: 0)
            if cues.count > 12 { cues.removeLast(cues.count - 12) }
            statusLine = "Answer ready"
            enrichWithSources(cardID: card.id, question: question)
        } catch {
            statusLine = "Answer failed: \(error.localizedDescription)"
        }
    }

    /// Second stage: search the local knowledge repo for the question and,
    /// if snippets are found, update the card with a grounded answer.
    private func enrichWithSources(cardID: UUID, question: String) {
        guard sourceSearchEnabled else { return }
        var roots: [String] = []
        let repoRoot = (sourceRoot as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: repoRoot) {
            roots.append(repoRoot)
        }
        let sessions = TranscriptStore.sessionsDirectory.path
        if FileManager.default.fileExists(atPath: sessions) {
            roots.append(sessions)
        }
        guard !roots.isEmpty else { return }
        updateCard(cardID) { $0.sourceState = .searching }

        let notes = contextNotes
        let key = apiKeyField
        let engine = answers
        let dialogue = recentWindow
        let exclude = Set([transcriptStore?.fileURL.lastPathComponent].compactMap { $0 })
        Task.detached(priority: .utility) { [weak self] in
            var search = SourceSearch(roots: roots)
            search.excludeBasenames = exclude
            let hits = search.search(question: question, context: dialogue)
            guard let self else { return }
            guard !hits.isEmpty else {
                await MainActor.run { self.updateCard(cardID) { $0.sourceState = .empty } }
                return
            }
            let snippets = hits
                .map { "FILE: \($0.file)\n\($0.snippet)" }
                .joined(separator: "\n\n---\n\n")
            do {
                let sourced = try await engine.sourcedAnswer(
                    question: question, snippets: snippets, notes: notes,
                    transcript: dialogue, apiKey: key
                )
                await MainActor.run {
                    self.updateCard(cardID) {
                        $0.sourceFiles = hits.map(\.file)
                        if sourced.isEmpty {
                            // Hits existed but the model declined to ground an answer.
                            $0.sourceState = .declined
                        } else {
                            $0.sourcedAnswer = sourced
                            $0.sourceState = .done
                        }
                    }
                }
            } catch {
                await MainActor.run { self.updateCard(cardID) { $0.sourceState = .failed } }
            }
        }
    }

    private func updateCard(_ id: UUID, _ mutate: (inout AnswerCard) -> Void) {
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return }
        mutate(&cues[idx])
    }

    private func maybeCoach() {
        guard coachingEnabled, phase == .listening, !coachingInFlight else { return }
        guard wordsSinceCoaching >= 40,
              Date().timeIntervalSince(lastCoachingAt) >= 45 else { return }
        coachingInFlight = true
        wordsSinceCoaching = 0
        lastCoachingAt = Date()

        let dialogue = recentWindow
        let notes = contextNotes
        let key = apiKeyField
        Task {
            defer { coachingInFlight = false }
            do {
                let new = try await coach.analyze(dialogue: dialogue, notes: notes, apiKey: key)
                let fresh = new.filter { note in
                    !coaching.contains { $0.content == note.content }
                }
                guard !fresh.isEmpty else { return }
                coaching.insert(contentsOf: fresh, at: 0)
                if coaching.count > 10 { coaching.removeLast(coaching.count - 10) }
            } catch {
                FileHandle.standardError.write(Data("cue: coaching error \(error.localizedDescription)\n".utf8))
            }
        }
    }

    func dismissCoaching(_ note: CoachingNote) {
        coaching.removeAll { $0.id == note.id }
    }

    func dismissCommitment(_ item: CallCommitment) {
        commitments.removeAll { $0.id == item.id }
    }

    private func maybeExtractCommitments() {
        guard phase == .listening, !commitmentsInFlight else { return }
        guard wordsSinceCommitments >= 50,
              Date().timeIntervalSince(lastCommitmentsAt) >= 60 else { return }
        commitmentsInFlight = true
        wordsSinceCommitments = 0
        lastCommitmentsAt = Date()

        let dialogue = recentWindow
        let key = apiKeyField
        Task {
            defer { commitmentsInFlight = false }
            do {
                let fresh = try await commitmentExtractor.extract(dialogue: dialogue, apiKey: key)
                let novel = fresh.filter { item in
                    !commitments.contains {
                        $0.kind == item.kind && $0.text.localizedCaseInsensitiveCompare(item.text) == .orderedSame
                    }
                }
                guard !novel.isEmpty else { return }
                commitments.insert(contentsOf: novel, at: 0)
                if commitments.count > 16 { commitments.removeLast(commitments.count - 16) }
            } catch {
                FileHandle.standardError.write(Data("cue: commitments error \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func keyterms(from notes: String) -> [String] {
        notes
            .split(whereSeparator: { ",\n;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && $0.count <= 50 }
    }
}

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let label: SpeakerLabel
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
    let answer: String
    var sourcedAnswer: String?
    var sourceFiles: [String] = []
    var sourceState: SourceState = .none
    let at: Date
}
