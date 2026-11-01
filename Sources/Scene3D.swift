import Foundation
import Metal
import MetalKit
import ImageIO
import AVFoundation
import simd

// uniforms des shaders de scene (meme disposition que dans Shaders.metal)
struct SceneV { var mvp: simd_float4x4; var m: simd_float4x4 }
struct SceneF {
    var col: SIMD4<Float>     // couleur de base
    var cam: SIMD4<Float>     // xyz : oeil ; w : seuil d'alpha (MASK)
    var a: SIMD4<Float>       // presence : couleur, relief, rugosite/metal, ombrage
    var b: SIMD4<Float>       // echelle du relief, rugosite, metal, force de l'ombrage
}

/*  Une scene glTF binaire (.glb) chargee depuis le telephone - equivalent
    de Scene3D dans MainActivity.kt (Android).

    Le fichier peut peser plusieurs centaines de Mo : il est projete en
    memoire (jamais lu en entier), la geometrie part dans des tampons Metal,
    et les images sont decodees une par une DIRECTEMENT a la taille voulue
    (plafond selon la memoire du telephone), puis envoyees au GPU. La scene
    apparait tout de suite et ses textures se remplissent au fur et a mesure.

    Animation (personnage qui danse) :
    - la hierarchie des noeuds est gardee et recalculee a chaque image ;
    - animation glTF standard (translation / rotation / echelle des os) ;
    - skinning sur le processeur, sur une file a part : autant d'os que le
      fichier en contient (341 pour un MetaHuman) ; les meshes portes a 100 %
      par un seul os (cheveux, sourcils) sont dessines avec la matrice de cet
      os, sans calcul par sommet ;
    - vetements simules : cache de sommets image par image (extras
      "kyoh_cache", positions en uint16), normales recalculees ici ;
    - musique (extras "kyoh_audio") lue depuis le .glb ; c'est elle qui
      donne l'heure a l'animation.

    Placement : la tete demarre a (0 ; 1,60 ; 0) dans le repere de la scene
    (origine au sol, Y en haut, metres), regard vers -Z.                   */
final class Scene3D {
    let url: URL
    private let device: MTLDevice
    private let plafond: Int
    private let chargeur: MTKTextureLoader
    private let verrou = NSLock()

    struct Mat {
        var col = SIMD4<Float>(1, 1, 1, 1)
        var image = -1, imageN = -1, imageM = -1, imageO = -1
        var cut: Float = 0, nEch: Float = 1, rugo: Float = 1, metal: Float = 0, oForce: Float = 1
        var blend = false, deuxFaces = false
    }

    final class Cache {
        let debut: Int, images: Int, n: Int
        let fps: Float
        let mn: SIMD3<Float>, ech: SIMD3<Float>
        init(debut: Int, images: Int, n: Int, fps: Float, mn: SIMD3<Float>, ech: SIMD3<Float>) {
            self.debut = debut; self.images = images; self.n = n; self.fps = fps; self.mn = mn; self.ech = ech
        }
    }

    final class Anim {
        let peau: Int
        let pos0: [Float]
        let nrmSrc: [Float]
        let aNormales: Bool
        let joints: [Int32]
        let poids: [Float]
        let cache: Cache?
        let tri: [UInt32]
        var pos: [Float]
        var nrm: [Float]
        let rigide: Int
        init(peau: Int, pos0: [Float], nrm0: [Float]?, joints: [Int32], poids: [Float], cache: Cache?, tri: [UInt32]) {
            self.peau = peau; self.pos0 = pos0
            self.aNormales = nrm0 != nil
            self.nrmSrc = nrm0 ?? [Float](repeating: 0, count: pos0.count)
            self.joints = joints; self.poids = poids; self.cache = cache; self.tri = tri
            pos = pos0
            nrm = nrm0 ?? [Float](repeating: 0, count: pos0.count)
            var r = -1
            let n = pos0.count / 3
            if !joints.isEmpty && joints.count >= n * 4 && poids.count >= n * 4 {
                r = Int(joints[0])
                for v in 0..<n where !(poids[v * 4] >= 0.999 && Int(joints[v * 4]) == r) { r = -1; break }
            }
            rigide = r
        }
    }

    final class Prim {
        let vPos: [MTLBuffer]          // 1 tampon (fixe) ou 3 en anneau (anime)
        let vNrm: [MTLBuffer]
        let vUv: MTLBuffer
        let ibo: MTLBuffer?
        let n: Int, mat: Int, noeud: Int
        let anim: Anim?
        let aUv: Bool
        var anneau = 0
        init(vPos: [MTLBuffer], vNrm: [MTLBuffer], vUv: MTLBuffer, ibo: MTLBuffer?, n: Int, mat: Int,
             noeud: Int, anim: Anim?, aUv: Bool) {
            self.vPos = vPos; self.vNrm = vNrm; self.vUv = vUv; self.ibo = ibo; self.n = n; self.mat = mat
            self.noeud = noeud; self.anim = anim; self.aUv = aUv
        }
    }

