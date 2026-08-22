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
    @Published var contextNotes = ""
    @Published var apiKeyField = ""
    @Published var includeMic = true
    @Published var errorMessage: String?
    @Published var lastQuestion: String?

    private let keychain = KeychainStore(service: "com.davidgeorgehope.cue")
    private let capture = DualCapture()
    private let stt = GrokSTTClient()
    private let answers = AnswerEngine()
    private let questions = QuestionDetector()
    private var recentWindow = ""
    private var lastAnswered = ""
    private var lastAnswerAt = Date.distantPast

    init() {
        contextNotes = UserDefaults.standard.string(forKey: "cue.context") ?? ""
        includeMic = UserDefaults.standard.object(forKey: "cue.includeMic") as? Bool ?? true
        wireSTT()
        Task { @MainActor [weak self] in
            self?.loadKey()
        }
    }

    func loadKey() {
        if let stored = keychain.read(account: "xai") {
            apiKeyField = stored
        } else if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], !env.isEmpty {
            apiKeyField = env
        }
    }

    var hasKey: Bool { !apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func saveSettings() {
        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Never delete a stored xAI key from an empty field. Settings can
            // appear before loadKey() finishes, and that already wiped the item.
        } else {
            keychain.write(account: "xai", value: trimmed)
        }
        UserDefaults.standard.set(contextNotes, forKey: "cue.context")
        UserDefaults.standard.set(includeMic, forKey: "cue.includeMic")
    }

    func toggleListen() {
        switch phase {
        case .listening:
            stop()
        default:
            start()
        }
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
        phase = .listening
        statusLine = "Connecting Grok Voice STT…"
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        capture.onPCM16 = { [weak self] data in
            self?.stt.sendPCM16(data)
        }
        stt.start(apiKey: apiKeyField, keyterms: keyterms(from: contextNotes))
        Task { [weak self] in
            await self?.beginCapture()
        }
    }

    private func beginCapture() async {
        if includeMic {
            let granted = await requestMicIfNeeded()
            if !granted {
                stt.stop()
                phase = .error
                errorMessage = CaptureError.micPermission.localizedDescription
                statusLine = "Capture failed"
                return
            }
        }
        do {
            try capture.start(includeMic: includeMic)
        } catch {
            stt.stop()
            phase = .error
            errorMessage = error.localizedDescription
            statusLine = "Capture failed"
        }
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
        stt.stop()
        phase = .idle
        statusLine = "Idle"
        livePartial = ""
        level = 0
    }

    func dismiss(_ card: AnswerCard) {
        cues.removeAll { $0.id == card.id }
    }

    private func wireSTT() {
        stt.onPartial = { [weak self] text in
            Task { @MainActor in
                self?.livePartial = text
            }
        }
        stt.onFinal = { [weak self] text in
            Task { @MainActor in
                self?.ingest(text)
            }
        }
        stt.onStatus = { [weak self] text in
            Task { @MainActor in
                if self?.phase == .listening {
                    self?.statusLine = text
                }
            }
        }
        stt.onError = { [weak self] text in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                self.statusLine = "STT: \(text)"
            }
        }
    }

    private func ingest(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.lowercased() != "(silence)" else { return }
        livePartial = ""

        let line = TranscriptLine(text: text, at: Date())
        transcript.append(line)
        if transcript.count > 80 { transcript.removeFirst(transcript.count - 80) }

        recentWindow = (recentWindow + " " + text)
            .split(separator: " ")
            .suffix(280)
            .joined(separator: " ")

        if let question = questions.detect(in: text, recent: recentWindow) {
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
        } catch {
            statusLine = "Answer failed: \(error.localizedDescription)"
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
    let text: String
    let at: Date
}

struct AnswerCard: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let answer: String
    let at: Date
}
