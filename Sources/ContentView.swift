import SwiftUI

/* Etape 1 : juste confirmer que le squelette compile et s'installe.
   Les etapes suivantes ajouteront la lecture video (AVPlayer),
   le suivi de tete (Core Motion), puis le rendu VR stereo (Metal). */
struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Lunettes VR")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Etape 1 : squelette installe correctement")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
