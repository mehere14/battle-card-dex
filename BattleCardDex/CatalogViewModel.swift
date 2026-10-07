import Foundation
import Combine
import OSLog
import SwiftUI

@MainActor
final class CatalogViewModel: ObservableObject {
    private nonisolated static let logger = Logger(
        subsystem: "com.askcruit.Battle-Card-Dex",
        category: "CatalogViewModel"
    )
    enum State: Equatable {
        case loading
        case ready
        case stale
        case emptyInstall
        case offline
        case incompatibleSchema
    }

    enum RefreshStatus: Equatable {
        case idle
        case checking
        case updated
        case failed
    }

    enum DetailStatus: Equatable {
        case notRequested
        case loading
        case loaded
        case empty
        case failed
    }

    enum DetailPriority: Sendable {
        case userInitiated
        case prefetch
    }

    struct CreatureDetailStatus: Equatable {
        var cards: DetailStatus = .notRequested
        var evolution: DetailStatus = .notRequested
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var creatures: [CreatureSummary] = []
    @Published private(set) var profiles: [Int: CreatureProfile] = [:]
    @Published private(set) var evolutions: [Int: EvolutionChain] = [:]
    @Published private(set) var cards: [BattleCardDetail] = []
    @Published private(set) var refreshStatus: RefreshStatus = .idle
    @Published private(set) var detailStatuses: [Int: CreatureDetailStatus] = [:]

    private let coordinator: CatalogCoordinator?
    private let supportedRange: ClosedRange<Int>
    private let manifestRecordIdentifier: String
    private let automaticallyWarmDetails: Bool
    private var loadedDocuments: [String: CatalogDocument] = [:]
    private var detailWarmupTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var detailTasks: [Int: Task<Void, Never>] = [:]
    private var bootstrapNeedsRemoteCheck = true
    let imageRepository: (any ImageRepository)?
    private let cardSetIndexRepository: CardSetIndexRepository?
    let packArtworkRepository: PackArtworkRepository?

    init(coordinator: CatalogCoordinator? = nil,
         supportedRange: ClosedRange<Int> = 1...30,
         manifestRecordIdentifier: String = "catalog-manifest-v1",
         automaticallyWarmDetails: Bool = true,
         imageRepository: (any ImageRepository)? = nil,
         cardSetIndexRepository: CardSetIndexRepository? = nil,
         packArtworkRepository: PackArtworkRepository? = nil) {
        self.coordinator = coordinator
        self.supportedRange = supportedRange
        self.manifestRecordIdentifier = manifestRecordIdentifier
        self.automaticallyWarmDetails = automaticallyWarmDetails
        self.imageRepository = imageRepository
        self.cardSetIndexRepository = cardSetIndexRepository
        self.packArtworkRepository = packArtworkRepository
    }

    static func preview() -> CatalogViewModel {
        let model = CatalogViewModel()
        model.creatures = (1...6).map { id in
            CreatureSummary(id: id, name: "creature-\(id)", displayName: "Creature \(id)", generation: "generation-1", types: [id.isMultiple(of: 2) ? "water" : "leaf"], artworkURL: nil)
        }
        model.cards = (1...14).map { id in
            BattleCardDetail(
                summary: BattleCardSummary(
                    id: "preview-card-\(id)",
                    relatedCreatureIDs: [1],
                    name: "Creature 1 Card \(id)",
                    setID: "me5",
                    setName: "Pitch Black",
                    collectorNumber: String(id),
                    rarity: id <= 6 ? "Common" : (id <= 10 ? "Uncommon" : "Rare"),
                    types: ["leaf"],
                    hitPoints: 100 + id * 10,
                    smallImageURL: nil,
                    largeImageURL: nil
                ),
                subtypes: [], rules: [], abilities: [], attacks: [], weaknesses: [],
                resistances: [], retreatCost: [], evolutionText: nil, artist: nil,
                flavorText: nil, regulationMark: nil, legalities: [:]
            )
        }
        model.state = .ready
        return model
    }

