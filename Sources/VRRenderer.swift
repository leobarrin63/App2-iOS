import Foundation
import UIKit
import Metal
import MetalKit
import simd

/* Equivalent de VrRenderer + de la boucle onDrawFrame dans
   MainActivity.kt (Android), en Metal. Meme structure : par oeil, on
   dessine dans une texture intermediaire (decor ou video, puis le
   panneau menu + curseur par-dessus), puis une passe de composition
   applique la distorsion barillet vers la moitie d'ecran correspondante. */

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

final class VRRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let sampler: MTLSamplerState

    private var pEnv: MTLRenderPipelineState!
    private var pVid: MTLRenderPipelineState!
    private var pQuad: MTLRenderPipelineState!
    private var pLens: MTLRenderPipelineState!

    private var quadBuf: MTLBuffer!   // plein ecran, triangle strip
    private var planBuf: MTLBuffer!   // quad panneau/curseur (position+uv)

    private var texPanel: MTLTexture?
    private var texCur: MTLTexture?
    private var fboTex: MTLTexture?
    private var fboW = 0, fboH = 0

    private let panel = Panel()
    private let tete = HeadTracker()
    private var video: VideoBridge!
    private let loader: MTKTextureLoader

    private let s = AppState.shared
    private let bus = VideoBus.shared

    private var viewW = 0, viewH = 0
    private var t0 = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()

    private var Q = SIMD4<Float>(0, 0, 0, 1)   // quaternion lisse
    private var M = matrix_identity_float3x3
    private var panelYaw: Float = 0

    var onEtatChange: (() -> Void)?
    var onOuvrirRecherche: (() -> Void)?

    func definirRecherche(_ texte: String) {
        s.recherche = texte
        s.defil = 0
        panel.draw()
    }

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        loader = MTKTextureLoader(device: device)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        super.init()
        video = VideoBridge(device: device)
        construirePipelines()
        construireBuffers()
        panel.onJouer = { [weak self] v in self?.jouer(v) }
        panel.onRecharger = { [weak self] in self?.chargerCatalogue() }
        panel.onOuvrirRecherche = { [weak self] in self?.onOuvrirRecherche?() }
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
    }

    private func construirePipelines() {
        let lib = device.makeDefaultLibrary()!

        func pipeline(_ vs: String, _ fs: String, format: MTLPixelFormat, blend: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = format
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if vs == "vsQuad" {
                let vdesc = MTLVertexDescriptor()
                vdesc.attributes[0].format = .float3
                vdesc.attributes[0].offset = 0
                vdesc.attributes[0].bufferIndex = 0
                vdesc.attributes[1].format = .float2
                vdesc.attributes[1].offset = MemoryLayout<Float>.size * 3
                vdesc.attributes[1].bufferIndex = 0
                vdesc.layouts[0].stride = MemoryLayout<Float>.size * 5
                d.vertexDescriptor = vdesc
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }

        pEnv = pipeline("vsPlein", "fsEnv", format: .bgra8Unorm, blend: false)
        pVid = pipeline("vsPlein", "fsVid", format: .bgra8Unorm, blend: false)
        pQuad = pipeline("vsQuad", "fsQuad", format: .bgra8Unorm, blend: true)
        pLens = pipeline("vsLens", "fsLens", format: .bgra8Unorm, blend: false)
    }

    private func construireBuffers() {
        let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]
        quadBuf = device.makeBuffer(bytes: quad, length: quad.count * 4)

        // UV identiques a l'original Android : les deux variantes de ce
        // mapping ont deja ete testees sans effet visible (voir historique
        // git) - c'est bien l'option d'origine du chargeur de texture qui
        // controle ce flip, pas ce mapping. Cf. MTKTextureLoader.Origin
        // plus bas, passe a .bottomLeft cette fois (jamais teste seul avec
        // un suivi de tete qui fonctionne correctement).
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
                s.info = l.isEmpty ? "catalogue vide" : "catalogue : \(l.count) videos"
            } catch {
                s.info = "catalogue : echec"
            }
            s.infoT = 6
            s.besoinRedessin = true
        }
    }

    private func jouer(_ v: Video) {
        bus.videoId = v.id
        bus.formatVideo = v.format
        bus.dejaCompte = false
        bus.demandeUrl = v.url
        s.info = "regarde vers le bas pour revenir au menu"
        s.infoT = 5
        s.menu = false
    }

    // ---------- MTKViewDelegate ----------
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewW = Int(size.width); viewH = Int(size.height)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        video.verifierDemandes()

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.05))
        lastFrame = now
        let temps = Float(now - t0)

        // lissage du quaternion
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

        let yaw = atan2(M.columns.2.x, M.columns.2.z)
        s.dbgYaw = yaw
        s.dbgPitch = asin(min(max(M.columns.2.y * -1, -1), 1))
        s.dbgRoll = atan2(M.columns.0.y, M.columns.1.y)

        if !s.menu && s.dbgPitch < -40 * .pi / 180 {
            s.menu = true
            panel.draw()
        }
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

        if s.besoinRedessin { s.besoinRedessin = false; panel.draw() }
        viser(dt: dt)

        if panel.dirty, let img = panel.image {
            texPanel = try? loader.newTexture(cgImage: img, options: [.origin: MTKTextureLoader.Origin.bottomLeft, .SRGB: false])
            panel.dirty = false
        }
        texCur = dessinerCurseur()

        let ew = viewW / 2, eh = viewH
        if ew != fboW || eh != fboH, ew > 0, eh > 0 {
            fboW = ew; fboH = eh
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ew, height: eh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            fboTex = device.makeTexture(descriptor: d)
        }

        guard let cmd = queue.makeCommandBuffer(), let fbo = fboTex, ew > 0, eh > 0 else { return }

        if let nouvelle = video.texturePourFrame() {
            texVidCourante = nouvelle
        }

        renderOeil(cmd: cmd, drawable: drawable.texture, signe: -1, ew: ew, eh: eh, temps: temps, fbo: fbo, premier: true)
        renderOeil(cmd: cmd, drawable: drawable.texture, signe: 1, ew: ew, eh: eh, temps: temps, fbo: fbo, premier: false)

        cmd.present(drawable)
        cmd.commit()
    }

    private var texVidCourante: MTLTexture?

    private func renderOeil(cmd: MTLCommandBuffer, drawable: MTLTexture, signe: Float, ew: Int, eh: Int, temps: Float, fbo: MTLTexture, premier: Bool) {
        let asp = Float(ew) / Float(eh)
        let ipd = s.ipd / 1000
        let ex = signe * ipd / 2
        let proj = perspective(s.fov * .pi / 180, asp, 0.05, 100)
        let view = simd_float4x4(columns: (
            SIMD4(M.columns.0.x, M.columns.1.x, M.columns.2.x, 0),
            SIMD4(M.columns.0.y, M.columns.1.y, M.columns.2.y, 0),
            SIMD4(M.columns.0.z, M.columns.1.z, M.columns.2.z, 0),
            SIMD4(-ex, 0, 0, 1)
        ))
        let VP = proj * view

        // ---- passe hors-ecran : decor ou video, puis panneau + curseur ----
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = fbo
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(ew), height: Double(eh), znear: 0, zfar: 1))

        if bus.enLecture, let texVid = texVidCourante {
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
        } else {
            enc.setRenderPipelineState(pEnv)
            enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
            let ty = tan(s.fov * .pi / 360)
            var u = EnvUniforms(uRot: simd_float4x4(M), uTan: SIMD2(ty * asp, ty), uEye: SIMD3(ex, 0, 0), uT: temps)
            enc.setFragmentBytes(&u, length: MemoryLayout<EnvUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if s.menu, let texPanel {
            let ps = panelSize()
            let c = cos(panelYaw), sn = sin(panelYaw)
            let U = SIMD3<Float>(c, 0, -sn)
            let V = SIMD3<Float>(0, 1, 0)
            let N = SIMD3<Float>(sn, 0, c)
            let P = SIMD3<Float>(-sn * s.menuDist, 0, -c * s.menuDist)

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
                let rs = 2 * s.menuDist * tan(3 * Float.pi / 180)
                let cx = (s.curU - 0.5) * ps.0
                let cy = (0.5 - s.curV) * ps.1
                let CP = SIMD3<Float>(
                    P.x + U.x * cx + V.x * cy + N.x * 0.012,
                    P.y + U.y * cx + V.y * cy + N.y * 0.012,
                    P.z + U.z * cx + V.z * cy + N.z * 0.012)
                var mvpC = VP * quadMat(U, V, N, CP, rs, rs)
                enc.setVertexBytes(&mvpC, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                var alphaC: Float = 0.95
                enc.setFragmentBytes(&alphaC, length: 4, index: 0)
                enc.setFragmentTexture(texCur, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()

        // ---- passe de composition : distorsion barillet vers la moitie d'ecran ----
        let rpF = MTLRenderPassDescriptor()
        rpF.colorAttachments[0].texture = drawable
        rpF.colorAttachments[0].loadAction = premier ? .clear : .load
        rpF.colorAttachments[0].storeAction = .store
        rpF.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encF = cmd.makeRenderCommandEncoder(descriptor: rpF) else { return }
        encF.setViewport(MTLViewport(originX: signe < 0 ? 0 : Double(ew), originY: 0, width: Double(ew), height: Double(eh), znear: 0, zfar: 1))
        encF.setRenderPipelineState(pLens)
        encF.setVertexBuffer(quadBuf, offset: 0, index: 0)
        var lu = LensUniforms(uK1: -s.k1, uAsp: asp)
        encF.setFragmentBytes(&lu, length: MemoryLayout<LensUniforms>.stride, index: 0)
        encF.setFragmentTexture(fbo, index: 0)
        encF.setFragmentSamplerState(sampler, index: 0)
        encF.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encF.endEncoding()
    }

    private func dessinerCurseur() -> MTLTexture? {
        let taille = 128
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: taille, height: taille))
        let img = renderer.image { rc in
            let ctx = rc.cgContext
            let col: UIColor = s.hot >= 0 ? UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1) : UIColor(red: 124/255, green: 178/255, blue: 240/255, alpha: 1)
            ctx.setStrokeColor(UIColor(red: 10/255, green: 13/255, blue: 19/255, alpha: 0.9).cgColor)
            ctx.setLineWidth(9)
            ctx.strokeEllipse(in: CGRect(x: 42, y: 42, width: 44, height: 44))
            ctx.setStrokeColor(col.cgColor)
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: 42, y: 42, width: 44, height: 44))
            if s.dwell > 0.01 {
                ctx.setStrokeColor(UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1).cgColor)
                ctx.setLineWidth(8)
                let path = UIBezierPath(arcCenter: CGPoint(x: 64, y: 64), radius: 34, startAngle: -.pi / 2, endAngle: -(.pi / 2) + 2 * .pi * CGFloat(s.dwell), clockwise: true)
                path.stroke()
            }
            ctx.setFillColor(col.cgColor)
            ctx.fillEllipse(in: CGRect(x: 59, y: 59, width: 10, height: 10))
        }
        guard let cg = img.cgImage else { return nil }
        return try? loader.newTexture(cgImage: cg, options: [.origin: MTKTextureLoader.Origin.bottomLeft, .SRGB: false])
    }

    // ---------- visee (curseur base sur le regard) ----------
    private func viser(dt: Float) {
        if !s.menu { s.hot = -1; return }
        let ps = panelSize()
        let f = SIMD3<Float>(-M.columns.2.x, -M.columns.2.y, -M.columns.2.z)
        let c = cos(panelYaw), sn = sin(panelYaw)
        let N = SIMD3<Float>(sn, 0, c)
        let P = SIMD3<Float>(-sn * s.menuDist, 0, -c * s.menuDist)
        let den = f.x * N.x + f.y * N.y + f.z * N.z
        if den < -1e-4 {
            let t = (P.x * N.x + P.y * N.y + P.z * N.z) / den
            if t > 0 {
                let hx = f.x * t - P.x, hy2 = f.y * t - P.y, hz = f.z * t - P.z
                let lu = hx * c + hz * (-sn)
                let lv = hy2
                s.curU = lu / ps.0 + 0.5
                s.curV = 0.5 - lv / ps.1
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
            s.hot = trouve; s.dwell = 0; panel.draw()
        } else if trouve >= 0 {
            if s.clickWanted {
                s.clickWanted = false; s.dwell = 0
                panel.agir(panel.zones[trouve].id)
            } else {
                s.dwell += dt / 1.2
                if s.dwell >= 1 { s.dwell = 0; panel.agir(panel.zones[trouve].id) }
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

    // ---------- entrees ----------
    func tap() {
        if !s.menu { s.menu = true } else { s.clickWanted = true }
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
