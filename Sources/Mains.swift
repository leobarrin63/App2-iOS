import Foundation
import Vision
import CoreVideo
import QuartzCore
import simd

/* MAINS — pincer pour cliquer, comme sur le Quest 3.

   Les images de la camera arriere (celles qu'ARKit utilise deja pour le
   6DoF et le passthrough) passent dans la detection de mains d'Apple
   (Vision, integree a iOS, rapide sur la puce du telephone). Elle trouve 21
   points par main, dans le meme ordre que MediaPipe sur Android. Tout tourne
   sur une file a part, une image a la fois : si elle est occupee, l'image
   suivante est simplement sautee.

   Gestes :
   - pincee courte (pouce contre index, relachee en moins de 0,6 s) : clic
     sur ce que vise le curseur, au centre du regard ;
   - pincee longue (1 s), PAUME TOURNEE VERS SOI : fait apparaitre ou
     disparaitre le menu, comme le geste du Quest.

   Vision ne donne que des points 2D : la distance de la main vient de la
   taille apparente de la paume, comparee a une paume d'adulte moyenne. */
final class Mains {
    // etat de la camera au moment de l'image : la main est placee dans la piece
    // avec la tete telle qu'elle etait quand la photo a ete prise
    struct Pose {
        var fx: Float, fy: Float, cx: Float, cy: Float   // intrinseques, normalisees par la taille d'image
        var aspect: Float                                // largeur / hauteur de l'image
        var cam: SIMD3<Float>                            // position de la camera (piece)
        var rot: matrix_float3x3                         // rotation camera -> piece
    }

    /* Resultat de la derniere analyse. Ecrit par la file de detection, lu
       par le rendu sous verrou : AppState n'est modifie que depuis la file
       principale (un texte Swift ecrit et lu en meme temps depuis deux
       files peut faire planter l'app). */
    struct Etat {
        var texte = "", cadence = ""
        var vue = false, pince = false
        var progres: Float = 0
        var derniere: CFTimeInterval = 0
        var clic = false, menu = false      // evenements : remis a zero a la lecture
    }

