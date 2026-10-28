import Foundation
import SwiftData

@Model
final class StoredLibraryAcquisition {
    @Attribute(.unique) var key: String
    var account: String
    var eventID: String
    var payload: Data
    var pending: Bool
    var systemFields: Data?
    init(account: String, event: LibraryAcquisition, pending: Bool, payload: Data, systemFields: Data? = nil) {
        key = "\(account):\(event.id.uuidString)"; self.account = account
        eventID = event.id.uuidString; self.payload = payload; self.pending = pending; self.systemFields = systemFields
    }
}

@Model
final class StoredLibrarySyncState {
    @Attribute(.unique) var account: String
    var serialization: Data
    init(account: String, serialization: Data) { self.account = account; self.serialization = serialization }
}

@MainActor
final class LibraryLocalStore {
    let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false, environment: String = "development", url: URL? = nil) throws {
        let schema = Schema([StoredLibraryAcquisition.self, StoredLibrarySyncState.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration("UserLibrary", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let directory = try url?.deletingLastPathComponent() ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true).appendingPathComponent("UserLibrary", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = ModelConfiguration("UserLibrary", schema: schema,
                                        url: url ?? directory.appendingPathComponent("\(environment).sqlite"), cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container); context.autosaveEnabled = false
    }

    func rows(account: String) throws -> [StoredLibraryAcquisition] {
        try context.fetch(FetchDescriptor(predicate: #Predicate<StoredLibraryAcquisition> { $0.account == account }))
    }
    func events(account: String) throws -> [(LibraryAcquisition, Bool)] {
        try rows(account: account).map { row in
            let event = try JSONDecoder().decode(LibraryAcquisition.self, from: row.payload)
            try event.validate()
            return (event, row.pending)
        }
    }
    func save(_ event: LibraryAcquisition, account: String, pending: Bool, systemFields: Data? = nil) throws {
        try event.validate()
        let payload = try JSONEncoder().encode(event)
        do {
            if let existing = try rows(account: account).first(where: { $0.eventID == event.id.uuidString }) {
                let previous = try JSONDecoder().decode(LibraryAcquisition.self, from: existing.payload)
                guard previous == event else { throw LibraryFailure.conflictingAcquisition }
                // A retry of a synced event must not turn it back into a pending upload.
                if !pending { existing.pending = false }
                if let systemFields { existing.systemFields = systemFields }
            } else { context.insert(StoredLibraryAcquisition(account: account, event: event, pending: pending, payload: payload, systemFields: systemFields)) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func remove(eventID: String, account: String) throws {
        do {
            for row in try rows(account: account) where row.eventID == eventID { context.delete(row) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func zoneDeleted(account: String) throws {
        do {
            for row in try rows(account: account) {
                if row.pending { row.systemFields = nil }
                else { context.delete(row) }
            }
            for row in try context.fetch(FetchDescriptor<StoredLibrarySyncState>()) where row.account == account { context.delete(row) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func syncState(account: String) throws -> Data? {
        try context.fetch(FetchDescriptor<StoredLibrarySyncState>()).first { $0.account == account }?.serialization
    }
    func saveSyncState(_ data: Data, account: String) throws {
        do {
            if let row = try context.fetch(FetchDescriptor<StoredLibrarySyncState>()).first(where: { $0.account == account }) { row.serialization = data }
            else { context.insert(StoredLibrarySyncState(account: account, serialization: data)) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
