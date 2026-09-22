import Foundation

/// Live Grok speech-to-text over `wss://api.x.ai/v1/stt`.
/// Sends 16 kHz mono PCM16 frames; emits interim + utterance-final text.
///
/// Turn boundaries come from the server's Smart Turn model: `speech_final`
/// fires when it judges the speaker has finished a thought (or after
/// `smart_turn_timeout` of silence). `is_final` without `speech_final` is a
/// chunk final — text locked every ~3s of speech, *not* a boundary — so those
/// accumulate and are emitted together as one utterance. A local silence timer,
/// deliberately longer than the server timeout, is only a safety net for a
/// stalled stream; `transcript.done` and `stop()` flush whatever is left.
@available(macOS 14.2, *)
final class GrokSTTClient: NSObject, URLSessionWebSocketDelegate {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var ready = false
    private var pending = Data()
    private let lock = NSLock()
    private var closed = true
    private var connectWatch: DispatchWorkItem?
    private var silenceCommit: DispatchWorkItem?
    private var lastPartial = ""
    private var lastFinal = ""
    /// Chunk-final segments of the utterance in progress (Smart Turn demotes
    /// mid-thought pauses to these). Joined with the closing text on `speech_final`.
    private var lockedChunks: [String] = []
    /// Safety net only: must exceed `smartTurnTimeoutMs` so the server, not this
    /// timer, decides where a turn ends.
    private let commitSilence: TimeInterval = 3.5
    /// 0.5 catches most natural endings; 0.7 is dictation-grade. Conversation
    /// sits between: end the turn when fairly sure, but ride out "um… so".
    static let smartTurnThreshold = "0.6"
    static let smartTurnTimeoutMs = "2500"

    /// Pinned: the endpoint defaults to grok-voice-transcribe-1.0 when `model`
    /// is omitted, so a newer transcribe model is only used if named here.
    static let model = "grok-voice-transcribe-2.0"

