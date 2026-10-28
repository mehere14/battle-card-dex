#if DEBUG
import CloudKit
import XCTest
@testable import Battle_Card_Dex

final class LibraryCloudKitIntegrationTests: XCTestCase {
    @MainActor
    func testDevelopmentPrivateAcquisitionRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["BATTLE_CARD_DEX_RUN_LIBRARY_CLOUD_TEST"] == "1" else {
            throw XCTSkip("Opt-in only: use the Library Cloud Verification scheme on a physical device.")
        }
        let configuration = AppConfiguration.current.cloudCatalog
        let namespace = try DevelopmentCloudRecordNamespace(service: configuration.service, runIdentifier: UUID().uuidString)
        let container = CKContainer(identifier: configuration.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw XCTSkip("The physical device must be signed in to iCloud.") }
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: namespace.recordName(for: "library-zone"), ownerName: CKCurrentUserDefaultName)
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        do {
            let card = try XCTUnwrap(CatalogViewModel.preview().cards.first)
            let event = LibraryAcquisition(id: UUID(), source: .scanned, acquiredAt: Date(), packSetID: nil, cards: [card])
            let encoded = try LibraryRecordCodec.encode(event)
            let isolated = CKRecord(recordType: LibraryRecordCodec.recordType, recordID: CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID))
            for key in encoded.allKeys() { isolated[key] = encoded[key] }
            _ = try await database.save(isolated)
            let fetched = try await database.record(for: isolated.recordID)
            let payload = try XCTUnwrap(fetched["payload"] as? Data)
            let decoded = try JSONDecoder().decode(LibraryAcquisition.self, from: payload)
            try decoded.validate()
            XCTAssertEqual(decoded, event)
            XCTAssertEqual(fetched["source"] as? String, "scanned")
            XCTAssertEqual((fetched["schemaVersion"] as? NSNumber)?.intValue, LibraryAcquisition.schemaVersion)
            XCTAssertEqual(fetched["acquiredAt"] as? Date, event.acquiredAt)
            // A second create with the same ID cannot produce a second acquisition.
            let duplicate = CKRecord(recordType: LibraryRecordCodec.recordType, recordID: isolated.recordID)
            for key in encoded.allKeys() { duplicate[key] = encoded[key] }
            do { _ = try await database.save(duplicate); XCTFail("Duplicate creation unexpectedly succeeded") }
            catch let error as CKError { XCTAssertEqual(error.code, .serverRecordChanged) }
            _ = try await database.deleteRecordZone(withID: zoneID)
        } catch {
            _ = try? await database.deleteRecordZone(withID: zoneID)
            throw error
        }
    }
}
#endif
