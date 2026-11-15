// InsightsView.swift — who you talked to, for how long, and an AI summary.
// Numbers come from Databricks SQL over workspace.visense.transcripts (this user
// only); the visense-chat model writes the summary from those exact numbers.
import Charts
import SwiftUI

struct InsightsView: View {
    @EnvironmentObject var sync: TranscriptSync
    @Environment(\.dismiss) private var dismiss

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var interval: DateInterval {
            let now = Date()
            switch self {
            case .today: return DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
            case .week:  return DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
            case .month: return DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: now)
            }
        }
    }

    @State private var period: Period = .week
    @State private var stats: ConversationAgent.Stats?
    @State private var loading = false
    @State private var error: String?
    @State private var summary: String?
    @State private var summarizing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.footnote) }
                    if loading && stats == nil { ProgressView("Crunching on Databricks…").frame(maxWidth: .infinity) }

                    if let st = stats {
                        if st.speakers.isEmpty {
                            Text("Nothing recorded in this period yet.").foregroundStyle(.secondary)
                        } else {
                            kpis(st)
                            chart(st)
                            summaryCard(st)
                            people(st)
                        }
                    }
                    Label("Computed with Databricks SQL · \(DatabricksSQL.table("transcripts"))", systemImage: "cylinder.split.1x2")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Insights")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: period) { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: Pieces

    private func kpis(_ st: ConversationAgent.Stats) -> some View {
        let named = st.speakers.filter { $0.who != ConversationAgent.unknownSpeaker }.count
        return HStack(spacing: 10) {
            kpi(minutes(st.totalMinutes), "talk time")
            kpi("\(named)", named == 1 ? "person" : "people")
            kpi("\(st.conversations.count)", "conversations")
        }
    }

    private func kpi(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private func chart(_ st: ConversationAgent.Stats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talk time per person").font(.headline)
            Chart(st.speakers) { s in
                BarMark(x: .value("Minutes", s.minutes), y: .value("Person", s.who))
                    .foregroundStyle(s.who == ConversationAgent.unknownSpeaker ? Color.gray.opacity(0.5) : Color.accentColor)
                    .annotation(position: .trailing) {
                        Text(minutes(s.minutes)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxisLabel("minutes")
            .frame(height: CGFloat(max(1, st.speakers.count)) * 38 + 30)
        }
    }

    private func summaryCard(_ st: ConversationAgent.Stats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI summary", systemImage: "sparkles").font(.headline)
                Spacer()
                if summarizing { ProgressView() }
            }
            if let summary {
                Text(summary).textSelection(.enabled)
            } else {
                Button("Summarize \(period == .today ? "my day" : "this period")") { Task { await summarize(st) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(summarizing)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
    }

    private func people(_ st: ConversationAgent.Stats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.headline)
            ForEach(st.speakers) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.who).font(.subheadline.bold())
                    Text("\(minutes(s.minutes)) · \(s.lines) lines · \(s.conversations) conversation\(s.conversations == 1 ? "" : "s") · last \(s.last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func minutes(_ m: Double) -> String {
        m < 1 ? String(format: "%.0f s", m * 60) : (m < 60 ? String(format: "%.0f min", m) : String(format: "%.1f h", m / 60))
    }

    // MARK: Loading

    private func load() async {
        loading = true; summary = nil; error = nil
        do {
            let st = try await ConversationAgent.speakerStats(user: sync.userID, window: period.interval)
            await MainActor.run { stats = st; loading = false }
        } catch {
            await MainActor.run { self.error = error.localizedDescription; loading = false }
        }
    }

    private func summarize(_ st: ConversationAgent.Stats) async {
        summarizing = true
        do {
            let text = try await ConversationAgent.answerAnalytics(
                "Summarize who I talked to, for how long and about what, with any patterns worth noticing.",
                history: [], window: period.interval, stats: st)
            await MainActor.run { summary = text; summarizing = false }
        } catch {
            await MainActor.run { self.error = error.localizedDescription; summarizing = false }
        }
    }
}
