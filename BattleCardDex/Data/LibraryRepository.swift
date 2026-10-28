import CloudKit
import Combine
import Foundation

@MainActor
final class LibraryRepository: ObservableObject, CKSyncEngineDelegate {
    @Published private(set) var acquisitions: [(LibraryAcquisition, Bool)] = []
    @Published private(set) var account: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isSyncing = false
    @Published private(set) var syncError: String?
    @Published private(set) var storageError: String?
    var canSave: Bool { account != nil && store != nil && storageError == nil }
    var pendingCount: Int { acquisitions.filter(\.1).count }
    private let store: LibraryLocalStore?
    private let container: CKContainer?
    private let defaults: UserDefaults
    private let accountDefaultsKey: String
    private var engine: CKSyncEngine?
    private var accountObserver: AnyCancellable?
    private var refreshingAccount = false
    private var syncing = false
    private var syncPersistenceFailed = false
    private var accountGeneration = UUID()
    private let simulated: Bool

    init(configuration: AppConfiguration? = nil, inMemory: Bool = false,
         store: LibraryLocalStore? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = configuration ?? AppConfiguration.current
        simulated = inMemory || configuration.cloudCatalog.service == .fake
        let environment = configuration.environment.rawValue
        accountDefaultsKey = "library.\(environment).lastAccount"
        container = simulated ? nil : CKContainer(identifier: configuration.cloudCatalog.containerIdentifier)
        do { self.store = try store ?? LibraryLocalStore(inMemory: simulated, environment: environment) }
        catch { self.store = nil; storageError = LibraryFailure.storageUnavailable.localizedDescription }
        if simulated { account = "fixture-account"; isLoading = false; reload() }
        else {
            accountObserver = NotificationCenter.default.publisher(for: .CKAccountChanged).sink { [weak self] _ in
                Task { @MainActor in await self?.accountChanged() }
            }
        }
    }

    func entries(for source: LibrarySource) -> [LibraryCardEntry] { LibraryCardEntry.grouped(acquisitions, source: source) }
    func addScannedCard(scanID: UUID, card: BattleCardDetail, acquiredAt: Date = Date()) throws {
        try add(LibraryAcquisition(id: scanID, source: .scanned, acquiredAt: acquiredAt, packSetID: nil, cards: [card]))
    }
    func addOpenedPack(openingID: UUID, packID: String, cards: [BattleCardDetail], acquiredAt: Date = Date()) throws {
        try add(LibraryAcquisition(id: openingID, source: .pulls, acquiredAt: acquiredAt, packSetID: packID, cards: cards))
    }
    private func add(_ event: LibraryAcquisition) throws {
        guard let account else { throw LibraryFailure.signInRequired }
        guard let store else { throw LibraryFailure.storageUnavailable }
        // The timestamp of the first commit remains authoritative on repeated calls.
        if let previous = try store.events(account: account).first(where: { $0.0.id == event.id })?.0 {
            guard previous.source == event.source, previous.cards == event.cards, previous.packSetID == event.packSetID else {
                throw LibraryFailure.conflictingAcquisition
            }
            return
        }
        try store.save(event, account: account, pending: !simulated)
        reload()
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(LibraryRecordCodec.recordID(event.id.uuidString))])
        // A durable pending flag exists even if the process exits before CKSyncEngine queues it.
    }

#if DEBUG
    func selectFixtureAccount(_ key: String?) {
        guard simulated else { return }
        account = key; reload()
    }
