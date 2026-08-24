import SwiftUI
import AppKit

@available(macOS 14.2, *)
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @AppStorage(WindowPin.defaultsKey) private var pinned = false

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()
            HSplitView {
                transcriptPane
                    .frame(minWidth: 320)
                cuePane
                    .frame(minWidth: 380)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("CUE")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(2)
                    Text(model.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    pinned.toggle()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .help(pinned ? "Stop floating above other apps" : "Keep Cue above other apps during a call")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(model.phase == .listening ? "Stop" : "Listen") {
                    model.toggleListen()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .tint(model.phase == .listening ? .red : .purple)
                .accessibilityLabel(model.phase == .listening ? "Stop" : "Listen")
                .accessibilityIdentifier("cue-listen")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .onAppear { model.loadKey() }
        .onChange(of: pinned) { _, newValue in
            if let window = NSApp.windows.first(where: { $0.title == "Cue" }) {
                WindowPin.apply(to: window, pinned: newValue)
            }
        }
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("LIVE")
            Text(rosterStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            LevelMeter(level: model.level, live: model.phase == .listening)
            if let err = model.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.transcript.isEmpty && model.livePartial.isEmpty {
                            Text(model.phase == .listening
                                 ? "Waiting for speech…"
                                 : "Hit Listen. Cue taps system audio natively — no BlackHole.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(model.transcript) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(line.label.displayName)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(line.label.role == .remote ? Color.purple : Color.green)
                                    Text(line.at.formatted(date: .omitted, time: .standard))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(line.text)
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                        if !model.livePartial.isEmpty {
                            Text(model.livePartial)
                                .italic()
                                .foregroundStyle(.purple.opacity(0.85))
                                .id("partial")
                        }
                    }
                    .padding(.trailing, 8)
                }
                .onChange(of: model.transcript.count) { _, _ in
                    if !model.livePartial.isEmpty {
                        proxy.scrollTo("partial", anchor: .bottom)
                    } else if let last = model.transcript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
    }

    private var rosterStatus: String {
        switch model.rosterState {
        case .accessibilityDenied:
            return "Grant Accessibility for names"
        case .zoomNotRunning:
            return "Zoom tags: Zoom not running"
        case .meetingNotDetected:
            return "Zoom tags: meeting not detected"
        case .tracking(let participantCount, _):
            return "Zoom tags: tracking \(participantCount)"
        }
    }

    private var cuePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("SAY THIS")
            if model.cues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Customer questions land here as short answers you can read out.")
                        .foregroundStyle(.secondary)
                    if let q = model.lastQuestion {
                        Text("Last heard: \(q)")
                            .font(.callout)
                    }
                }
                .padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.cues) { card in
                            AnswerCardView(card: card) {
                                model.dismiss(card)
                            }
                        }
                    }
                }
            }
            if model.coachingEnabled {
                header("COACH")
                if model.coaching.isEmpty {
                    Text("Coaching notes appear here as the call progresses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.coaching) { note in
                                CoachingNoteView(note: note) {
                                    model.dismissCoaching(note)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.03))
    }

    private func header(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Spacer()
            if title == "LIVE" {
                Button(model.phase == .listening ? "Stop" : "Listen") {
                    model.toggleListen()
                }
                .buttonStyle(.borderedProminent)
                .tint(model.phase == .listening ? .red : .purple)
                .accessibilityLabel(model.phase == .listening ? "Stop" : "Listen")
            }
        }
    }
}

struct AnswerCardView: View {
    let card: AnswerCard
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.question)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(card.answer.isEmpty ? "(skipped — not a real question)" : card.answer)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            sourceSection
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.sourcedAnswer ?? card.answer, forType: .string)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.35)))
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch card.sourceState {
        case .none:
            EmptyView()
        case .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking everysphere + docs…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text("No matching docs or past calls.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .declined:
            VStack(alignment: .leading, spacing: 2) {
                Text("Docs matched but didn’t answer this directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !card.sourceFiles.isEmpty {
                    Text("Looked at: " + card.sourceFiles.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        case .failed:
            Text("Source lookup failed.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .done:
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(card.sourcedAnswer ?? "")
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Text("From: " + card.sourceFiles.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }
}

struct CoachingNoteView: View {
    let note: CoachingNote
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.kind.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            Text(note.content)
                .font(.callout)
                .textSelection(.enabled)
            if let suggestion = note.suggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3)))
    }
}

struct LevelMeter: View {
    let level: Float
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(live ? Color.purple : Color.gray.opacity(0.4))
                    .frame(width: max(8, geo.size.width * CGFloat(level)))
            }
        }
        .frame(height: 8)
    }
}

@available(macOS 14.2, *)
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                settingsForm
                    .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Toggle("Also capture microphone (you + them if they’re in the room)", isOn: $model.includeMic)
            Text("System audio (Zoom/Meet/browser) uses a Core Audio process tap. No BlackHole, no Multi-Output Device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Coaching notes (objections, questions to ask)", isOn: $model.coachingEnabled)
            Toggle("Save transcripts (searched as part of the knowledge base)", isOn: $model.saveTranscripts)
            HStack(spacing: 8) {
                Text(TranscriptStore.sessionsDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([TranscriptStore.sessionsDirectory])
                }
                .font(.caption)
            }
            Toggle("Ground answers in a local repo/docs search", isOn: $model.sourceSearchEnabled)
            if model.sourceSearchEnabled {
                TextField("Knowledge repo path", text: $model.sourceRoot)
                    .textFieldStyle(.roundedBorder)
                Text("Markdown in this repo is searched when a question is detected; a grounded answer with file citations is added to the card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("xAI API key")
                .font(.headline)
            SecureField("xai-…", text: $model.apiKeyField)
                .textFieldStyle(.roundedBorder)
            Text("Call context / facts Cue is allowed to use")
                .font(.headline)
            TextEditor(text: $model.contextNotes)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
            Text("Paste product facts, pricing you can say, competitive notes. Cue will not invent numbers that aren’t here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