    final class Noeud {
        let parent: Int
        var t: SIMD3<Float>, r: SIMD4<Float>, s: SIMD3<Float>
        let fixe: simd_float4x4?
        init(parent: Int, t: SIMD3<Float>, r: SIMD4<Float>, s: SIMD3<Float>, fixe: simd_float4x4?) {
            self.parent = parent; self.t = t; self.r = r; self.s = s; self.fixe = fixe
        }
    }

    final class Peau {
        let joints: [Int]
        let ibm: [simd_float4x4]
        var mats: [simd_float4x4]
        var calc: [simd_float4x4]
        var affiche: [simd_float4x4]
        init(joints: [Int], ibm: [simd_float4x4]) {
            self.joints = joints; self.ibm = ibm
            mats = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
            calc = mats; affiche = mats
        }
    }

    struct Canal { let noeud: Int; let chemin: Int; let temps: [Float]; let vals: [Float]; let nc: Int; let mode: Int }

    private(set) var prete = false
    private(set) var erreur: String?
    private(set) var imagesTotal = 0
    private(set) var imagesFaites = 0
    private var arret = false

    private var mats: [Mat] = []
    private var prims: [Prim] = []
    private var textures: [Int: MTLTexture] = [:]
    private var noeuds: [Noeud] = []
    private var ordre: [Int] = []
    private var mondes: [simd_float4x4] = []
    private var peaux: [Peau] = []
    private var canaux: [Canal] = []
    private(set) var duree: Float = 0
    private var data = Data()
    private var debutBin = 0
    private var lecteur: AVAudioPlayer?
    private var lecteurLance = false
    private var t0: CFTimeInterval = 0
    private let racine: simd_float4x4 = {
        var m = matrix_identity_float4x4; m.columns.3.y = -1.6; return m
    }()

    private let calcul = DispatchQueue(label: "scene.calcul", qos: .userInitiated)
    private var calculEnCours = false
    private var resultatPret = false

    // JSON du glTF, garde pendant le chargement
    private var accs: [[String: Any]] = []
    private var vues: [[String: Any]] = []

    init(url: URL, device: MTLDevice, plafond: Int) {
        self.url = url; self.device = device; self.plafond = plafond
        chargeur = MTKTextureLoader(device: device)
    }

