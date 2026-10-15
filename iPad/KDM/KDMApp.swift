import SwiftUI

@main
@MainActor
struct KDMApp: App {
    @StateObject private var audio: AudioInputManager
    @StateObject private var model: AnalysisViewModel

    init() {
        let audio = AudioInputManager()
        _audio = StateObject(wrappedValue: audio)
        _model = StateObject(wrappedValue: AnalysisViewModel(audio: audio))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(audio: audio, model: model)
                .onAppear {
                    audio.start()
                    model.start()
                }
        }
    }
}
