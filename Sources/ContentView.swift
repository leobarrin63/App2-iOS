import SwiftUI

/* Etape 4 : rendu VR complet (Metal), suivi de tete (Core Motion),
   menu et lecture video en stereo. Equivalent iOS de MainActivity.kt.
   La recherche passe par un clavier virtuel dans le menu 3D (Panel.swift)
   plutot que le clavier systeme iOS - navigable au regard/dwell ou a la
   souris gyroscopique, sans avoir a enlever le casque. */
struct ContentView: View {
    @State private var renderer = VRRenderer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalView(renderer: renderer)
                .ignoresSafeArea()
        }
    }
}
