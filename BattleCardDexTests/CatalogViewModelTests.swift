import Foundation
import Testing
@testable import Battle_Card_Dex

@Suite(.serialized)
@MainActor
struct CatalogViewModelTests {
    @Test func coldCatalogDefersEvolutionAndCardsUntilDetailIsRequested() async throws {
        let catalog = try makeCatalog()
        let local = FakeLocalCatalogStore(states: [.empty, .empty, .empty])
        let publicStore = FakePublicCatalogStore(states: [
            .success(catalog.primaryDocuments),
            .success(catalog.relatedDocuments.filter { document in
                document.identifier == "catalog-evolution-1" ||
                (document.identifier.dropFirst("catalog-card-".count).description as NSString).integerValue % 30 == 1
            }),
        ])
        let model = CatalogViewModel(
            coordinator: CatalogCoordinator(local: local, publicStore: publicStore),
            supportedRange: 1...30,
            manifestRecordIdentifier: catalog.manifest.identifier,
            automaticallyWarmDetails: false
        )

        await model.load()

        #expect(model.state == .ready)
        #expect(model.creatures.map(\.id) == Array(1...30))
        #expect(model.profiles.count == 30)
        #expect(model.evolutions.isEmpty)
        #expect(model.cards.isEmpty)

        await model.loadDetails(for: [1])

        #expect(model.evolutions.count == 1)
        #expect(model.cards.count == 35)
        #expect(model.cards(for: 1).count == 35)
        #expect(model.cards(for: 30).isEmpty)
        #expect(CreatureFilter(query: "creature 12").apply(to: model.creatures).map(\.id) == [12])
        #expect(CreatureFilter(generation: "generation-2", type: "water").apply(to: model.creatures).map(\.id) == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30])
        #expect((await publicStore.receivedQueries).count == 2)
    }

