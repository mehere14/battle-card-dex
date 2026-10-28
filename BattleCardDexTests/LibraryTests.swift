import CloudKit
import Foundation
import Testing
import UIKit
@testable import Battle_Card_Dex

@MainActor
@Suite("User library persistence and scanning")
struct LibraryTests {
    private func card(_ id: String = "test-card") -> BattleCardDetail {
        BattleCardDetail(summary: BattleCardSummary(id: id, relatedCreatureIDs: [], name: "Test Card",
            setID: "test-set", setName: "Test Set", collectorNumber: "1", rarity: nil, types: [], hitPoints: nil,
            smallImageURL: nil, largeImageURL: nil), subtypes: [], rules: [], abilities: [], attacks: [],
            weaknesses: [], resistances: [], retreatCost: [], evolutionText: nil, artist: nil,
            flavorText: nil, regulationMark: nil, legalities: [:])
    }
    private func event(id: UUID = UUID(), source: LibrarySource = .scanned) -> LibraryAcquisition {
        LibraryAcquisition(id: id, source: source, acquiredAt: Date(timeIntervalSince1970: 1000),
            packSetID: source == .pulls ? "test-set" : nil,
            cards: source == .pulls ? (0..<10).map { card("card-\($0)") } : [card()])
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "library-tests-\(UUID().uuidString)")! }

    @Test func repeatAcquisitionIsIdempotent() throws {
        let store = try LibraryLocalStore(inMemory: true)
        let value = event()
        try store.save(value, account: "a", pending: true)
        try store.save(value, account: "a", pending: true)
        #expect(try store.events(account: "a").count == 1)
        try store.save(value, account: "a", pending: false)
        try store.save(value, account: "a", pending: true)
        #expect(try store.events(account: "a").first?.1 == false)
    }
    @Test func duplicatesGroupWithinTheirSource() {
        let scan = event()
        let nextScan = event()
        let pack = LibraryAcquisition(id: UUID(), source: .pulls, acquiredAt: scan.acquiredAt, packSetID: "test-set", cards: Array(repeating: card(), count: 10))
        let values = [(scan, true), (nextScan, false), (pack, false)]
        let scanned = LibraryCardEntry.grouped(values, source: .scanned)
        #expect(scanned.count == 1 && scanned[0].quantity == 2 && scanned[0].pendingSync)
        let pulls = LibraryCardEntry.grouped(values, source: .pulls)
        #expect(pulls.count == 1 && pulls[0].quantity == 10 && !pulls[0].pendingSync)
    }
    @Test func conflictingEventDoesNotOverwriteExistingCards() throws {
        let store = try LibraryLocalStore(inMemory: true), value = event()
        try store.save(value, account: "a", pending: true)
        let conflict = LibraryAcquisition(id: value.id, source: value.source, acquiredAt: value.acquiredAt, packSetID: nil, cards: [card("different")])
        #expect(throws: LibraryFailure.self) { try store.save(conflict, account: "a", pending: false) }
        #expect(try store.events(account: "a").first?.0 == value)
        #expect(try store.events(account: "a").first?.1 == true)
    }
    @Test func accountsAreIsolated() throws {
        let store = try LibraryLocalStore(inMemory: true)
        try store.save(event(), account: "a", pending: true)
        #expect(try store.events(account: "b").isEmpty)
        try store.saveSyncState(Data([1,2,3]), account: "a")
        #expect(try store.syncState(account: "b") == nil)
    }
    @Test func packIsOneDurableAcquisition() throws {
        let store = try LibraryLocalStore(inMemory: true), value = event(source: .pulls)
        try store.save(value, account: "a", pending: true)
        #expect(try store.events(account: "a").count == 1)
        #expect(try store.events(account: "a").first?.0.cards.count == 10)
        let invalid = LibraryAcquisition(id: UUID(), source: .pulls, acquiredAt: value.acquiredAt, packSetID: "test-set", cards: [card()])
        #expect(throws: LibraryFailure.self) { try store.save(invalid, account: "a", pending: true) }
        #expect(try store.events(account: "a").count == 1)
    }
    @Test func codecPreservesSnapshotAndRejectsWrongSchema() throws {
        let value = event(source: .pulls)
        let record = try LibraryRecordCodec.encode(value)
        #expect(try LibraryRecordCodec.decode(record) == value)
        let restored = try LibraryRecordCodec.encode(value, systemFields: LibraryRecordCodec.systemFields(record))
        #expect(try LibraryRecordCodec.decode(restored) == value)
        record["schemaVersion"] = NSNumber(value: 99)
        #expect(throws: LibraryFailure.self) { try LibraryRecordCodec.decode(record) }
    }
    @Test func retryRepositoryAddUsesFirstTimestamp() throws {
        let repository = LibraryRepository(inMemory: true, defaults: defaults()), id = UUID()
        try repository.addScannedCard(scanID: id, card: card(), acquiredAt: Date(timeIntervalSince1970: 1))
        try repository.addScannedCard(scanID: id, card: card(), acquiredAt: Date(timeIntervalSince1970: 2))
        #expect(repository.entries(for: .scanned).first?.quantity == 1)
        #expect(repository.acquisitions.first?.0.acquiredAt == Date(timeIntervalSince1970: 1))
    }
    @Test func diskRestartRetainsPendingUploadAndSyncState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite"), value = event()
        do {
            let store = try LibraryLocalStore(url: url)
            try store.save(value, account: "a", pending: true)
            try store.saveSyncState(Data([4,5]), account: "a")
        }
        let reopened = try LibraryLocalStore(url: url)
        #expect(try reopened.events(account: "a").first?.0 == value)
        #expect(try reopened.events(account: "a").first?.1 == true)
        #expect(try reopened.syncState(account: "a") == Data([4,5]))
    }
    @Test func separateDeviceEventsMergeWithoutLosingCopies() throws {
        let store = try LibraryLocalStore(inMemory: true), first = event(), second = event()
        try store.save(first, account: "a", pending: true)
        try store.save(second, account: "a", pending: false)
        try store.save(first, account: "a", pending: false)
        #expect(LibraryCardEntry.grouped(try store.events(account: "a"), source: .scanned).first?.quantity == 2)
    }
    @Test func uniqueMatchRequiresManualAddAndPreventsRepeatSave() async throws {
        let repository = LibraryRepository(inMemory: true, defaults: defaults())
        let model = CardScannerModel(library: repository, recognizer: StubRecognition(cards: [card()]), defaults: defaults())
        model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test")
        await model.waitForRecognition()
        #expect(model.phase == .found(card()))
        #expect(repository.acquisitions.isEmpty)
        model.add(); model.add()
        #expect(model.phase == .added(card()))
        #expect(repository.entries(for: .scanned).first?.quantity == 1)
    }
    @Test func autoAddSavesCurrentAndFutureScans() async {
        let repository = LibraryRepository(inMemory: true, defaults: defaults()), prefs = defaults()
        let model = CardScannerModel(library: repository, recognizer: StubRecognition(cards: [card()]), defaults: prefs)
        model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test"); await model.waitForRecognition()
        model.setAutoAdd(true)
        #expect(model.phase == .added(card()))
        model.reset(); model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test"); await model.waitForRecognition()
        #expect(model.phase == .added(card()))
        #expect(repository.entries(for: .scanned).first?.quantity == 2)
        model.setAutoAdd(false)
        #expect(!CardScannerModel(library: repository, recognizer: StubRecognition(cards: []), defaults: prefs).autoAdd)
    }
    @Test func ambiguousMatchWaitsForArtworkChoiceEvenWithAutoAdd() async {
        let repository = LibraryRepository(inMemory: true, defaults: defaults())
        let matches = [card(), card("other")]
        let model = CardScannerModel(library: repository, recognizer: StubRecognition(cards: matches), defaults: defaults())
        model.setAutoAdd(true); model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test"); await model.waitForRecognition()
        #expect(model.phase == .choosing(matches))
        #expect(repository.acquisitions.isEmpty)
        model.choose(card("not-a-match")); #expect(repository.acquisitions.isEmpty)
        model.choose(matches[1]); #expect(repository.entries(for: .scanned).first?.card.id == "other")
    }
    @Test func scannerErrorDetailsIncludeUnderlyingCause() {
        let cause = NSError(domain: "Network", code: -1009, userInfo: [NSLocalizedDescriptionKey: "Offline"])
        let error = NSError(domain: "Recognition", code: 403, userInfo: [NSLocalizedDescriptionKey: "Request rejected", NSUnderlyingErrorKey: cause])
        let details = CardScannerModel.describeError(error)
        #expect(details.contains("Request rejected"))
        #expect(details.contains("Recognition · Code: 403"))
        #expect(details.contains("Offline"))
        #expect(details.contains("Network · Code: -1009"))
    }

    @Test func noMatchAndFailureAreRetryable() async {
        let repository = LibraryRepository(inMemory: true, defaults: defaults())
        for failing in [false, true] {
            let model = CardScannerModel(library: repository, recognizer: StubRecognition(cards: [], fails: failing), defaults: defaults())
            model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test"); await model.waitForRecognition()
            if case .failed = model.phase {} else { Issue.record("Expected a retryable failure") }
            #expect((model.errorDetails != nil) == failing)
            model.reset(); #expect(model.phase == .starting && model.photo == nil && model.errorDetails == nil)
            #expect(repository.acquisitions.isEmpty)
        }
    }
    @Test func saveFailureRetainsMatchAndRetryAddsOnlyOnce() async {
        let repository = LibraryRepository(inMemory: true, defaults: defaults())
        repository.selectFixtureAccount(nil)
        let model = CardScannerModel(library: repository, recognizer: StubRecognition(cards: [card()]), defaults: defaults())
        model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test"); await model.waitForRecognition()
        model.add()
        if case .saveFailed(let match, _) = model.phase { #expect(match == card()) }
        else { Issue.record("Expected failed save with retained card") }
        repository.selectFixtureAccount("a"); model.add(); model.add()
        #expect(repository.entries(for: .scanned).first?.quantity == 1)
        repository.selectFixtureAccount("b"); #expect(repository.acquisitions.isEmpty)
        repository.selectFixtureAccount("a"); #expect(repository.entries(for: .scanned).first?.quantity == 1)
    }
    @Test func deletingCloudZoneRetainsOnlyUnsyncedAcquisitions() throws {
        let store = try LibraryLocalStore(inMemory: true), pending = event(), synced = event()
        try store.save(pending, account: "a", pending: true)
        try store.save(synced, account: "a", pending: false)
        try store.zoneDeleted(account: "a")
        #expect(try store.events(account: "a").count == 1)
        #expect(try store.events(account: "a").first?.0.id == pending.id)
    }
    @Test func backgroundIgnoresLateRecognitionResults() async {
        let repository = LibraryRepository(inMemory: true, defaults: defaults())
        let model = CardScannerModel(library: repository, recognizer: StubRecognition(cards: [card()], delayed: true), defaults: defaults())
        model.setAutoAdd(true); model.cameraEvent(.ready); model.capture(); model.captured(UIImage(), text: "test")
        await Task.yield(); model.backgrounded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(repository.acquisitions.isEmpty)
        if case .failed = model.phase {} else { Issue.record("Expected interrupted scan") }
    }
}

@MainActor
private struct StubRecognition: CardRecognizing {
    let cards: [BattleCardDetail]
    var fails = false
    var delayed = false
    func recognize(text: String) async throws -> [BattleCardDetail] {
        if delayed { try? await Task.sleep(for: .milliseconds(30)) }
        if fails { throw ScannerFailure.message("test failure") }
        return cards
    }
}
