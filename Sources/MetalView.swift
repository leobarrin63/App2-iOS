import SwiftUI
import MetalKit

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

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    final class Coordinator {
        let renderer: VRRenderer
        init(renderer: VRRenderer) { self.renderer = renderer }
        @objc func onTap() { renderer.tap() }
    }
}
