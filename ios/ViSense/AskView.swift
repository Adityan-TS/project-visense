// AskView.swift — Recall: questions over saved transcripts.
import SwiftUI

struct AskTurn: Identifiable {
    let id = UUID()
    var message: ChatMessage
    var window: DateInterval? = nil
    var lines = 0
}

struct AskView: View {
    @EnvironmentObject var sync: TranscriptSync
    @EnvironmentObject var cc: CaptionController
    @EnvironmentObject var nav: AppNav

    @State private var turns: [AskTurn] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var error: String?
    @State private var showData = false
    @State private var showInsights = false
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Who did I talk to most this week?",
        "Summarize my last conversation",
        "What was said around 3 PM?",
    ]

    private let focusSuggestions = [
        "Summarize this conversation",
        "List action items and dates",
        "What questions came up?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            header.vsReveal(0)
                            if turns.isEmpty { emptyState.vsReveal(1) }
                            ForEach(Array(turns.enumerated()), id: \.element.id) { i, t in
                                bubble(t).vsReveal(min(i + 2, 8))
                            }
                            if thinking { thinkingRow }
                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(VSColor.warn)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: thinking) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }

                if let f = nav.askFocus { focusChip(f) }
                inputBar
            }
            .onChange(of: nav.askFocus) { _, _ in turns = []; error = nil }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showData) { MyDataView() }
            .sheet(isPresented: $showInsights) { InsightsView() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VSSectionHeader("Recall", subtitle: "Ask across everything you've captured.")
            Spacer()
            Button { showInsights = true } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title3)
                    .foregroundStyle(VSColor.inkMuted)
            }
            Button { showData = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(VSColor.inkMuted)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            syncStatus
            Button { showInsights = true } label: {
                Label("Insights: who you talked to, and for how long", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(VSChipButtonStyle())
            FlowSuggestions(items: nav.askFocus == nil ? suggestions : focusSuggestions) { send($0) }
                .disabled(thinking)
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(VSColor.accent)
            Text("Tracing your transcripts…")
                .font(.subheadline)
                .foregroundStyle(VSColor.inkMuted)
        }
        .padding(14)
        .glass(radius: 16)
    }

    private func focusChip(_ f: ConversationFocus) -> some View {
        HStack {
            Label(f.title, systemImage: "scope")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button { nav.askFocus = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(VSColor.inkFaint)
            }
        }
        .foregroundStyle(VSColor.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(VSColor.accentSoft)
    }

    private var syncStatus: some View {
        Group {
            if !DatabricksConfig.isConfigured {
                Label("Connect Databricks in Secrets.xcconfig", systemImage: "xmark.octagon")
                    .foregroundStyle(VSColor.danger)
            } else if let e = sync.lastError {
                Label("Upload paused: \(e)", systemImage: "icloud.slash").foregroundStyle(VSColor.warn)
            } else {
                Label("\(sync.uploaded) synced · \(sync.pending) queued", systemImage: "checkmark.icloud")
                    .foregroundStyle(VSColor.live)
            }
        }
        .font(.footnote)
    }

    private func bubble(_ t: AskTurn) -> some View {
        let mine = t.message.role == "user"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 8) {
            Text(t.message.content)
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(VSColor.ink)
                .padding(14)
                .glass(radius: 18, stroke: mine ? VSColor.accent.opacity(0.5) : Color.white.opacity(0.1))
                .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)

            if !mine {
                HStack(spacing: 12) {
                    if let w = t.window {
                        Text("\(t.lines) lines · \(w.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(VSColor.inkFaint)
                    }
                    Button { showOnGlasses(t.message.content) } label: {
                        Label("Glasses", systemImage: "eyeglasses").font(.caption)
                    }
                    .buttonStyle(VSChipButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about a time, topic, or thread…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(input) }
                .padding(12)
                .glass(radius: 16)

            Button { send(input) } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(VSColor.canvas)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(VSColor.accent))
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.bottom, 88)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        input = ""; inputFocused = false; error = nil
        let history = turns.map(\.message)
        withAnimation(VSMotion.tap) {
            turns.append(AskTurn(message: ChatMessage(role: "user", content: q)))
        }
        thinking = true
        Task {
            do {
                let a = try await ConversationAgent.ask(q, history: history, focus: nav.askFocus?.window)
                await MainActor.run {
                    withAnimation(VSMotion.reveal) {
                        turns.append(AskTurn(message: ChatMessage(role: "assistant", content: a.text),
                                             window: a.window, lines: a.lines))
                    }
                    thinking = false
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; thinking = false }
            }
        }
    }

    private func showOnGlasses(_ answer: String) {
        let flat = answer.replacingOccurrences(of: "\n", with: " ")
        let first = flat.split(separator: ".", maxSplits: 1).first.map(String.init) ?? flat
        cc.sendTyped(String(first.prefix(80)), final: true)
    }
}

/// Wrapped suggestion chips (no lazy grid reflow jank).
private struct FlowSuggestions: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                Button { action(s) } label: {
                    Text(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(VSChipButtonStyle())
                .vsReveal(i + 2)
            }
        }
    }
}

struct MyDataView: View {
    @EnvironmentObject var sync: TranscriptSync
    @EnvironmentObject var store: TranscriptStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        Group {
                            row("Workspace", DatabricksConfig.host.host ?? "—")
                            row("Model", DatabricksConfig.endpoint)
                            row("User", String(sync.userID.prefix(8)) + "…")
                            row("Queue", "\(sync.uploaded) up · \(sync.pending) wait")
                        }
                        .padding(16)
                        .glass(radius: 18)

                        Button("Delete all transcripts", role: .destructive) { confirmDelete = true }
                            .buttonStyle(VSChipButtonStyle())
                        if let status { Text(status).font(.footnote).foregroundStyle(VSColor.inkMuted) }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Your data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(VSColor.accent)
                }
            }
            .confirmationDialog("Delete everything on this phone and in Databricks?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteAll() }
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(VSColor.inkFaint)
            Spacer()
            Text(value).foregroundStyle(VSColor.ink).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func deleteAll() {
        store.deleteAll()
        status = "Deleting…"
        Task {
            do {
                _ = try await DatabricksSQL.run("DELETE FROM \(DatabricksSQL.table("transcripts")) WHERE user_id = :u",
                                                [SQLParam(name: "u", value: sync.userID)])
                await MainActor.run { status = "Deleted." }
            } catch {
                await MainActor.run { status = "Failed: \(error.localizedDescription)" }
            }
        }
    }
}