import Foundation
import ARKit
import simd

/* Suivi par la camera arriere (ARKit world tracking). Sert a trois choses :
   - le 6DoF : rotation ET position de la tete, comme le Quest ;
   - le passthrough : l'image camera affichee en fond ;
   - les mains : la meme image passe dans la detection de Vision.

   Dans un casque type Cardboard, l'ecran regarde les yeux et la camera
   arriere regarde devant : l'axe -Z de la camera ARKit est directement le
   regard. Repere monde ARKit (.gravity) : Y vers le haut, origine = position
   du telephone au demarrage - le meme repere que le rendu Metal. La camera
   est exprimee pour l'orientation paysage-droite, celle a laquelle l'app
   est verrouillee (project.yml). */
final class ArTracker {
    let session = ARSession()
    private(set) var actif = false

    static var disponible: Bool { ARWorldTrackingConfiguration.isSupported }

    func start() {
        guard Self.disponible, !actif else { return }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = []
        c.isLightEstimationEnabled = false
        /* Image 4:3 (tout le capteur) a 60 i/s si possible : passthrough
           plus haut, et 60 positions par seconde pour la tete. */
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let f = formats.filter({ abs(Float($0.imageResolution.width / $0.imageResolution.height) - 4.0 / 3.0) < 0.02 })
            .sorted(by: { ($0.framesPerSecond, $0.imageResolution.height) > ($1.framesPerSecond, $1.imageResolution.height) })
            .first {
            c.videoFormat = f
        }
        session.run(c, options: [.resetTracking, .removeExistingAnchors])
        actif = true
    }

    func stop() {
        guard actif else { return }
        session.pause()
        actif = false
    }

    var frame: ARFrame? { actif ? session.currentFrame : nil }

    /* Rotation tete -> monde et position (m) de la CAMERA, ou nil si le
       suivi n'est pas exploitable (camera masquee, permission refusee,
       demarrage...). */
    func pose() -> (rotation: matrix_float3x3, position: SIMD3<Float>, etat: String)? {
        guard actif, let frame = session.currentFrame else { return nil }
        let cam = frame.camera
        let etat: String
        switch cam.trackingState {
        case .normal: etat = "6DOF ACTIF"
        case .limited(let raison):
            switch raison {
            case .initializing, .relocalizing: etat = "6DOF : INITIALISATION"
            case .excessiveMotion: etat = "6DOF : MOUVEMENT TROP RAPIDE"
            case .insufficientFeatures: etat = "6DOF : PAS ASSEZ DE DETAILS (LUMIERE ?)"
            @unknown default: etat = "6DOF : LIMITE"
            }
        case .notAvailable: return nil
        }
        let t = cam.transform
        let r = matrix_float3x3(columns: (
            SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
            SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
            SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        ))
        return (r, SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), etat)
    }
}
