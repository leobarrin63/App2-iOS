import SwiftUI
import MetalKit

/* Aucun geste a l'ecran : dans le casque, toucher l'ecran ne fait rien
   (comme sur Android). Tout passe par la tete et les mains. */
struct MetalView: UIViewRepresentable {
    let renderer: VRRenderer

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.delegate = renderer
        v.preferredFramesPerSecond = 60
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.framebufferOnly = false
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
