import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PackArtworkRecordBuilder {
    public static func records(manifestURL: URL) throws -> [LoaderRecord] {
        let manifest = try JSONDecoder().decode(ArtworkManifest.self, from: Data(contentsOf: manifestURL))
        let root = manifestURL.deletingLastPathComponent()
        return try manifest.sets.compactMap { setID, set in
            guard set.status == "processed", let variant = set.variants.first else { return nil }
            let imageData = try Data(contentsOf: root.appendingPathComponent(variant.path))
            guard imageData.count <= 900 * 1_024 else { throw CatalogPipelineError.invalidCatalog("pack-art-size-\(setID)") }
            let thumbnail = try thumbnailData(from: imageData)
            let year = releaseYear(date: set.forumDate, setID: setID)
            let name = set.cachedNames.first ?? set.forumName ?? setID
            let hash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            return LoaderRecord(
                identifier: "catalog-pack-art-\(setID.lowercased())", recordType: "PackArtworkRecord",
                contentHash: hash, payload: imageData,
                fields: ["schemaVersion": .integer(1), "sourceIdentifier": .string(setID),
                         "setIdentifier": .string(setID), "displayName": .string(name),
                         "releaseYear": .integer(Int64(year)), "thumbnail": .data(thumbnail)]
            )
        }.sorted { $0.identifier < $1.identifier }
    }

    private static func thumbnailData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { throw CatalogPipelineError.invalidProviderPayload("pack-art-image") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CatalogPipelineError.invalidProviderPayload("pack-art-thumbnail")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CatalogPipelineError.invalidProviderPayload("pack-art-thumbnail") }
        return output as Data
    }

    private static func releaseYear(date: String?, setID: String) -> Int {
        if let date, let match = date.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) { return Int(date[match]) ?? 0 }
        if setID == "swsh7" { return 2021 }
        if setID.hasPrefix("pop"), let number = Int(setID.dropFirst(3)) { return 2003 + number }
        return 0
    }
}

private struct ArtworkManifest: Decodable { let sets: [String: ArtworkSet] }
private struct ArtworkSet: Decodable {
    let cachedNames: [String]
    let forumDate: String?
    let forumName: String?
    let status: String
    let variants: [ArtworkVariant]
    enum CodingKeys: String, CodingKey {
        case status, variants
        case cachedNames = "cached_names"
        case forumDate = "forum_date"
        case forumName = "forum_name"
    }
}
private struct ArtworkVariant: Decodable { let path: String }
