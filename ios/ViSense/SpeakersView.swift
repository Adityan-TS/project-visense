// SpeakersView.swift — name the voices ViSense has heard ("Speaker 2" -> "Priya").
// Giving two speakers the same name merges them (fixes one person split in two).
import SwiftUI

struct SpeakersView: View {
    @EnvironmentObject var cc: CaptionController
    @Environment(\.dismiss) private var dismiss
    @State private var teachName = ""
    @State private var teachLeft = 0          // seconds left while recording
    @State private var teachStatus: String?
    private let teachSeconds = 8
    @State private var speakers: [SpeakerProfile] = []
    @State private var editing: SpeakerProfile?
    @State private var newName = ""
    @State private var confirmForget = false
    @State private var modelsReady = false
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmDeleteSelected = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Their name", text: $teachName)
                        .textInputAutocapitalization(.words)
                        .disabled(teachLeft > 0)
                    Button {
                        Task { await teach() }
                    } label: {
                        if teachLeft > 0 {
                            Label("Listening… \(teachLeft) s, keep talking", systemImage: "waveform")
                        } else {
                            Label("Record \(teachSeconds) seconds of their voice", systemImage: "mic.circle.fill")
                        }
                    }
                    .disabled(teachLeft > 0 || teachName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let teachStatus { Text(teachStatus).font(.footnote) }
                } header: {
                    Text("Teach a voice")
                } footer: {
                    Text("Ask the person to talk normally for \(teachSeconds) s near the mic you'll use. Recording again with the same name adds to their voice (e.g. in a noisy room).")
                }
                Section {
                    if !modelsReady {
                        Label("Loading voice models (first launch downloads them)…", systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if speakers.isEmpty {
                        Text("No voices yet. Start captions; each person who says a full sentence gets a speaker.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(speakers) { s in
                        Button {
                            if selecting {
                                if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
                            } else {
                                editing = s; newName = s.displayName ?? ""
                            }
                        } label: {
                            HStack {
                                if selecting {
                                    Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(s.id) ? Color.red : Color.secondary)
                                        .font(.title3)
                                }
                                Image(systemName: s.isNamed ? "person.crop.circle.fill" : "person.crop.circle.badge.questionmark")
                                VStack(alignment: .leading) {
                                    Text(s.label).font(.headline)
                                    Text("\(s.recordingCount) lines · last heard \(s.lastSeen.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !selecting { Image(systemName: "pencil").foregroundStyle(.secondary) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing) {          // swipe left: forget just this voice
                            Button(role: .destructive) { Task { await forget([s.id]) } } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Voiceprints stay on this iPhone. Tap to rename; same name as another speaker merges them. Swipe left to forget one voice, or tap Select to forget several.")
                }
                Section {
                    if selecting {
                        Button(role: .destructive) { confirmDeleteSelected = true } label: {
                            Label(selected.isEmpty ? "Select voices to forget" : "Forget \(selected.count) selected voice\(selected.count == 1 ? "" : "s")",
                                  systemImage: "trash")
                        }
                        .disabled(selected.isEmpty)
                    } else {
                        Button("Forget all voices", role: .destructive) { confirmForget = true }
                    }
                }
            }
            .navigationTitle("Speakers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !speakers.isEmpty {
                        Button(selecting ? "Cancel" : "Select") { selecting.toggle(); selected = [] }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Forget \(selected.count) voice\(selected.count == 1 ? "" : "s")? They'll be treated as new speakers next time.",
                                isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    let ids = selected
                    Task { await forget(ids); selecting = false; selected = [] }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .alert("Name this speaker", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { save() }
                Button("Cancel", role: .cancel) { editing = nil }
            }
            .confirmationDialog("Forget every saved voice? Speakers start again from Speaker 1.",
                                isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget all voices", role: .destructive) {
                    Task { await SpeakerRecognizer.shared.forgetAll(); await reload() }
                }
            }
        }
    }

    private func teach() async {
        let name = teachName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cc.running { cc.start() }                         // the mic must be on
        teachStatus = nil
        for left in stride(from: teachSeconds, to: 0, by: -1) {
            teachLeft = left
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        teachLeft = 0
        let audio = cc.recentAudio(seconds: Double(teachSeconds))
        do {
            let prints = try await SpeakerLabeler.shared.teachingVoiceprints(audio)
            let tag = await SpeakerRecognizer.shared.enroll(name: name, voiceprints: prints)
            teachStatus = tag.map { "Saved \($0.name)'s voice (\(prints.count) voiceprints)\($0.isNew ? "" : ", added to existing")." }
            teachName = ""
        } catch {
            teachStatus = error.localizedDescription
        }
        await reload()
    }

    private func forget(_ ids: Set<UUID>) async {
        for id in ids { await SpeakerRecognizer.shared.delete(id) }
        await reload()
    }

    private func reload() async {
        let s = await SpeakerRecognizer.shared.heardSpeakers()
        let ready = await SpeakerLabeler.shared.isReady
        await MainActor.run { speakers = s; modelsReady = ready }
    }

    private func save() {
        guard let s = editing else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        Task {
            // Same name as another speaker = same person: merge into that one.
            if let other = speakers.first(where: { $0.id != s.id && ($0.displayName ?? "").caseInsensitiveCompare(name) == .orderedSame }),
               !name.isEmpty {
                await SpeakerRecognizer.shared.merge(keep: other.id, remove: s.id)
            } else {
                await SpeakerRecognizer.shared.rename(s.id, to: name)
            }
            await reload()
        }
    }
}
