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

    /* Ecart entre les centres des deux lentilles du casque (mm) : chaque
       image est centree en face de sa lentille, quelle que soit la largeur
       du telephone. Memorise. */
    var ecartLentilles: Float = 63
    /* Luminosite de l'ecran fixee par l'app (0,1 a 1) : dans le casque, le
       capteur de lumiere est dans le noir. Memorisee. */
    var luminosite: Float = 0.8

    // quaternion cible, ecrit par le capteur
    var qtX: Float = 0; var qtY: Float = 0; var qtZ: Float = 0; var qtW: Float = 1

    var hz: Float = 0
    var sensorOk: Bool = false
    var yawOffset: Float = 0

    // 6DoF : position de la tete suivie par la camera (ARKit). Si le suivi
    // n'est pas disponible, on retombe sur la rotation seule (Core Motion).
    var mode6dof: Bool = true
    var etat6dof: String = ""         // affiche dans l'onglet LUNETTES
    var pos6dof: Bool = false         // la position vient vraiment d'ARKit
    var posX: Float = 0; var posY: Float = 0; var posZ: Float = 0
    var demandeRecentrage: Bool = false

    /* Fond par defaut : le PASSTHROUGH (image de la camera arriere a taille
       reelle), comme l'accueil du Quest. Pluie de code en secours ou au
       choix. zoomPt > 1 agrandit l'image (et les mains dessinees). */
    var passthrough: Bool = true
    var zoomPt: Float = 1

    // Mains (Vision) : pincer pour cliquer, pincee longue paume vers soi pour le menu
    var mains: Bool = true
    var mainsOk: Bool = false         // la camera analyse vraiment (sinon : regard + fixation)
    var mainVue: Bool = false
    var pince: Bool = false           // pouce et index colles en ce moment
    var pinceClic: Bool = false       // une pincee courte vient d'etre relachee
    var basculerMenu: Bool = false    // pincee longue, paume vers soi
    var progresMenu: Float = 0        // anneau de la pincee longue, 0..1
    var etatMains: String = ""
    var cadenceMains: String = ""

    // cote maximal des textures des scenes 3D, selon la memoire du telephone
    var plafondTex: Int = 1024

    // navigation menu
    var tab: String = "videos"     // videos | glasses | settings
    var feed: String = "sugg"      // sugg | trend | new
    var recherche: String = ""
    var rechActive: Bool = false   // clavier virtuel affiche
    var azerty: Bool = false       // QWERTY (defaut) ou AZERTY
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

    // reglages memorises d'un lancement a l'autre
    func charger() {
        let d = UserDefaults.standard
        if d.object(forKey: "lentilles") != nil { ecartLentilles = d.float(forKey: "lentilles") }
        if d.object(forKey: "luminosite") != nil { luminosite = d.float(forKey: "luminosite") }
        if d.object(forKey: "zoomPt") != nil { zoomPt = d.float(forKey: "zoomPt") }
    }

    func sauver() {
        let d = UserDefaults.standard
        d.set(ecartLentilles, forKey: "lentilles")
        d.set(luminosite, forKey: "luminosite")
        d.set(zoomPt, forKey: "zoomPt")
    }
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