#endif

    func start() async {
        guard !simulated, !refreshingAccount, let container else { return }
        refreshingAccount = true
        let generation = accountGeneration
        defer { refreshingAccount = false; isLoading = false }
        do {
            let status = try await container.accountStatus()
            guard generation == accountGeneration else { return }
            guard status == .available else {
                await deactivateAccount()
                syncError = status == .noAccount ? "Sign in to iCloud in Settings to save cards." : "iCloud is unavailable. Please check your account in Settings."
                return
            }
            let user = try await container.userRecordID()
            guard generation == accountGeneration else { return }
            await activateAccount(user.recordName, generation: generation)
        } catch {
            guard generation == accountGeneration else { return }
            // Permit offline use only for an account already identified on this installation.
            if account == nil, let cached = defaults.string(forKey: accountDefaultsKey) { account = cached; reload() }
            syncError = "iCloud is temporarily unavailable. Saved cards will sync when it reconnects."
        }
    }
    private func activateAccount(_ key: String, generation: UUID) async {
        guard generation == accountGeneration else { return }
        if account != key || engine == nil {
            let oldEngine = engine; engine = nil
            await oldEngine?.cancelOperations()
            guard generation == accountGeneration else { return }
            account = key; defaults.set(key, forKey: accountDefaultsKey); reload()
            guard let store, let container else { return }
            do {
                let serialization = try store.syncState(account: key).map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
                let newEngine = CKSyncEngine(.init(database: container.privateCloudDatabase, stateSerialization: serialization, delegate: self))
                engine = newEngine
                newEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: LibraryRecordCodec.zoneID))])
                let pending = try store.rows(account: key).filter(\.pending).map { CKSyncEngine.PendingRecordZoneChange.saveRecord(LibraryRecordCodec.recordID($0.eventID)) }
                newEngine.state.add(pendingRecordZoneChanges: pending)
                syncError = nil
            } catch { syncError = "Library sync couldn’t start. Your local cards are safe. Tap Retry Sync." }
        }
    }
    private func deactivateAccount() async {
        let old = engine; engine = nil; account = nil; acquisitions = []
        defaults.removeObject(forKey: accountDefaultsKey)
        await old?.cancelOperations()
    }
    private func accountChanged() async {
        accountGeneration = UUID()
        // Hide old-account data before awaiting network calls or cancellation.
        await deactivateAccount()
        refreshingAccount = false
        await start()
    }
    func retrySync() async {
        guard !syncing else { return }
        syncing = true; defer { syncing = false }
        if syncPersistenceFailed {
            let previous = engine; engine = nil
            await previous?.cancelOperations()
            syncPersistenceFailed = false
        }
        await start()
        guard let engine, let account, let store else { return }
        do {
            let pending = try store.rows(account: account).filter(\.pending).map { CKSyncEngine.PendingRecordZoneChange.saveRecord(LibraryRecordCodec.recordID($0.eventID)) }
            engine.state.add(pendingRecordZoneChanges: pending)
            syncError = nil
            try await engine.fetchChanges()
            guard engine === self.engine, account == self.account else { return }
            try await engine.sendChanges()
        } catch { syncError = "iCloud couldn’t finish syncing. Your cards are saved on this device. Try again later." }
    }
    private func reload() {
        guard let account, let store else { acquisitions = []; return }
        do { acquisitions = try store.events(account: account); storageError = nil }
        catch { storageError = "Your saved library couldn’t be read. Please restart the app." }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine, let account, let store else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                if !syncPersistenceFailed { try store.saveSyncState(JSONEncoder().encode(update.stateSerialization), account: account) }
            case .accountChange(let change):
                switch change.changeType {
                case .signIn(let user):
                    if user.recordName != account { await accountChanged() }
                case .signOut, .switchAccounts: await accountChanged()
                @unknown default: await accountChanged()
                }
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == LibraryRecordCodec.zoneID }) {
                    try store.zoneDeleted(account: account)
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: LibraryRecordCodec.zoneID))])
                    reload()
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications where modification.record.recordType == LibraryRecordCodec.recordType {
                    let event = try LibraryRecordCodec.decode(modification.record)
                    try store.save(event, account: account, pending: false, systemFields: LibraryRecordCodec.systemFields(modification.record))
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(modification.record.recordID)])
                }
                for deletion in changes.deletions where deletion.recordID.zoneID == LibraryRecordCodec.zoneID {
                    try store.remove(eventID: deletion.recordID.recordName, account: account)
                }
                reload()
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    try store.save(LibraryRecordCodec.decode(record), account: account, pending: false, systemFields: LibraryRecordCodec.systemFields(record))
                }
                for failure in changes.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged,
                       let server = failure.error.serverRecord {
                        // An immutable event already on the server is acknowledged only if identical.
                        try store.save(LibraryRecordCodec.decode(server), account: account, pending: false, systemFields: LibraryRecordCodec.systemFields(server))
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    } else if failure.error.code == .zoneNotFound {
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: LibraryRecordCodec.zoneID))])
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    } else {
                        syncError = failure.error.code == .quotaExceeded ? "Your iCloud storage is full. Cards are saved on this device." : "Some cards are waiting to sync. Your local library is safe."
                    }
                }
                reload()
            case .sentDatabaseChanges(let changes):
                if !changes.failedZoneSaves.isEmpty { syncError = "iCloud library setup couldn’t finish. Tap Retry Sync." }
            case .didFetchRecordZoneChanges(let changes):
                if changes.error != nil { syncError = "Library updates couldn’t be downloaded. Tap Retry Sync." }
            case .willFetchChanges, .willSendChanges: isSyncing = true
            case .didFetchChanges, .didSendChanges: isSyncing = false
            default: break
            }
        } catch { syncPersistenceFailed = true; syncError = error.localizedDescription; reload() }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, let account, let store else { return nil }
        do {
            let rows = try store.rows(account: account).filter { $0.pending && context.options.scope.contains(LibraryRecordCodec.recordID($0.eventID)) }
            let records = try rows.prefix(100).map { row in
                try LibraryRecordCodec.encode(JSONDecoder().decode(LibraryAcquisition.self, from: row.payload), systemFields: row.systemFields)
            }
            return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
        } catch { syncError = error.localizedDescription; return nil }
    }
}
