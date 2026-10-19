import SwiftUI

@main
@MainActor
struct KDMApp: App {
    @StateObject private var audio: AudioInputManager
    @StateObject private var model: AnalysisViewModel
    @StateObject private var players: PlayerLink

    init() {
        let audio = AudioInputManager()
        let players = PlayerLink()
        _audio = StateObject(wrappedValue: audio)
        _players = StateObject(wrappedValue: players)
        _model = StateObject(wrappedValue: AnalysisViewModel(audio: audio, players: players))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(audio: audio, model: model, players: players)
                .onAppear {
                    audio.start()
                    model.start()
                    players.start()
                }
        }
    }
}
