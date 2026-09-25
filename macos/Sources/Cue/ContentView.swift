import SwiftUI
import AppKit
import UniformTypeIdentifiers

@available(macOS 14.2, *)
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showTrack = false
    /// nil = follow the newest card. Set when the user taps an earlier one;
    /// cleared when a new card arrives so live answers always take over.
    @State private var focusedID: UUID?
    @AppStorage(WindowPin.defaultsKey) private var pinned = false
    @AppStorage("cue.transcriptExpanded") private var transcriptExpanded = false
    @State private var dropTargeted = false
    @State private var showBriefPopover = false
    @State private var briefTopic = ""

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                askRow
                prepRow
                errorBlock
                callBanner
                statusRibbon
                if let card = focusedCard {
                    FocusCardView(card: card, isLatest: card.id == model.cues.first?.id) {
                        model.dismiss(card)
                    }
                } else {
                    emptyState
                }
                coachingChips
                historyStrip
                Spacer(minLength: 0)
                transcriptDock
            }
            .padding(16)
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8)
                    .overlay(
                        Text("Drop prep docs for this call")
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.7)))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty { model.attachPrep(urls) }
            }
            return true
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showTrack.toggle() } label: {
                    Image(systemName: "checklist")
                        .overlay(alignment: .topTrailing) {
                            if !model.commitments.isEmpty {
                                Text("\(model.commitments.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.cyan))
                                    .foregroundStyle(.black)
                                    .offset(x: 9, y: -7)
                            }
                        }
                }
                .help("Commitments, decisions and open questions from this call")
                .popover(isPresented: $showTrack, arrowEdge: .bottom) { trackPopover }
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
                WrapSheetView(
                    wrap: wrap,
                    onDone: { model.showWrapSheet = false },
                    canSend: model.canSendWrap,
                    sendState: model.wrapSend,
                    onSend: { model.sendWrapToBot() }
                )
            }
        }
        .onAppear { model.loadKey() }
        .onChange(of: model.cues.first?.id) { _, _ in focusedID = nil }
        .onChange(of: pinned) { _, newValue in
            if let window = NSApp.windows.first(where: { $0.title == "Cue" }) {
                WindowPin.apply(to: window, pinned: newValue)
            }
        }
    }

    private var focusedCard: AnswerCard? {
        if let focusedID, let card = model.cues.first(where: { $0.id == focusedID }) {
            return card
        }
        return model.cues.first
    }

    private var historyCards: [AnswerCard] {
        model.cues.filter { $0.id != focusedCard?.id }
    }

    // MARK: - Rows

    private var askRow: some View {
        HStack(spacing: 8) {
            Picker("Meeting", selection: Binding(
                get: { model.meetingType },
                set: { model.setMeetingType($0) }
            )) {
                ForEach(MeetingType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 118)
            .accessibilityLabel("Meeting type")
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
        .help(model.hasKey ? "Ask Cue using recent transcript or selected session" : "Add an xAI API key in Settings or .env")
    }

    /// Prep attached for this call. Files drop anywhere on the window or via +;
    /// anything an automation writes to prep/inbox is swept in on Listen.
    private var prepRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("PREP")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                ForEach(model.prepDocs) { doc in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text(doc.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button { model.removePrep(doc) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 260)
                    .background(Capsule().fill(Color.cyan.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.cyan.opacity(0.3)))
                    .help(doc.url.path)
                }
                Button(action: pickPrep) {
                    Label(model.prepDocs.isEmpty ? "Add prep docs" : "Add", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Attach briefs, last-call notes, or pricing for this call (md, txt, pdf, docx). Or drop files on the window.")
                if model.grokBotHookConfigured {
                    Button { showBriefPopover = true } label: {
                        HStack(spacing: 4) {
                            if model.briefRequestInFlight || model.briefPending != nil {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(model.briefPending == nil ? "Grok Bot brief" : "Brief on the way…")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Ask your Grok Bot automation to research this call and drop a brief into PREP. Do this a few minutes before the call.")
                    .popover(isPresented: $showBriefPopover, arrowEdge: .bottom) { briefPopover }
                }
            }
        }
    }

    private var briefPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Grok Bot for a pre-call brief")
                .font(.headline)
            Text("Leave blank for the meeting you're in (or your next one), or say who it's with — company, people, agenda.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("The meeting I'm in, or my next one", text: $briefTopic, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendBriefRequest)
            HStack {
                Text(model.briefPending == nil
                     ? "Lands in PREP automatically when the bot finishes — can take several minutes."
                     : "Still waiting on “\(model.briefPending ?? "")”. It lands in PREP when Legend finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.briefPending != nil {
                    Button("Stop waiting") { model.clearBriefPending(); showBriefPopover = false }
                }
                Button("Request") { sendBriefRequest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.briefRequestInFlight)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func sendBriefRequest() {
        model.requestBrief(topic: briefTopic)
        briefTopic = ""
        showBriefPopover = false
    }

    private func pickPrep() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, .rtf, .html, UTType("net.daringfireball.markdown"),
                                     UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }
        panel.message = "Attach prep for this call"
        if panel.runModal() == .OK {
            model.attachPrep(panel.urls)
        }
    }

    @ViewBuilder
    private var errorBlock: some View {
        if let err = model.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("System Audio…") { Permissions.openSystemAudioRecordingSettings() }
                    Button("Microphone…") { Permissions.openMicrophoneSettings() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    /// Call boundary hints: a meeting app took the mic while idle, or let go
    /// of it (or the schedule ran out) while listening. Countdown is cancellable.
    @ViewBuilder
    private var callBanner: some View {
        if let hint = model.callHint {
            HStack(spacing: 10) {
                switch hint {
                case .callStarted(let app):
                    Image(systemName: "phone.arrow.down.left")
                        .foregroundStyle(Color.green)
                    Text("\(app) has the mic — on a call?")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Listen") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.small)
                    Button("Not now") { model.dismissCallHint() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                case .callEnding(let reason, let stopAt):
                    Image(systemName: "phone.down")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason)
                            .font(.callout)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(stopAt.timeIntervalSince(ctx.date).rounded(.up)))
                            Text("Stopping and writing the wrap in \(left)s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Stop now") { model.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    Button("Keep listening") { model.keepListening() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .callMaybeOver(let reason):
                    Image(systemName: "phone.down")
                        .foregroundStyle(Color.orange)
                    Text("\(reason) — call over?")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Stop") { model.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    Button("Keep listening") { model.keepListening() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        }
    }

    /// One quiet line so it is obvious Cue is working between cards.
    private var statusRibbon: some View {
        let busy = model.phase == .listening && (model.draftsInFlight > 0 || model.analysisInFlight)
        return HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
            }
            Text(busy
                 ? (model.draftsInFlight > 0 ? "Drafting an answer…" : "Listening for questions…")
                 : model.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.meetingType.emptyStateCopy)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let q = model.lastQuestion {
                Text("Last heard: \(q)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var coachingChips: some View {
        if model.coachingEnabled, !model.coaching.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if model.coaching.count > 3 {
                    header("COACHING · \(model.coaching.count)")
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.coaching) { note in
                            CoachingChip(note: note) { model.dismissCoaching(note) }
                        }
                    }
                }
                // About three rows; scrolls beyond that so history keeps its space.
                .frame(maxHeight: 190)
            }
        }
    }

    @ViewBuilder
    private var historyStrip: some View {
        if !historyCards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header("EARLIER")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(historyCards) { card in
                            HistoryRow(card: card)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Latest line + live partial as a ticker; the chevron opens the full
    /// transcript. Listening state stays visible via the level meter.
    private var transcriptDock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if transcriptExpanded {
                header("TRANSCRIPT")
                transcriptList
                    .frame(height: 220)
            }
            HStack(alignment: .center, spacing: 10) {
                Button(model.phase == .listening ? "Stop" : "Listen") {
                    model.toggleListen()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .tint(model.phase == .listening ? .red : .purple)
                .accessibilityLabel(model.phase == .listening ? "Stop" : "Listen")
                .accessibilityIdentifier("cue-listen")
                if model.phase != .listening {
                    Button("New call") { model.newCall() }
                        .disabled(!model.hasCallContent && model.prepDocs.isEmpty)
                        .keyboardShortcut("n", modifiers: [.command])
                        .buttonStyle(.bordered)
                        .help("Clear the last call's cards and transcript. Prep stays attached.")
                }
                LevelMeter(level: model.level, live: model.phase == .listening)
                    .frame(width: 48)
                tickerText
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { transcriptExpanded.toggle() }
                } label: {
                    Image(systemName: transcriptExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(transcriptExpanded ? "Hide transcript" : "Show transcript")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private var tickerText: some View {
        if !model.livePartial.isEmpty {
            Text(model.livePartial)
                .italic()
                .foregroundStyle(.purple.opacity(0.85))
                .lineLimit(2)
        } else if let last = model.transcript.last {
            (Text(last.speaker.rawValue + "  ").bold().foregroundStyle(last.speaker == .them ? .purple : .green)
             + Text(last.text))
                .font(.callout)
                .lineLimit(2)
        } else {
            Text(model.phase == .listening
                 ? "Waiting for speech…"
                 : "Cue taps system audio natively — no BlackHole.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.transcript) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(line.speaker.rawValue)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(line.speaker == .them ? Color.purple : Color.green)
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
            .onAppear {
                if let last = model.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
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

    private var trackPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(.secondary)
    }
}

/// The dominant card: one answer, and a single line saying how much to trust it.
private struct AnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct FocusCardView: View {
    @State private var answerHeight: CGFloat = 0
    let card: AnswerCard
    let isLatest: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(card.origin == .lookup ? "CONTEXT" : card.origin == .userAsk ? "YOU ASKED" : "THEY ASKED")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(card.origin == .lookup ? Color.teal : card.origin == .userAsk ? Color.cyan : Color.purple)
                Text(card.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !isLatest {
                    Text("EARLIER")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.displayAnswer, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Text(card.question)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if card.isPlaceholder {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking it up…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                // Long answers scroll inside the card instead of drawing over
                // the rows below it. Height tracks the text up to a cap.
                ScrollView {
                    Text(card.displayAnswer.isEmpty ? "(skipped — not a real question)" : card.displayAnswer)
                        .font(.title3.weight(.semibold))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: AnswerHeightKey.self, value: geo.size.height)
                        })
                }
                .onPreferenceChange(AnswerHeightKey.self) { answerHeight = $0 }
                .frame(height: min(max(answerHeight, 24), FocusCardView.maxAnswerHeight))
            }
            groundingLine
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.35)))
        .clipped()
    }

    static let maxAnswerHeight: CGFloat = 260

    @ViewBuilder
    private var groundingLine: some View {
        switch card.sourceState {
        case .none:
            EmptyView()
        case .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking knowledge base…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .done:
            let docs = card.sourceFiles.filter { $0 != "live-dialogue" }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: docs.isEmpty ? "waveform" : "checkmark.seal.fill")
                    .foregroundStyle(docs.isEmpty ? Color.secondary : Color.green)
                Text(docs.isEmpty ? "From this call" : "Grounded · " + docs.joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .empty, .declined:
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("From the call only — no doc backs this.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed:
            Text("Couldn’t reach xAI for the docs pass — showing the quick answer.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// A past answer. Click to expand in place; rows never leave the list, so
/// selecting or copying text is always possible.
struct HistoryRow: View {
    let card: AnswerCard
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(card.isGrounded ? Color.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.question)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .textSelection(.enabled)
                Text(card.displayAnswer)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .textSelection(.enabled)
                if expanded {
                    let docs = card.sourceFiles.filter { $0 != "live-dialogue" }
                    if !docs.isEmpty {
                        Text(docs.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.displayAnswer, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy answer")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(.borderless)
                .help(expanded ? "Collapse" : "Show full answer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(expanded ? 0.07 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }
}

struct CoachingChip: View {
    let note: CoachingNote
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(note.kind.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.content)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let suggestion = note.suggestion, !suggestion.isEmpty {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25)))
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

@available(macOS 14.2, *)
struct WrapSheetView: View {
    let wrap: CallWrap
    let onDone: () -> Void
    var canSend = false
    var sendState: AppModel.WrapSendState = .idle
    var onSend: () -> Void = {}

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
            HStack(spacing: 10) {
                Button("Copy follow-up") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(wrap.followUpDraft, forType: .string)
                }
                if canSend {
                    switch sendState {
                    case .idle:
                        Button("Send to Grok Bot", action: onSend)
                    case .sending:
                        ProgressView().controlSize(.small)
                        Text("Sending to Grok Bot…").font(.caption).foregroundStyle(.secondary)
                    case .sent:
                        Label("Grok Bot has it", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.green)
                        Button("Send again", action: onSend).controlSize(.small)
                    case .failed(let why):
                        Text(why).font(.caption).foregroundStyle(.red).lineLimit(2)
                        Button("Retry", action: onSend).controlSize(.small)
                    }
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
        .frame(width: 560, height: 620)
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
            Text("“Me” is your microphone, always on; “Them” is system audio (Zoom/Meet/browser) from a Core Audio process tap. No BlackHole, no Multi-Output Device. On speakers your mic hears the call too — headphones keep “Me” clean.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Coaching notes (objections, questions to ask)", isOn: $model.coachingEnabled)
            Toggle("Save transcripts (searched as part of the knowledge base)", isOn: $model.saveTranscripts)
            Toggle("Start listening when a meeting on today's calendar begins", isOn: $model.autoStartOnCallStart)
            Toggle("Stop automatically when the call ends (30s countdown you can cancel)", isOn: $model.autoStopOnCallEnd)
            Text("Cue watches which app holds the microphone — Zoom, Teams, Chrome for Meet. When the app takes it during a calendar meeting Cue hasn't listened to, Cue starts (Stop or Not now skips that meeting; calls not on the calendar just get the banner). When it lets go, or the scheduled end has passed and the room is quiet, Cue stops and writes the wrap. If the app hops straight into your next meeting, Cue saves the last call and starts a new one. The schedule comes from today's calendar (GROK_BOT_CALENDAR_URL and GROK_BOT_CALENDAR_KEY in .env" + (model.grokBotCalendarConfigured ? ", configured)" : ", not set)") + " or the brief's meeting times.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Hand the wrap to Grok Bot for the summary and follow-ups", isOn: $model.sendWrapToGrokBot)
            Text("Needs GROK_BOT_SUM_URL and GROK_BOT_SUM_KEY in .env" + (model.grokBotWrapConfigured ? " (configured)." : " (not set).") + " Sends the summary, commitments, draft follow-up, an excerpt of the transcript, and the paths of the saved transcript and wrap so the bot can read the whole call. Calls under ~120 words are not sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Prep inbox")
                .font(.headline)
            HStack(spacing: 8) {
                Text(PrepStore.inbox.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([PrepStore.inbox])
                }
                .font(.caption)
            }
            Text("Files written here are attached the moment they land (and on Listen), then archived with the call's transcript. The PREP row's “Grok Bot brief” button asks your automation to write one here; it needs GROK_BOT_HOOK_URL and GROK_BOT_HOOK_KEY in .env" + (model.grokBotHookConfigured ? " (configured)." : " (not set)."))
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Optional override — leave empty to use `XAI_API_KEY` from the repo `.env` (or the process environment). Save with a value to pin it in Keychain; clear and Save to fall back to `.env`.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
