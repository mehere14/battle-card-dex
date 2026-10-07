import Foundation
import SwiftData

struct AppDependencies: Sendable {
    let catalog: CatalogCoordinator
    let images: URLSessionImageRepository
    let cardSetIndexes: CardSetIndexRepository
    let packArtwork: PackArtworkRepository

    init(container: ModelContainer, configuration: AppConfiguration) {
        let local = SwiftDataLocalCatalogStore(container: container)
        let remote = PublicCloudKitCatalogStore(configuration: configuration.cloudCatalog)
        catalog = CatalogCoordinator(local: local, publicStore: remote)
        images = URLSessionImageRepository(configuration: configuration.cache, session: URLSessionImageRepository.configuredSession(cache: configuration.cache))
        cardSetIndexes = CardSetIndexRepository(configuration: configuration.cloudCatalog)
        packArtwork = PackArtworkRepository(configuration: configuration.cloudCatalog)
    }
}
