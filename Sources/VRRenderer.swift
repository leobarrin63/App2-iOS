import Foundation
import UIKit
import Metal
import MetalKit
import ARKit
import AVFoundation
import simd

/* Equivalent de VrRenderer + de la boucle onDrawFrame dans
   MainActivity.kt (Android), en Metal. Meme structure : par oeil, on
   dessine dans une texture intermediaire (avec profondeur) le fond -
   passthrough, decor, video ou scene 3D - puis le menu, le curseur et les
   mains par-dessus ; une passe de composition applique ensuite la
   distorsion barillet vers la zone de l'ecran placee en face de la
   lentille de cet oeil. */

private struct EnvUniforms {
    var uRot: simd_float4x4
    var uTan: SIMD2<Float>
    var uEye: SIMD3<Float>
    var uT: Float
}
private struct VidUniforms {
    var uRot: simd_float4x4
    var uTan: SIMD2<Float>
    var uUV: SIMD4<Float>
}
private struct LensUniforms {
    var uK1: Float
    var uAsp: Float
}
private struct CamUniforms {
    var uTan: SIMD2<Float>
    var uZoom: Float
    var pad: Float
    var uK: SIMD4<Float>
}
private struct MainUniforms {
    var vp: simd_float4x4
    var col: SIMD4<Float>
    var taille: Float
}

