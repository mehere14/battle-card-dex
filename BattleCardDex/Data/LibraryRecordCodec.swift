import CloudKit
import Foundation

nonisolated enum LibraryRecordCodec {
    static let recordType = "LibraryAcquisition"
    static let zoneName = "UserLibrary"
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }
    static func recordID(_ eventID: String) -> CKRecord.ID { CKRecord.ID(recordName: eventID, zoneID: zoneID) }

    static func encode(_ event: LibraryAcquisition, systemFields: Data? = nil) throws -> CKRecord {
        try event.validate()
        let record: CKRecord
        if let systemFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            decoder.requiresSecureCoding = true
            guard let restored = CKRecord(coder: decoder) else { throw LibraryFailure.invalidAcquisition }
            decoder.finishDecoding(); record = restored
        } else { record = CKRecord(recordType: recordType, recordID: recordID(event.id.uuidString)) }
        guard record.recordType == recordType, record.recordID == recordID(event.id.uuidString) else { throw LibraryFailure.invalidAcquisition }
        record["schemaVersion"] = NSNumber(value: LibraryAcquisition.schemaVersion)
        record["source"] = event.source.rawValue as NSString
        record["acquiredAt"] = event.acquiredAt as NSDate
        record["packSetID"] = event.packSetID as NSString?
        record["payload"] = try JSONEncoder().encode(event) as NSData
        return record
    }
    static func decode(_ record: CKRecord) throws -> LibraryAcquisition {
        guard record.recordType == recordType, record.recordID.zoneID == zoneID,
              let version = record["schemaVersion"] as? NSNumber else { throw LibraryFailure.invalidAcquisition }
        guard version.intValue == LibraryAcquisition.schemaVersion else { throw LibraryFailure.unsupportedSchema }
        guard let data = record["payload"] as? Data else { throw LibraryFailure.invalidAcquisition }
        let event = try JSONDecoder().decode(LibraryAcquisition.self, from: data)
        try event.validate()
        guard event.id.uuidString == record.recordID.recordName,
              record["source"] as? String == event.source.rawValue,
              record["acquiredAt"] as? Date == event.acquiredAt,
              record["packSetID"] as? String == event.packSetID else { throw LibraryFailure.invalidAcquisition }
        return event
    }
    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding(); return coder.encodedData
    }
}
