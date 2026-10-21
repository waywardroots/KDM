import SwiftUI
import UIKit

@main
@MainActor
struct KDMApp: App {
    @StateObject private var audio: AudioInputManager
    @StateObject private var model: AnalysisViewModel
    @StateObject private var players: PlayerLink
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let audio = AudioInputManager()
        let players = PlayerLink()
        _audio = StateObject(wrappedValue: audio)
        _players = StateObject(wrappedValue: players)
        _model = StateObject(wrappedValue: AnalysisViewModel(audio: audio, players: players))
    }

    /// Keep the display awake while KDM is open (no auto-lock mid-set).
    private func keepScreenOn() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView(audio: audio, model: model, players: players)
                .onAppear {
                    audio.start()
                    model.start()
                    players.start()
                    keepScreenOn()
                }
                .onChange(of: scenePhase) { phase in
                    // iPadOS resets this when the app goes to the background.
                    if phase == .active { keepScreenOn() }
                }
        }
    }
}
