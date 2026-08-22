import Foundation

/// Live Grok speech-to-text over `wss://api.x.ai/v1/stt`.
/// Sends 16 kHz mono PCM16 frames; emits interim + utterance-final text.
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

    func start(apiKey: String, keyterms: [String] = []) {
        stop()
        closed = false
        ready = false
        pending = Data()

        var items: [URLQueryItem] = [
            .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "pcm"),
            .init(name: "interim_results", value: "true"),
            .init(name: "language", value: "en")
        ]
        for term in keyterms.prefix(8) {
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
        closed = true
        ready = false
        connectWatch?.cancel()
        connectWatch = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        pending = Data()
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
            onError?("Grok STT closed (\(closeCode.rawValue))")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            log("complete \(error.localizedDescription)")
            if !closed { onError?("STT: \(error.localizedDescription)") }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.log("recv fail \(error.localizedDescription)")
                if !self.closed {
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
        log("msg \(text.prefix(160))")
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "transcript.created":
            flushPending()
            onStatus?("Listening for customer questions…")
        case "transcript.partial":
            let spoken = (obj["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !spoken.isEmpty else { return }
            let isFinal = obj["is_final"] as? Bool ?? false
            let speechFinal = obj["speech_final"] as? Bool ?? false
            onPartial?(spoken)
            if speechFinal || isFinal {
                onFinal?(spoken)
            }
        case "transcript.done":
            if let spoken = obj["text"] as? String, !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onFinal?(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "error":
            onError?(obj["message"] as? String ?? "Grok STT error")
        default:
            break
        }
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