    func load() async {
        refreshStatus = .checking
        await bootstrap()
        if bootstrapNeedsRemoteCheck {
            await refreshCatalog()
        } else {
            refreshStatus = .idle
        }
    }

    func retry() async {
        if creatures.isEmpty { await bootstrap() }
        await refreshCatalog()
    }

    func bootstrap() async {
        await loadCachedCatalog()
    }

    func refreshCatalog() async {
        if let refreshTask { return await refreshTask.value }
        refreshStatus = .checking
        let task = Task { [weak self] in
            await self?.performCatalogRefresh()
            return ()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func loadDetails(for creatureIDs: [Int], priority: DetailPriority = .userInitiated) async {
        for id in Array(Set(creatureIDs)) {
            await loadDetails(for: id, priority: priority)
        }
    }

    private func loadDetails(for creatureID: Int, priority: DetailPriority) async {
        if let existing = detailTasks[creatureID] { return await existing.value }
        if priority == .userInitiated { detailWarmupTask?.cancel() }
        let taskPriority: TaskPriority = priority == .userInitiated ? .userInitiated : .utility
        let task = Task(priority: taskPriority) { [weak self] in
            await self?.performDetailLoad(for: creatureID)
            return ()
        }
        detailTasks[creatureID] = task
        await task.value
        detailTasks[creatureID] = nil
        if priority == .userInitiated { scheduleDetailWarmup() }
    }

    private func performDetailLoad(for creatureID: Int) async {
        guard let coordinator else { return }
        guard let document = loadedDocuments["catalog-creature-\(creatureID)"],
              let envelope = try? document.persistedEnvelope(),
              let creature = try? envelope.decode(CatalogCreaturePayload.self) else { return }
        let cardIDs = creature.cardRecordIdentifiers ?? []
        let evolutionIDs = [creature.evolutionRecordIdentifier].compactMap { $0 }
        var status = detailStatuses[creatureID] ?? CreatureDetailStatus()
        status.cards = cardIDs.isEmpty ? .empty : .loading
        status.evolution = evolutionIDs.isEmpty ? .empty : .loading
        detailStatuses[creatureID] = status
        let identifiers = cardIDs + evolutionIDs
        let missingIdentifiers = Array(Set(identifiers)).filter { loadedDocuments[$0] == nil }.sorted()
        var failed = Set<String>()
        if !missingIdentifiers.isEmpty {
            let snapshot = await coordinator.load(identifiers: missingIdentifiers)
            failed = Set(snapshot.failedIdentifiers)
            if snapshot.state == .offline || snapshot.state == .emptyInstall || snapshot.state == .incompatibleSchema {
                failed.formUnion(missingIdentifiers)
            }
            for document in snapshot.documents { loadedDocuments[document.identifier] = document }
            await mergeDetails(from: snapshot.documents)
        }
        status = detailStatuses[creatureID] ?? status
        if !cardIDs.isEmpty { status.cards = cardIDs.contains(where: failed.contains) ? .failed : (cards(for: creatureID).isEmpty ? .empty : .loaded) }
        if !evolutionIDs.isEmpty { status.evolution = evolutionIDs.contains(where: failed.contains) ? .failed : (evolutionChain(for: creatureID) == nil ? .empty : .loaded) }
        detailStatuses[creatureID] = status
    }

    private func scheduleDetailWarmup() {
        guard automaticallyWarmDetails, detailWarmupTask == nil else { return }
        let ids = creatures.map(\.id)
        detailWarmupTask = Task(priority: .utility) { [weak self] in
            // Give SwiftUI a chance to present the catalog before background I/O
            // and decoding begins.
            try? await Task.sleep(nanoseconds: 350_000_000)
            for start in stride(from: 0, to: ids.count, by: 25) {
                guard !Task.isCancelled, let self else { return }
                let end = min(start + 25, ids.count)
                await self.loadDetails(for: Array(ids[start..<end]), priority: .prefetch)
                await Task.yield()
            }
            self?.detailWarmupTask = nil
        }
    }

    private func loadCachedCatalog() async {
        guard let coordinator else { state = creatures.isEmpty ? .emptyInstall : .ready; return }
        state = .loading
        let primaryIdentifiers = [manifestRecordIdentifier] + supportedRange.map { "catalog-creature-\($0)" }
        let fetch: ([String]) async -> CatalogCoordinatorSnapshot = { ids in
            await coordinator.load(identifiers: ids)
        }
        let primarySnapshot = await fetch(primaryIdentifiers)
        Self.logger.info("Primary load completed with state \(String(describing: primarySnapshot.state), privacy: .public), \(primarySnapshot.documents.count, privacy: .public) records, and \(primarySnapshot.failedIdentifiers.count, privacy: .public) misses")
#if DEBUG
        print("BattleCardDex catalog: primary load state=\(primarySnapshot.state) records=\(primarySnapshot.documents.count) misses=\(primarySnapshot.failedIdentifiers.count)")
#endif
        guard let manifest = Self.manifest(in: primarySnapshot.documents, identifier: manifestRecordIdentifier) else {
            Self.logger.error("The catalog manifest could not be found or decoded")
#if DEBUG
            print("BattleCardDex catalog: manifest missing or undecodable")
#endif
            await apply(documents: primarySnapshot.documents, state: primarySnapshot.state)
            bootstrapNeedsRemoteCheck = primarySnapshot.servedFromCache
            return
        }

        let additionalCreatureIdentifiers = manifest.creatureCount > supportedRange.upperBound
            ? ((supportedRange.upperBound + 1)...manifest.creatureCount).map { "catalog-creature-\($0)" }
            : []
        let relatedIdentifiers = additionalCreatureIdentifiers
        let relatedSnapshot: CatalogCoordinatorSnapshot = relatedIdentifiers.isEmpty
            ? CatalogCoordinatorSnapshot(state: .ready, documents: [], failedIdentifiers: [], servedFromCache: primarySnapshot.servedFromCache)
            : await fetch(relatedIdentifiers)
        let cardSnapshot = CatalogCoordinatorSnapshot(state: .ready, documents: [], failedIdentifiers: [], servedFromCache: true)
        Self.logger.info("Related load completed with state \(String(describing: relatedSnapshot.state), privacy: .public), \(relatedSnapshot.documents.count, privacy: .public) records, and \(relatedSnapshot.failedIdentifiers.count, privacy: .public) misses")
#if DEBUG
        print("BattleCardDex catalog: related load state=\(relatedSnapshot.state) records=\(relatedSnapshot.documents.count) misses=\(relatedSnapshot.failedIdentifiers.count)")
#endif
        let snapshot = Self.combined(primarySnapshot, relatedSnapshot, cardSnapshot)
        let allDocuments = Self.mergedDocuments([primarySnapshot.documents, relatedSnapshot.documents, cardSnapshot.documents])
        loadedDocuments = Dictionary(uniqueKeysWithValues: allDocuments.map { ($0.identifier, $0) })
        await apply(documents: allDocuments, state: snapshot.state)
        bootstrapNeedsRemoteCheck = primarySnapshot.servedFromCache && relatedSnapshot.servedFromCache
        scheduleDetailWarmup()

        // A warm launch has now rendered from memory/SwiftData. Refresh only the
        // manifest, then ask CloudKit for records whose published hashes changed.
        // This preserves the fixed read order while avoiding a full-catalog fetch
        // on every launch.
    }

    private func performCatalogRefresh() async {
        guard let coordinator else { refreshStatus = .idle; return }
        let allDocuments = loadedDocuments.values.sorted { $0.identifier < $1.identifier }
        guard Self.manifest(in: allDocuments, identifier: manifestRecordIdentifier) != nil else {
            refreshStatus = creatures.isEmpty ? .failed : .idle
            return
        }
        let refreshedManifestSnapshot = await coordinator.refresh(identifiers: [manifestRecordIdentifier])
        guard let refreshedManifest = Self.manifest(in: refreshedManifestSnapshot.documents, identifier: manifestRecordIdentifier) else {
            refreshStatus = .failed
            return
        }

        let currentByIdentifier = Dictionary(uniqueKeysWithValues: allDocuments.map { ($0.identifier, $0) })
        let changedIdentifiers = refreshedManifest.contentHashes.keys.filter { identifier in
            guard identifier != manifestRecordIdentifier else { return false }
            return currentByIdentifier[identifier]?.contentHash != refreshedManifest.contentHashes[identifier]
        }.sorted()
        let changedSnapshot = changedIdentifiers.isEmpty
            ? CatalogCoordinatorSnapshot(state: .ready, documents: [], failedIdentifiers: [])
            : await coordinator.refresh(identifiers: changedIdentifiers)
        let snapshot = Self.combined(refreshedManifestSnapshot, changedSnapshot)

        let expectedIdentifiers = Set(refreshedManifest.contentHashes.keys).union([manifestRecordIdentifier])
        var refreshedDocuments = Dictionary(uniqueKeysWithValues: allDocuments.map { ($0.identifier, $0) })
        for document in refreshedManifestSnapshot.documents + changedSnapshot.documents {
            refreshedDocuments[document.identifier] = document
        }
        let finalDocuments = refreshedDocuments.values
            .filter { expectedIdentifiers.contains($0.identifier) }
            .sorted { $0.identifier < $1.identifier }
        guard snapshot.failedIdentifiers.isEmpty else { refreshStatus = .failed; return }
        await coordinator.retain(identifiers: expectedIdentifiers)
        loadedDocuments = Dictionary(uniqueKeysWithValues: finalDocuments.map { ($0.identifier, $0) })
        await apply(documents: finalDocuments, state: snapshot.state)
        refreshStatus = changedIdentifiers.isEmpty ? .idle : .updated
    }

    private func apply(documents: [CatalogDocument], state coordinatorState: CatalogCoordinatorState) async {
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(documents: documents) }.value
        creatures = decoded.summaries
        profiles = decoded.profiles
        evolutions = decoded.evolutions
        cards = decoded.cards
        loadedDetailStatuses()
        applyState(coordinatorState)
    }

    private nonisolated static func decode(documents: [CatalogDocument]) -> (summaries: [CreatureSummary], profiles: [Int: CreatureProfile], evolutions: [Int: EvolutionChain], cards: [BattleCardDetail]) {
        var summaries: [CreatureSummary] = []
        var loadedProfiles: [Int: CreatureProfile] = [:]
        var loadedEvolutions: [Int: EvolutionChain] = [:]
        var loadedCards: [BattleCardDetail] = []
        for document in documents {
            guard let envelope = try? document.persistedEnvelope() else { continue }
            switch envelope.kind {
            case .creature:
                guard let value = try? envelope.decode(CatalogCreaturePayload.self) else { continue }
                let profile = value.domainValue()
                summaries.append(profile.summary)
                loadedProfiles[profile.summary.id] = profile
            case .evolution:
                if let value = try? envelope.decode(CatalogEvolutionPayload.self) { loadedEvolutions[value.id] = value.domainValue() }
            case .card:
                if let value = try? envelope.decode(CatalogCardPayload.self) { loadedCards.append(value.domainValue()) }
            case .manifest: break
            }
        }
        return (summaries.sorted { $0.id < $1.id }, loadedProfiles, loadedEvolutions, loadedCards.sorted { $0.summary.id < $1.summary.id })
    }

    private func applyState(_ coordinatorState: CatalogCoordinatorState) {
        switch coordinatorState {
        case .ready: state = .ready
        case .stale: state = .stale
        case .emptyInstall: state = .emptyInstall
        case .offline: state = .offline
        case .incompatibleSchema: state = .incompatibleSchema
        default: state = creatures.isEmpty ? .emptyInstall : .ready
        }
    }

    private func mergeDetails(from documents: [CatalogDocument]) async {
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(documents: documents) }.value
        var updatedEvolutions = evolutions
        var updatedCards = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        decoded.evolutions.forEach { updatedEvolutions[$0.key] = $0.value }
        decoded.cards.forEach { updatedCards[$0.id] = $0 }
        evolutions = updatedEvolutions
        cards = updatedCards.values.sorted { $0.id < $1.id }
    }