    @Test func warmCatalogChecksManifestWithoutEagerlyLoadingCards() async throws {
        let oldCatalog = try makeCatalog(cardName: "Original Card")
        let updatedCatalog = try makeCatalog(cardName: "Updated Card", changedCardIdentifier: "catalog-card-1")
        let local = FakeLocalCatalogStore(states: [
            .success(oldCatalog.primaryDocuments),
            .success([oldCatalog.manifest]), .empty,
        ])
        let publicStore = FakePublicCatalogStore(states: [
            .success([updatedCatalog.manifest]),
        ])
        let model = CatalogViewModel(
            coordinator: CatalogCoordinator(local: local, publicStore: publicStore),
            supportedRange: 1...30,
            manifestRecordIdentifier: oldCatalog.manifest.identifier,
            automaticallyWarmDetails: false
        )

        await model.load()

        #expect(model.state == .ready)
        #expect(model.cards.isEmpty)
        #expect((await publicStore.receivedQueries).map(\.identifiers) == [
            [oldCatalog.manifest.identifier],
        ])
    }

    @Test func startupSummaryCanOpenCardsBeforeBootstrap() async throws {
        let catalog = try makeCatalog()
        let savedCreature = try #require(catalog.primaryDocuments.first { $0.identifier == "catalog-creature-1" })
        let summary = try savedCreature.persistedEnvelope().decode(CatalogCreaturePayload.self).domainValue().summary
        let details = catalog.relatedDocuments.filter {
            $0.identifier == "catalog-evolution-1" ||
            ($0.identifier.hasPrefix("catalog-card-") &&
             (Int($0.identifier.dropFirst("catalog-card-".count))! - 1) % 30 == 0)
        }
        let local = FakeLocalCatalogStore(states: [.success([savedCreature]), .success(details)])
        let remote = FakePublicCatalogStore(states: [])
        let model = CatalogViewModel(
            coordinator: CatalogCoordinator(local: local, publicStore: remote),
            automaticallyWarmDetails: false, initialCreatures: [summary]
        )
        #expect(model.creatures == [summary])
        await model.loadDetails(for: [1])
        #expect(model.cards(for: 1).count == 35)
        #expect(model.profile(for: 1) != nil)
        #expect(model.detailStatus(for: 1).cards == .loaded)
        #expect(await remote.receivedQueries.isEmpty)
    }

    @Test func launchShowsPartialCacheBeforeNetworkCompletes() async throws {
        let catalog = try makeCatalog()
        let cachedCreature = try #require(catalog.primaryDocuments.first { $0.identifier == "catalog-creature-1" })
        let local = FakeLocalCatalogStore(states: [.success([cachedCreature]), .empty])
        let store = SuspendedManifestStore(manifest: catalog.manifest, details: catalog.primaryDocuments)
        let model = CatalogViewModel(
            coordinator: CatalogCoordinator(local: local, publicStore: store),
            automaticallyWarmDetails: false
        )
        let launch = Task { await model.load() }
        await store.waitForManifestRequest()
        #expect(model.creatures.map(\.id) == [1])
        #expect(model.state == .ready)
        #expect(model.refreshStatus == .checking)
        await store.finishManifestRequest()
        await launch.value
        #expect(model.creatures.count == 30)
        #expect(model.refreshStatus == .idle)
    }

    @Test(arguments: [false, true])
    func manifestRefreshPreservesDetailsLoadedWhileRefreshIsWaiting(compactManifest: Bool) async throws {
        let catalog = try makeCatalog(compactManifest: compactManifest)
        let details = catalog.relatedDocuments.filter {
            $0.identifier == "catalog-evolution-1" ||
            ($0.identifier.hasPrefix("catalog-card-") &&
             (Int($0.identifier.dropFirst("catalog-card-".count))! - 1) % 30 == 0)
        }
        let store = SuspendedManifestStore(manifest: catalog.manifest, details: details)
        let local = FakeLocalCatalogStore(states: [
            .success(catalog.primaryDocuments), .success([catalog.manifest]), .empty,
            .success(catalog.relatedDocuments),
        ])
        let model = CatalogViewModel(
            coordinator: CatalogCoordinator(local: local, publicStore: store),
            automaticallyWarmDetails: false
        )
        await model.bootstrap()
        let refresh = Task { await model.refreshCatalog() }
        await store.waitForManifestRequest()
        await model.loadDetails(for: [1])
        #expect(model.cards(for: 1).count == 35)
        await store.finishManifestRequest()
        await refresh.value
        #expect(model.cards(for: 1).count == 35)
        #expect(model.evolutionChain(for: 1) != nil)
        #expect(model.detailStatus(for: 1).cards == .loaded)
        await model.loadDetails(for: [1])
        #expect(model.cards(for: 1).count == 35)
        #expect(await store.detailRequestCount == 1)
        let retained = try #require(await local.retainedIdentifierSets.last)
        #expect(retained.contains("catalog-card-2")) // Disk-only card, never opened this launch.
    }

    private func makeCatalog(
        cardName: String = "Card",
        changedCardIdentifier: String? = nil,
        compactManifest: Bool = false
    ) throws -> FixtureCatalog {
        let creatures = try (1...30).map { id in
            try document(
                creature(
                    id: id,
                    cardRecordIdentifiers: (1...1_040).compactMap { index in
                        ((index - 1) % 30) + 1 == id ? "catalog-card-\(index)" : nil
                    },
                    evolutionRecordIdentifier: id <= 12 ? "catalog-evolution-\(id)" : nil
                ),
                identifier: "catalog-creature-\(id)",
                hash: "creature-hash-\(id)"
            )
        }
        let evolutions = try (1...12).map { id in
            let payload = CatalogEvolutionPayload(
                schemaVersion: 1,
                id: id,
                root: CatalogEvolutionNode(creatureID: id, name: "creature-\(id)", requirements: [], children: [])
            )
            return try document(
                payload,
                identifier: "catalog-evolution-\(id)",
                hash: "evolution-hash-\(id)"
            )
        }
        let cards = try (1...1_040).map { index in
            let identifier = "catalog-card-\(index)"
            return try document(
                card(id: "card-\(index)", relatedID: ((index - 1) % 30) + 1, name: identifier == changedCardIdentifier ? cardName : "Card \(index)"),
                identifier: identifier,
                hash: identifier == changedCardIdentifier ? "changed-card-hash" : "card-hash-\(index)"
            )
        }
        let records = creatures + evolutions + cards
        let indexedRecords = compactManifest ? creatures + evolutions : records
        let hashes = Dictionary(uniqueKeysWithValues: indexedRecords.map { ($0.identifier, $0.contentHash) })
        let manifestPayload = CatalogManifestPayload(
            schemaVersion: 1, id: "catalog-manifest", revision: changedCardIdentifier == nil ? 1 : 2,
            publishedAt: Date(timeIntervalSince1970: changedCardIdentifier == nil ? 1 : 2),
            creatureCount: 30, evolutionCount: 12, cardCount: 1_040, contentHashes: hashes
        )
        let manifest = try document(
            manifestPayload,
            identifier: "catalog-manifest-v1",
            hash: changedCardIdentifier == nil ? "manifest-hash-1" : "manifest-hash-2"
        )
        return FixtureCatalog(manifest: manifest, primaryDocuments: [manifest] + creatures, relatedDocuments: evolutions + cards)
    }

    private func document<Value: NormalizedCatalogPayload>(
        _ payload: Value,
        identifier: String,
        hash: String
    ) throws -> CatalogDocument {
        try CatalogDocument(identifier: identifier, envelope: CatalogPersistenceEnvelope(payload), contentHash: hash)
    }

    private func creature(id: Int, cardRecordIdentifiers: [String] = [], evolutionRecordIdentifier: String? = nil) -> CatalogCreaturePayload {
        .init(schemaVersion: 1, id: id, name: "creature-\(id)", displayName: "Creature \(id)",
              generation: id.isMultiple(of: 2) ? "generation-2" : "generation-1",
              types: [id.isMultiple(of: 2) ? "water" : "leaf"], artworkURL: nil, genus: nil, description: nil,
              heightMetres: nil, weightKilograms: nil, baseExperience: nil, abilities: [], hiddenAbilities: [],
              stats: .init(hitPoints: 1, attack: 1, defense: 1, specialAttack: 1, specialDefense: 1, speed: 1),
              forms: [], moves: [], encounters: [], versionGroups: [],
              cardRecordIdentifiers: cardRecordIdentifiers,
              evolutionRecordIdentifier: evolutionRecordIdentifier)
    }

    private func card(id: String, relatedID: Int, name: String) -> CatalogCardPayload {
        .init(schemaVersion: 1, id: id, relatedCreatureIDs: [relatedID], name: name, setID: "set", setName: "Set",
              collectorNumber: id, rarity: nil, types: [], hitPoints: nil, smallImageURL: nil, largeImageURL: nil,
              subtypes: [], rules: [], abilities: [], attacks: [], weaknesses: [], resistances: [], retreatCost: [],
              evolutionText: nil, artist: nil, flavorText: nil, regulationMark: nil, legalities: [:])
    }
}

private struct FixtureCatalog {
    let manifest: CatalogDocument
    let primaryDocuments: [CatalogDocument]
    let relatedDocuments: [CatalogDocument]
}

private actor SuspendedManifestStore: PublicCatalogStore {
    let manifest: CatalogDocument
    let details: [CatalogDocument]
    private var manifestContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var detailRequestCount = 0

    init(manifest: CatalogDocument, details: [CatalogDocument]) {
        self.manifest = manifest
        self.details = details
    }

    func fetch(_ query: CatalogQuery) async throws -> ServiceResponse<[CatalogDocument]> {
        if query.identifiers.contains(manifest.identifier) {
            await withCheckedContinuation { continuation in
                manifestContinuation = continuation
                startedContinuation?.resume()
                startedContinuation = nil
            }
            return ServiceResponse(value: [manifest] + details.filter {
                $0.identifier != manifest.identifier && query.identifiers.contains($0.identifier)
            })
        }
        detailRequestCount += 1
        return ServiceResponse(value: details.filter { query.identifiers.contains($0.identifier) })
    }

    func waitForManifestRequest() async {
        if manifestContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finishManifestRequest() {
        manifestContinuation?.resume()
        manifestContinuation = nil
    }
}
