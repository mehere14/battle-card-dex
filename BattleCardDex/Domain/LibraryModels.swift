import Foundation

nonisolated enum LibrarySource: String, Codable, CaseIterable, Sendable, Identifiable {
    case scanned, pulls
    var id: String { rawValue }
    var title: String { self == .scanned ? "Scanned Cards" : "Pack Pulls" }
}

nonisolated struct LibraryAcquisition: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1
    let version: Int
    let id: UUID
    let source: LibrarySource
    let acquiredAt: Date
    let packSetID: String?
    let cards: [BattleCardDetail]

    init(id: UUID, source: LibrarySource, acquiredAt: Date, packSetID: String?, cards: [BattleCardDetail], version: Int = schemaVersion) {
        self.version = version; self.id = id; self.source = source; self.acquiredAt = acquiredAt
        self.packSetID = packSetID; self.cards = cards
    }

    func validate() throws {
        guard version == Self.schemaVersion else { throw LibraryFailure.unsupportedSchema }
        guard !cards.isEmpty, cards.allSatisfy({ !$0.id.isEmpty }),
              (source == .scanned && cards.count == 1 && packSetID == nil)
                || (source == .pulls && cards.count == 10 && !(packSetID ?? "").isEmpty) else {
            throw LibraryFailure.invalidAcquisition
        }
    }
}

nonisolated struct LibraryCardEntry: Identifiable, Equatable, Sendable {
    let source: LibrarySource
    let card: BattleCardDetail
    let quantity: Int
    let latestAcquisition: Date
    let pendingSync: Bool
    var id: String { "\(source.rawValue):\(card.id)" }

    static func grouped(_ acquisitions: [(LibraryAcquisition, Bool)], source: LibrarySource) -> [Self] {
        var groups: [String: (BattleCardDetail, Int, Date, Bool)] = [:]
        for (event, pending) in acquisitions where event.source == source {
            for card in event.cards {
                let previous = groups[card.id]
                let latest = previous.map { max($0.2, event.acquiredAt) } ?? event.acquiredAt
                let snapshot = previous.map { $0.2 > event.acquiredAt ? $0.0 : card } ?? card
                groups[card.id] = (snapshot, (previous?.1 ?? 0) + 1, latest, (previous?.3 ?? false) || pending)
            }
        }
        return groups.map { Self(source: source, card: $0.value.0, quantity: $0.value.1,
                                 latestAcquisition: $0.value.2, pendingSync: $0.value.3) }
            .sorted { $0.latestAcquisition == $1.latestAcquisition ? $0.id < $1.id : $0.latestAcquisition > $1.latestAcquisition }
    }
}

nonisolated enum LibraryFailure: LocalizedError {
    case signInRequired, storageUnavailable, invalidAcquisition, conflictingAcquisition, unsupportedSchema
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to iCloud in Settings to save cards to your library."
        case .storageUnavailable: "Your library couldn’t be saved on this device. Please try again."
        case .invalidAcquisition: "This card collection couldn’t be saved."
        case .conflictingAcquisition: "A library record could not be reconciled. Your local cards are safe."
        case .unsupportedSchema: "Update the app to read this library record."
        }
    }
}
