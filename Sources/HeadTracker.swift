import Foundation
import CoreMotion
import simd

/* Equivalent de HeadTracker dans MainActivity.kt (Android). Utilise
   CoreMotion plutot que SensorManager. Le repere de reference iOS
   (xArbitraryZVertical) est Z vers le haut, X/Y horizontaux arbitraires
   - similaire au repere "sans boussole" utilise cote Android (Z-up).

   INCERTITUDE CONNUE : contrairement au code Android (teste et corrige
   empiriquement), ce remap d'axes n'a jamais ete verifie sur un vrai
   appareil. Si l'image tourne dans le mauvais sens ou sur le mauvais
   axe une fois teste, c'est ici qu'il faut ajuster les signes/permutations
   ci-dessous - pas une erreur de compilation a chercher ailleurs. */
final class HeadTracker {
    private let mm = CMMotionManager()
    private let state = AppState.shared

    private var count = 0
    private var t0 = CFAbsoluteTimeGetCurrent()

    func start() {
        guard mm.isDeviceMotionAvailable else {
            state.sensorOk = false
            return
        }
        mm.deviceMotionUpdateInterval = 1.0 / 60.0
        state.sensorOk = true
        t0 = CFAbsoluteTimeGetCurrent()
        count = 0
        mm.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.traiter(motion)
        }
    }

    func stop() {
        mm.stopDeviceMotionUpdates()
    }

    private func traiter(_ motion: CMDeviceMotion) {
        let q = motion.attitude.quaternion
        // repere capteur (Z-up, X/Y horizontaux) -> repere Metal (Y-up, -Z devant)
        // rotation fixe de +90 deg autour de X (inversee par rapport au
        // premier essai a -90 : inverser le composant x du quaternion du
        // capteur directement causait un couplage indesirable entre les
        // axes - "tourne au lieu d'aller a droite". Inverser plutot le
        // signe de cette rotation fixe reste une rotation propre, donc pas
        // de couplage, juste le haut/bas qui s'inverse.
        let qCapteur = simd_quatf(real: Float(q.w), imag: SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z)))
        let bascule = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let paysage = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let qFinal = (bascule * qCapteur * paysage).normalized

        state.qtX = qFinal.imag.x
        state.qtY = qFinal.imag.y
        state.qtZ = qFinal.imag.z
        state.qtW = qFinal.real

        count += 1
        let dt = CFAbsoluteTimeGetCurrent() - t0
        if dt >= 0.5 {
            state.hz = Float(Double(count) / dt)
            count = 0
            t0 = CFAbsoluteTimeGetCurrent()
        }
    }
}
