import Foundation

nonisolated enum BoosterPackSlot: Equatable, Sendable {
    case common
    case uncommon
    case foil
    case rareOrBetter
}

nonisolated struct SampledBoosterCard: Identifiable, Equatable, Sendable {
    let card: BattleCardDetail
    let slot: BoosterPackSlot
    var id: String { card.summary.id }
}

nonisolated enum BoosterPackSampler {
    static func sample<R: RandomNumberGenerator>(from cards: [BattleCardDetail], using generator: inout R) -> [SampledBoosterCard] {
        var available = Dictionary(cards.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SampledBoosterCard] = []

        func normalizedRarity(_ card: BattleCardDetail) -> String {
            card.summary.rarity?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func draw(where predicate: (BattleCardDetail) -> Bool, slot: BoosterPackSlot) -> SampledBoosterCard? {
            let pool = available.values.filter(predicate)
            guard let card = pool.randomElement(using: &generator) else { return nil }
            available.removeValue(forKey: card.summary.id)
            return SampledBoosterCard(card: card, slot: slot)
        }
        func fill(_ count: Int, slot: BoosterPackSlot, preferred: (BattleCardDetail) -> Bool) {
            for _ in 0..<count {
                guard let pick = draw(where: preferred, slot: slot) ?? draw(where: { _ in true }, slot: slot) else { break }
                result.append(pick)
            }
        }

        fill(4, slot: .common) { normalizedRarity($0) == "common" }
        fill(3, slot: .uncommon) { normalizedRarity($0) == "uncommon" }
        // Finish variants are not separate catalog records. These two slots choose
        // distinct cards from the set and retain foil-slot semantics for later rendering.
        fill(2, slot: .foil) { normalizedRarity($0) == "common" || normalizedRarity($0) == "uncommon" }
        fill(1, slot: .rareOrBetter) {
            let rarity = normalizedRarity($0)
            return !rarity.isEmpty && rarity != "common" && rarity != "uncommon" && !rarity.contains("energy")
        }
        return result
    }

    static func sample(from cards: [BattleCardDetail]) -> [SampledBoosterCard] {
        var generator = SystemRandomNumberGenerator()
        return sample(from: cards, using: &generator)
    }
}
