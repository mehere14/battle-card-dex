//
//  BattleCardDexApp.swift
//  Battle Card Dex
//
//  Created on 2026-08-31.
//

import SwiftUI
import SwiftData

@main
@MainActor
struct BattleCardDexApp: App {
    let sharedModelContainer: ModelContainer
    @StateObject private var catalogModel: CatalogViewModel
    @StateObject private var library: LibraryRepository

    init() {
        let appConfiguration = AppConfiguration.current
        let useFixtures = ProcessInfo.processInfo.environment["BATTLE_CARD_DEX_USE_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _library = StateObject(wrappedValue: LibraryRepository(configuration: appConfiguration, inMemory: useFixtures))
        do {
            let container = try LocalCatalogContainer.make(
                isStoredInMemoryOnly: appConfiguration.localPersistenceMode == .inMemory
            )
            sharedModelContainer = container
            if useFixtures {
                _catalogModel = StateObject(wrappedValue: CatalogViewModel.preview())
                return
            }
            let dependencies = AppDependencies(container: container, configuration: appConfiguration)
            _catalogModel = StateObject(wrappedValue: CatalogViewModel(
                coordinator: dependencies.catalog,
                supportedRange: appConfiguration.initialSeedRange,
                manifestRecordIdentifier: appConfiguration.cloudCatalog.manifestRecordIdentifier,
                imageRepository: dependencies.images,
                cardSetIndexRepository: dependencies.cardSetIndexes,
                packArtworkRepository: dependencies.packArtwork,
                initialCreatures: (try? SwiftDataLocalCatalogStore.startupSummaries(container: container)) ?? []
            ))
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: catalogModel, library: library)
        }
        .modelContainer(sharedModelContainer)
    }
}