    private let file = DispatchQueue(label: "mains", qos: .userInteractive)
    private let verrou = NSLock()
    private var occupe = false
    private var etat = Etat()
    private let requete: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2                           // les deux mains, comme le Quest
        return r
    }()

    // ordre des 21 points, identique a MediaPipe (0 poignet, 4 pouce, 8 index...)
    private let ordre: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    // mains placees dans la piece : 21 points (x, y, z) puis 1 si la main pince
    private var mondes: [[Float]] = []
    private var tempsMondes: CFTimeInterval = 0
    private var nbAnalyses = 0
    private var debutCadence: CFTimeInterval = 0
    private var cadence = ""

    private final class EtatPince { var pince = false; var debut: CFTimeInterval = 0; var longFait = false }
    private var etats: [Bool: EtatPince] = [true: EtatPince(), false: EtatPince()]   // true = main droite
    private var filtres: [Bool: UnEuro] = [:]

    var libre: Bool { verrou.lock(); defer { verrou.unlock() }; return !occupe }

    func lire() -> (mondes: [[Float]], temps: CFTimeInterval) {
        verrou.lock(); defer { verrou.unlock() }
        return (mondes, tempsMondes)
    }

    func lireEtat() -> Etat {
        verrou.lock(); defer { verrou.unlock() }
        let e = etat
        etat.clic = false; etat.menu = false
        return e
    }

    /* Confie une image camera a la file de detection. */
    func traiter(_ image: CVPixelBuffer, pose: Pose) {
        verrou.lock()
        if occupe { verrou.unlock(); return }
        occupe = true
        verrou.unlock()
        file.async { [weak self] in
            guard let self else { return }
            self.analyser(image, pose: pose)
            self.verrou.lock(); self.occupe = false; self.verrou.unlock()
        }
    }

    private func analyser(_ image: CVPixelBuffer, pose: Pose) {
        // l'image camera est deja a l'endroit en paysage-droite (orientation de l'app)
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up, options: [:])
        do { try handler.perform([requete]) } catch { return }
        let maintenant = CACurrentMediaTime()
        nbAnalyses += 1
        if maintenant - debutCadence >= 1 {
            let c = Double(nbAnalyses) / (maintenant - debutCadence)
            cadence = String(format: "VISION %.0f IM/S", c)
            nbAnalyses = 0; debutCadence = maintenant
        }

        var vues = Set<Bool>()
        var progres: Float = 0
        var textes: [String] = []
        var sortie: [[Float]] = []
        var clic = false, menu = false

        for obs in requete.results ?? [] {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            // points en coordonnees image (0..1, origine en haut a gauche)
            var p = [Float](repeating: 0, count: 42)
            var fiable = true
            for (i, nom) in ordre.enumerated() {
                guard let q = pts[nom], q.confidence > 0.2 else { fiable = false; break }
                p[i * 2] = Float(q.location.x)
                p[i * 2 + 1] = 1 - Float(q.location.y)           // Vision : origine en bas
            }
            if !fiable { continue }
            let droite = obs.chirality != .left
            if vues.contains(droite) { continue }
            vues.insert(droite)
            let st = etats[droite]!

            // distances en unites isotropes (x corrige par le rapport largeur/hauteur)
            func d(_ a: Int, _ b: Int) -> Float {
                let dx = (p[a * 2] - p[b * 2]) * pose.aspect, dy = p[a * 2 + 1] - p[b * 2 + 1]
                return (dx * dx + dy * dy).squareRoot()
            }
            let ratio = d(4, 8) / max(d(0, 9), 1e-4)

            /* Paume vers la camera ? Le sens du triangle poignet / base de
               l'index / base de l'auriculaire s'inverse entre paume et dos,
               et entre main droite et main gauche. */
            let ax = (p[10] - p[0]) * pose.aspect, ay = p[11] - p[1]
            let bx = (p[34] - p[0]) * pose.aspect, by = p[35] - p[1]
            let cz = ax * by - ay * bx
            let paume = droite ? cz < 0 : cz > 0

            if !st.pince && ratio < 0.25 {
                st.pince = true; st.debut = maintenant; st.longFait = false
            } else if st.pince && ratio > 0.42 {
                if relacher(st, maintenant) { clic = true }
            }
            if st.pince && !st.longFait {
                let duree = Float(maintenant - st.debut)
                if paume { progres = max(progres, min(max((duree - 0.3) / 0.7, 0), 1)) }
                if paume && duree >= 1 {
                    st.longFait = true
                    menu = true
                }
            }
            textes.append((droite ? "DROITE" : "GAUCHE") + (paume ? " PAUME" : " DOS") + (st.pince ? " PINCEE" : ""))

            if var monde = placer(p, pose: pose) {
                let f = filtres[droite] ?? UnEuro(n: 63)
                filtres[droite] = f
                f.filtrer(&monde, t: maintenant)
                sortie.append(f.x + [st.pince ? 1 : 0])
            }
        }
        // une main qui disparait en pincant : on relache
        for (cle, st) in etats where !vues.contains(cle) && st.pince { if relacher(st, maintenant) { clic = true } }
        for cle in Array(filtres.keys) where !vues.contains(cle) { filtres[cle] = nil }

        verrou.lock()
        mondes = sortie
        tempsMondes = maintenant
        etat.texte = textes.isEmpty ? "AUCUNE MAIN EN VUE" : "MAIN " + textes.joined(separator: "  +  ")
        etat.cadence = cadence
        etat.vue = !vues.isEmpty
        etat.pince = etats.values.contains { $0.pince }
        etat.progres = progres
        etat.derniere = maintenant
        if clic { etat.clic = true }
        if menu { etat.menu = true }
        verrou.unlock()
    }

    // vrai si c'etait une pincee courte (un clic)
    private func relacher(_ st: EtatPince, _ maintenant: CFTimeInterval) -> Bool {
        let duree = maintenant - st.debut
        st.pince = false
        return !st.longFait && duree < 0.6
    }

    /* Chaque point de l'image donne une direction depuis la camera. La
       distance vient des os de la paume : leur longueur moyenne chez un
       adulte, divisee par l'angle sous lequel la camera les voit. Tous les
       points sont poses a cette distance (Vision ne donne pas le relief de
       la main), puis passes dans le repere de la piece. */
    private let paires: [(Int, Int, Float)] = [
        (0, 5, 0.085), (0, 17, 0.075), (5, 17, 0.065), (0, 9, 0.090),
        (5, 9, 0.022), (9, 13, 0.020), (13, 17, 0.020),
    ]

    private func placer(_ p: [Float], pose: Pose) -> [Float]? {
        var r = [SIMD3<Float>](repeating: .zero, count: 21)
        for i in 0..<21 {
            let x = (p[i * 2] - pose.cx) / pose.fx
            let y = -(p[i * 2 + 1] - pose.cy) / pose.fy
            r[i] = simd_normalize(SIMD3<Float>(x, y, -1))
        }
        var somL: Float = 0, somA: Float = 0
        for (a, b, l) in paires {
            somL += l
            somA += acos(min(max(simd_dot(r[a], r[b]), -1), 1))
        }
        if somA < 1e-4 { return nil }
        let dist = min(max(somL / somA, 0.1), 1.2)
        var out = [Float](repeating: 0, count: 63)
        for i in 0..<21 {
            let w = pose.cam + pose.rot * (r[i] * dist)
            out[i * 3] = w.x; out[i * 3 + 1] = w.y; out[i * 3 + 2] = w.z
        }
        return out
    }
}

/* Filtre "One Euro" (Casiez et al., la reference en VR) : lisse fort quand
   la main est immobile (plus de tremblement), presque pas quand elle bouge
   vite (pas de retard). */
final class UnEuro {
    var x: [Float]
    private var dx: [Float]
    private var t: CFTimeInterval = 0
    private var actif = false

    init(n: Int) { x = [Float](repeating: 0, count: n); dx = [Float](repeating: 0, count: n) }

    func filtrer(_ v: inout [Float], t tps: CFTimeInterval) {
        if !actif || tps - t > 0.3 {
            x = v; dx = [Float](repeating: 0, count: v.count); t = tps; actif = true; return
        }
        let dt = Float(max(tps - t, 0.001))
        t = tps
        let aD = UnEuro.alpha(1, dt)
        for i in 0..<x.count {
            let d = (v[i] - x[i]) / dt
            dx[i] += aD * (d - dx[i])
            let coupure = 1.0 + 8 * abs(dx[i])          // Hz : 1 a l'arret, ~9 a 1 m/s
            x[i] += UnEuro.alpha(coupure, dt) * (v[i] - x[i])
        }
    }

    private static func alpha(_ coupure: Float, _ dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * coupure)
        return 1 / (1 + tau / dt)
    }
}