    func demarrer() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { try self.charger() } catch { self.erreur = String(describing: error) }
        }
    }

    func liberer() {
        arret = true
        lecteur?.stop()
        lecteur = nil
    }

    // ---------- petits lecteurs ----------
    private func num(_ a: Any?) -> Float? { (a as? NSNumber)?.floatValue }
    private func ent(_ a: Any?) -> Int? { (a as? NSNumber)?.intValue }
    private func vec(_ a: Any?, _ n: Int, _ def: [Float]) -> [Float] {
        guard let l = a as? [Any], l.count == n else { return def }
        return l.map { num($0) ?? 0 }
    }

    private enum ErreurScene: Error { case format }

    // Lit un accesseur en flottants, quel que soit son type stocke
    private func tableau(_ ai: Int, _ nc: Int) -> [Float]? {
        guard ai >= 0, ai < accs.count else { return nil }
        let a = accs[ai]
        guard let bvi = ent(a["bufferView"]), bvi >= 0, bvi < vues.count else { return nil }
        let bv = vues[bvi]
        let ct = ent(a["componentType"]) ?? 5126
        let norm = (a["normalized"] as? Bool) ?? false
        let taille = (ct == 5126 || ct == 5125) ? 4 : ((ct == 5123 || ct == 5122) ? 2 : 1)
        let debut = debutBin + (ent(bv["byteOffset"]) ?? 0) + (ent(a["byteOffset"]) ?? 0)
        let st = ent(bv["byteStride"]) ?? 0
        let pas = st == 0 ? nc * taille : st
        let n = ent(a["count"]) ?? 0
        var out = [Float](repeating: 0, count: n * nc)
        data.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<n {
                    for c in 0..<nc {
                        let off = debut + i * pas + c * taille
                        let v: Float
                        switch ct {
                        case 5126: v = raw.loadUnaligned(fromByteOffset: off, as: Float.self)
                        case 5125: v = Float(raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
                        case 5123:
                            let u = Float(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                            v = norm ? u / 65535 : u
                        case 5122:
                            let u = Float(raw.loadUnaligned(fromByteOffset: off, as: Int16.self))
                            v = norm ? max(u / 32767, -1) : u
                        case 5121:
                            let u = Float(raw[off])
                            v = norm ? u / 255 : u
                        default:
                            let u = Float(Int8(bitPattern: raw[off]))
                            v = norm ? max(u / 127, -1) : u
                        }
                        o[i * nc + c] = v
                    }
                }
            }
        }
        return out
    }

    private func indices(_ ai: Int) -> [UInt32]? {
        guard ai >= 0, ai < accs.count else { return nil }
        let a = accs[ai]
        guard let bvi = ent(a["bufferView"]), bvi >= 0, bvi < vues.count else { return nil }
        let bv = vues[bvi]
        let ct = ent(a["componentType"]) ?? 5125
        let debut = debutBin + (ent(bv["byteOffset"]) ?? 0) + (ent(a["byteOffset"]) ?? 0)
        let n = ent(a["count"]) ?? 0
        var out = [UInt32](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<n {
                    switch ct {
                    case 5125: o[i] = raw.loadUnaligned(fromByteOffset: debut + i * 4, as: UInt32.self)
                    case 5123: o[i] = UInt32(raw.loadUnaligned(fromByteOffset: debut + i * 2, as: UInt16.self))
                    default: o[i] = UInt32(raw[debut + i])
                    }
                }
            }
        }
        return out
    }

    private func tampon(_ v: [Float]) -> MTLBuffer {
        v.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 4), options: .storageModeShared)! }
    }

    // ---------- lecture du fichier (file a part) ----------
    private func charger() throws {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        data = d
        guard d.count >= 28 else { throw ErreurScene.format }
        let magic = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x46546C67 else { throw ErreurScene.format }
        let lgJson = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        guard let json = try JSONSerialization.jsonObject(with: d.subdata(in: 20..<(20 + lgJson))) as? [String: Any]
        else { throw ErreurScene.format }
        debutBin = 28 + lgJson

        accs = json["accessors"] as? [[String: Any]] ?? []
        vues = json["bufferViews"] as? [[String: Any]] ?? []
        let textures = json["textures"] as? [[String: Any]] ?? []

        // ---- materiaux : couleur, relief, rugosite/metal, ombrage ----
        func source(_ info: Any?) -> Int {
            guard let t = info as? [String: Any], let ti = ent(t["index"]), ti >= 0, ti < textures.count else { return -1 }
            return ent(textures[ti]["source"]) ?? -1
        }
        var lm: [Mat] = []
        for m in json["materials"] as? [[String: Any]] ?? [] {
            var mat = Mat()
            let pbr = m["pbrMetallicRoughness"] as? [String: Any]
            let f = vec(pbr?["baseColorFactor"], 4, [1, 1, 1, 1])
            mat.col = SIMD4(f[0], f[1], f[2], f[3])
            mat.image = source(pbr?["baseColorTexture"])
            mat.imageM = source(pbr?["metallicRoughnessTexture"])
            mat.rugo = num(pbr?["roughnessFactor"]) ?? 1
            mat.metal = num(pbr?["metallicFactor"]) ?? (pbr == nil ? 0 : 1)
            let nt = m["normalTexture"] as? [String: Any]
            mat.imageN = source(nt); mat.nEch = num(nt?["scale"]) ?? 1
            let ot = m["occlusionTexture"] as? [String: Any]
            mat.imageO = source(ot); mat.oForce = num(ot?["strength"]) ?? 1
            let mode = m["alphaMode"] as? String ?? "OPAQUE"
            mat.cut = mode == "MASK" ? (num(m["alphaCutoff"]) ?? 0.5) : 0
            mat.blend = mode == "BLEND"
            mat.deuxFaces = (m["doubleSided"] as? Bool) ?? false
            lm.append(mat)
        }
        var defaut = Mat(); defaut.col = SIMD4(0.8, 0.8, 0.8, 1); defaut.deuxFaces = true
        lm.append(defaut)
        mats = lm

        // ---- noeuds : la hierarchie est gardee (l'animation la modifie) ----
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        var parents = [Int](repeating: -1, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            for c in (n["children"] as? [Any] ?? []) { if let ci = ent(c), ci < nodes.count { parents[ci] = i } }
        }
        noeuds = nodes.enumerated().map { (i, n) in
            var fixe: simd_float4x4? = nil
            if let m = n["matrix"] as? [Any], m.count == 16 {
                let v = m.map { num($0) ?? 0 }
                fixe = simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                               SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
            }
            let t = vec(n["translation"], 3, [0, 0, 0]), r = vec(n["rotation"], 4, [0, 0, 0, 1]), s = vec(n["scale"], 3, [1, 1, 1])
            return Noeud(parent: parents[i], t: SIMD3(t[0], t[1], t[2]), r: SIMD4(r[0], r[1], r[2], r[3]),
                         s: SIMD3(s[0], s[1], s[2]), fixe: fixe)
        }
        var lo: [Int] = []
        func descendre(_ i: Int) {
            lo.append(i)
            for c in (nodes[i]["children"] as? [Any] ?? []) { if let ci = ent(c), ci < nodes.count { descendre(ci) } }
        }
        if let scenes = json["scenes"] as? [[String: Any]], !scenes.isEmpty {
            let si = min(max(ent(json["scene"]) ?? 0, 0), scenes.count - 1)
            for r in (scenes[si]["nodes"] as? [Any] ?? []) { if let ri = ent(r), ri < nodes.count { descendre(ri) } }
        } else {
            for i in 0..<nodes.count where parents[i] < 0 { descendre(i) }
        }
        ordre = lo
        mondes = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)

        // ---- peaux (skinning) ----
        peaux = (json["skins"] as? [[String: Any]] ?? []).map { sk in
            let joints = (sk["joints"] as? [Any] ?? []).map { min(max(ent($0) ?? 0, 0), max(nodes.count - 1, 0)) }
            let brut = ent(sk["inverseBindMatrices"]).flatMap { tableau($0, 16) }
            let ibm: [simd_float4x4] = (0..<joints.count).map { j in
                guard let b = brut, b.count >= (j + 1) * 16 else { return matrix_identity_float4x4 }
                let o = j * 16
                return simd_float4x4(columns: (SIMD4(b[o], b[o + 1], b[o + 2], b[o + 3]), SIMD4(b[o + 4], b[o + 5], b[o + 6], b[o + 7]),
                                               SIMD4(b[o + 8], b[o + 9], b[o + 10], b[o + 11]), SIMD4(b[o + 12], b[o + 13], b[o + 14], b[o + 15])))
            }
            return Peau(joints: joints, ibm: ibm)
        }

        // ---- animation : la premiere du fichier ----
        var lc: [Canal] = []
        var dureeAnim: Float = 0
        if let an = (json["animations"] as? [[String: Any]])?.first {
            let samplers = an["samplers"] as? [[String: Any]] ?? []
            for c in an["channels"] as? [[String: Any]] ?? [] {
                guard let cible = c["target"] as? [String: Any], let ni = ent(cible["node"]), ni >= 0, ni < nodes.count,
                      let si = ent(c["sampler"]), si < samplers.count else { continue }
                let chemin: Int
                switch cible["path"] as? String ?? "" {
                case "translation": chemin = 0
                case "rotation": chemin = 1
                case "scale": chemin = 2
                default: continue
                }
                let smp = samplers[si]
                let nc = chemin == 1 ? 4 : 3
                guard let ii = ent(smp["input"]), let oi = ent(smp["output"]),
                      let temps = tableau(ii, 1), let vals = tableau(oi, nc), !temps.isEmpty else { continue }
                let mode: Int
                switch smp["interpolation"] as? String ?? "LINEAR" {
                case "STEP": mode = 1
                case "CUBICSPLINE": mode = 2
                default: mode = 0
                }
                dureeAnim = max(dureeAnim, temps.last!)
                lc.append(Canal(noeud: ni, chemin: chemin, temps: temps, vals: vals, nc: nc, mode: mode))
            }
        }
        canaux = lc
        var dureeTotale = dureeAnim

        // ---- primitives, dans l'ordre de la hierarchie ----
        var sortie: [Prim] = []
        for ni in ordre {
            if arret { return }
            let n = nodes[ni]
            guard let mi0 = ent(n["mesh"]), mi0 < meshes.count else { continue }
            let me = meshes[mi0]
            let peau = (ent(n["skin"]).map { $0 < peaux.count ? $0 : -1 }) ?? -1
            let kc = (me["extras"] as? [String: Any])?["kyoh_cache"] as? [String: Any]
            for (k, pr) in (me["primitives"] as? [[String: Any]] ?? []).enumerated() {
                if (ent(pr["mode"]) ?? 4) != 4 { continue }               // triangles seulement
                guard let at = pr["attributes"] as? [String: Any], let pa = ent(at["POSITION"]),
                      let pos0 = tableau(pa, 3) else { continue }
                let nv = pos0.count / 3
                let nrm0 = ent(at["NORMAL"]).flatMap { tableau($0, 3) }
                let uv = ent(at["TEXCOORD_0"]).flatMap { tableau($0, 2) }
                var mi = ent(pr["material"]) ?? -1
                if mi < 0 || mi >= lm.count - 1 { mi = lm.count - 1 }
                let idx = ent(pr["indices"]).flatMap { indices($0) }

                // vetement simule : cache image par image (une seule primitive par mesh)
                var cache: Cache? = nil
                if let kc, k == 0, ent(kc["count"]) == nv, let bvi = ent(kc["bufferView"]), bvi < vues.count {
                    let mn = vec(kc["min"], 3, [0, 0, 0]), mx = vec(kc["max"], 3, [1, 1, 1])
                    let c = Cache(debut: ent(vues[bvi]["byteOffset"]) ?? 0, images: ent(kc["frames"]) ?? 1, n: nv,
                                  fps: num(kc["fps"]) ?? 30, mn: SIMD3(mn[0], mn[1], mn[2]),
                                  ech: SIMD3(mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]))
                    cache = c
                    dureeTotale = max(dureeTotale, Float(c.images) / c.fps)
                }
                let jiA = ent(at["JOINTS_0"]), wiA = ent(at["WEIGHTS_0"])
                let skinne = peau >= 0 && jiA != nil && wiA != nil
                var anim: Anim? = nil
                if skinne || cache != nil {
                    let tri = idx ?? (0..<UInt32(nv)).map { $0 }
                    let joints: [Int32] = skinne ? (tableau(jiA!, 4) ?? []).map { Int32($0) } : []
                    let poids: [Float] = skinne ? (tableau(wiA!, 4) ?? []) : []
                    anim = Anim(peau: skinne ? peau : -1, pos0: pos0, nrm0: nrm0, joints: joints, poids: poids,
                                cache: cache, tri: tri)
                }
                // normales absentes : vers le haut (recalculees si la primitive bouge)
                let nrm = nrm0 ?? (0..<nv * 3).map { $0 % 3 == 1 ? Float(1) : 0 }
                let anneaux = anim != nil && (anim!.rigide < 0) ? 3 : 1
                let vp = (0..<anneaux).map { _ in tampon(pos0) }
                let vn = (0..<anneaux).map { _ in tampon(nrm) }
                let vu = tampon(uv ?? [Float](repeating: 0, count: nv * 2))
                var ibo: MTLBuffer? = nil
                if let idx { ibo = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 4), options: .storageModeShared) } }
                sortie.append(Prim(vPos: vp, vNrm: vn, vUv: vu, ibo: ibo, n: idx?.count ?? nv, mat: mi,
                                   noeud: ni, anim: anim, aUv: uv != nil))
            }
        }

        // ---- musique, lue dans le .glb ----
        if let au = (json["extras"] as? [String: Any])?["kyoh_audio"] as? [String: Any],
           let bvi = ent(au["bufferView"]), bvi < vues.count {
            let bv = vues[bvi]
            let off = debutBin + (ent(bv["byteOffset"]) ?? 0)
            let lg = ent(bv["byteLength"]) ?? 0
            if lg > 0, off + lg <= d.count {
                do {
                    let p = try AVAudioPlayer(data: d.subdata(in: off..<(off + lg)), fileTypeHint: AVFileType.m4a.rawValue)
                    p.numberOfLoops = -1
                    p.prepareToPlay()
                    lecteur = p
                    dureeTotale = max(dureeTotale, num(au["duree"]) ?? 0)
                } catch {
                    erreur = "musique illisible"
                }
            }
        }
        duree = dureeTotale
        calculerMondes()
        verrou.lock(); prims = sortie; prete = true; verrou.unlock()

        // ---- images : couleurs d'abord, puis relief, rugosite, ombrage ----
        let images = json["images"] as? [[String: Any]] ?? []
        var utiles: [Int] = []
        for liste in [lm.map { $0.image }, lm.map { $0.imageN }, lm.map { $0.imageM }, lm.map { $0.imageO }] {
            for i in liste where i >= 0 && i < images.count && !utiles.contains(i) { utiles.append(i) }
        }
        imagesTotal = utiles.count
        for ii in utiles {
            if arret { return }
            autoreleasepool {
                let im = images[ii]
                if let bvi = ent(im["bufferView"]), bvi < vues.count {
                    let bv = vues[bvi]
                    let off = debutBin + (ent(bv["byteOffset"]) ?? 0)
                    let lg = ent(bv["byteLength"]) ?? 0
                    if lg > 0, off + lg <= d.count,
                       let src = CGImageSourceCreateWithData(d.subdata(in: off..<(off + lg)) as CFData, nil) {
                        /* Decodee directement a la taille voulue : une 8192x8192
                           decodee en entier occuperait 256 Mo pour rien. */
                        let opts: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: plafond,
                            kCGImageSourceCreateThumbnailWithTransform: false,
                        ]
                        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                           let tex = try? chargeur.newTexture(cgImage: cg, options: [
                               .SRGB: false,
                               .generateMipmaps: true,
                               .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                               .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                           ]) {
                            verrou.lock(); self.textures[ii] = tex; verrou.unlock()
                        }
                    }
                }
                imagesFaites += 1
            }
        }
    }

    // ---------- animation (rendu, une fois par image) ----------
    private func trs(_ n: Noeud) -> simd_float4x4 {
        if let f = n.fixe { return f }
        let q = simd_quatf(ix: n.r.x, iy: n.r.y, iz: n.r.z, r: n.r.w)
        var m = simd_float4x4(q)
        m.columns.0 *= n.s.x; m.columns.1 *= n.s.y; m.columns.2 *= n.s.z
        m.columns.3 = SIMD4(n.t.x, n.t.y, n.t.z, 1)
        return m
    }

    private func calculerMondes() {
        for i in ordre {
            let n = noeuds[i]
            let par = n.parent >= 0 ? mondes[n.parent] : racine
            mondes[i] = par * trs(n)
        }
    }

    // valeur d'un canal a l'instant t (lineaire, palier ou spline)
    private func echantillon(_ c: Canal, _ t: Float) -> SIMD4<Float> {
        let ts = c.temps, n = ts.count, nc = c.nc
        let bloc = c.mode == 2 ? 3 : 1
        let decal = c.mode == 2 ? 1 : 0
        func valeur(_ k: Int) -> SIMD4<Float> {
            let o = (k * bloc + decal) * nc
            return SIMD4(c.vals[o], c.vals[o + 1], c.vals[o + 2], nc == 4 ? c.vals[o + 3] : 0)
        }
        if n == 1 || t <= ts[0] { return valeur(0) }
        if t >= ts[n - 1] { return valeur(n - 1) }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if ts[m] <= t { lo = m } else { hi = m } }
        let f: Float = c.mode == 1 ? 0 : (t - ts[lo]) / (ts[hi] - ts[lo])
        let a = valeur(lo), b = valeur(hi)
        if nc == 4 {
            // quaternions : interpolation normalisee, par le plus court chemin
            let sg: Float = simd_dot(a, b) < 0 ? -1 : 1
            return simd_normalize(a * (1 - f) + b * f * sg)
        }
        return a * (1 - f) + b * f
    }

    func animer() {
        guard prete, duree > 0 else { return }
        if let lp = lecteur, !lecteurLance { lp.play(); lecteurLance = true }
        if t0 == 0 { t0 = CACurrentMediaTime() }
        var t: Float
        if let lp = lecteur, lecteurLance { t = Float(lp.currentTime) } else { t = Float(CACurrentMediaTime() - t0) }
        t = t.truncatingRemainder(dividingBy: duree)

        if !canaux.isEmpty {
            for c in canaux {
                let v = echantillon(c, t)
                let nd = noeuds[c.noeud]
                switch c.chemin {
                case 0: nd.t = SIMD3(v.x, v.y, v.z)
                case 1: nd.r = v
                default: nd.s = SIMD3(v.x, v.y, v.z)
                }
            }
            calculerMondes()
            for pe in peaux { for j in 0..<pe.joints.count { pe.mats[j] = mondes[pe.joints[j]] * pe.ibm[j] } }
        }

        /* Le calcul des sommets (peau + vetements) tourne sur une file a part :
           l'affichage ne l'attend jamais. Quand un calcul est fini, ses
           resultats partent dans le tampon suivant de l'anneau, et on lance le
           calcul suivant avec la pose du moment. */
        verrou.lock(); let enCours = calculEnCours; let pret = resultatPret; verrou.unlock()
        if enCours { return }
        if pret {
            for p in prims {
                guard let a = p.anim, a.rigide < 0, p.vPos.count == 3 else { continue }
                let k = (p.anneau + 1) % 3
                a.pos.withUnsafeBytes { memcpy(p.vPos[k].contents(), $0.baseAddress!, $0.count) }
                a.nrm.withUnsafeBytes { memcpy(p.vNrm[k].contents(), $0.baseAddress!, $0.count) }
                p.anneau = k
            }
            for pe in peaux { pe.affiche = pe.calc }
            verrou.lock(); resultatPret = false; verrou.unlock()
        }
        for pe in peaux { pe.calc = pe.mats }
        let tCalc = t
        verrou.lock(); calculEnCours = true; verrou.unlock()
        calcul.async { [weak self] in
            guard let self else { return }
            for p in self.prims {
                guard let a = p.anim, a.rigide < 0 else { continue }
                if a.peau >= 0 { self.skinner(a, self.peaux[a.peau]) } else if let c = a.cache { self.rejouer(a, c, tCalc) }
            }
            self.verrou.lock(); self.resultatPret = true; self.calculEnCours = false; self.verrou.unlock()
        }
    }

    // skinning : chaque sommet = somme ponderee de ses (au plus) 4 os (pose "calc")
    private func skinner(_ a: Anim, _ pe: Peau) {
        let mats = pe.calc
        let n = a.pos0.count / 3
        guard a.joints.count >= n * 4, a.poids.count >= n * 4 else { return }
        a.pos0.withUnsafeBufferPointer { p0 in
            a.nrmSrc.withUnsafeBufferPointer { n0 in
                a.joints.withUnsafeBufferPointer { jj in
                    a.poids.withUnsafeBufferPointer { ww in
                        a.pos.withUnsafeMutableBufferPointer { po in
                            a.nrm.withUnsafeMutableBufferPointer { no in
                                for v in 0..<n {
                                    let x = SIMD4<Float>(p0[v * 3], p0[v * 3 + 1], p0[v * 3 + 2], 1)
                                    let nn = SIMD4<Float>(n0[v * 3], n0[v * 3 + 1], n0[v * 3 + 2], 0)
                                    var acc = SIMD4<Float>(repeating: 0), accN = SIMD4<Float>(repeating: 0)
                                    for k in 0..<4 {
                                        let w = ww[v * 4 + k]
                                        if w == 0 { continue }
                                        let j = Int(jj[v * 4 + k])
                                        if j < 0 || j >= mats.count { continue }
                                        let m = mats[j]
                                        acc += w * (m * x)
                                        accN += w * (m * nn)
                                    }
                                    po[v * 3] = acc.x; po[v * 3 + 1] = acc.y; po[v * 3 + 2] = acc.z
                                    let l = 1 / max((accN.x * accN.x + accN.y * accN.y + accN.z * accN.z).squareRoot(), 1e-6)
                                    no[v * 3] = accN.x * l; no[v * 3 + 1] = accN.y * l; no[v * 3 + 2] = accN.z * l
                                }
                            }
                        }
                    }
                }
            }
        }
        if !a.aNormales { normales(a) }
    }

    // vetement : positions de l'image courante, interpolees avec la suivante
    private func rejouer(_ a: Anim, _ c: Cache, _ t: Float) {
        let f = t * c.fps
        let i0 = ((Int(f.rounded(.down)) % c.images) + c.images) % c.images
        let i1 = (i0 + 1) % c.images
        let fr = f - f.rounded(.down)
        let o0 = debutBin + c.debut + i0 * c.n * 6
        let o1 = debutBin + c.debut + i1 * c.n * 6
        let mn = [c.mn.x, c.mn.y, c.mn.z], ech = [c.ech.x, c.ech.y, c.ech.z]
        data.withUnsafeBytes { raw in
            a.pos.withUnsafeMutableBufferPointer { po in
                for v in 0..<(c.n * 3) {
                    let q0 = Float(raw.loadUnaligned(fromByteOffset: o0 + v * 2, as: UInt16.self)) / 65535
                    let q1 = Float(raw.loadUnaligned(fromByteOffset: o1 + v * 2, as: UInt16.self)) / 65535
                    let k = v % 3
                    po[v] = mn[k] + (q0 + (q1 - q0) * fr) * ech[k]
                }
            }
        }
        normales(a)
    }

    // normales lissees : somme des normales des triangles autour de chaque sommet
    private func normales(_ a: Anim) {
        // ecrit dans le tableau du sommet lui-meme (echange : pas de copie ni d'allocation)
        var out: [Float] = []
        swap(&out, &a.nrm)
        defer { swap(&out, &a.nrm) }
        let p: [Float] = a.pos
        let tri: [UInt32] = a.tri
        let np: Int = p.count
        guard out.count == np else { return }
        for i in 0..<np { out[i] = 0 }
        var i = 0
        while i + 2 < tri.count {
            let ia = Int(tri[i]) * 3
            let ib = Int(tri[i + 1]) * 3
            let ic = Int(tri[i + 2]) * 3
            i += 3
            if ia + 2 >= np || ib + 2 >= np || ic + 2 >= np { continue }
            let pa = SIMD3<Float>(p[ia], p[ia + 1], p[ia + 2])
            let u: SIMD3<Float> = SIMD3<Float>(p[ib], p[ib + 1], p[ib + 2]) - pa
            let w: SIMD3<Float> = SIMD3<Float>(p[ic], p[ic + 1], p[ic + 2]) - pa
            let n: SIMD3<Float> = simd_cross(u, w)
            out[ia] += n.x; out[ia + 1] += n.y; out[ia + 2] += n.z
            out[ib] += n.x; out[ib + 1] += n.y; out[ib + 2] += n.z
            out[ic] += n.x; out[ic + 1] += n.y; out[ic + 2] += n.z
        }
        var v = 0
        while v + 2 < np {
            let l: Float = simd_length(SIMD3<Float>(out[v], out[v + 1], out[v + 2]))
            let k: Float = l > 1e-9 ? 1 / l : 0
            out[v] *= k; out[v + 1] *= k; out[v + 2] *= k
            v += 3
        }
    }

    // ---------- dessin, pour un oeil ----------
    func dessiner(_ enc: MTLRenderCommandEncoder, opaque: MTLRenderPipelineState, transparent: MTLRenderPipelineState,
                  dsOpaque: MTLDepthStencilState, dsTransparent: MTLDepthStencilState, sampler: MTLSamplerState,
                  blanche: MTLTexture, vp: simd_float4x4, oeil: SIMD3<Float>) {
        verrou.lock()
        let ps = prims; let tex = textures; let ok = prete
        verrou.unlock()
        guard ok else { return }
        enc.setCullMode(.none)
        enc.setFrontFacing(.counterClockwise)
        enc.setFragmentSamplerState(sampler, index: 0)
        for passe in 0..<2 {
            enc.setRenderPipelineState(passe == 0 ? opaque : transparent)
            enc.setDepthStencilState(passe == 0 ? dsOpaque : dsTransparent)
            for p in ps {
                let m = mats[p.mat]
                if m.blend != (passe == 1) { continue }
                // un mesh skinne est deja en coordonnees monde (ses os portent tout)
                let modele: simd_float4x4
                if let a = p.anim, a.peau >= 0 {
                    modele = a.rigide >= 0 ? peaux[a.peau].affiche[a.rigide] : matrix_identity_float4x4
                } else {
                    modele = mondes[p.noeud]
                }
                var uv = SceneV(mvp: vp * modele, m: modele)
                let i = min(p.anneau, p.vPos.count - 1)
                enc.setVertexBuffer(p.vPos[i], offset: 0, index: 0)
                enc.setVertexBuffer(p.vNrm[i], offset: 0, index: 1)
                enc.setVertexBuffer(p.vUv, offset: 0, index: 2)
                enc.setVertexBytes(&uv, length: MemoryLayout<SceneV>.stride, index: 3)
                func carte(_ img: Int) -> MTLTexture? { p.aUv && img >= 0 ? tex[img] : nil }
                let tc = carte(m.image), tn = carte(m.imageN), tm = carte(m.imageM), to = carte(m.imageO)
                var uf = SceneF(col: m.col, cam: SIMD4(oeil.x, oeil.y, oeil.z, m.cut),
                                a: SIMD4(tc == nil ? 0 : 1, tn == nil ? 0 : 1, tm == nil ? 0 : 1, to == nil ? 0 : 1),
                                b: SIMD4(m.nEch, m.rugo, m.metal, m.oForce))
                enc.setFragmentBytes(&uf, length: MemoryLayout<SceneF>.stride, index: 0)
                enc.setFragmentTexture(tc ?? blanche, index: 0)
                enc.setFragmentTexture(tn ?? blanche, index: 1)
                enc.setFragmentTexture(tm ?? blanche, index: 2)
                enc.setFragmentTexture(to ?? blanche, index: 3)
                if let ibo = p.ibo {
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: p.n, indexType: .uint32,
                                              indexBuffer: ibo, indexBufferOffset: 0)
                } else {
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: p.n)
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
//  SCENES 3D — telechargees sur le telephone, ouvertes hors ligne
// ═══════════════════════════════════════════════════════════════════
/*  Une scene n'est jamais lue en streaming : on telecharge le .glb en
    entier dans l'app, puis on l'ouvre depuis le fichier. Si la connexion
    coupe, le telechargement reprend la ou il s'etait arrete. */
final class SceneBus: NSObject, URLSessionDownloadDelegate {
    static let shared = SceneBus()

    var progres: [String: Float] = [:]          // id -> 0..1 pendant le telechargement
    var demandeOuverture: URL?
    var demandeFermeture = false

    private var sessionDL: URLSession!
    private var taches: [Int: Video] = [:]
    private var reprises: [String: Data] = [:]
    private let s = AppState.shared

    override init() {
        super.init()
        sessionDL = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
    }

    var dossier: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func fichier(_ id: String) -> URL { dossier.appendingPathComponent(id + ".glb") }

    func presente(_ v: Video) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: fichier(v.id).path),
              let t = (a[.size] as? NSNumber)?.int64Value else { return false }
        return v.taille <= 0 || t == v.taille
    }

    static func mo(_ o: Int64) -> String { o > 0 ? "\((o + 524_288) / 1_048_576) Mo" : "? Mo" }

    /* Appele quand on vise une scene dans la liste : l'ouvre si elle est
       deja sur le telephone, sinon lance (ou reprend) le telechargement. */
    func action(_ v: Video) {
        if presente(v) {
            VideoBus.shared.demandeStop = true
            demandeOuverture = fichier(v.id)
            s.menu = false
            s.info = "chargement de la scene..."; s.infoT = 4
        } else if let p = progres[v.id] {
            s.info = "telechargement en cours : \(Int(p * 100)) %"; s.infoT = 3
        } else if v.url.isEmpty {
            s.info = "aucun fichier pour cette scene"; s.infoT = 3.5
        } else {
            telecharger(v)
        }
    }

    private func telecharger(_ v: Video) {
        guard let url = URL(string: v.url) else { return }
        if v.taille > 0,
           let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dossier.path),
           let libre = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
           libre < v.taille + 50_000_000 {
            s.info = "espace insuffisant : il faut " + SceneBus.mo(v.taille); s.infoT = 6
            return
        }
        let tache: URLSessionDownloadTask
        if let r = reprises[v.id] {
            tache = sessionDL.downloadTask(withResumeData: r)
            reprises[v.id] = nil
        } else {
            tache = sessionDL.downloadTask(with: url)
        }
        taches[tache.taskIdentifier] = v
        progres[v.id] = 0
        s.info = "telechargement : " + v.nom; s.infoT = 3
        s.besoinRedessin = true
        tache.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let v = taches[downloadTask.taskIdentifier] else { return }
        let total = v.taille > 0 ? v.taille : totalBytesExpectedToWrite
        if total > 0 { progres[v.id] = Float(totalBytesWritten) / Float(total) }
        s.besoinRedessin = true
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let v = taches[downloadTask.taskIdentifier] else { return }
        // une page d'erreur du serveur ne doit pas devenir une "scene"
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            s.info = "telechargement refuse (erreur \(http.statusCode))"; s.infoT = 6
            return
        }
        let dest = fichier(v.id)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            s.info = "scene prete : " + v.nom
        } catch {
            s.info = "ecriture impossible"
        }
        s.infoT = 6
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let v = taches.removeValue(forKey: task.taskIdentifier) else { return }
        progres[v.id] = nil
        if let e = error as NSError? {
            if let r = e.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { reprises[v.id] = r }
            s.info = "telechargement interrompu : reessaie pour reprendre"; s.infoT = 6
        }
        s.besoinRedessin = true
    }
}
