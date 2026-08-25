import AppKit
import ApplicationServices
import Foundation

struct SpeakerLabel: Equatable {
    enum Role: Equatable {
        case remote
        case me
    }

    let role: Role
    let name: String?

    var displayName: String {
        name ?? (role == .remote ? "Customer" : "Me")
    }
}

enum RosterState: Equatable {
    case accessibilityDenied
    case zoomNotRunning
    case meetingNotDetected
    case tracking(participantCount: Int, localName: String?)
}

final class ZoomRoster {
    var onStateChange: ((RosterState) -> Void)?

    private struct ActiveSpeakerSample {
        let at: Date
        let name: String?
    }

    private struct ParsedParticipant {
        let name: String?
        let isLocal: Bool
    }

    private struct Candidate {
        let name: String
        let score: Int
    }

    private struct Snapshot {
        let meetingDetected: Bool
        let participantCount: Int
        let localName: String?
        let activeSpeaker: String?
    }

    private let queue = DispatchQueue(label: "cue.zoom-roster", qos: .utility)
    private let logURL = URL(fileURLWithPath: "/tmp/cue-zoom-roster.log")
    private var timer: DispatchSourceTimer?
    private var logHandle: FileHandle?
    private var samples: [ActiveSpeakerSample] = []
    private var localName: String?
    private var state: RosterState = .meetingNotDetected
    private var running = false

