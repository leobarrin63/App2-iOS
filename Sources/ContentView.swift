import SwiftUI

/* Rendu VR complet (Metal) : passthrough camera, 6DoF (ARKit), mains
   (Vision), videos 360 et scenes 3D telechargees. Equivalent iOS de
   MainActivity.kt. La recherche passe par un clavier virtuel dans le menu
   3D (Panel.swift) : on vise au regard et on pince pour taper, sans
   enlever le casque. */
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
