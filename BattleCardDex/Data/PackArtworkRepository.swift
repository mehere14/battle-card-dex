import CloudKit
import Foundation

actor PackArtworkRepository {
    enum Resolution { case thumbnail, full }
    private let database: CKDatabase
    private let directory: URL
    private var memory: [String: Data] = [:]

    init(configuration: CloudCatalogConfiguration, container: CKContainer? = nil, directory: URL? = nil) {
        database = (container ?? CKContainer(identifier: configuration.containerIdentifier)).publicCloudDatabase
        self.directory = directory ?? Self.defaultDirectory()
    }

    func data(recordID: String, resolution: Resolution) async throws -> Data {
        let suffix = resolution == .thumbnail ? "thumb" : "full"
        let key = "\(recordID)-\(suffix)"
        if let value = memory[key] { return value }
        let destination = directory.appendingPathComponent(key).appendingPathExtension("png")
        if let value = try? Data(contentsOf: destination), !value.isEmpty {
            memory[key] = value
            return value
        }
        let field = resolution == .thumbnail ? "thumbnail" : "payload"
        let id = CKRecord.ID(recordName: recordID)
        let results = try await database.records(for: [id], desiredKeys: [field])
        guard case let .success(record)? = results[id], let value = record[field] as? Data, !value.isEmpty else {
            throw CatalogServiceError.notFound(recordID)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try value.write(to: destination, options: .atomic)
        memory[key] = value
        return value
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BattleCardDex/PackArtwork", isDirectory: true)
    }
}
