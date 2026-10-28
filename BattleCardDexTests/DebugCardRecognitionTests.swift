#if DEBUG
import Foundation
import Testing
@testable import Battle_Card_Dex

@Suite("Debug card scanner matching")
struct DebugCardRecognitionTests {
    private func card(number: String = "3", name: String = "Exploud", set: String = "ex9") -> BattleCardDetail {
        BattleCardDetail(summary: BattleCardSummary(id: "\(set)-\(number)", relatedCreatureIDs: [], name: name,
            setID: set, setName: "Emerald", collectorNumber: number, rarity: nil, types: [], hitPoints: nil,
            smallImageURL: nil, largeImageURL: nil), subtypes: [], rules: [], abilities: [], attacks: [],
            weaknesses: [], resistances: [], retreatCost: [], evolutionText: nil, artist: nil,
            flavorText: nil, regulationMark: nil, legalities: [:])
    }

    @Test func leadingZerosMatchButOtherCardsDoNot() {
        let identity = ScannedCardIdentity(name: "exploud", collectorNumber: "003", printedTotal: "106", setCode: nil, language: "English")
        #expect(identity.matches(card()))
        #expect(!identity.matches(card(number: "4")))
        #expect(!identity.matches(card(name: "Exploud ex")))
    }

    @Test func printedMechanicsCanMatchCatalogBaseNames() {
        for suffix in ["ex", "EX", "GX", "V", "VMAX", "VSTAR", "V-UNION", "LV.X", "BREAK", "Prime"] {
            let identity = ScannedCardIdentity(name: "Exploud \(suffix)", collectorNumber: "003", printedTotal: "106", setCode: nil, language: nil)
            #expect(identity.matches(card()))
            #expect(identity.matches(card(name: "Exploud \(suffix)")))
            #expect(!identity.matches(card(number: "4")))
            #expect(!identity.matches(card(name: "Exploud Other")))
            #expect(!identity.matches(card(set: "me4")))
        }
        #expect(ScannedCardIdentity.catalogLookupNames("  Charizard-EX  ") == ["charizard-ex", "charizard"])
        #expect(ScannedCardIdentity.catalogLookupNames("Eevee") == ["eevee"])
        #expect(ScannedCardIdentity.catalogLookupNames("Vulpix") == ["vulpix"])
        #expect(!ScannedCardIdentity(name: "Exploud VMAX", collectorNumber: "3", printedTotal: nil, setCode: nil, language: nil).matches(card(name: "Exploud V")))
    }

    @Test func printedDenominatorAndSetCodeDisambiguate() {
        #expect(!ScannedCardIdentity(name: "Exploud", collectorNumber: "3", printedTotal: "107", setCode: nil, language: nil).matches(card()))
        #expect(ScannedCardIdentity(name: "Exploud", collectorNumber: "3", printedTotal: nil, setCode: "EM", language: nil).matches(card()))
        #expect(!ScannedCardIdentity(name: "Exploud", collectorNumber: "3", printedTotal: nil, setCode: "XYZ", language: nil).matches(card()))
    }

    @Test func missingFieldsNeverSelectACard() throws {
        let missing = try JSONDecoder().decode(ScannedCardIdentity.self, from: Data(#"{"name":null,"collectorNumber":null,"printedTotal":null,"setCode":null,"language":null}"#.utf8))
        #expect(!missing.matches(card()))
    }

    @Test func kakunaTruncatedCodeIsRecoveredFromFooterEvidence() {
        let raw = ScannedCardIdentity(name: "Kakuna", collectorNumber: "002", printedTotal: "086", setCode: "CR", language: "EN")
        let kakuna = card(number: "2", name: "Kakuna", set: "me4")
        #expect(!raw.matches(kakuna))
        let resolved = raw.reconcilingSetCode(ocrText: "[WHOLE_CARD_OCR]\nKakuna\nCRI EN\n002/086\n[FOOTER_ORIGINAL_OCR]\nCRI EN")
        #expect(resolved.setCode == "CRI")
        #expect(resolved.matches(kakuna))
        #expect(raw.reconcilingSetCode(ocrText: "Kakuna\n002/086").setCode == "CR")
    }

    @Test func conflictingCodeEvidenceDoesNotOverrideIdentity() {
        let raw = ScannedCardIdentity(name: "Kakuna", collectorNumber: "002", printedTotal: "086", setCode: "CR", language: "EN")
        #expect(raw.reconcilingSetCode(ocrText: "CRI EN\nBLK EN").setCode == "CR")
        let wrong = ScannedCardIdentity(name: "Kakuna", collectorNumber: "002", printedTotal: "086", setCode: "BLK", language: "EN")
        #expect(wrong.reconcilingSetCode(ocrText: "CRI EN").setCode == "BLK")
    }

    @Test func diagnosticReportPreservesPartialAndCompleteExtraction() {
        var diagnostics = ScanRecognitionDiagnostics(ocrText: "Pikachu ex\n001/100")
        let partial = diagnostics.report(error: "Request failed")
        #expect(partial.contains("Pikachu ex\n001/100"))
        #expect(partial.contains("Request failed"))
        #expect(partial.contains("Unavailable: no response received."))
        diagnostics.geminiResponse = "SDK response metadata"
        diagnostics.geminiText = #"{"name":"Pikachu ex"}"#
        diagnostics.structuredIdentity = #"{"name":"Pikachu ex","collectorNumber":"001"}"#
        let complete = diagnostics.report(error: "No matching card")
        #expect(complete.contains(diagnostics.geminiResponse!))
        #expect(complete.contains(diagnostics.geminiText!))
        #expect(complete.contains(diagnostics.structuredIdentity!))
    }

    @Test func letterPrefixesArePreserved() {
        #expect(ScannedCardIdentity.normalizedNumber(" TG05 ") == "TG05")
        #expect(ScannedCardIdentity.normalizedNumber("057") == "57")
    }
}
#endif
