// HistoryView.swift — Databricks conversations (glass cards).
import SwiftUI

final class AppNav: ObservableObject {
    enum Tab: Hashable { case captions, history, ask }
    @Published var tab: Tab = .captions
    @Published var askFocus: ConversationFocus?
}

struct ConversationFocus: Equatable {
    var window: DateInterval
    var title: String
}

struct HistoryView: View {
    @EnvironmentObject var sync: TranscriptSync
    @State private var sessions: [ConversationAgent.SessionInfo] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VSSectionHeader("Archive", subtitle: "Conversations synced to your workspace.")
                        .vsReveal(0)

                    statusCard.vsReveal(1)

                    if loaded && sessions.isEmpty && error == nil {
                        emptyCard.vsReveal(2)
                    }

                    ForEach(Array(groupedByDay.enumerated()), id: \.offset) { gi, group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.day)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VSColor.inkFaint)
                                .padding(.leading, 4)
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, s in
                                NavigationLink(value: s) {
                                    sessionCard(s)
                                }
                                .buttonStyle(.plain)
                                .vsReveal(2 + gi + i)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ConversationAgent.SessionInfo.self) { TranscriptDetailView(session: $0) }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
            .overlay {
                if loading && !loaded {
                    ProgressView()
                        .tint(VSColor.accent)
                        .padding(24)
                        .glass(radius: 16)
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cloud memory", systemImage: "cylinder.split.1x2")
                .font(.subheadline.weight(.semibold))
            if sync.pending > 0 {
                Text("\(sync.pending) lines still climbing to the cloud")
                    .font(.caption)
                    .foregroundStyle(VSColor.warn)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(VSColor.danger)
            }
        }
        .foregroundStyle(VSColor.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glass(radius: 18)
    }

    private var emptyCard: some View {
        Text("Nothing here yet. Run a live session on the first tab — lines land here about half a minute later.")
            .font(.subheadline)
            .foregroundStyle(VSColor.inkMuted)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(radius: 18)
    }

    private func sessionCard(_ s: ConversationAgent.SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timeRange(s))
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(s.lines) · \(duration(s))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(VSColor.inkFaint)
            }
            Text(s.firstLine)
                .font(.subheadline)
                .foregroundStyle(VSColor.inkMuted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(VSColor.ink)
        .padding(16)
        .glass(radius: 18)
        .modifier(VSSelectedStroke(selected: false))
    }

    private func timeRange(_ s: ConversationAgent.SessionInfo) -> String {
        "\(s.start.formatted(date: .omitted, time: .shortened)) – \(s.end.formatted(date: .omitted, time: .shortened))"
    }

    private func duration(_ s: ConversationAgent.SessionInfo) -> String {
        let m = Int(s.end.timeIntervalSince(s.start) / 60)
        return m < 1 ? "<1m" : "\(m)m"
    }

    private var groupedByDay: [(day: String, items: [ConversationAgent.SessionInfo])] {
        var out: [(day: String, items: [ConversationAgent.SessionInfo])] = []
        for s in sessions {
            let day = dayTitle(s.start)
            if out.last?.day == day { out[out.count - 1].items.append(s) } else { out.append((day, [s])) }
        }
        return out
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .complete, time: .omitted)
    }

    private func load() async {
        loading = true
        do {
            let s = try await ConversationAgent.sessionIndex(user: sync.userID, days: nil, limit: 200)
            await MainActor.run { sessions = s; error = nil; loaded = true; loading = false }
        } catch {
            await MainActor.run { self.error = error.localizedDescription; loaded = true; loading = false }
        }
    }
}

struct TranscriptDetailView: View {
    let session: ConversationAgent.SessionInfo
    @EnvironmentObject var nav: AppNav
    @State private var lines: [ConversationAgent.Line] = []
    @State private var loading = true
    @State private var error: String?
    @State private var mode: DetailMode = .transcript

    enum DetailMode: String, CaseIterable { case summary = "Highlights", transcript = "Transcript" }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header

                Picker("Mode", selection: $mode) {
                    ForEach(DetailMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .summary:
                    summaryPane.vsReveal(1)
                case .transcript:
                    transcriptPane.vsReveal(1)
                }
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if loading && lines.isEmpty {
                ProgressView().tint(VSColor.accent)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.start.formatted(date: .abbreviated, time: .shortened))
                .font(.title2.weight(.bold))
            Button {
                nav.askFocus = ConversationFocus(
                    window: DateInterval(start: session.start.addingTimeInterval(-1), end: session.end.addingTimeInterval(1)),
                    title: "\(session.start.formatted(date: .abbreviated, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))")
                nav.tab = .ask
            } label: {
                Label("Open in Recall", systemImage: "text.quote")
            }
            .buttonStyle(VSChipButtonStyle())
        }
        .foregroundStyle(VSColor.ink)
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lines.isEmpty {
                Text("Still loading lines…")
                    .foregroundStyle(VSColor.inkMuted)
            } else {
                Text("Overview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VSColor.inkFaint)
                Text(lines.prefix(3).map(\.text).joined(separator: " "))
                    .font(.body)
                    .foregroundStyle(VSColor.inkMuted)

                Text("First spoken lines")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VSColor.inkFaint)
                    .padding(.top, 8)
                ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { i, l in
                    Text("· \(l.text)")
                        .font(.subheadline)
                        .foregroundStyle(VSColor.ink)
                        .vsReveal(i + 2)
                }
            }
        }
        .padding(18)
        .glass(radius: 20)
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                Text(error).foregroundStyle(VSColor.danger).padding(.bottom, 8)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(l.time.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(VSColor.inkFaint)
                        .frame(width: 64, alignment: .leading)
                    Text(l.text)
                        .foregroundStyle(VSColor.ink)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 10)
                if i < lines.count - 1 {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .padding(16)
        .glass(radius: 20)
    }

    private func load() async {
        do {
            let l = try await ConversationAgent.sessionLines(session: session.id)
            await MainActor.run { lines = l; error = nil; loading = false }
        } catch {
            await MainActor.run { self.error = error.localizedDescription; loading = false }
        }
    }
}