    private static func manifest(in documents: [CatalogDocument], identifier: String) -> CatalogManifestPayload? {
        guard let document = documents.first(where: { $0.identifier == identifier }) else { return nil }
        return try? document.persistedEnvelope().decode(CatalogManifestPayload.self)
    }

    private static func mergedDocuments(_ groups: [[CatalogDocument]]) -> [CatalogDocument] {
        Dictionary(groups.flatMap { $0 }.map { ($0.identifier, $0) }, uniquingKeysWith: { _, latest in latest })
            .values.sorted { $0.identifier < $1.identifier }
    }

    private static func combined(_ snapshots: CatalogCoordinatorSnapshot...) -> CatalogCoordinatorSnapshot {
        let documents = mergedDocuments(snapshots.map(\.documents))
        let failed = Array(Set(snapshots.flatMap(\.failedIdentifiers))).sorted()
        let hasDocuments = !documents.isEmpty
        let states = snapshots.map(\.state)
        let state: CatalogCoordinatorState
        if states.contains(.incompatibleSchema) {
            state = .incompatibleSchema
        } else if !hasDocuments, states.contains(.offline) {
            state = .offline
        } else if !hasDocuments, states.contains(.emptyInstall) {
            state = .emptyInstall
        } else if !failed.isEmpty || states.contains(.stale) || states.contains(.offline) {
            state = .stale
        } else {
            state = .ready
        }
        return CatalogCoordinatorSnapshot(
            state: state,
            documents: documents,
            failedIdentifiers: failed,
            servedFromCache: snapshots.allSatisfy(\.servedFromCache)
        )
    }

