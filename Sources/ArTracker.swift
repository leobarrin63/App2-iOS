import Foundation
import ARKit
import simd

/* Suivi 6DoF par la camera arriere (ARKit world tracking) : donne la
   rotation ET la position de la tete, comme le Quest. Dans un casque
   type Cardboard, l'ecran regarde les yeux et la camera arriere regarde
   devant : l'axe -Z de la camera ARKit est donc directement le regard.

   Repere monde ARKit (.gravity) : Y vers le haut, origine = position du
   telephone au demarrage - le meme repere que le rendu Metal (Y haut,
   -Z devant). La transformation de la camera est exprimee pour
   l'orientation d'interface paysage-droite, celle a laquelle l'app est
   verrouillee (project.yml), donc aucun remap d'axes n'est necessaire.

   A VERIFIER SUR APPAREIL : comme pour HeadTracker, ce repere n'a pas
   encore ete teste sur un vrai iPhone. Si les axes sont faux, c'est ici
   et dans VRRenderer.poseTete() qu'il faut corriger. */
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
        session.run(c, options: [.resetTracking, .removeExistingAnchors])
        actif = true
    }

    func stop() {
        guard actif else { return }
        session.pause()
        actif = false
    }

    /* Rotation tete -> monde et position (m), ou nil si le suivi n'est pas
       exploitable (camera masquee, permission refusee, demarrage...). */
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
