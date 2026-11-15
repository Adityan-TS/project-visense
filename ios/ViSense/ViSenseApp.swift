// ViSenseApp.swift — shell: ambient backdrop + custom tab bar.
import SwiftUI

@main
struct ViSenseApp: App {
    @StateObject private var ble: BLEManager
    @StateObject private var captions: CaptionController
    @StateObject private var nav = AppNav()

    init() {
        let b = BLEManager()
        _ble = StateObject(wrappedValue: b)
        _captions = StateObject(wrappedValue: CaptionController(ble: b))
    }

    var body: some Scene {
        WindowGroup {
            VSRootShell {
                ZStack(alignment: .bottom) {
                    Group {
                        switch nav.tab {
                        case .captions: ContentView()
                        case .history: HistoryView()
                        case .ask: AskView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.18), value: nav.tab)

                    VSTabBar(selection: $nav.tab)
                }
            }
            .environmentObject(ble)
            .environmentObject(captions)
            .environmentObject(Log.shared)
            .environmentObject(TranscriptStore.shared)
            .environmentObject(TranscriptSync.shared)
            .environmentObject(nav)
            .preferredColorScheme(.dark)
            .onAppear { TranscriptSync.shared.start() }
        }
    }
}