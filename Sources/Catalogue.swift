import Foundation

/* Meme adresse et meme format JSON que l'appli Android (MainActivity.kt,
   CATALOGUE_URL). Un seul catalogue partage entre les deux plateformes. */
let catalogueURL = URL(string: "https://lunettes.leobarrin63.workers.dev/catalogue.json")!

struct Video: Identifiable, Decodable {
    let id: String
    let titre: String
    let duree: Int
    let vues: Int
    let url: String
    let format: String?

    enum CodingKeys: String, CodingKey {
        case id, titre, duree, vues, url, format
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        titre = try c.decodeIfPresent(String.self, forKey: .titre) ?? "sans titre"
        duree = try c.decodeIfPresent(Int.self, forKey: .duree) ?? 0
        vues = try c.decodeIfPresent(Int.self, forKey: .vues) ?? 0
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        format = try c.decodeIfPresent(String.self, forKey: .format)
    }
}

private struct CatalogueRacine: Decodable {
    let videos: [Video]
}

enum CatalogueErreur: Error {
    case reponseInvalide
}

enum Catalogue {
    static func charger() async throws -> [Video] {
        let (data, reponse) = try await URLSession.shared.data(from: catalogueURL)
        guard let http = reponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogueErreur.reponseInvalide
        }
        let racine = try JSONDecoder().decode(CatalogueRacine.self, from: data)
        return racine.videos
    }
}
