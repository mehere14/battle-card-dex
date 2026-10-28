import CryptoKit
import Foundation

/// Copies the published public catalog, including query fields, rather than
/// importing an iPad cache or rebuilding a potentially different upstream version.
public struct CatalogProductionPromotion: Sendable {
    private let additionalSetIDs: Set<String>
    public init(additionalSetIDs: Set<String> = []) { self.additionalSetIDs = additionalSetIDs }

    private static let common = ["payload", "contentHash", "schemaVersion", "sourceIdentifier", "loaderTimestamp"]
    static let fieldsByType: [String: [String]] = [
        "CatalogManifest": common + ["sourceTimestamp", "revision", "publishedAt", "creatureCount", "evolutionCount", "cardCount"],
        "CreatureCatalogRecord": common + ["normalizedName", "displayName", "types", "generation"],
        "EvolutionCatalogRecord": common + ["memberIdentifiers"],
        "CardCatalogRecord": common + ["normalizedName", "displayName", "setIdentifier", "collectorNumber", "types", "relatedCreatureIdentifiers"],
        "CardSetIndexRecord": common + ["setIdentifier", "displayName", "revision"],
        "PackArtworkRecord": common + ["setIdentifier", "displayName", "releaseYear", "thumbnail"],
    ]

    public func readSource(service: any LoaderCloudKitQuerying) async throws -> [LoaderRecord] {
        var records: [LoaderRecord] = []
        let manifestResult = try await service.lookupRecords(identifiers: ["catalog-manifest-v1"], desiredKeys: Self.fieldsByType["CatalogManifest"]!)
        guard manifestResult.records.count == 1 else { throw invalid("manifest") }
        let manifestRecord = try Self.copyRecord(manifestResult.records[0])
        records.append(manifestRecord)
        let envelope = try JSONDecoder().decode(Envelope.self, from: manifestRecord.payload)
        let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        guard manifest.creatureCount > 0 else { throw invalid("manifest-counts") }
        for (type, prefix) in [("CreatureCatalogRecord", "catalog-creature-"), ("EvolutionCatalogRecord", "catalog-evolution-")] {
            var names = Set(manifest.contentHashes.keys.filter { $0.hasPrefix(prefix) })
            if type == "CreatureCatalogRecord" { names.formUnion((1...manifest.creatureCount).map { prefix + String($0) }) }
            Self.progress("Reading Development \(type): \(names.count) IDs…")
            let result = try await service.lookupRecords(identifiers: Array(names), desiredKeys: Self.fieldsByType[type]!)
            guard result.records.count == names.count else { throw invalid("missing-source-reference") }
            for record in result.records {
                guard record.recordType == type else { throw invalid("record-type") }
                records.append(try Self.copyRecord(record))
            }
        }
        Self.progress("Reading Development CardCatalogRecord…")
        let cards = try await service.queryRecords(recordType: "CardCatalogRecord", desiredKeys: Self.fieldsByType["CardCatalogRecord"]!)
        Self.progress("Read \(cards.records.count) CardCatalogRecord records")
        for record in cards.records {
            guard record.recordType == "CardCatalogRecord" else { throw invalid("record-type") }
            records.append(try Self.copyRecord(record))
        }
        let setIDs = additionalSetIDs.union(records.compactMap { record -> String? in
            guard record.recordType == "CardCatalogRecord", case let .string(id)? = record.fields["setIdentifier"] else { return nil }
            return id
        })
        for (type, prefix) in [("CardSetIndexRecord", "catalog-card-set-index-"), ("PackArtworkRecord", "catalog-pack-art-")] {
            Self.progress("Reading Development \(type) by ID…")
            let result = try await service.lookupRecords(identifiers: setIDs.map { prefix + $0.lowercased() }, desiredKeys: Self.fieldsByType[type]!)
            guard !result.records.isEmpty else { throw invalid("empty-\(type)") }
            for record in result.records {
                guard record.recordType == type else { throw invalid("record-type") }
                records.append(try Self.copyRecord(record))
            }
        }
        try validate(records)
        return records.sorted { $0.identifier < $1.identifier }
    }

    static func copyRecord(_ source: CloudKitQueriedRecord) throws -> LoaderRecord {
        guard let allowed = fieldsByType[source.recordType], source.recordName.hasPrefix("catalog-"),
              case let .data(payload)? = source.fields["payload"],
              case let .string(hash)? = source.fields["contentHash"], hash == digest(payload),
              case .integer(1)? = source.fields["schemaVersion"] else {
            throw CatalogValidationError.invalidCatalog("promotion-invalid-record-\(source.recordName)")
        }
        var fields: [String: LoaderRecordField] = [:]
        for (key, value) in source.fields where key != "payload" && key != "contentHash" {
            guard allowed.contains(key) else { throw CatalogValidationError.invalidCatalog("promotion-unknown-field") }
            switch value {
            case let .string(value): fields[key] = .string(value)
            case let .integer(value): fields[key] = .integer(value)
            case let .data(value): fields[key] = .data(value)
            case let .strings(value): fields[key] = .strings(value)
            case let .integers(value): fields[key] = .integers(value)
            case let .date(value): fields[key] = .date(value)
            case .unknown: throw CatalogValidationError.invalidCatalog("promotion-unsupported-field-\(key)")
            }
        }
        return LoaderRecord(identifier: source.recordName, recordType: source.recordType, contentHash: hash,
            payload: payload, fields: fields, isManifest: source.recordType == "CatalogManifest")
    }

