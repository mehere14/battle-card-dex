import Testing
@testable import Battle_Card_Dex

struct PackOpeningInteractionTests {
    private let model = PackOpeningInteractionModel()

    @Test func horizontalCutTracksAndClamps() {
        #expect(model.cutProgress(translationX: 65, translationY: 4, availableWidth: 100) == 0.65)
        #expect(model.cutProgress(translationX: 140, translationY: 0, availableWidth: 100) == 1)
    }

    @Test func wrongDirectionDoesNotCut() {
        #expect(model.cutProgress(translationX: -80, translationY: 0, availableWidth: 100) == 0)
        #expect(model.cutProgress(translationX: 40, translationY: 60, availableWidth: 100) == 0)
    }

    @Test func thresholdAndRevealSequence() {
        #expect(!model.commits(progress: 0.649))
        #expect(model.commits(progress: 0.65))
        #expect(model.nextPhase(afterReveal: 3, cardCount: 5) == .revealing(index: 4))
        #expect(model.nextPhase(afterReveal: 4, cardCount: 5) == .completed)
    }

    @Test func samplerBuildsTenUniqueCardsInRevealOrder() {
        let cards = (1...8).map { makeCard(id: "c\($0)", rarity: "Common") }
            + (1...6).map { makeCard(id: "u\($0)", rarity: "Uncommon") }
            + (1...4).map { makeCard(id: "r\($0)", rarity: $0 == 1 ? "Rare" : "Illustration Rare") }
        var generator = SeededGenerator(seed: 42)
        let pack = BoosterPackSampler.sample(from: cards, using: &generator)

        #expect(pack.count == 10)
        #expect(Set(pack.map(\.id)).count == 10)
        #expect(pack.map(\.slot) == [.common, .common, .common, .common,
                                    .uncommon, .uncommon, .uncommon,
                                    .foil, .foil, .rareOrBetter])
        #expect(["Rare", "Illustration Rare"].contains(pack.last?.card.summary.rarity ?? ""))
    }

    private func makeCard(id: String, rarity: String) -> BattleCardDetail {
        BattleCardDetail(
            summary: BattleCardSummary(id: id, relatedCreatureIDs: [1], name: id, setID: "me5", setName: "Pitch Black",
                                       collectorNumber: id, rarity: rarity, types: [], hitPoints: nil,
                                       smallImageURL: nil, largeImageURL: nil),
            subtypes: [], rules: [], abilities: [], attacks: [], weaknesses: [], resistances: [], retreatCost: [],
            evolutionText: nil, artist: nil, flavorText: nil, regulationMark: nil, legalities: [:]
        )
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }
}
