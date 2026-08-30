import Foundation

/* Meme adresse et meme format JSON que l'appli Android (MainActivity.kt,
   CATALOGUE_URL). Un seul catalogue partage entre les deux plateformes. */
let catalogueURL = URL(string: "https://lunettes.leobarrin63.workers.dev/catalogue.json")!

/* Classe (pas struct) comme cote Android : `lectures` est mutable et
   suivi localement, independamment de ce que renvoie le serveur. */
final class Video: Identifiable {
    let id: String
    let nom: String
    let duree: Int
    let vues: Int
    let ajoute: Int64
    let url: String
    let teinte: Int
    let format: Int   // -1 suit le reglage manuel, 0 sbs, 1 haut-bas, 2 mono
    var lectures: Int = 0

    init(id: String, nom: String, duree: Int, vues: Int, ajoute: Int64,
         url: String, teinte: Int, format: Int) {
        self.id = id; self.nom = nom; self.duree = duree; self.vues = vues
        self.ajoute = ajoute; self.url = url; self.teinte = teinte; self.format = format
    }
}

enum CatalogueErreur: Error {
    case reponseInvalide
}

enum Catalogue {
    static func charger() async throws -> (videos: [Video], apiUrl: String) {
        let (data, reponse) = try await URLSession.shared.data(from: catalogueURL)
        guard let http = reponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogueErreur.reponseInvalide
        }
        guard let racine = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogueErreur.reponseInvalide
        }
        let apiUrl = racine["api"] as? String ?? ""
        let arr = racine["videos"] as? [[String: Any]] ?? []
        var l: [Video] = []
        for (i, v) in arr.enumerated() {
            let dStr = (v["ajoute"] as? String ?? "").replacingOccurrences(of: "-", with: "")
            let ajoute = Int64(dStr) ?? Int64(arr.count - i)
            let fmtStr = (v["format"] as? String ?? "").lowercased()
            let fmt: Int
            switch fmtStr {
            case "ou", "haut-bas", "tb": fmt = 1
            case "mono": fmt = 2
            case "sbs": fmt = 0
            default: fmt = -1
            }
            l.append(Video(
                id: v["id"] as? String ?? "v\(i)",
                nom: v["titre"] as? String ?? "sans titre",
                duree: v["duree"] as? Int ?? 0,
                vues: v["vues"] as? Int ?? 0,
                ajoute: ajoute,
                url: v["url"] as? String ?? "",
                teinte: v["teinte"] as? Int ?? ((i * 47) % 360),
                format: fmt))
        }
        return (l, apiUrl)
    }
}

enum Compteur {
    /* Prevenir le serveur qu'une video a ete regardee, comme cote
       Android : c'est le serveur qui decide si la vue compte. */
    static func envoyer(videoId: String) {
        let apiUrl = AppState.shared.apiUrl
        let appareil = AppState.shared.appareil
        guard !apiUrl.isEmpty, !videoId.isEmpty, !appareil.isEmpty,
              let url = URL(string: apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/vue")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": videoId, "appareil": appareil])
        URLSession.shared.dataTask(with: req).resume()
    }
}