    func validate(_ records: [LoaderRecord]) throws {
        guard Set(records.map(\.identifier)).count == records.count else { throw invalid("duplicate-record") }
        let manifests = records.filter(\.isManifest)
        guard manifests.count == 1, let manifest = manifests.first,
              manifest.identifier == "catalog-manifest-v1" else { throw invalid("manifest") }
        for record in records {
            guard Self.fieldsByType[record.recordType] != nil,
                  record.contentHash == Self.digest(record.payload) else { throw invalid("payload-hash") }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: manifest.payload)
        guard envelope.schemaVersion == 1, envelope.kind == "manifest" else { throw invalid("manifest-envelope") }
        let value = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
        let counts = Dictionary(grouping: records, by: \.recordType).mapValues(\.count)
        guard counts["CreatureCatalogRecord"] == value.creatureCount,
              counts["EvolutionCatalogRecord"] == value.evolutionCount,
              counts["CardCatalogRecord"] == value.cardCount,
              value.creatureCount > 0, value.cardCount > 0 else { throw invalid("manifest-counts") }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.identifier, $0) })
        guard value.contentHashes.allSatisfy({ byID[$0.key]?.contentHash == $0.value }) else { throw invalid("manifest-hashes") }
        // Prevent propagating the dangling relationships seen in the Release logs.
        for record in records where record.recordType == "CreatureCatalogRecord" {
            let envelope = try JSONDecoder().decode(Envelope.self, from: record.payload)
            let creature = try JSONDecoder().decode(CreatureReferences.self, from: envelope.payload)
            for id in creature.cardRecordIdentifiers ?? [] {
                guard byID[id]?.recordType == "CardCatalogRecord" else { throw invalid("missing-card-reference") }
            }
            if let id = creature.evolutionRecordIdentifier {
                guard byID[id]?.recordType == "EvolutionCatalogRecord" else { throw invalid("missing-evolution-reference") }
            }
        }
    }

    public func run(records: [LoaderRecord], destination: any LoaderCloudKitService, apply: Bool) async throws -> [String: Int] {
        try validate(records)
        var counts = Dictionary(grouping: records, by: \.recordType).mapValues(\.count)
        counts["written"] = 0; counts["changedOrMissing"] = 0; counts["unchanged"] = 0
        // Publish the manifest last, after every referenced data record and index.
        let ordered = records.filter { !$0.isManifest }.sorted { $0.identifier < $1.identifier } + records.filter(\.isManifest)
        // Small artwork batches keep CloudKit request bodies below service limits.
        for type in Self.fieldsByType.keys.sorted().filter({ $0 != "CatalogManifest" }) + ["CatalogManifest"] {
            let group = ordered.filter { $0.recordType == type }
            Self.progress("\(apply ? "Publishing" : "Comparing") Production \(type): \(group.count) records")
            let batchSize = type == "PackArtworkRecord" ? 2 : 100
            let batches = stride(from: 0, to: group.count, by: batchSize).map {
                Array(group[$0..<min($0 + batchSize, group.count)])
            }
            let totals = try await withThrowingTaskGroup(of: BatchCounts.self) { tasks in
                var next = 0
                var completed = 0
                var totals = BatchCounts()
                func enqueue(_ index: Int) {
                    let batch = batches[index]
                    tasks.addTask {
                        try Task.checkCancellation()
                        let hashes = try await destination.existingHashes(for: batch.map(\.identifier))
                        let changed = batch.filter { hashes[$0.identifier] != $0.contentHash }
                        if apply, !changed.isEmpty {
                            try await destination.save(changed)
                            let verified = try await destination.existingHashes(for: changed.map(\.identifier))
                            guard changed.allSatisfy({ verified[$0.identifier] == $0.contentHash }) else {
                                throw CatalogValidationError.invalidCatalog("promotion-destination-verification")
                            }
                        }
                        return BatchCounts(changed: changed.count, unchanged: batch.count - changed.count,
                                           written: apply ? changed.count : 0)
                    }
                }
                while next < min(3, batches.count) { enqueue(next); next += 1 }
                while let result = try await tasks.next() {
                    totals.changed += result.changed; totals.unchanged += result.unchanged; totals.written += result.written
                    completed += 1
                    if completed % 10 == 0 || completed == batches.count {
                        Self.progress("\(type): verified \(completed)/\(batches.count) batches")
                    }
                    if next < batches.count { enqueue(next); next += 1 }
                }
                return totals
            }
            counts["changedOrMissing", default: 0] += totals.changed
            counts["unchanged", default: 0] += totals.unchanged
            counts["written", default: 0] += totals.written
        }
        return counts
    }

    private struct BatchCounts: Sendable { var changed = 0; var unchanged = 0; var written = 0 }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func invalid(_ reason: String) -> CatalogValidationError { .invalidCatalog("promotion-" + reason) }
    private struct Envelope: Decodable { let schemaVersion: Int; let kind: String; let payload: Data }
    private struct Manifest: Decodable { let creatureCount: Int; let evolutionCount: Int; let cardCount: Int; let contentHashes: [String: String] }
    private struct CreatureReferences: Decodable { let cardRecordIdentifiers: [String]?; let evolutionRecordIdentifier: String? }
}