    func start() {
        Permissions.ensureAccessibility(promptIfNeeded: true)

        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.openLog()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            try? self.logHandle?.close()
            self.logHandle = nil
            self.samples.removeAll(keepingCapacity: true)
            self.localName = nil
            self.updateState(.meetingNotDetected)
        }
    }

    func label(for source: AudioSource, during interval: DateInterval) -> SpeakerLabel {
        queue.sync {
            switch source {
            case .mic:
                return SpeakerLabel(role: .me, name: localName)
            case .system:
                let padded = DateInterval(
                    start: interval.start.addingTimeInterval(-0.7),
                    end: interval.end.addingTimeInterval(0.7)
                )
                let relevant = samples.filter { padded.contains($0.at) }
                guard !relevant.isEmpty else {
                    return SpeakerLabel(role: .remote, name: nil)
                }

                let counts = relevant.compactMap(\.name).reduce(into: [String: Int]()) { counts, name in
                    counts[name, default: 0] += 1
                }
                guard let winner = counts.max(by: { $0.value < $1.value }),
                      Double(winner.value) / Double(relevant.count) >= 0.5
                else {
                    return SpeakerLabel(role: .remote, name: nil)
                }
                return SpeakerLabel(role: .remote, name: winner.key)
            }
        }
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            samples.removeAll(keepingCapacity: true)
            localName = nil
            updateState(.accessibilityDenied)
            log("state=accessibilityDenied")
            return
        }

        guard let zoom = NSRunningApplication.runningApplications(
            withBundleIdentifier: "us.zoom.xos"
        ).first else {
            samples.removeAll(keepingCapacity: true)
            localName = nil
            updateState(.zoomNotRunning)
            log("state=zoomNotRunning")
            return
        }

        let snapshot = inspect(application: AXUIElementCreateApplication(zoom.processIdentifier))
        guard snapshot.meetingDetected else {
            appendSample(name: nil)
            updateState(.meetingNotDetected)
            log("state=meetingNotDetected")
            return
        }

        if let detectedLocalName = snapshot.localName {
            localName = detectedLocalName
        }
        appendSample(name: snapshot.activeSpeaker)
        updateState(.tracking(participantCount: snapshot.participantCount, localName: localName))
        log(
            "state=tracking participants=\(snapshot.participantCount) " +
            "local=\(localName ?? "-") active=\(snapshot.activeSpeaker ?? "-")"
        )
    }

    private func inspect(application: AXUIElement) -> Snapshot {
        guard let windows: [AXUIElement] = attribute(kAXWindowsAttribute as CFString, from: application) else {
            return Snapshot(
                meetingDetected: false,
                participantCount: 0,
                localName: nil,
                activeSpeaker: nil
            )
        }

        var stack = windows.map { ($0, 0, false) }
        var visited = Set<CFHashCode>()
        var candidates: [Candidate] = []
        var participants = Set<String>()
        var detectedLocalName: String?
        var meetingSignals = Set<String>()
        var inspected = 0

        while let (element, depth, highlightedAncestor) = stack.popLast(), inspected < 4_000 {
            inspected += 1
            guard depth <= 18, visited.insert(CFHash(element)).inserted else { continue }

            let role: String = attribute(kAXRoleAttribute as CFString, from: element) ?? ""
            let selected: Bool = attribute(kAXSelectedAttribute as CFString, from: element) ?? false
            let focused: Bool = attribute(kAXFocusedAttribute as CFString, from: element) ?? false
            let highlighted = highlightedAncestor || selected || focused
            let strings = [
                attribute(kAXTitleAttribute as CFString, from: element) as String?,
                attribute(kAXDescriptionAttribute as CFString, from: element) as String?,
                stringValue(of: element)
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let joined = strings.joined(separator: " ").lowercased()
            collectMeetingSignals(in: joined, into: &meetingSignals)

            for text in strings {
                let parsed = parseParticipant(text)
                if parsed.isLocal, let name = parsed.name {
                    detectedLocalName = name
                    participants.insert(name)
                }

                if looksLikeParticipant(text: text, role: role), let name = parsed.name {
                    participants.insert(name)
                }

                if containsSpeakingMarker(text), let name = parsed.name {
                    participants.insert(name)
                    candidates.append(Candidate(name: name, score: 100))
                }
            }

            if highlighted {
                for text in strings where looksLikeParticipant(text: text, role: role) {
                    if let name = parseParticipant(text).name {
                        let score = selected ? 60 : (focused ? 50 : 40)
                        candidates.append(Candidate(name: name, score: score))
                    }
                }
            }

            if let children: [AXUIElement] = attribute(kAXChildrenAttribute as CFString, from: element) {
                stack.append(contentsOf: children.map { ($0, depth + 1, highlighted) })
            }
        }

        let activeSpeaker = candidates.max {
            if $0.score == $1.score { return $0.name.count > $1.name.count }
            return $0.score < $1.score
        }?.name
        let meetingDetected = activeSpeaker != nil || meetingSignals.count >= 2

        return Snapshot(
            meetingDetected: meetingDetected,
            participantCount: participants.count,
            localName: detectedLocalName,
            activeSpeaker: activeSpeaker
        )
    }

    private func attribute<T>(_ name: CFString, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func parseParticipant(_ raw: String) -> ParsedParticipant {
        let lowercased = raw.lowercased()
        let isLocal = lowercased.contains("(you)") ||
            lowercased.trimmingCharacters(in: .whitespacesAndNewlines) == "you"

        var name = raw
        let patterns = [
            #"(?i)\s+is\s+speaking\b"#,
            #"(?i)\bspeaking\b\s*:?\s*"#,
            #"(?i)\btalking\b\s*:?\s*"#,
            #"(?i)\s*\((host|guest|me|you)\)\s*"#
        ]
        for pattern in patterns {
            name = name.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        name = name
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        let rejected = [
            "", "you", "zoom", "zoom meeting", "meeting", "participants",
            "participant", "active speaker", "speaker", "talking", "mute", "unmute",
            "start video", "stop video", "share screen", "leave", "leave meeting",
            "end", "end meeting", "chat", "reactions", "more"
        ]
        return ParsedParticipant(
            name: rejected.contains(name.lowercased()) || name.count > 80 ? nil : name,
            isLocal: isLocal
        )
    }

    private func containsSpeakingMarker(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("is speaking") ||
            value.contains("speaking") ||
            value.contains("talking")
    }

    private func looksLikeParticipant(text: String, role: String) -> Bool {
        let value = text.lowercased()
        if value.contains("(host)") ||
            value.contains("(guest)") ||
            value.contains("(you)") ||
            value.contains("(me)") {
            return true
        }
        let participantRoles = ["axcell", "axrow", "axgroup", "aximage"]
        let controlWords = [
            "mute", "video", "screen", "meeting", "chat", "reaction",
            "participant", "record", "caption", "security", "invite"
        ]
        return participantRoles.contains(role.lowercased()) &&
            text.count <= 80 &&
            !text.contains("\n") &&
            !controlWords.contains(where: value.contains) &&
            parseParticipant(text).name != nil
    }

    private func collectMeetingSignals(in text: String, into signals: inout Set<String>) {
        if text.contains("mute") || text.contains("unmute") { signals.insert("mute") }
        if text.contains("participants") { signals.insert("participants") }
        if text.contains("leave meeting") || text.contains("end meeting") { signals.insert("leave") }
        if text.contains("start video") || text.contains("stop video") { signals.insert("video") }
        if text.contains("share screen") { signals.insert("share") }
    }

    private func appendSample(name: String?) {
        let now = Date()
        samples.append(ActiveSpeakerSample(at: now, name: name))
        samples.removeAll { now.timeIntervalSince($0.at) > 5 }
    }

    private func updateState(_ newState: RosterState) {
        guard state != newState else { return }
        state = newState
        let callback = onStateChange
        DispatchQueue.main.async {
            callback?(newState)
        }
    }

    private func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? logHandle?.write(contentsOf: Data(line.utf8))
    }
}
