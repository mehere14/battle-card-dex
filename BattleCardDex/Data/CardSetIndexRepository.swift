import CloudKit
import Foundation

nonisolated struct CardSetIndexEntry: Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let collectorNumber: String
    let rarity: String?
    let smallImageURL: URL?
    let largeImageURL: URL?
}

nonisolated struct CardSetIndex: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let setID: String
    let setName: String
    let revision: Int
    let cards: [CardSetIndexEntry]

    var cardDetails: [BattleCardDetail] {
        cards.map { entry in
            BattleCardDetail(
                summary: BattleCardSummary(id: entry.id, relatedCreatureIDs: [], name: entry.name,
                                           setID: setID, setName: setName, collectorNumber: entry.collectorNumber,
                                           rarity: entry.rarity, types: [], hitPoints: nil,
                                           smallImageURL: entry.smallImageURL, largeImageURL: entry.largeImageURL),
                subtypes: [], rules: [], abilities: [], attacks: [], weaknesses: [], resistances: [], retreatCost: [],
                evolutionText: nil, artist: nil, flavorText: nil, regulationMark: nil, legalities: [:]
            )
        }
    }
}

actor CardSetIndexRepository {
    private let database: CKDatabase
    private let directory: URL
    private var memory: [String: CardSetIndex] = [:]

    init(configuration: CloudCatalogConfiguration, container: CKContainer? = nil, directory: URL? = nil) {
        database = (container ?? CKContainer(identifier: configuration.containerIdentifier)).publicCloudDatabase
        self.directory = directory ?? Self.defaultDirectory()
    }

    func cached(setID: String) -> CardSetIndex? {
        let key = setID.lowercased()
        if let value = memory[key] { return value }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let value = try? JSONDecoder().decode(CardSetIndex.self, from: data) else { return nil }
        memory[key] = value
        return value
    }

    func remote(setID: String) async throws -> CardSetIndex {
        let key = setID.lowercased()
        let record = try await database.record(for: CKRecord.ID(recordName: "catalog-card-set-index-\(key)"))
        guard let payload = record["payload"] as? Data else { throw CatalogServiceError.malformed("set_index_payload") }
        let value = try JSONDecoder().decode(CardSetIndex.self, from: payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: fileURL(for: key), options: .atomic)
        memory[key] = value
        return value
    }

    private func fileURL(for setID: String) -> URL {
        let safe = setID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BattleCardDex/CardSetIndexes", isDirectory: true)
    }
}
