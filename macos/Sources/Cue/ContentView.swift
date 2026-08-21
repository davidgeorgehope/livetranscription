import SwiftUI
import AppKit

@available(macOS 14.2, *)
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false

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
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .onAppear { model.saveSettings() }
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("LIVE")
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
                        if model.transcript.isEmpty {
                            Text(model.phase == .listening
                                 ? "Waiting for speech…"
                                 : "Hit Listen. Cue taps system audio natively — no BlackHole.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(model.transcript) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.at.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(line.text)
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .onChange(of: model.transcript.count) { _, _ in
                    if let last = model.transcript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
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
        }
        .padding(16)
        .background(Color.white.opacity(0.03))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(.secondary)
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
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.answer, forType: .string)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Toggle("Also capture microphone (you + them if they’re in the room)", isOn: $model.includeMic)
            Text("System audio (Zoom/Meet/browser) uses a Core Audio process tap. No BlackHole, no Multi-Output Device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("OpenAI API key")
                .font(.headline)
            SecureField("sk-…", text: $model.apiKeyField)
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
            HStack {
                Spacer()
                Button("Save") {
                    model.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
    }
}
