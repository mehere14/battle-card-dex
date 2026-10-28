import CryptoKit
import Foundation
import Testing
@testable import BattleCardDexLoaderCore

private func promotionHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func promotionFixtures(dangling: Bool = false, cardCount: Int = 1) throws -> [LoaderRecord] {
    func record(_ id: String, _ type: String, _ object: [String: Any], kind: String? = nil) throws -> LoaderRecord {
        let inner = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let payload = try kind.map { try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": $0, "payload": inner.base64EncodedString()], options: [.sortedKeys]) } ?? inner
        return LoaderRecord(identifier: id, recordType: type, contentHash: promotionHash(payload), payload: payload,
            fields: ["schemaVersion": .integer(1)], isManifest: type == "CatalogManifest")
    }
    var records = try [
        record("catalog-creature-1", "CreatureCatalogRecord", ["cardRecordIdentifiers": [dangling ? "missing-card" : "catalog-card-one"], "evolutionRecordIdentifier": "catalog-evolution-1"], kind: "creature"),
        record("catalog-evolution-1", "EvolutionCatalogRecord", [:], kind: "evolution"),
        record("catalog-card-one", "CardCatalogRecord", [:], kind: "card"),
        record("catalog-card-set-index-me2", "CardSetIndexRecord", [:]),
        record("catalog-pack-art-me2", "PackArtworkRecord", [:]),
    ]
    if cardCount > 1 {
        for index in 2...cardCount { records.append(try record("catalog-card-\(index)", "CardCatalogRecord", [:], kind: "card")) }
    }
    let manifest = try record("catalog-manifest-v1", "CatalogManifest", ["creatureCount": 1, "evolutionCount": 1, "cardCount": cardCount,
        "contentHashes": Dictionary(uniqueKeysWithValues: records.map { ($0.identifier, $0.contentHash) })], kind: "manifest")
    return records + [manifest]
}

private actor PromotionDestination: LoaderCloudKitService {
    var hashes: [String: String] = [:]
    var saved: [String] = []
    var failType: String?
    let delayed: Bool
    var activeSaves = 0
    var maximumSaves = 0
    init(failType: String? = nil, delayed: Bool = false) { self.failType = failType; self.delayed = delayed }
    func existingHashes(for identifiers: [String]) async throws -> [String: String] { hashes.filter { identifiers.contains($0.key) } }
    func save(_ records: [LoaderRecord]) async throws {
        activeSaves += 1; maximumSaves = max(maximumSaves, activeSaves)
        defer { activeSaves -= 1 }
        if delayed { try await Task.sleep(for: .milliseconds(15)) }
        if records.contains(where: { $0.recordType == failType }) { failType = nil; throw CloudKitWebServiceError.httpStatus(503) }
        for record in records { hashes[record.identifier] = record.contentHash; saved.append(record.identifier) }
    }
}

private actor PromotionTransport: LoaderTransport {
    var requests: [LoaderHTTPRequest] = []
    func send(_ request: LoaderHTTPRequest) async throws -> LoaderHTTPResponse {
        requests.append(request)
        return LoaderHTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"records":[]}"#.utf8))
    }
}
private struct PromotionSigner: CloudKitRequestSigning {
    func signedHeaders(body: Data, url: URL) throws -> [String: String] { [:] }
}

@Test func productionPromotionRequiresExplicitMode() throws {
    #expect(try LoaderCommand.parse(["promote-production", "--dry-run"]) == .promoteProduction(apply: false))
    #expect(try LoaderCommand.parse(["promote-production", "--apply"]) == .promoteProduction(apply: true))
    #expect(throws: LoaderCommandError.self) { try LoaderCommand.parse(["promote-production"]) }
    #expect(throws: CloudKitWebServiceError.unsafeConfiguration) {
        try CloudKitWebServiceConfiguration(containerIdentifier: "iCloud.com.example.catalog", environment: "production")
    }
    #expect(throws: CloudKitWebServiceError.unsafeConfiguration) {
        try CloudKitWebServiceConfiguration(containerIdentifier: "iCloud.com.example.catalog", environment: "production", database: "private", productionAccess: .publish)
    }
}

@Test func productionReadOnlyCannotMutate() async throws {
    let transport = PromotionTransport()
    let config = try CloudKitWebServiceConfiguration(containerIdentifier: "iCloud.com.example.catalog", environment: "production", productionAccess: .readOnly)
    let service = CloudKitWebService(configuration: config, transport: transport, signer: PromotionSigner())
    await #expect(throws: CloudKitWebServiceError.unsafeConfiguration) { try await service.save(promotionFixtures()) }
    #expect(await transport.requests.isEmpty)
}

@Test func productionPromotionDryRunManifestOrderAndRepeat() async throws {
    let records = try promotionFixtures()
    let destination = PromotionDestination()
    let promotion = CatalogProductionPromotion()
    let plan = try await promotion.run(records: records, destination: destination, apply: false)
    #expect(plan["changedOrMissing"] == records.count)
    #expect(await destination.saved.isEmpty)
    let applied = try await promotion.run(records: records, destination: destination, apply: true)
    #expect(applied["written"] == records.count)
    #expect(await destination.saved.last == "catalog-manifest-v1")
    let repeated = try await promotion.run(records: records, destination: destination, apply: true)
    #expect(repeated["written"] == 0)
    #expect(repeated["unchanged"] == records.count)
}