final class VRRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let sampler: MTLSamplerState
    private let samplerScene: MTLSamplerState
    // au plus 2 images en cours sur le GPU : les tampons animes (anneau de 3) restent surs
    private let enVol = DispatchSemaphore(value: 2)

    private var pEnv: MTLRenderPipelineState!
    private var pVid: MTLRenderPipelineState!
    private var pQuad: MTLRenderPipelineState!
    private var pLens: MTLRenderPipelineState!
    private var pCam: MTLRenderPipelineState!
    private var pMain: MTLRenderPipelineState!
    private var pScene: MTLRenderPipelineState!
    private var pSceneBlend: MTLRenderPipelineState!
    private var dsScene: MTLDepthStencilState!
    private var dsSceneBlend: MTLDepthStencilState!
    private var dsAucun: MTLDepthStencilState!

    private var quadBuf: MTLBuffer!   // plein ecran, triangle strip
    private var planBuf: MTLBuffer!   // quad panneau/curseur (position+uv)

    private var texPanel: MTLTexture?
    private var texCur: MTLTexture?
    private var texBlanche: MTLTexture!
    private var fboTex: MTLTexture?
    private var fboProf: MTLTexture?
    private var fboW = 0, fboH = 0

    private let panel = Panel()
    private let tete = HeadTracker()
    private let ar = ArTracker()
    private let mains = Mains()
    private var video: VideoBridge!
    private var scene: Scene3D?

    // image camera (passthrough) : Y + CbCr, intrinseques normalisees
    private var cacheCam: CVMetalTextureCache?
    private var camY: CVMetalTexture?
    private var camUV: CVMetalTexture?
    private var camK = SIMD4<Float>(0, 0, 0, 0)
    private var camAspect: Float = 4.0 / 3.0
    private var camOk = false
    private var dernierTsCam: TimeInterval = 0

    private let s = AppState.shared
    private let bus = VideoBus.shared

    private var viewW = 0, viewH = 0
    private var t0 = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()

    private var Q = SIMD4<Float>(0, 0, 0, 1)   // quaternion lisse
    private var M = matrix_identity_float3x3
    private var panelYaw: Float = 0

    // 6DoF : milieu des yeux (vue), camera (mains, passthrough), menu, origine
    private var tetePos = SIMD3<Float>(0, 0, 0)
    private var camPos = SIMD3<Float>(0, 0, 0)
    private var panelCentre = SIMD3<Float>(0, 0, 0)
    private var origineLacet: Float = 0
    private var originePos = SIMD3<Float>(0, 0, 0)
    private var origineAFixer = true
    private var menuAvant = true
    private var rafraichLunettes: Float = 0
    private var infoScene: Float = 0
    private var dernierReglageLum: CFTimeInterval = 0

    // mains a dessiner : articulations + points le long des os, par main
    private var mainsPts: [[Float]] = []
    private var mainsOs: [[Float]] = []
    private var mainsPince: [Bool] = []
    private let osPaires: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8),
        (9, 10), (10, 11), (11, 12), (13, 14), (14, 15), (15, 16),
        (0, 17), (17, 18), (18, 19), (19, 20), (5, 9), (9, 13), (13, 17),
    ]

    /* La position d'ARKit est celle de la CAMERA du telephone, pas des yeux :
       sur l'iPhone 13 mini, elle est ~5 cm a gauche, 2 cm plus haut et 6,5 cm
       devant le milieu des yeux (camera dans le coin, puis epaisseur du
       telephone + lentilles). La vue est placee au milieu des yeux, les mains
       restent placees par la camera. */
    private let oeilDepuisCamera = SIMD3<Float>(0.052, -0.018, 0.065)

    /* Densite physique de l'ecran, pour centrer chaque image en face de sa
       lentille. iOS ne la donne pas : on la lit dans une table par modele. */
    private let ppi = VRRenderer.ppiAppareil()

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        let sc = MTLSamplerDescriptor()
        sc.minFilter = .linear; sc.magFilter = .linear; sc.mipFilter = .linear
        sc.sAddressMode = .repeat; sc.tAddressMode = .repeat
        sc.maxAnisotropy = 4
        samplerScene = device.makeSamplerState(descriptor: sc)!

        super.init()
        s.charger()
        // cote maximal des textures de scene selon la memoire : 4 Go -> 1024
        let go = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
        s.plafondTex = go < 5 ? 1024 : (go < 7.5 ? 2048 : 4096)

        video = VideoBridge(device: device)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheCam)
        construirePipelines()
        construireBuffers()
        texPanel = creerTextureVide(Panel.W, Panel.H)
        texCur = creerTextureVide(128, 128)
        texBlanche = creerTextureVide(1, 1)
        let blanc: [UInt8] = [255, 255, 255, 255]
        texBlanche.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: blanc, bytesPerRow: 4)
        panel.onJouer = { [weak self] v in self?.jouer(v) }
        panel.onRecharger = { [weak self] in self?.chargerCatalogue() }
        panel.draw()
        tete.start()
        chargerCatalogue()

        let prefs = UserDefaults.standard
        var appareil = prefs.string(forKey: "appareil")
        if appareil == nil {
            appareil = UUID().uuidString
            prefs.set(appareil, forKey: "appareil")
        }
        s.appareil = appareil!
        UIApplication.shared.isIdleTimerDisabled = true      // l'ecran ne se met pas en veille dans le casque
        // le son des videos et des scenes passe meme quand l'iPhone est en mode silencieux
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    static func ppiAppareil() -> Float {
        var u = utsname()
        uname(&u)
        let id = withUnsafePointer(to: &u.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        switch id {
        case "iPhone13,1", "iPhone14,4": return 476                         // 12 mini, 13 mini
        case "iPhone11,8", "iPhone12,1", "iPhone12,8", "iPhone14,6": return 326 // XR, 11, SE 2, SE 3
        case "iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone11,4", "iPhone11,6",
             "iPhone12,3", "iPhone12,5", "iPhone13,4", "iPhone14,3", "iPhone14,8",
             "iPhone15,3", "iPhone15,5", "iPhone16,2", "iPhone17,4": return 458
        default: return 460
        }
    }

    private func construirePipelines() {
        let lib = device.makeDefaultLibrary()!

        func pipeline(_ vs: String, _ fs: String, blend: Bool, profondeur: Bool,
                      desc: MTLVertexDescriptor? = nil) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = profondeur ? .depth32Float : .invalid
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            d.vertexDescriptor = desc
            return try! device.makeRenderPipelineState(descriptor: d)
        }

        let dQuad = MTLVertexDescriptor()
        dQuad.attributes[0].format = .float3
        dQuad.attributes[0].offset = 0
        dQuad.attributes[0].bufferIndex = 0
        dQuad.attributes[1].format = .float2
        dQuad.attributes[1].offset = MemoryLayout<Float>.size * 3
        dQuad.attributes[1].bufferIndex = 0
        dQuad.layouts[0].stride = MemoryLayout<Float>.size * 5

        let dScene = MTLVertexDescriptor()
        dScene.attributes[0].format = .float3; dScene.attributes[0].bufferIndex = 0
        dScene.attributes[1].format = .float3; dScene.attributes[1].bufferIndex = 1
        dScene.attributes[2].format = .float2; dScene.attributes[2].bufferIndex = 2
        dScene.layouts[0].stride = 12
        dScene.layouts[1].stride = 12
        dScene.layouts[2].stride = 8

        pEnv = pipeline("vsPlein", "fsEnv", blend: false, profondeur: true)
        pVid = pipeline("vsPlein", "fsVid", blend: false, profondeur: true)
        pCam = pipeline("vsPlein", "fsCam", blend: false, profondeur: true)
        pQuad = pipeline("vsQuad", "fsQuad", blend: true, profondeur: true, desc: dQuad)
        pMain = pipeline("vsMain", "fsMain", blend: true, profondeur: true)
        pScene = pipeline("vsScene", "fsScene", blend: false, profondeur: true, desc: dScene)
        pSceneBlend = pipeline("vsScene", "fsScene", blend: true, profondeur: true, desc: dScene)
        pLens = pipeline("vsLens", "fsLens", blend: false, profondeur: false)

        let a = MTLDepthStencilDescriptor()
        a.depthCompareFunction = .lessEqual; a.isDepthWriteEnabled = true
        dsScene = device.makeDepthStencilState(descriptor: a)
        let b = MTLDepthStencilDescriptor()
        b.depthCompareFunction = .lessEqual; b.isDepthWriteEnabled = false
        dsSceneBlend = device.makeDepthStencilState(descriptor: b)
        let c = MTLDepthStencilDescriptor()
        c.depthCompareFunction = .always; c.isDepthWriteEnabled = false
        dsAucun = device.makeDepthStencilState(descriptor: c)
    }

    private func construireBuffers() {
        let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]
        quadBuf = device.makeBuffer(bytes: quad, length: quad.count * 4)

        // textures du menu et du curseur : ligne 0 = haut de l'image (convention
        // Metal), donc v = 0 en haut du quad ; u = 0 a gauche
        let plan: [Float] = [
            -0.5, -0.5, 0, 0, 1,
             0.5, -0.5, 0, 1, 1,
            -0.5,  0.5, 0, 0, 0,
             0.5,  0.5, 0, 1, 0,
        ]
        planBuf = device.makeBuffer(bytes: plan, length: plan.count * 4)
    }

    private func chargerCatalogue() {
        Task {
            do {
                let (l, api) = try await Catalogue.charger()
                panel.lib = l
                s.apiUrl = api
                let nScenes = l.filter { $0.estScene }.count
                s.info = l.isEmpty ? "catalogue vide"
                    : "catalogue : \(l.count - nScenes) videos" + (nScenes > 0 ? ", \(nScenes) scenes 3D" : "")
            } catch {
                s.info = "catalogue : echec"
            }
            s.infoT = 6
            s.besoinRedessin = true
        }
    }

    private func jouer(_ v: Video) {
        SceneBus.shared.demandeFermeture = true
        bus.videoId = v.id
        bus.formatVideo = v.format
        bus.dejaCompte = false
        bus.demandeUrl = v.url
        s.info = "pincee longue paume vers toi : menu"
        s.infoT = 5
        s.menu = false
    }

    // ---------- MTKViewDelegate ----------
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewW = Int(size.width); viewH = Int(size.height)
    }

    func draw(in view: MTKView) {
        enVol.wait()
        var envoye = false
        defer { if !envoye { enVol.signal() } }
        guard let drawable = view.currentDrawable else { return }
        video.verifierDemandes()

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.05))
        lastFrame = now
        let temps = Float(now - t0)

        // lissage du quaternion (Core Motion : rotation seule, en secours)
        let k = 1 - pow(s.smooth * 0.92, dt * 60)
        var target = SIMD4<Float>(s.qtX, s.qtY, s.qtZ, s.qtW)
        if simd_dot(target, Q) < 0 { target = -target }
        Q += (target - Q) * k
        Q = simd_normalize(Q)

        // recentrage autour de Y
        let hy = s.yawOffset / 2
        let oy = sin(hy), ow = cos(hy)
        let x = ow * Q.x + oy * Q.z
        let y = ow * Q.y + oy * Q.w
        let z = ow * Q.z - oy * Q.x
        let ww = ow * Q.w - oy * Q.y
        M = matFromQ(x, y, z, ww)

        poseTete(dt: dt)      // remplace M par la rotation d'ARKit des que la camera tourne

        let yaw = atan2(M.columns.2.x, M.columns.2.z)
        s.dbgYaw = yaw
        s.dbgPitch = asin(min(max(M.columns.2.y * -1, -1), 1))
        s.dbgRoll = atan2(M.columns.0.y, M.columns.1.y)

        /* Gestes de la main : pincee longue paume vers soi -> menu ;
           pincee courte -> clic sur la zone visee. Plus aucun menu au
           mouvement de tete, ni au toucher de l'ecran. */
        if s.basculerMenu { s.basculerMenu = false; s.menu.toggle(); panel.draw() }
        if s.pinceClic { s.pinceClic = false; if s.menu { s.clickWanted = true } }

        if s.infoT > 0 {
            s.infoT -= dt
            if s.infoT <= 0 { s.info = ""; panel.draw() }
        }

        let ps = panelSize()
        var diff = yaw - panelYaw
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        let dead = atan(ps.0 / 2 / s.menuDist) * 0.78
        if abs(diff) > dead {
            panelYaw += (abs(diff) - dead) * (diff < 0 ? -1 : 1) * min(1, dt * 3.5)
        }

        // le menu reste fixe dans la piece, mais revient vers la tete a
        // l'ouverture ou si l'on s'en eloigne de plus de 50 cm
        if s.menu && !menuAvant { panelCentre = tetePos; panelYaw = yaw }
        menuAvant = s.menu
        let ecart = tetePos - panelCentre
        let dist = simd_length(ecart)
        if dist > 0.5 { panelCentre += ecart * ((dist - 0.5) / dist) * min(1, dt * 3) }

        // onglet LUNETTES et telechargements : valeurs qui changent en continu
        if s.menu && (s.tab == "glasses" || !SceneBus.shared.progres.isEmpty) {
            rafraichLunettes += dt
            if rafraichLunettes > 0.25 { rafraichLunettes = 0; s.besoinRedessin = true }
        }

        // ---- scene 3D : ouverture, fermeture, animation ----
        let sb = SceneBus.shared
        if sb.demandeFermeture {
            sb.demandeFermeture = false
            scene?.liberer(); scene = nil
        }
        if let u = sb.demandeOuverture {
            sb.demandeOuverture = nil
            scene?.liberer()
            let nouvelle = Scene3D(url: u, device: device, plafond: s.plafondTex)
            nouvelle.demarrer()
            scene = nouvelle
            s.demandeRecentrage = true      // on demarre au point d'entree de la scene
        }
        if let sc = scene {
            sc.animer()
            infoScene += dt
            if infoScene > 0.5 {
                infoScene = 0
                if let err = sc.erreur { s.info = "scene : " + err; s.infoT = 8; s.besoinRedessin = true }
                else if sc.imagesTotal > 0 && sc.imagesFaites < sc.imagesTotal {
                    s.info = "scene : textures \(sc.imagesFaites)/\(sc.imagesTotal)"; s.infoT = 2
                    s.besoinRedessin = true
                }
            }
        }

        // luminosite fixe : iOS la reajuste parfois, on la reimpose chaque seconde
        if now - dernierReglageLum > 1 {
            dernierReglageLum = now
            if abs(Float(UIScreen.main.brightness) - s.luminosite) > 0.02 {
                UIScreen.main.brightness = CGFloat(s.luminosite)
            }
        }

        if s.besoinRedessin { s.besoinRedessin = false; panel.draw() }
        viser(dt: dt)
        preparerMains()

        if panel.dirty, let img = panel.image, let texPanel {
            mettreAJour(texPanel, avec: img)
            panel.dirty = false
        }
        dessinerCurseur()

        /* Chaque image est centree en face de sa lentille : centres a
           +- ecartLentilles/2 du milieu de l'ecran, en pixels physiques. */
        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height), demi = w / 2
        // pixels de rendu par mm : le rendu (x3) est reduit a l'ecran reel (x2,88 sur un mini)
        let pxParPoint = Float(view.drawableSize.width / max(view.bounds.width, 1))
        let pxParMm = ppi / 25.4 * pxParPoint / max(Float(UIScreen.main.nativeScale), 1)
        var ew = demi, x0G = 0, x0D = demi
        let sep = Int(s.ecartLentilles * pxParMm)
        if sep > 0 && w > 0 {
            ew = min(sep, demi)
            x0G = max(0, demi - sep / 2 - ew / 2)
            x0D = min(w - ew, demi + sep / 2 - ew / 2)
        }
        let eh = h
        if ew != fboW || eh != fboH, ew > 0, eh > 0 {
            fboW = ew; fboH = eh
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ew, height: eh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            fboTex = device.makeTexture(descriptor: d)
            let dp = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: ew, height: eh, mipmapped: false)
            dp.usage = [.renderTarget]
            dp.storageMode = .memoryless      // profondeur jamais relue : reste dans la puce graphique
            fboProf = device.makeTexture(descriptor: dp)
        }

        guard let cmd = queue.makeCommandBuffer(), let fbo = fboTex, let prof = fboProf, ew > 0, eh > 0 else { return }

        if let nouvelle = video.texturePourFrame() {
            texVidCourante = nouvelle
        }

        renderOeil(cmd: cmd, drawable: drawable.texture, signe: -1, ew: ew, eh: eh, x0: x0G, temps: temps, fbo: fbo, prof: prof, premier: true)
        renderOeil(cmd: cmd, drawable: drawable.texture, signe: 1, ew: ew, eh: eh, x0: x0D, temps: temps, fbo: fbo, prof: prof, premier: false)

        // les textures camera doivent vivre jusqu'a la fin du travail du GPU
        let gardeY = camY, gardeUV = camUV
        let sema = enVol
        cmd.addCompletedHandler { _ in
            _ = gardeY; _ = gardeUV
            sema.signal()
        }
        envoye = true
        cmd.present(drawable)
        cmd.commit()
    }

    private var texVidCourante: MTLTexture?

    private func renderOeil(cmd: MTLCommandBuffer, drawable: MTLTexture, signe: Float, ew: Int, eh: Int, x0: Int,
                            temps: Float, fbo: MTLTexture, prof: MTLTexture, premier: Bool) {
        let asp = Float(ew) / Float(eh)
        let ipd = s.ipd / 1000
        let ex = signe * ipd / 2
        let proj = perspective(s.fov * .pi / 180, asp, 0.05, 100)
        var view = simd_float4x4(columns: (
            SIMD4(M.columns.0.x, M.columns.1.x, M.columns.2.x, 0),
            SIMD4(M.columns.0.y, M.columns.1.y, M.columns.2.y, 0),
            SIMD4(M.columns.0.z, M.columns.1.z, M.columns.2.z, 0),
            SIMD4(-ex, 0, 0, 1)
        ))
        // position de la tete : camera deplacee de -(M^T * tetePos)
        let a = simd_transpose(M) * tetePos
        view.columns.3 = SIMD4(-ex - a.x, -a.y, -a.z, 1)
        let oeilMonde = tetePos + M * SIMD3<Float>(ex, 0, 0)
        let VP = proj * view

        // ---- passe hors-ecran : fond, puis menu + curseur + mains ----
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = fbo
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.depthAttachment.texture = prof
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(ew), height: Double(eh), znear: 0, zfar: 1))
        enc.setDepthStencilState(dsAucun)

        if let sc = scene, !bus.enLecture {
            // scene 3D : la pluie de code sert de ciel derriere les fenetres
            dessinerDecor(enc, asp: asp, oeil: oeilMonde, temps: temps)
            sc.dessiner(enc, opaque: pScene, transparent: pSceneBlend, dsOpaque: dsScene, dsTransparent: dsSceneBlend,
                        sampler: samplerScene, blanche: texBlanche, vp: VP, oeil: oeilMonde)
            enc.setDepthStencilState(dsAucun)
            enc.setCullMode(.none)
        } else if bus.enLecture, let texVid = texVidCourante {
            enc.setRenderPipelineState(pVid)
            enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
            let vty = tan(s.fov * .pi / 360)
            var moitie: Float = signe < 0 ? 0 : 1
            if s.yeuxInverses { moitie = 1 - moitie }
            let fmt = bus.formatVideo >= 0 ? bus.formatVideo : s.format
            var uUV: SIMD4<Float>
            switch fmt {
            case 1: uUV = SIMD4(0, 1, moitie * 0.5, 0.5)
            case 2: uUV = SIMD4(0, 1, 0, 1)
            default: uUV = SIMD4(moitie * 0.5, 0.5, 0, 1)
            }
            var u = VidUniforms(uRot: simd_float4x4(M), uTan: SIMD2(vty * asp, vty), uUV: uUV)
            enc.setFragmentBytes(&u, length: MemoryLayout<VidUniforms>.stride, index: 0)
            enc.setFragmentTexture(texVid, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else if s.passthrough, camOk, let y = camY.flatMap({ CVMetalTextureGetTexture($0) }),
                  let uv = camUV.flatMap({ CVMetalTextureGetTexture($0) }) {
            // accueil : le monde reel, vu par la camera arriere
            enc.setRenderPipelineState(pCam)
            enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
            let ty = tan(s.fov * .pi / 360)
            var u = CamUniforms(uTan: SIMD2(ty * asp, ty), uZoom: s.zoomPt, pad: 0, uK: camK)
            enc.setFragmentBytes(&u, length: MemoryLayout<CamUniforms>.stride, index: 0)
            enc.setFragmentTexture(y, index: 0)
            enc.setFragmentTexture(uv, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            dessinerDecor(enc, asp: asp, oeil: oeilMonde, temps: temps)
        }

        let ps = panelSize()
        let c = cos(panelYaw), sn = sin(panelYaw)
        let U = SIMD3<Float>(c, 0, -sn)
        let V = SIMD3<Float>(0, 1, 0)
        let N = SIMD3<Float>(sn, 0, c)
        let P = panelCentre + SIMD3<Float>(-sn * s.menuDist, 0, -c * s.menuDist)
        let rs = 2 * s.menuDist * tan(3 * Float.pi / 180)

        if s.menu, let texPanel {
            enc.setRenderPipelineState(pQuad)
            enc.setVertexBuffer(planBuf, offset: 0, index: 0)
            var mvp = VP * quadMat(U, V, N, P, ps.0, ps.1)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            var alpha: Float = 1
            enc.setFragmentBytes(&alpha, length: 4, index: 0)
            enc.setFragmentTexture(texPanel, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if let texCur {
                // curseur pose sur le menu, la ou le regard le touche
                let cx = (s.curU - 0.5) * ps.0
                let cy = (0.5 - s.curV) * ps.1
                let CP = P + U * cx + V * cy + N * 0.012
                var mvpC = VP * quadMat(U, V, N, CP, rs, rs)
                enc.setVertexBytes(&mvpC, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                var alphaC: Float = 0.95
                enc.setFragmentBytes(&alphaC, length: 4, index: 0)
                enc.setFragmentTexture(texCur, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        } else if s.pince || s.progresMenu > 0.01, let texCur {
            /* Menu cache : le curseur n'apparait que pendant une pincee, au
               centre du regard, pour montrer l'anneau de la pincee longue. */
            enc.setRenderPipelineState(pQuad)
            enc.setVertexBuffer(planBuf, offset: 0, index: 0)
            let CP = tetePos - M.columns.2 * s.menuDist
            var mvpC = VP * quadMat(M.columns.0, M.columns.1, M.columns.2, CP, rs, rs)
            enc.setVertexBytes(&mvpC, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            var alphaC: Float = 0.95
            enc.setFragmentBytes(&alphaC, length: 4, index: 0)
            enc.setFragmentTexture(texCur, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // les mains reconnues, par-dessus tout (scene, video, menu)
        if !mainsPts.isEmpty {
            let vpMain: simd_float4x4
            if scene == nil && !bus.enLecture && s.passthrough && camOk {
                /* En passthrough, l'image vient de la seule camera, sans relief :
                   la main est dessinee depuis la camera elle-meme (meme vue pour
                   les deux yeux, meme agrandissement) pour tomber exactement sur
                   l'image de la vraie main. */
                let tz = tan(s.fov * .pi / 360) / s.zoomPt
                let pz = perspective(2 * atan(tz), asp, 0.05, 100)
                var vc = simd_float4x4(columns: (
                    SIMD4(M.columns.0.x, M.columns.1.x, M.columns.2.x, 0),
                    SIMD4(M.columns.0.y, M.columns.1.y, M.columns.2.y, 0),
                    SIMD4(M.columns.0.z, M.columns.1.z, M.columns.2.z, 0),
                    SIMD4(0, 0, 0, 1)
                ))
                let cc = simd_transpose(M) * camPos
                vc.columns.3 = SIMD4(-cc.x, -cc.y, -cc.z, 1)
                vpMain = pz * vc
            } else {
                vpMain = VP      // scenes, videos : vrai relief, depuis chaque oeil
            }
            dessinerMains(enc, vp: vpMain, eh: eh)
        }
        enc.endEncoding()

        // ---- passe de composition : distorsion barillet vers la zone de la lentille ----
        let rpF = MTLRenderPassDescriptor()
        rpF.colorAttachments[0].texture = drawable
        rpF.colorAttachments[0].loadAction = premier ? .clear : .load
        rpF.colorAttachments[0].storeAction = .store
        rpF.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encF = cmd.makeRenderCommandEncoder(descriptor: rpF) else { return }
        encF.setViewport(MTLViewport(originX: Double(x0), originY: 0, width: Double(ew), height: Double(eh), znear: 0, zfar: 1))
        encF.setRenderPipelineState(pLens)
        encF.setVertexBuffer(quadBuf, offset: 0, index: 0)
        var lu = LensUniforms(uK1: -s.k1, uAsp: asp)
        encF.setFragmentBytes(&lu, length: MemoryLayout<LensUniforms>.stride, index: 0)
        encF.setFragmentTexture(fbo, index: 0)
        encF.setFragmentSamplerState(sampler, index: 0)
        encF.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encF.endEncoding()
    }

    // decor : pluie de code + sol quadrille, calcules dans le shader
    private func dessinerDecor(_ enc: MTLRenderCommandEncoder, asp: Float, oeil: SIMD3<Float>, temps: Float) {
        enc.setRenderPipelineState(pEnv)
        enc.setDepthStencilState(dsAucun)
        enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
        let ty = tan(s.fov * .pi / 360)
        var u = EnvUniforms(uRot: simd_float4x4(M), uTan: SIMD2(ty * asp, ty), uEye: oeil, uT: temps)
        enc.setFragmentBytes(&u, length: MemoryLayout<EnvUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // squelette des mains : os en petits points clairs, articulations en pastilles bleues
    private func dessinerMains(_ enc: MTLRenderCommandEncoder, vp: simd_float4x4, eh: Int) {
        enc.setRenderPipelineState(pMain)
        enc.setDepthStencilState(dsAucun)
        let focale = Float(eh) / (2 * tan(s.fov * .pi / 360))
        for h in 0..<mainsPts.count {
            var u = MainUniforms(vp: vp, col: SIMD4(0.80, 0.93, 1, 0.8), taille: 0.008 * focale)
            let os = mainsOs[h]
            os.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.setVertexBytes(&u, length: MemoryLayout<MainUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<MainUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: os.count / 3)

            u.col = SIMD4(0.25, 0.78, 0.93, 1); u.taille = 0.014 * focale
            let pts = mainsPts[h]
            pts.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.setVertexBytes(&u, length: MemoryLayout<MainUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<MainUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 21)

            if mainsPince[h] {
                // cette main pince : bouts du pouce et de l'index en orange
                let bouts: [Float] = [pts[12], pts[13], pts[14], pts[24], pts[25], pts[26]]
                u.col = SIMD4(0.91, 0.77, 0.35, 1)
                bouts.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                enc.setVertexBytes(&u, length: MemoryLayout<MainUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<MainUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 2)
            }
        }
    }

    // mains a dessiner cette image : deja placees dans la piece et lissees par Mains
    private func preparerMains() {
        mainsPts.removeAll(); mainsOs.removeAll(); mainsPince.removeAll()
        let (mondes, tempsM) = mains.lire()
        guard CACurrentMediaTime() - tempsM < 0.3 else { return }
        for d in mondes.prefix(2) where d.count >= 64 {
            let pts = Array(d[0..<63])
            var os: [Float] = []
            os.reserveCapacity(osPaires.count * 5 * 3)
            for (a, b) in osPaires {
                for k in 1...5 {
                    let f = Float(k) / 6
                    for c in 0..<3 { os.append(pts[a * 3 + c] + (pts[b * 3 + c] - pts[a * 3 + c]) * f) }
                }
            }
            mainsPts.append(pts); mainsOs.append(os); mainsPince.append(d[63] > 0.5)
        }
    }

    // ---------- 6DoF, image camera, mains ----------
    private func poseTete(dt: Float) {
        // la camera sert au 6DoF, aux mains et au passthrough
        if (s.mode6dof || s.mains || s.passthrough) && ArTracker.disponible { ar.start() } else { ar.stop() }

        /* Des que la camera tourne, la rotation vient d'ARKit (plus juste que
           Core Motion, et dans le meme repere que l'image camera et les
           mains) ; le deplacement seulement si le 6DoF est active. */
        if ArTracker.disponible, let p = ar.pose() {
            if origineAFixer || s.demandeRecentrage {
                // origine = milieu des yeux a cet instant : la tete demarre pile en (0, 0, 0)
                origineLacet = atan2(p.rotation.columns.2.x, p.rotation.columns.2.z)
                originePos = p.position + p.rotation * oeilDepuisCamera
                origineAFixer = false
                s.demandeRecentrage = false
            }
            // 6DoF coupe : la tete reste en (0, 0, 0), et le 6DoF repart d'ici sans saut
            if !s.mode6dof { originePos = p.position + p.rotation * oeilDepuisCamera }
            // rotation de -origineLacet autour de Y : le regard au moment du recentrage devient -Z
            let c = cos(-origineLacet), sn = sin(-origineLacet)
            let ry = matrix_float3x3(columns: (
                SIMD3(c, 0, -sn),
                SIMD3(0, 1, 0),
                SIMD3(sn, 0, c)
            ))
            M = ry * p.rotation
            camPos = ry * (p.position - originePos)
            tetePos = camPos + M * oeilDepuisCamera
            s.pos6dof = s.mode6dof
            s.etat6dof = s.mode6dof ? p.etat : "6DOF DESACTIVE (ROTATION PAR LA CAMERA)"
            s.posX = tetePos.x; s.posY = tetePos.y; s.posZ = tetePos.z
        } else {
            s.pos6dof = false
            if !ArTracker.disponible { s.etat6dof = "6DOF NON SUPPORTE SUR CET APPAREIL" }
            else { s.etat6dof = "6DOF : CAMERA INDISPONIBLE (ROTATION SEULE)" }
            tetePos = .zero; camPos = .zero
        }

        // ---- image camera : passthrough, puis detection des mains ----
        if let f = ar.frame, f.timestamp != dernierTsCam {
            dernierTsCam = f.timestamp
            majTexturesCamera(f)
            if s.mains && mains.libre && camOk {
                mains.traiter(f.capturedImage, pose: Mains.Pose(
                    fx: camK.x, fy: camK.y, cx: camK.z, cy: camK.w, aspect: camAspect, cam: camPos, rot: M))
            }
        }
        // resultats de la detection, recopies ici, sur la file principale
        let e = mains.lireEtat()
        let actives = s.mains && CACurrentMediaTime() - e.derniere < 2
        if s.mainsOk != actives { s.mainsOk = actives; s.besoinRedessin = true }
        if actives {
            if e.clic { s.pinceClic = true }
            if e.menu { s.basculerMenu = true }
            s.mainVue = e.vue; s.pince = e.pince; s.progresMenu = e.progres
            s.etatMains = e.texte; s.cadenceMains = e.cadence
        } else {
            s.mainVue = false; s.pince = false; s.progresMenu = 0
            s.etatMains = s.mains ? "MAINS : CAMERA INACTIVE" : "MAINS DESACTIVEES"
        }
    }

    private func majTexturesCamera(_ f: ARFrame) {
        guard let cache = cacheCam else { return }
        let pb = f.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { camOk = false; return }
        var y: CVMetalTexture?
        var uv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .r8Unorm,
            CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &y)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &uv)
        camY = y; camUV = uv
        let res = f.camera.imageResolution
        let K = f.camera.intrinsics
        let W = Float(res.width), H = Float(res.height)
        camK = SIMD4(K[0][0] / W, K[1][1] / H, K[2][0] / W, K[2][1] / H)
        camAspect = W / H
        camOk = y != nil && uv != nil
    }

    /* Contexte reutilise d'une frame a l'autre (pas de bitmap realloue 60
       fois par seconde). Retournement applique une seule fois. */
    private lazy var cursorCtx: CGContext = {
        let ctx = CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 128 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.translateBy(x: 0, y: 128)
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }()

    private func dessinerCurseur() {
        guard let tex = texCur else { return }
        let ctx = cursorCtx
        ctx.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
        UIGraphicsPushContext(ctx)
        let col: UIColor = s.hot >= 0 ? UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1) : UIColor(red: 124/255, green: 178/255, blue: 240/255, alpha: 1)
        ctx.setStrokeColor(UIColor(red: 10/255, green: 13/255, blue: 19/255, alpha: 0.9).cgColor)
        ctx.setLineWidth(9)
        ctx.strokeEllipse(in: CGRect(x: 42, y: 42, width: 44, height: 44))
        ctx.setStrokeColor(col.cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: CGRect(x: 42, y: 42, width: 44, height: 44))
        // anneau : pincee longue vers le menu (orange), ou fixation de secours (bleu)
        let anneau = s.progresMenu > 0.01 ? s.progresMenu : s.dwell
        if anneau > 0.01 {
            let path = UIBezierPath(arcCenter: CGPoint(x: 64, y: 64), radius: 50, startAngle: -.pi / 2,
                                    endAngle: -(.pi / 2) + 2 * .pi * CGFloat(anneau), clockwise: true)
            path.lineWidth = 14
            (s.progresMenu > 0.01 ? UIColor(red: 232/255, green: 196/255, blue: 90/255, alpha: 1)
                                  : UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1)).setStroke()
            path.stroke()
        }
        ctx.setFillColor(col.cgColor)
        // pincee en cours : le point central grossit, comme un bouton enfonce
        let r: CGFloat = s.pince ? 12 : 5
        ctx.fillEllipse(in: CGRect(x: 64 - r, y: 64 - r, width: 2 * r, height: 2 * r))
        UIGraphicsPopContext()
        guard let data = ctx.data else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0, withBytes: data, bytesPerRow: 128 * 4)
    }

    private func creerTextureVide(_ w: Int, _ h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        return device.makeTexture(descriptor: desc)!
    }

    private lazy var panelCtx: CGContext = {
        let ctx = CGContext(
            data: nil, width: Panel.W, height: Panel.H, bitsPerComponent: 8, bytesPerRow: Panel.W * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // pas de retournement : l'image dessinee a l'endroit donne la ligne 0 = haut, comme Metal
        return ctx
    }()

    private func mettreAJour(_ tex: MTLTexture, avec cgImage: CGImage) {
        let w = tex.width, h = tex.height
        let bytesPerRow = w * 4
        let ctx = panelCtx
        // sans ce clear, le fond semi-transparent du menu se superposait aux images precedentes
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
    }

    // ---------- visee (curseur au centre du regard) ----------
    private func viser(dt: Float) {
        if !s.menu { s.hot = -1; return }
        let ps = panelSize()
        let f = -M.columns.2
        let c = cos(panelYaw), sn = sin(panelYaw)
        let N = SIMD3<Float>(sn, 0, c)
        let P = panelCentre + SIMD3<Float>(-sn * s.menuDist, 0, -c * s.menuDist)
        // le rayon du regard part du milieu des yeux
        let O = tetePos
        let den = simd_dot(f, N)
        if den < -1e-4 {
            let t = simd_dot(P - O, N) / den
            if t > 0 {
                let h = O + f * t - P
                let lu = h.x * c + h.z * (-sn)
                let lv = h.y
                /* Le curseur est exactement la ou le regard touche le menu :
                   aucune amplification, il suit la tete a l'identique. */
                s.curU = min(max(lu / ps.0 + 0.5, 0), 1)
                s.curV = min(max(0.5 - lv / ps.1, 0), 1)
            }
        }

        var trouve = -1
        let px = CGFloat(s.curU) * CGFloat(Panel.W), py = CGFloat(s.curV) * CGFloat(Panel.H)
        for (i, z) in panel.zones.enumerated() {
            if px >= z.rect.minX, px <= z.rect.maxX, py >= z.rect.minY, py <= z.rect.maxY {
                trouve = i; break
            }
        }
        if trouve != s.hot {
            // un clic en attente ne doit jamais tomber sur une AUTRE zone
            s.hot = trouve; s.dwell = 0; s.clickWanted = false; panel.draw()
        } else if trouve >= 0 {
            if s.clickWanted {
                s.clickWanted = false; s.dwell = 0
                panel.agir(panel.zones[trouve].id)
            } else if !s.mainsOk {
                // fixation : SECOURS seulement, quand les mains ne sont pas suivies
                s.dwell += dt / 1.2
                if s.dwell >= 1 { s.dwell = 0; panel.agir(panel.zones[trouve].id) }
            } else {
                s.dwell = 0
            }
        }
        s.clickWanted = false
    }

    // ---------- geometrie ----------
    private func panelSize() -> (Float, Float) {
        let pw = 2 * s.menuDist * tan(s.menuAngle * Float.pi / 360)
        return (pw, pw * Float(Panel.H) / Float(Panel.W))
    }

    private func matFromQ(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> matrix_float3x3 {
        matrix_float3x3(columns: (
            SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
            SIMD3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
            SIMD3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y))
        ))
    }

    private func perspective(_ fovy: Float, _ asp: Float, _ n: Float, _ f: Float) -> simd_float4x4 {
        let t = 1 / tan(fovy / 2)
        return simd_float4x4(columns: (
            SIMD4(t / asp, 0, 0, 0),
            SIMD4(0, t, 0, 0),
            SIMD4(0, 0, (f + n) / (n - f), -1),
            SIMD4(0, 0, 2 * f * n / (n - f), 0)
        ))
    }

    private func quadMat(_ U: SIMD3<Float>, _ V: SIMD3<Float>, _ N: SIMD3<Float>, _ P: SIMD3<Float>, _ w: Float, _ h: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(U.x * w, U.y * w, U.z * w, 0),
            SIMD4(V.x * h, V.y * h, V.z * h, 0),
            SIMD4(N.x, N.y, N.z, 0),
            SIMD4(P.x, P.y, P.z, 1)
        ))
    }
}

private extension simd_float4x4 {
    init(_ m3: matrix_float3x3) {
        self.init(columns: (
            SIMD4(m3.columns.0, 0),
            SIMD4(m3.columns.1, 0),
            SIMD4(m3.columns.2, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }
}
