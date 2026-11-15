// ContentView.swift — live captions (glass, periwinkle, snap-responsive).
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var cc: CaptionController
    @EnvironmentObject var log: Log
    @State private var testText = "Hello glasses"
    @State private var showDebug = false
    @State private var controlsOpen = false
    @State private var showSpeakers = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header.vsReveal(0)
                transcriptCard.vsReveal(1)
                statusRow.vsReveal(2)
                startButton.vsReveal(3)
                quickControls.vsReveal(4)
                if controlsOpen { expandedControls.vsReveal(5) }
                debugDisclosure.vsReveal(6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
    }

    private var latencyText: String {
        guard let rec = cc.recognizerMs else { return "Latency will appear when you speak" }
        let oneWay = (ble.rttMs ?? 0) / 2
        let glasses = cc.source == .glasses && !cc.usingFallback
        let capture = glasses ? 20.0 : 25.0
        let total = capture + (glasses ? oneWay : 0) + rec + oneWay + Double(ble.status.drawMs)
        return String(format: "≈%.0f ms end-to-end", total)
    }

  private var header: some View {
      HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ViSense")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text("Words on the glass, in real time.")
                    .font(.footnote)
                    .foregroundStyle(VSColor.inkMuted)
            }
            Spacer()
            VSConnectionPill(connected: ble.state == .connected)
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(cc.running ? "Listening" : "Standby", systemImage: cc.running ? "dot.radiowaves.left.and.right" : "moon.zzz")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(cc.running ? VSColor.live : VSColor.inkFaint)
                Spacer()
                if cc.running {
                    LevelMeter(level: cc.level)
                        .frame(width: 88, height: 6)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(cc.lines.suffix(24).enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.body)
                                .foregroundStyle(VSColor.inkMuted)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        Text(cc.partial.isEmpty ? " " : cc.partial)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(VSColor.ink)
                            .id("live")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200, maxHeight: 280)
                .onChange(of: cc.partial) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
                .onChange(of: cc.lines.count) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
            }
        }
        .padding(18)
        .glass(radius: 24, stroke: cc.running ? VSColor.accent.opacity(0.35) : Color.white.opacity(0.12))
        .animation(.easeOut(duration: 0.2), value: cc.running)
    }

    private var statusRow: some View {
        HStack {
            Text(cc.speechStatus)
                .lineLimit(1)
            Spacer()
            Text(latencyText)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(VSColor.inkFaint)
    }

    private var startButton: some View {
        Button(action: { cc.running ? cc.stop() : cc.start() }) {
            Text(cc.running ? "Stop session" : "Start captions")
        }
        .buttonStyle(VSPrimaryButtonStyle(live: cc.running))
    }

    private var quickControls: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(VSMotion.tap) { controlsOpen.toggle() }
            } label: {
                Label(controlsOpen ? "Hide setup" : "Mic & display", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(VSChipButtonStyle())

            Button { cc.clear() } label: {
                Label("Clear", systemImage: "text.badge.xmark")
            }
            .buttonStyle(VSChipButtonStyle())
        }
    }

  @ViewBuilder
  private var expandedControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Input")
                .font(.caption.weight(.semibold))
                .foregroundStyle(VSColor.inkFaint)

            Picker("Source", selection: $cc.source) {
                ForEach(CaptionController.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if cc.source == .glasses {
                Toggle("Fallback to phone mic if glasses audio stops", isOn: $cc.autoFallback)
                    .tint(VSColor.accent)
                    .font(.footnote)
                if cc.usingFallback {
                    Label("Using phone mic", systemImage: "iphone.and.arrow.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(VSColor.warn)
                }
            }

            HStack {
                Text("OLED font").foregroundStyle(VSColor.inkMuted)
                Spacer()
                Picker("Font", selection: $cc.fontSize) {
                    Text("S").tag(0); Text("M").tag(1); Text("L").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }

            Text("Speakers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(VSColor.inkFaint)
            Toggle("Name who's speaking (voice)", isOn: $cc.speakerNames).tint(VSColor.accent)
            if cc.speakerNames {
                Button { showSpeakers = true } label: {
                    Label(cc.lastSpeaker.map { "Last: \($0.name) · Name speakers" } ?? "Name speakers",
                          systemImage: "person.2.wave.2")
                }
                .buttonStyle(VSChipButtonStyle())
            }
        }
        .padding(16)
        .glass(radius: 20)
        .sheet(isPresented: $showSpeakers) { SpeakersView() }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private var debugDisclosure: some View {
        DisclosureGroup(isExpanded: $showDebug) {
            debugPanel
        } label: {
            Text("Engineering panel")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VSColor.inkMuted)
        }
        .tint(VSColor.accent)
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Text to send", text: $testText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Send partial") { cc.sendTyped(testText, final: false) }
                Button("Send final") { cc.sendTyped(testText, final: true) }
            }
            .buttonStyle(VSChipButtonStyle())

            Toggle("Monitor glasses mic (headphones!)", isOn: $cc.monitorGlasses).tint(VSColor.accent)
            Stepper(String(format: "Commit after %.1f s pause", cc.pauseCommit), value: $cc.pauseCommit, in: 0.4...2.5, step: 0.1)
            Stepper("Glasses gain: \(cc.glassesGain)×", value: $cc.glassesGain, in: 1...64)

            Toggle("Tone punctuation", isOn: $cc.tonePunctuation).tint(VSColor.accent)
            Toggle("Databricks tone polish", isOn: $cc.databricksTone).tint(VSColor.accent)
                .disabled(!DatabricksConfig.isConfigured)
            #if canImport(Translation)
            if #available(iOS 18.0, *) { TranslationLiveToggle() }
            #endif

            Group {
                Text("Audio \(ble.audioPacketsPerSec) pkt/s · lost \(cc.glassesLostFrames)")
                Text(String(format: "BLE RTT %.0f ms · MTU %d", ble.rttMs ?? 0, ble.mtu))
            }
            .font(.caption2.monospaced())
            .foregroundStyle(VSColor.inkFaint)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(log.lines.suffix(12).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption2.monospaced()).foregroundStyle(VSColor.inkFaint)
                }
            }
        }
        .padding(.top, 10)
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct TranslationLiveToggle: View {
    @State private var on = UserDefaults.standard.bool(forKey: "visense.liveTranslation")

    var body: some View {
        Toggle("Live English translation", isOn: $on)
            .tint(VSColor.accent)
            .onChange(of: on) { _, new in
                UserDefaults.standard.set(new, forKey: "visense.liveTranslation")
            }
    }
}
#endif

/// Mic level — accent fill, no rainbow (cheap to draw).
struct LevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [VSColor.accent.opacity(0.5), VSColor.accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.07), value: level)
            }
        }
    }
}