@Test func productionPromotionResumesFromRemoteHashesAfterFailure() async throws {
    let records = try promotionFixtures()
    let destination = PromotionDestination(failType: "EvolutionCatalogRecord")
    let promotion = CatalogProductionPromotion()
    await #expect(throws: CloudKitWebServiceError.httpStatus(503)) { try await promotion.run(records: records, destination: destination, apply: true) }
    #expect(await !destination.saved.contains("catalog-manifest-v1"))
    let result = try await promotion.run(records: records, destination: destination, apply: true)
    #expect(result["unchanged", default: 0] > 0)
    #expect(await destination.saved.count == records.count)
    #expect(await destination.saved.last == "catalog-manifest-v1")
}

@Test func productionPromotionRejectsDanglingReferencesBeforeWrites() async throws {
    let destination = PromotionDestination()
    await #expect(throws: CatalogValidationError.self) {
        try await CatalogProductionPromotion().run(records: promotionFixtures(dangling: true), destination: destination, apply: true)
    }
    #expect(await destination.saved.isEmpty)
}

@Test func promotionCopiesSearchFieldsAndTimestampsAndRejectsCorruption() throws {
    let payload = Data("payload".utf8)
    let fields: [String: CloudKitQueriedField] = ["payload": .data(payload), "contentHash": .string(promotionHash(payload)),
        "schemaVersion": .integer(1), "normalizedName": .string("duraludon"), "collectorNumber": .string("74"),
        "setIdentifier": .string("me2"), "loaderTimestamp": .date(Date(timeIntervalSince1970: 100))]
    let copied = try CatalogProductionPromotion.copyRecord(.init(recordName: "catalog-card-one", recordType: "CardCatalogRecord", fields: fields))
    #expect(copied.fields["normalizedName"] == .string("duraludon"))
    #expect(copied.fields["loaderTimestamp"] == .date(Date(timeIntervalSince1970: 100)))
    var corrupted = fields; corrupted["contentHash"] = .string("wrong")
    #expect(throws: CatalogValidationError.self) {
        try CatalogProductionPromotion.copyRecord(.init(recordName: "catalog-card-one", recordType: "CardCatalogRecord", fields: corrupted))
    }
}

@Test func promotionCredentialsAreSeparateCompleteAndRedacted() {
    let incomplete = LoaderSecrets(cloudKitKeyID: "source-key", cloudKitPrivateKeyPath: "/source.pem", productionKeyID: "production-key")
    #expect(incomplete.missingRequiredValues(for: .promoteProduction(apply: false)) == [.productionPrivateKeyPath])
    #expect(incomplete.missingRequiredValues(for: .syncAll).isEmpty)
    let complete = LoaderSecrets(cloudKitKeyID: "source-key", cloudKitPrivateKeyPath: "/source.pem",
        productionKeyID: "production-key", productionPrivateKeyPath: "/production.pem")
    #expect(complete.missingRequiredValues(for: .promoteProduction(apply: true)).isEmpty)
    #expect(SecretRedactor.redact("source-key production-key /source.pem /production.pem", secrets: complete) == "[REDACTED] [REDACTED] [REDACTED] [REDACTED]")
}

private struct PromotionSource: LoaderCloudKitQuerying {
    let records: [LoaderRecord]
    func queried(_ record: LoaderRecord) -> CloudKitQueriedRecord {
        var fields: [String: CloudKitQueriedField] = ["schemaVersion": .integer(1), "payload": .data(record.payload), "contentHash": .string(record.contentHash)]
        if record.recordType == "CardCatalogRecord" { fields["setIdentifier"] = .string("me2") }
        return .init(recordName: record.identifier, recordType: record.recordType, fields: fields)
    }
    func queryRecords(recordType: String, desiredKeys: [String]) async throws -> CloudKitQueryResult {
        guard !["CardSetIndexRecord", "PackArtworkRecord"].contains(recordType) else { throw CloudKitWebServiceError.invalidResponse }
        return .init(records: records.filter { $0.recordType == recordType }.map(queried), responseBytes: 0)
    }
    func lookupRecords(identifiers: [String], desiredKeys: [String]) async throws -> CloudKitQueryResult {
        .init(records: records.filter { identifiers.contains($0.identifier) }.map(queried), responseBytes: 0)
    }
}

@Test func promotionReadsUnqueryableIndexesByKnownIDs() async throws {
    let fixtures = try promotionFixtures()
    let records = try await CatalogProductionPromotion().readSource(service: PromotionSource(records: fixtures))
    #expect(Set(records.map(\.identifier)) == Set(fixtures.map(\.identifier)))
}

@Test func productionUploadUsesBoundedParallelBatchesAndKeepsManifestLast() async throws {
    let records = try promotionFixtures(cardCount: 350)
    let destination = PromotionDestination(delayed: true)
    let result = try await CatalogProductionPromotion().run(records: records, destination: destination, apply: true)
    #expect(result["written"] == records.count)
    #expect(await destination.maximumSaves == 3)
    #expect(await destination.saved.last == "catalog-manifest-v1")
}
