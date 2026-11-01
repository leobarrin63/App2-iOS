import UIKit

/* Equivalent de la classe Panel dans MainActivity.kt (Android) : dessine
   le menu sur un bitmap (via UIGraphicsImageRenderer, l'equivalent iOS
   du Canvas 2D Android), colle ensuite comme texture sur un quad 3D par
   le renderer. La recherche se tape sur le clavier virtuel du menu. */
final class Panel {
    static let W = 1180
    static let H = 720

    struct Zone { let id: String; let rect: CGRect }

    private(set) var zones: [Zone] = []
    var dirty = true
    var image: CGImage?
    var lib: [Video] = []

    private let s = AppState.shared

    private func vise(_ id: String) -> Bool {
        s.hot >= 0 && s.hot < zones.count && zones[s.hot].id == id
    }

    private func couleurFond(_ actif: Bool, _ chaud: Bool) -> UIColor {
        if actif { return UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 0.15) }
        if chaud { return UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 0.18) }
        return UIColor(white: 1, alpha: 0.05)
    }
    private func couleurBord(_ actif: Bool, _ chaud: Bool) -> UIColor {
        (actif || chaud) ? UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1) : UIColor(red: 43/255, green: 57/255, blue: 73/255, alpha: 1)
    }

    private func rect(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                       _ r: CGFloat, fill: UIColor?, stroke: UIColor?, largeur: CGFloat = 2) {
        let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.lineWidth = largeur; path.stroke() }
    }

    private func txt(_ s: String, _ x: CGFloat, _ y: CGFloat, _ taille: CGFloat, _ couleur: UIColor,
                      centre: Bool = false, droite: Bool = false, gras: Bool = false, mono: Bool = false) {
        let police: UIFont = mono ? .monospacedSystemFont(ofSize: taille, weight: .regular)
                                   : (gras ? .boldSystemFont(ofSize: taille) : .systemFont(ofSize: taille))
        let style = NSMutableParagraphStyle()
        style.alignment = centre ? .center : (droite ? .right : .left)
        let attrs: [NSAttributedString.Key: Any] = [.font: police, .foregroundColor: couleur, .paragraphStyle: style]
        let taille2 = (s as NSString).size(withAttributes: attrs)
        var origine = CGPoint(x: x, y: y - taille2.height * 0.75)
        if centre { origine.x = x - taille2.width / 2 }
        if droite { origine.x = x - taille2.width }
        (s as NSString).draw(at: origine, withAttributes: attrs)
    }

    private func bouton(_ ctx: CGContext, _ id: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                         _ label: String, actif: Bool = false, taille: CGFloat = 22) {
        let chaud = vise(id)
        rect(ctx, x, y, w, h, 12, fill: couleurFond(actif, chaud), stroke: couleurBord(actif, chaud))
        txt(label, x + w / 2, y + h / 2, taille, actif ? UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1) : .white, centre: true, gras: true)
        zones.append(Zone(id: id, rect: CGRect(x: x, y: y, width: w, height: h)))
    }

    func liste() -> [Video] {
        let q = s.recherche.trimmingCharacters(in: .whitespaces).lowercased()
        var l = lib.filter { q.isEmpty || $0.nom.lowercased().contains(q) }
        switch s.feed {
        case "new": l.sort { $0.ajoute > $1.ajoute }
        case "trend": l.sort { $0.vues > $1.vues }
        default: l.sort { $0.lectures * 1_000_000 + $0.vues > $1.lectures * 1_000_000 + $1.vues }
        }
        return l
    }

    func draw() {
        zones.removeAll()
        // une image a la taille de la texture (1180 x 720), pas x3 comme l'ecran : 9 fois moins de pixels a chaque redessin
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: Panel.W, height: Panel.H), format: format)
        let img = renderer.image { rc in
            let ctx = rc.cgContext
            rect(ctx, 0, 0, CGFloat(Panel.W), CGFloat(Panel.H), 24,
                 fill: UIColor(red: 10/255, green: 13/255, blue: 19/255, alpha: 0.91),
                 stroke: UIColor(white: 1, alpha: 0.2))

            let onglets = [("videos", "VIDEOS"), ("glasses", "LUNETTES"), ("settings", "REGLAGES")]
            let lw: CGFloat = 300, ecart: CGFloat = 18
            let x0 = (CGFloat(Panel.W) - (3 * lw + 2 * ecart)) / 2
            for (i, o) in onglets.enumerated() {
                let x = x0 + CGFloat(i) * (lw + ecart)
                let on = s.tab == o.0
                let chaud = vise("tab:\(o.0)")
                rect(ctx, x, 30, lw, 60, 12, fill: couleurFond(on, chaud), stroke: couleurBord(on, chaud))
                txt(o.1, x + lw / 2, 60, 22, on ? UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1) : UIColor(white: 1, alpha: 0.65), centre: true, gras: true)
                zones.append(Zone(id: "tab:\(o.0)", rect: CGRect(x: x, y: 30, width: lw, height: 60)))
            }

            switch s.tab {
            case "videos": videos(ctx)
            case "glasses": lunettes(ctx)
            default: reglages(ctx)
            }

            ctx.setStrokeColor(UIColor(white: 1, alpha: 0.2).cgColor)
            ctx.move(to: CGPoint(x: 40, y: CGFloat(Panel.H) - 96))
            ctx.addLine(to: CGPoint(x: CGFloat(Panel.W) - 40, y: CGFloat(Panel.H) - 96))
            ctx.strokePath()
            bouton(ctx, "hide", 40, CGFloat(Panel.H) - 80, 240, 56, "MASQUER", taille: 20)
            bouton(ctx, "recenter", 300, CGFloat(Panel.H) - 80, 240, 56, "RECENTRER", taille: 20)
            bouton(ctx, "stop", 560, CGFloat(Panel.H) - 80, 240, 56, "ACCUEIL", taille: 20)
            if !s.info.isEmpty {
                txt(s.info, CGFloat(Panel.W) - 40, CGFloat(Panel.H) - 30, 18, UIColor(red: 232/255, green: 196/255, blue: 90/255, alpha: 1), droite: true)
            }
        }
        image = img.cgImage
        dirty = true
    }

    private func videos(_ ctx: CGContext) {
        let pastilles = [("sugg", "SUGGESTIONS", 240), ("trend", "TENDANCE", 190), ("new", "NOUVEAUTE", 210)]
        var x: CGFloat = 40
        for p in pastilles {
            let on = s.feed == p.0
            let chaud = vise("feed:\(p.0)")
            rect(ctx, x, 100, CGFloat(p.2), 48, 24, fill: on ? .white : couleurFond(false, chaud), stroke: on ? .white : couleurBord(false, chaud))
            txt(p.1, x + CGFloat(p.2) / 2, 124, 18, on ? UIColor(red: 10/255, green: 13/255, blue: 19/255, alpha: 1) : .white, centre: true, gras: true)
            zones.append(Zone(id: "feed:\(p.0)", rect: CGRect(x: x, y: 100, width: CGFloat(p.2), height: 48)))
            x += CGFloat(p.2) + 12
        }
        bouton(ctx, "recharger", 986, 100, 154, 48, "CATALOGUE", taille: 17)

        let sy: CGFloat = 164
        let chaudSearch = vise("search")
        rect(ctx, 40, sy, 1100, 50, 25, fill: couleurFond(s.rechActive, chaudSearch), stroke: couleurBord(s.rechActive, chaudSearch))
        let texteRecherche = s.recherche.isEmpty ? "Rechercher une video" : s.recherche + (s.rechActive ? "_" : "")
        txt(texteRecherche, 66, sy + 32, 20, s.recherche.isEmpty ? UIColor(white: 1, alpha: 0.35) : .white)
        zones.append(Zone(id: "search", rect: CGRect(x: 40, y: sy, width: 1000, height: 50)))
        if !s.recherche.isEmpty {
            bouton(ctx, "clear", 1054, sy + 6, 60, 38, "X", taille: 18)
        }

        if s.rechActive {
            clavier(ctx)
            return
        }

        let l = liste()
        let ly: CGFloat = 228, hl: CGFloat = 74, gap: CGFloat = 6, vis = 4
        var off = s.defil
        let maxOff = max(0, l.count - vis)
        if off > maxOff { off = maxOff; s.defil = off }

        if l.isEmpty {
            txt("Aucune video ne correspond", 590, ly + 90, 20, UIColor(white: 1, alpha: 0.35), centre: true)
        }
        var k = 0
        while k < vis && k + off < l.count {
            let v = l[k + off]
            let y = ly + CGFloat(k) * (hl + gap)
            let chaud = vise("play:\(v.id)")
            rect(ctx, 40, y, 1050, hl, 12, fill: couleurFond(false, chaud), stroke: couleurBord(false, chaud))
            let teinte = UIColor(hue: CGFloat(v.teinte) / 360, saturation: 0.48, brightness: 0.4, alpha: 1)
            rect(ctx, 54, y + 8, 108, hl - 16, 6, fill: teinte, stroke: nil)
            txt(v.estScene ? "3D" : "360", 150, y + hl - 14, 12, UIColor(white: 1, alpha: 0.7), droite: true, mono: true)
            txt(v.nom, 178, y + 30, 21, .white, gras: true)
            let vues = v.vues >= 1000 ? "\(v.vues / 1000) k vues" : "\(v.vues) vues"
            if v.estScene {
                // scene 3D : ou en est le fichier sur le telephone
                txt("\(vues) - scene 3D 6DoF - " + SceneBus.mo(v.taille), 178, y + 54, 16,
                    UIColor(white: 1, alpha: 0.55), mono: true)
                let bus = SceneBus.shared
                let orange = UIColor(red: 232/255, green: 196/255, blue: 90/255, alpha: 1)
                if let pr = bus.progres[v.id] {
                    txt("\(Int(pr * 100)) %", 1068, y + hl / 2 + 7, 18, orange, droite: true, gras: true)
                    rect(ctx, 178, y + hl - 8, 860, 4, 2, fill: UIColor(white: 1, alpha: 0.15), stroke: nil)
                    rect(ctx, 178, y + hl - 8, 860 * CGFloat(pr), 4, 2, fill: orange, stroke: nil)
                } else if bus.presente(v) {
                    txt("PRETE", 1068, y + hl / 2 + 7, 18, UIColor(red: 91/255, green: 214/255, blue: 164/255, alpha: 1), droite: true, gras: true)
                } else {
                    txt("TELECHARGER", 1068, y + hl / 2 + 7, 18, UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1), droite: true, gras: true)
                }
            } else {
                let d = v.duree >= 60 ? "\(v.duree / 60) min" : "\(v.duree) s"
                txt("\(vues) - \(d)", 178, y + 54, 16, UIColor(white: 1, alpha: 0.55), mono: true)
            }
            if v.lectures > 0 && !v.estScene {
                txt("vu \(v.lectures)x", 1068, y + hl / 2 + 5, 15, UIColor(red: 91/255, green: 214/255, blue: 164/255, alpha: 1), droite: true, mono: true)
            }
            zones.append(Zone(id: "play:\(v.id)", rect: CGRect(x: 40, y: y, width: 1050, height: hl)))
            k += 1
        }
        if l.count > vis {
            bouton(ctx, "up", 1096, ly, 44, 70, "^", taille: 20)
            bouton(ctx, "down", 1096, ly + 78, 44, 70, "v", taille: 20)
            txt("\(off + 1)-\(min(l.count, off + vis))/\(l.count)", 1118, ly + 170, 14, UIColor(white: 1, alpha: 0.35), centre: true, mono: true)
        }
    }

    /* Clavier virtuel dans le menu 3D lui-meme : navigable au regard +
       clic (dwell) ou a la souris gyroscopique, comme le reste du menu -
       pas besoin d'enlever le casque pour voir le clavier systeme iOS.
       QWERTY par defaut, bascule vers AZERTY possible. Touches plus
       grandes et plus espacees que la premiere version (plus tolerant
       si la visee au regard n'est pas parfaitement precise). */
    private func clavier(_ ctx: CGContext) {
        let qwerty = [Array("QWERTYUIOP"), Array("ASDFGHJKL"), Array("ZXCVBNM")]
        let azerty = [Array("AZERTYUIOP"), Array("QSDFGHJKLM"), Array("WXCVBN")]
        let rangees = s.azerty ? azerty : qwerty

        let w: CGFloat = 100, ecart: CGFloat = 11, h: CGFloat = 80, gapV: CGFloat = 10
        let y1: CGFloat = 224, y2 = y1 + h + gapV, y3 = y2 + h + gapV, y4 = y3 + h + gapV
        let largeurRangee1 = CGFloat(rangees[0].count) * (w + ecart) - ecart

        func rangeeTouches(_ lettres: [Character], _ x0: CGFloat, _ y: CGFloat) {
            var x = x0
            for l in lettres {
                bouton(ctx, "kb:\(l)", x, y, w, h, String(l), taille: 26)
                x += w + ecart
            }
        }

        rangeeTouches(rangees[0], 40, y1)
        let x2 = 40 + (largeurRangee1 - (CGFloat(rangees[1].count) * (w + ecart) - ecart)) / 2
        rangeeTouches(rangees[1], x2, y2)

        let x3: CGFloat = 40
        rangeeTouches(rangees[2], x3, y3)
        let xDel = x3 + CGFloat(rangees[2].count) * (w + ecart)
        bouton(ctx, "kb:del", xDel, y3, CGFloat(Panel.W) - 40 - xDel, h, "DEL", taille: 22)

        bouton(ctx, "kb:layout", 40, y4, 220, h, s.azerty ? "AZERTY" : "QWERTY", taille: 20)
        bouton(ctx, "kb:espace", 276, y4, 560, h, "SPACE", taille: 20)
        bouton(ctx, "kb:ok", 852, y4, CGFloat(Panel.W) - 40 - 852, h, "CLOSE", actif: true, taille: 22)
    }

    private func lunettes(_ ctx: CGContext) {
        txt("SUIVI DE LA TETE", 44, 118, 16, UIColor(white: 1, alpha: 0.5), mono: true)
        let ok = s.sensorOk && s.hz > 1
        rect(ctx, 40, 134, 1100, 108, 14,
             fill: (ok ? UIColor(red: 91/255, green: 214/255, blue: 164/255, alpha: 1) : UIColor(red: 242/255, green: 102/255, blue: 74/255, alpha: 1)).withAlphaComponent(0.11),
             stroke: ok ? UIColor(red: 91/255, green: 214/255, blue: 164/255, alpha: 1) : UIColor(red: 242/255, green: 102/255, blue: 74/255, alpha: 1))
        txt(ok ? "CAPTEUR ACTIF" : "AUCUN CAPTEUR", 66, 174, 22,
            ok ? UIColor(red: 91/255, green: 214/255, blue: 164/255, alpha: 1) : UIColor(red: 242/255, green: 102/255, blue: 74/255, alpha: 1), gras: true)
        txt(String(format: "%.0f Hz", s.hz), 66, 218, 38, .white, mono: true)

        let d2r = 180.0 / Double.pi
        let vals: [(String, Float)] = [("LACET", s.dbgYaw), ("TANGAGE", s.dbgPitch), ("ROULIS", s.dbgRoll)]
        rect(ctx, 40, 262, 1100, 116, 12, fill: UIColor(white: 1, alpha: 0.04), stroke: UIColor(red: 43/255, green: 57/255, blue: 73/255, alpha: 1))
        for (i, val) in vals.enumerated() {
            let x = 78 + CGFloat(i) * 356
            txt(val.0, x, 298, 16, UIColor(white: 1, alpha: 0.5), mono: true)
            var deg = Double(val.1) * d2r.truncatingRemainder(dividingBy: 360)
            if deg > 180 { deg -= 360 }; if deg < -180 { deg += 360 }
            txt(String(format: "%.1f deg", deg), x, 350, 34, .white, mono: true)
        }

        // 6DoF : etat du suivi camera + position de la tete
        let vert = UIColor(red: 91/255, green: 214/255, blue: 164/255, alpha: 1)
        let orange = UIColor(red: 232/255, green: 196/255, blue: 90/255, alpha: 1)
        rect(ctx, 40, 398, 1100, 120, 12, fill: UIColor(white: 1, alpha: 0.04), stroke: UIColor(red: 43/255, green: 57/255, blue: 73/255, alpha: 1))
        txt(s.etat6dof, 66, 434, 20, s.pos6dof ? vert : orange, gras: true)
        if s.pos6dof {
            txt(String(format: "X %+.2f   Y %+.2f   Z %+.2f  m", s.posX, s.posY, s.posZ), 66, 486, 30, .white, mono: true)
        }
        bouton(ctx, "6dof", 880, 448, 240, 52, s.mode6dof ? "6DOF : OUI" : "6DOF : NON", actif: s.mode6dof, taille: 20)

        // MAINS : ce que voit la camera, le geste en cours, la vitesse de detection
        txt("MAINS (PINCER = CLIC, PINCEE LONGUE PAUME VERS SOI = MENU)  " + s.cadenceMains, 44, 556, 15,
            UIColor(white: 1, alpha: 0.5), mono: true)
        txt(s.etatMains, 44, 594, 20, s.mainVue ? vert : orange, gras: true)
        bouton(ctx, "mains", 880, 560, 240, 50, s.mains ? "MAINS : OUI" : "MAINS : NON", actif: s.mains, taille: 20)
    }

    private func reglages(_ ctx: CGContext) {
        let lignes: [(String, String, String)] = [
            ("ECART DES LENTILLES", String(format: "%.0f mm", s.ecartLentilles), "lentilles"),
            ("TAILLE DU PASSTHROUGH", s.zoomPt <= 1.001 ? "REELLE" : String(format: "x%.1f", s.zoomPt), "zoomPt"),
            ("ECART PUPILLAIRE", String(format: "%.0f mm", s.ipd), "ipd"),
            ("CHAMP DE VISION", String(format: "%.0f deg", s.fov), "fov"),
            ("DISTORSION", String(format: "%.2f", s.k1), "k1"),
            ("DISTANCE DU MENU", String(format: "%.2f m", s.menuDist), "menuDist"),
            ("TAILLE DU MENU", String(format: "%.0f deg", s.menuAngle), "menuAngle"),
            ("LISSAGE", String(format: "%.0f %%", s.smooth * 100), "smooth"),
            ("LUMINOSITE", String(format: "%.0f %%", s.luminosite * 100), "lum"),
        ]
        // 9 lignes + FORMAT : pas de 48 pour tout faire tenir au-dessus de la barre du bas
        var y: CGFloat = 108
        for (label, valeur, cle) in lignes {
            txt(label, 60, y + 30, 21, .white)
            txt(valeur, 740, y + 30, 21, UIColor(red: 63/255, green: 199/255, blue: 238/255, alpha: 1), droite: true, mono: true)
            bouton(ctx, "set:\(cle):-", 800, y, 76, 42, "-", taille: 24)
            bouton(ctx, "set:\(cle):+", 888, y, 76, 42, "+", taille: 24)
            y += 48
        }
        txt("FORMAT", 60, y + 30, 21, .white)
        let noms = ["COTE-A-COTE", "HAUT-BAS", "IMAGE UNIQUE"]
        bouton(ctx, "fmt", 300, y, 240, 42, noms[s.format], actif: true, taille: 17)
        bouton(ctx, "yeux", 556, y, 240, 42, s.yeuxInverses ? "YEUX INVERSES" : "YEUX NORMAUX", actif: s.yeuxInverses, taille: 17)
        // fond de l'accueil : le monde reel (camera) ou la pluie de code
        bouton(ctx, "fond", 812, y, 290, 42, s.passthrough ? "FOND : CAMERA" : "FOND : CODE", actif: s.passthrough, taille: 17)
    }

    // ---------- actions ----------
    var onJouer: ((Video) -> Void)?
    var onRecharger: (() -> Void)?

    func agir(_ id: String) {
        switch true {
        case id.hasPrefix("tab:"): s.tab = String(id.dropFirst(4)); s.hot = -1
        case id.hasPrefix("feed:"): s.feed = String(id.dropFirst(5)); s.defil = 0
        case id == "search": s.rechActive.toggle(); s.hot = -1
        case id == "clear": s.recherche = ""; s.defil = 0
        case id == "up": s.defil = max(0, s.defil - 1)
        case id == "down": s.defil += 1
        case id == "kb:ok": s.rechActive = false; s.hot = -1
        case id == "kb:espace": s.recherche += " "; s.defil = 0
        case id == "kb:layout": s.azerty.toggle(); s.hot = -1
        case id == "kb:del":
            if !s.recherche.isEmpty { s.recherche.removeLast() }
            s.defil = 0
        case id.hasPrefix("kb:"):
            s.recherche += String(id.dropFirst(3)).lowercased()
            s.defil = 0
        case id.hasPrefix("play:"):
            let vid = String(id.dropFirst(5))
            if let v = lib.first(where: { $0.id == vid }) {
                if v.estScene {
                    SceneBus.shared.action(v)       // telecharger, ou ouvrir si deja la
                } else {
                    v.lectures += 1
                    if v.url.isEmpty {
                        s.info = "aucun fichier pour cette entree"; s.infoT = 3.5
                    } else {
                        onJouer?(v)
                    }
                }
            }
        case id == "stop":
            VideoBus.shared.demandeStop = true; SceneBus.shared.demandeFermeture = true; s.info = ""
        case id == "mains": s.mains.toggle()
        case id == "fond": s.passthrough.toggle()
        case id == "recharger":
            onRecharger?(); s.info = "chargement du catalogue..."; s.infoT = 4
        case id == "fmt": s.format = (s.format + 1) % 3; VideoBus.shared.formatVideo = -1
        case id == "yeux": s.yeuxInverses.toggle()
        case id == "recenter": s.yawOffset = 0; s.demandeRecentrage = true
        case id == "6dof": s.mode6dof.toggle()
        case id == "hide": s.menu = false
        case id.hasPrefix("set:"):
            let part = id.split(separator: ":")
            let plus = part[2] == "+"
            switch part[1] {
            case "ipd": s.ipd = min(max(s.ipd + (plus ? 1 : -1), 54), 74)
            case "fov": s.fov = min(max(s.fov + (plus ? 2 : -2), 65), 115)
            case "k1": s.k1 = min(max(s.k1 + (plus ? 0.02 : -0.02), 0), 0.6)
            case "menuDist": s.menuDist = min(max(s.menuDist + (plus ? 0.05 : -0.05), 0.8), 3)
            case "menuAngle": s.menuAngle = min(max(s.menuAngle + (plus ? 2 : -2), 40), 96)
            case "smooth": s.smooth = min(max(s.smooth + (plus ? 0.05 : -0.05), 0), 0.9)
            case "lentilles": s.ecartLentilles = min(max(s.ecartLentilles + (plus ? 1 : -1), 50), 80)
            case "zoomPt": s.zoomPt = (min(max(s.zoomPt + (plus ? 0.1 : -0.1), 1), 2) * 10).rounded() / 10
            case "lum": s.luminosite = (min(max(s.luminosite + (plus ? 0.1 : -0.1), 0.1), 1) * 10).rounded() / 10
            default: break
            }
            s.sauver()
        default: break
        }
        draw()
    }
}