    func profile(for id: Int) -> CreatureProfile? { profiles[id] }

    func cards(for creatureID: Int) -> [BattleCardDetail] {
        cards.filter { $0.summary.relatedCreatureIDs.contains(creatureID) }
    }

    func cards(inSet setID: String) async -> [BattleCardDetail] {
        let existing = cards.filter { $0.summary.setID.caseInsensitiveCompare(setID) == .orderedSame }
        if let repository = cardSetIndexRepository {
            if let cached = await repository.cached(setID: setID) {
                Task { try? await repository.remote(setID: setID) }
                return cached.cardDetails
            }
            if let remote = try? await repository.remote(setID: setID) { return remote.cardDetails }
        }
        guard let coordinator else { return existing }
        let snapshot = await coordinator.loadCards(setID: setID)
        await mergeDetails(from: snapshot.documents)
        return cards.filter { $0.summary.setID.caseInsensitiveCompare(setID) == .orderedSame }
    }

    func evolutionChain(for creatureID: Int) -> EvolutionChain? {
        evolutions.values.first { $0.memberIDs.contains(creatureID) }
    }

    func detailStatus(for creatureID: Int) -> CreatureDetailStatus {
        detailStatuses[creatureID] ?? CreatureDetailStatus()
    }

    private func loadedDetailStatuses() {
        for id in creatures.map(\.id) where detailStatuses[id] == nil {
            detailStatuses[id] = CreatureDetailStatus()
        }
    }
}
