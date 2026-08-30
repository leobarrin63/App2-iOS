import SwiftUI

/* Etape 4 : rendu VR complet (Metal), suivi de tete (Core Motion),
   menu et lecture video en stereo. Equivalent iOS de MainActivity.kt. */
struct ContentView: View {
    @State private var renderer = VRRenderer()
    @State private var rechercheVisible = false
    @State private var texteRecherche = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalView(renderer: renderer)
                .ignoresSafeArea()

            if rechercheVisible {
                VStack {
                    HStack {
                        TextField("Rechercher une video", text: $texteRecherche)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { fermerRecherche() }
                        Button("OK") { fermerRecherche() }
                    }
                    .padding()
                    .background(.black.opacity(0.7))
                    Spacer()
                }
            }
        }
        .onAppear {
            renderer.onOuvrirRecherche = {
                texteRecherche = ""
                rechercheVisible = true
            }
        }
    }

    private func fermerRecherche() {
        renderer.definirRecherche(texteRecherche)
        rechercheVisible = false
    }
}
