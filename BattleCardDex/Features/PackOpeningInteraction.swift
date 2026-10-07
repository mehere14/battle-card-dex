import Foundation

enum PackOpeningPhase: Equatable, Sendable {
    case sealed
    case cutting(progress: Double)
    case opening
    case revealing(index: Int)
    case completed
}

struct PackOpeningInteractionModel: Sendable {
    let commitFraction: Double
    let directionTolerance: Double

    init(commitFraction: Double = 0.65, directionTolerance: Double = 1.2) {
        self.commitFraction = commitFraction
        self.directionTolerance = directionTolerance
    }

    func cutProgress(translationX: Double, translationY: Double, availableWidth: Double) -> Double {
        guard translationX > 0, abs(translationX) >= abs(translationY) * directionTolerance else { return 0 }
        return min(max(translationX / max(availableWidth, 1), 0), 1)
    }

    func commits(progress: Double) -> Bool { progress >= commitFraction }

    func nextPhase(afterReveal index: Int, cardCount: Int) -> PackOpeningPhase {
        index + 1 >= cardCount ? .completed : .revealing(index: index + 1)
    }
}