    func start(apiKey: String, keyterms: [String] = []) {
        stop()
        closed = false
        ready = false
        pending = Data()
        lastFinal = ""
        lastPartial = ""
        lockedChunks = []

        var items: [URLQueryItem] = [
            .init(name: "model", value: Self.model),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "pcm"),
            .init(name: "interim_results", value: "true"),
            .init(name: "language", value: "en"),
            .init(name: "smart_turn", value: Self.smartTurnThreshold),
            .init(name: "smart_turn_timeout", value: Self.smartTurnTimeoutMs),
        ]
        for term in keyterms.prefix(100) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 50 {
                items.append(.init(name: "keyterm", value: trimmed))
            }
        }
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        components.queryItems = items
        guard let url = components.url else {
            onError?("Bad Grok STT URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        log("start \(url.absoluteString)")
        task.resume()
        listen()
        onStatus?("Connecting Grok Voice STT…")
        let watch = DispatchWorkItem { [weak self] in
            guard let self, !self.closed, !self.ready else { return }
            self.onError?("STT connect timed out")
            self.log("timeout")
        }
        connectWatch = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: watch)
    }

    func sendPCM16(_ data: Data) {
        guard !data.isEmpty, !closed else { return }
        lock.lock()
        if !ready {
            if pending.count < 320_000 { pending.append(data) }
            lock.unlock()
            return
        }
        lock.unlock()
        task?.send(.data(data)) { [weak self] error in
            if let error {
                self?.onError?("STT send: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        // Commit whatever we were still showing as a live partial.
        silenceCommit?.cancel()
        silenceCommit = nil
        flushPartialAsFinal()
        closed = true
        ready = false
        connectWatch?.cancel()
        connectWatch = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        pending = Data()
        lastPartial = ""
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        log("open proto=\(proto ?? "nil")")
        onStatus?("Grok Voice STT connected")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        ready = false
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        log("close \(closeCode.rawValue) \(why)")
        if !closed {
            // Unexpected close — keep any in-flight words.
            flushPartialAsFinal()
            onError?("Grok STT closed (\(closeCode.rawValue))")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            log("complete \(error.localizedDescription)")
            if !closed {
                flushPartialAsFinal()
                onError?("STT: \(error.localizedDescription)")
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.log("recv fail \(error.localizedDescription)")
                if !self.closed {
                    self.flushPartialAsFinal()
                    self.onError?("STT socket: \(error.localizedDescription)")
                }
            case .success(let message):
                self.handle(message)
                self.listen()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s):
            text = s
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else {
            log("msg (unparsed) \(text.prefix(160))")
            return
        }

        switch type {
        case "transcript.created":
            log("created id=\(obj["id"] as? String ?? "?")")
            flushPending()
            onStatus?("Listening for customer questions…")
        case "transcript.partial":
            let spoken = ((obj["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isFinal = obj["is_final"] as? Bool ?? false
            let speechFinal = obj["speech_final"] as? Bool ?? false
            let eot = obj["end_of_turn_confidence"] as? Double
            log("partial final=\(isFinal) speech=\(speechFinal) eot=\(eot.map { String(format: "%.2f", $0) } ?? "-") chunks=\(lockedChunks.count) chars=\(spoken.count) text=\(spoken.prefix(100))")

            if !spoken.isEmpty {
                if speechFinal {
                    emitFinal(stitched(closing: spoken))
                } else if isFinal {
                    // Chunk final: locked text, but the thought continues.
                    appendChunk(spoken)
                    lastPartial = ""
                    onPartial?(lockedChunks.joined(separator: " "))
                    scheduleSilenceCommit()
                } else {
                    lastPartial = spoken
                    onPartial?((lockedChunks + [spoken]).joined(separator: " "))
                    scheduleSilenceCommit()
                }
                return
            }

            // Empty text with a final flag: end-of-turn on a quiet channel, or a
            // chunk boundary with nothing new. Only speech_final closes the turn.
            if speechFinal {
                flushPartialAsFinal()
            } else if isFinal, !lastPartial.isEmpty {
                appendChunk(lastPartial)
                lastPartial = ""
            }
        case "transcript.done":
            let spoken = ((obj["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            log("done chars=\(spoken.count) text=\(spoken.prefix(100))")
            if !spoken.isEmpty {
                emitFinal(stitched(closing: spoken))
            } else {
                flushPartialAsFinal()
            }
        case "error":
            onError?(obj["message"] as? String ?? "Grok STT error")
        default:
            log("msg \(type)")
        }
    }

    private func scheduleSilenceCommit() {
        silenceCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPartialAsFinal()
        }
        silenceCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + commitSilence, execute: work)
    }

    private func flushPartialAsFinal() {
        silenceCommit?.cancel()
        silenceCommit = nil
        let text = (lockedChunks + [lastPartial]).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return }
        emitFinal(text)
    }

    /// Chunk-final text is usually just the new segment, but tolerate a
    /// cumulative server: if it already contains the previous chunk, replace.
    private func appendChunk(_ text: String) {
        if let last = lockedChunks.last, text.count > last.count, text.hasPrefix(String(last.prefix(24))) {
            lockedChunks[lockedChunks.count - 1] = text
        } else {
            lockedChunks.append(text)
        }
    }

    /// The utterance to emit when the server closes a turn: the stitched text
    /// if the server sent it, otherwise our locked chunks plus the closing segment.
    private func stitched(closing: String) -> String {
        guard let first = lockedChunks.first else { return closing }
        if closing.hasPrefix(String(first.prefix(24))) { return closing }
        return (lockedChunks + [closing]).joined(separator: " ")
    }

    /// The server can finalize the same utterance twice (an `is_final`
    /// partial followed by `speech_final` or `transcript.done` with identical
    /// text), which duplicated transcript lines. Emit each final text once.
    private func emitFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastFinal else { return }
        silenceCommit?.cancel()
        silenceCommit = nil
        lastFinal = trimmed
        lastPartial = ""
        lockedChunks = []
        onFinal?(trimmed)
    }

    private func flushPending() {
        lock.lock()
        ready = true
        let queued = pending
        pending = Data()
        lock.unlock()
        connectWatch?.cancel()
        if !queued.isEmpty {
            task?.send(.data(queued)) { _ in }
        }
    }

    private func log(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/cue-stt.log")
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
}
