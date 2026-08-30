import SwiftUI
import AVKit

/* Etape 2 : verifier que le reseau (catalogue.json) et la lecture video
   (AVPlayer) marchent sur iOS. Lecture a plat pour l'instant, pas de
   rendu stereo/VR : ca viendra a l'etape 4 avec Metal. */
struct ContentView: View {
    @State private var videos: [Video] = []
    @State private var etat = "Chargement du catalogue..."
    @State private var videoEnCours: Video?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let video = videoEnCours, let url = URL(string: video.url) {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
                    .overlay(alignment: .topLeading) {
                        Button("< Retour au catalogue") { videoEnCours = nil }
                            .padding(10)
                            .background(.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .padding()
                    }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Lunettes VR")
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(etat)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))

                    List(videos) { video in
                        Button {
                            videoEnCours = video
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(video.titre)
                                    .foregroundStyle(.white)
                                Text("\(video.duree) s - \(video.vues) vues")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                    .scrollContentBackground(.hidden)
                }
                .padding()
            }
        }
        .task {
            await chargerCatalogue()
        }
    }

    private func chargerCatalogue() async {
        do {
            let l = try await Catalogue.charger()
            videos = l
            etat = "catalogue : \(l.count) videos"
        } catch {
            etat = "catalogue : echec (\(error.localizedDescription))"
        }
    }
}
