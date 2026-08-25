import SwiftUI
import AppKit

@available(macOS 14.2, *)
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @State private var showSessions = false
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
                    model.refreshSessions()
                    showSessions = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .help("Past calls")
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
        .sheet(isPresented: $showSessions) {
            SessionsBrowserView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showWrapSheet) {
            if let wrap = model.latestWrap {
                WrapSheetView(wrap: wrap) {
                    model.showWrapSheet = false
                }
            }
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
                    .foregroundStyle(.red.opacity(0.9))
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("System Audio…") { Permissions.openSystemAudioRecordingSettings() }
                    Button("Microphone…") { Permissions.openMicrophoneSettings() }
                    Button("Accessibility…") { Permissions.openAccessibilitySettings() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
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
            return "Zoom names need Accessibility — if Cue already shows On, remove it and re-enable (stale grant from an older build)."
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
            HStack {
                Text("SAY THIS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Meeting", selection: Binding(
                    get: { model.meetingType },
                    set: { model.setMeetingType($0) }
                )) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .labelsHidden()
                .accessibilityLabel("Meeting type")
            }
            askRow
            if model.cues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.meetingType.emptyStateCopy)
                        .foregroundStyle(.secondary)
                    if let q = model.lastQuestion {
                        Text("Last heard: \(q)")
                            .font(.callout)
                    }
                }
                .padding(.top, 12)
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
                    .frame(maxHeight: 180)
                }
            }
            header("TRACK")
            if model.commitments.isEmpty {
                Text(model.phase == .listening
                     ? "Commitments and open questions land here as the call progresses."
                     : "Start a call to capture commitments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.commitments) { item in
                            CommitmentRowView(item: item) {
                                model.dismissCommitment(item)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.03))
    }

    private var askRow: some View {
        HStack(spacing: 8) {
            TextField("Ask Cue…", text: $model.askDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.hasKey)
                .onSubmit { model.ask() }
            Button("Ask") { model.ask() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasKey || model.askDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .opacity(model.hasKey ? 1 : 0.55)
        .help(model.hasKey ? "Ask Cue using recent transcript or selected session" : "Add an xAI API key in Settings")
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
            if card.origin == .userAsk {
                Text("ASK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
            }
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
                Text("Checking knowledge base…")
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

struct CommitmentRowView: View {
    let item: CallCommitment
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.kind.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                Text(item.speaker)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            Text(item.text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3)))
    }

    private var color: Color {
        switch item.kind {
        case .commitment: return .cyan
        case .openQuestion: return .yellow
        case .decision: return .mint
        }
    }
}

@available(macOS 14.2, *)
struct SessionsBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Past calls")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") { model.refreshSessions() }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                if model.sessions.isEmpty {
                    Text("No saved transcripts yet. Hit Listen with “Save transcripts” on.")
                        .foregroundStyle(.secondary)
                        .padding(16)
                    Spacer()
                } else {
                    List(model.sessions, selection: Binding(
                        get: { model.selectedSession?.id },
                        set: { url in
                            if let url, let session = model.sessions.first(where: { $0.id == url }) {
                                model.openSession(session)
                            }
                        }
                    )) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.title)
                                    .font(.callout.weight(.semibold))
                                if session.hasWrap {
                                    Text("WRAP")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.purple)
                                }
                            }
                            Text("\(session.lineCount) lines")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !session.preview.isEmpty {
                                Text(session.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .tag(session.id)
                    }
                }
            }
            .frame(minWidth: 260)

            VStack(alignment: .leading, spacing: 0) {
                if let session = model.selectedSession {
                    HStack {
                        Text(session.title)
                            .font(.headline)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
                        }
                    }
                    .padding(12)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(model.selectedSessionBody)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let wrap = model.selectedSessionWrap, !wrap.isEmpty {
                                Divider()
                                Text("Wrap")
                                    .font(.headline)
                                Text(wrap)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    Text("Select a call to read the full transcript.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
        .frame(width: 900, height: 560)
        .onAppear {
            model.refreshSessions()
            if model.selectedSession == nil, let first = model.sessions.first {
                model.openSession(first)
            }
        }
    }
}

struct WrapSheetView: View {
    let wrap: CallWrap
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Call wrap")
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Summary")
                        .font(.headline)
                    Text(wrap.summary.isEmpty ? "(empty)" : wrap.summary)
                        .textSelection(.enabled)
                    if !wrap.commitments.isEmpty {
                        Text("Commitments & open questions")
                            .font(.headline)
                        ForEach(wrap.commitments) { item in
                            Text("• [\(item.kind.rawValue)] \(item.speaker): \(item.text)")
                                .textSelection(.enabled)
                        }
                    }
                    Text("Follow-up draft")
                        .font(.headline)
                    Text(wrap.followUpDraft.isEmpty ? "(empty)" : wrap.followUpDraft)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Copy follow-up") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(wrap.followUpDraft, forType: .string)
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
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
            Picker("Meeting type", selection: Binding(
                get: { model.meetingType },
                set: { model.setMeetingType($0) }
            )) {
                ForEach(MeetingType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            Text(model.meetingType.autoAnswerRemoteQuestions
                 ? "Sales auto-opens SAY THIS cards from remote questions."
                 : "Remote questions do not auto-card; use Ask Cue.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                TextField("Primary knowledge folder", text: $model.sourceRoot)
                    .textFieldStyle(.roundedBorder)
                Text("Additional folders (one path per line)")
                    .font(.headline)
                TextEditor(text: $model.extraSourceRoots)
                    .font(.body.monospaced())
                    .frame(minHeight: 72)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
                Text("Markdown under these paths is searched when a question is detected. Past Cue calls are included automatically when transcript saving is on.\n\nGrok Bot: point an agent at \(TranscriptStore.sessionsDirectory.path) to read Cue transcripts/wraps. To pull Grok Bot notes into Cue, dump markdown somewhere and add that folder above — do not point Cue at ~/.grokbot (daemon config + secrets, not docs).")
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
