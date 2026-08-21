import Foundation
import SwiftUI
import Combine

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
    @Published var transcript: [TranscriptLine] = []
    @Published var cues: [AnswerCard] = []
    @Published var contextNotes = ""
    @Published var apiKeyField = ""
    @Published var includeMic = true
    @Published var errorMessage: String?
    @Published var lastQuestion: String?

    private let keychain = KeychainStore(service: "com.davidgeorgehope.cue")
    private let capture = DualCapture()
    private let whisper = WhisperClient()
    private let answers = AnswerEngine()
    private let questions = QuestionDetector()
    private var chunkTask: Task<Void, Never>?
    private var recentWindow = ""

    init() {
        if let stored = keychain.read(account: "openai") {
            apiKeyField = stored
        } else if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            apiKeyField = env
        }
        contextNotes = UserDefaults.standard.string(forKey: "cue.context") ?? ""
        includeMic = UserDefaults.standard.object(forKey: "cue.includeMic") as? Bool ?? true
    }

    var hasKey: Bool { !apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func saveSettings() {
        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: "openai")
        } else {
            keychain.write(account: "openai", value: trimmed)
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
        saveSettings()
        guard hasKey else {
            errorMessage = "Add an OpenAI API key in Settings first."
            phase = .error
            return
        }
        errorMessage = nil
        phase = .listening
        statusLine = "Listening for customer questions…"
        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.level = level
            }
        }
        capture.onChunk = { [weak self] data in
            Task { @MainActor in
                self?.handleChunk(data)
            }
        }
        do {
            try capture.start(includeMic: includeMic)
        } catch {
            phase = .error
            errorMessage = error.localizedDescription
            statusLine = "Capture failed"
        }
    }

    func stop() {
        capture.stop()
        chunkTask?.cancel()
        phase = .idle
        statusLine = "Idle"
        level = 0
    }

    func dismiss(_ card: AnswerCard) {
        cues.removeAll { $0.id == card.id }
    }

    private func handleChunk(_ wav: Data) {
        guard phase == .listening, hasKey else { return }
        chunkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await whisper.transcribe(wav: wav, apiKey: apiKeyField)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.ingest(text)
                }
            } catch {
                await MainActor.run {
                    if self.phase == .listening {
                        self.statusLine = "STT hiccup: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func ingest(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.lowercased() != "(silence)" else { return }

        let line = TranscriptLine(text: text, at: Date())
        transcript.append(line)
        if transcript.count > 80 { transcript.removeFirst(transcript.count - 80) }

        recentWindow = (recentWindow + " " + text)
            .split(separator: " ")
            .suffix(280)
            .joined(separator: " ")

        if let question = questions.detect(in: text, recent: recentWindow) {
            lastQuestion = question
            statusLine = "Customer asked — drafting…"
            Task {
                await draftAnswer(for: question)
            }
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
