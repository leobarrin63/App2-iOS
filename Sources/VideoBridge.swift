import AVFoundation
import CoreVideo
import Metal

/* Equivalent du "battement" (Handler.post toutes les 150ms) dans
   MainActivity.kt (Android) qui relie ExoPlayer au rendu OpenGL.
   Ici AVPlayer + AVPlayerItemVideoOutput fournissent directement des
   CVPixelBuffer qu'on convertit en texture Metal a chaque frame. */
final class VideoBridge {
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache?
    private var observation: NSKeyValueObservation?
    private let bus = VideoBus.shared
    private let state = AppState.shared

    init(device: MTLDevice) {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func verifierDemandes() {
        if let u = bus.demandeUrl, let url = URL(string: u) {
            bus.demandeUrl = nil
            jouer(url: url)
        }
        if bus.demandeStop {
            bus.demandeStop = false
            player?.pause()
            bus.enLecture = false
            state.besoinRedessin = true
        }
    }

    private func jouer(url: URL) {
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        output = out

        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        p.actionAtItemEnd = .none
        player = p

        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            item?.seek(to: .zero, completionHandler: nil)
            self?.player?.play()
        }

        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                self.player?.play()
                self.bus.enLecture = true
                if !self.bus.dejaCompte {
                    self.bus.dejaCompte = true
                    Compteur.envoyer(videoId: self.bus.videoId)
                }
            } else if item.status == .failed {
                self.state.info = "lecture : " + (item.error?.localizedDescription ?? "erreur")
                self.state.infoT = 8
                self.state.menu = true
                self.state.besoinRedessin = true
                self.bus.enLecture = false
            }
        }
    }

    /* Renvoie une texture Metal si une nouvelle image video est
       disponible, sinon nil (on garde alors la texture precedente). */
    func texturePourFrame() -> MTLTexture? {
        guard bus.enLecture, let output, let cache = textureCache else { return nil }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        else { return nil }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        let ok = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard ok == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return nil
        }
        return tex
    }
}
