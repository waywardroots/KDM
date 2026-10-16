import SwiftUI

/// Minimal view: the main output's key, the next keys to mix to and the note
/// bars, big and readable from a distance. Tap "Full view" (top right) to go back.
struct MinimalView: View {
    @ObservedObject var model: AnalysisViewModel
    var onExit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 600
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        Label("Full view", systemImage: "rectangle.expand.vertical")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }

                Spacer(minLength: 12)

                VStack(spacing: 8) {
                    Text(model.keyText)
                        .font(.system(size: compact ? 110 : 170, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .foregroundStyle(model.keyIsReliable ? .primary : .secondary)
                    Text(model.keyAltText.isEmpty ? " " : model.keyAltText)
                        .font(.system(size: compact ? 34 : 48, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 12)

                // Where to mix next on the Camelot wheel.
                if let key = model.mainKey {
                    NextKeysView(from: key, model: model, large: true)
                        .padding(.bottom, 24)
                }

                NoteBarsView(values: model.chroma, key: model.mainKey)
                    .frame(height: geo.size.height * (compact ? 0.22 : 0.26))
            }
            .padding(28)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
