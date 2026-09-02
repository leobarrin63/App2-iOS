import Foundation

/* Equivalent de l'objet S dans MainActivity.kt (Android). Etat partage
   entre le suivi de tete, le rendu et le menu. */
final class AppState: ObservableObject {
    static let shared = AppState()

    var ipd: Float = 63       // mm
    var fov: Float = 88       // degres
    var k1: Float = 0.22      // distorsion barillet
    var menuDist: Float = 1.25 // m
    var menuAngle: Float = 82  // degres
    var smooth: Float = 0.35
    var menu: Bool = true

    // quaternion cible, ecrit par le capteur
    var qtX: Float = 0; var qtY: Float = 0; var qtZ: Float = 0; var qtW: Float = 1

    var hz: Float = 0
    var sensorOk: Bool = false
    var yawOffset: Float = 0

    // navigation menu
    var tab: String = "videos"     // videos | glasses | settings
    var feed: String = "sugg"      // sugg | trend | new
    var recherche: String = ""
    var rechActive: Bool = false   // clavier virtuel affiche
    var defil: Int = 0
    var info: String = ""
    var infoT: Float = 0

    var dbgYaw: Float = 0
    var dbgPitch: Float = 0
    var dbgRoll: Float = 0
    var besoinRedessin: Bool = false
    var appareil: String = ""
    var apiUrl: String = ""
    var format: Int = 0            // 0 cote-a-cote, 1 haut-bas, 2 image unique
    var yeuxInverses: Bool = false

    // curseur : position sur le panneau, en 0..1
    var curU: Float = 0.5
    var curV: Float = 0.5
    var dwell: Float = 0
    var hot: Int = -1
    var clickWanted: Bool = false
}

/* Equivalent de VideoBus : passerelle entre le lecteur AVPlayer et le
   rendu Metal. */
final class VideoBus {
    static let shared = VideoBus()

    var videoId: String = ""
    var formatVideo: Int = -1     // -1 = suivre le reglage manuel
    var dejaCompte: Bool = false
    var demandeStop: Bool = false
    var enLecture: Bool = false
    var demandeUrl: String?
}
