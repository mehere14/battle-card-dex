import SwiftUI
import UIKit

@MainActor
struct DebugPackOpeningView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: PackOpeningPhase = .sealed
    @State private var cutProgress = 0.0
    @State private var topDeparture = 0.0
    @State private var wrapperDeparture = 0.0
    @State private var cardsRise = 0.0
    @State private var cardDrag: CGSize = .zero
    @State private var entranceTurns = 0.0
    @State private var entranceScale = 0.34
    @State private var entranceComplete = false
    @State private var cards: [SampledBoosterCard] = []
    @State private var isLoadingCards = true
    @State private var preparedImageCount = 0
    @State private var cardIsFaceUp = false
    @State private var cardTurns = 0.0
    @State private var remotePackArtwork: UIImage?

    private let interaction = PackOpeningInteractionModel()
    private let packRatio: CGFloat = 400.0 / 731.0
    let pack: BoosterPackArtwork
    @ObservedObject var model: CatalogViewModel

    init(pack: BoosterPackArtwork, model: CatalogViewModel) { self.pack = pack; self.model = model }

    var body: some View {
        GeometryReader { proxy in
            let height = min(proxy.size.height * 0.66, 650)
            let width = height * packRatio
            ZStack {
                PackLabBackground()
                VStack(spacing: 18) {
                    header
                    Spacer(minLength: 0)
                    packStage(width: width, height: height)
                        .rotation3DEffect(.degrees(entranceTurns), axis: (x: 0, y: 1, z: 0), perspective: 0.62)
                        .scaleEffect(entranceScale)
                    controls
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: animateEntrance)
        .task { await loadPackCards() }
        .task { await loadPackArtwork() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("OPEN PACK").font(.caption.bold()).tracking(2).foregroundStyle(.yellow)
                Text(pack.name).font(.title2.bold())
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline)
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close pack prototype")
        }
    }

    private func packStage(width: CGFloat, height: CGFloat) -> some View {
        let seamY = height * 0.105
        return ZStack(alignment: .top) {
            if cardsVisible {
                cardStack(width: width * 0.90, height: height * 0.69)
                    .offset(y: height * (0.23 - 0.075 * cardsRise))
                    .zIndex(1)
            }

            foilImage(width: width, height: height)
                .clipShape(PackBodyShape(seamY: seamY, opening: cardsRise))
                .overlay(alignment: .top) {
                    Capsule().fill(.black.opacity(0.78 * cardsRise))
                        .frame(width: width * 0.82, height: 10 + 16 * cardsRise)
                        .blur(radius: 2).offset(y: seamY - 5)
                }
                .offset(x: wrapperDeparture * width * 2.4)
                .rotationEffect(.degrees(wrapperDeparture * 10))
                .zIndex(2)

            foilImage(width: width, height: height)
                .clipShape(PackTopShape(seamY: seamY))
                .offset(x: topDeparture * width * 0.82, y: -topDeparture * height * 0.10)
                .rotationEffect(.degrees(topDeparture * 17), anchor: .leading)
                .opacity(1 - topDeparture * 0.7)
                .zIndex(4)

            if !cardsVisible {
                if isLoadingCards || cards.count != 10 {
                    preparationGauge(width: width, seamY: seamY).zIndex(5)
                } else {
                    seamControl(width: width, seamY: seamY).zIndex(5)
                }
            }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.72), radius: 28, y: 18)
    }

    private func foilImage(width: CGFloat, height: CGFloat) -> some View {
        TimelineView(.animation(paused: reduceMotion || cardsVisible)) { timeline in
            Group {
                if let remotePackArtwork { Image(uiImage: remotePackArtwork).resizable() }
                else if let fallback = pack.bundledFallbackName { Image(fallback).resizable() }
                else { RoundedRectangle(cornerRadius: 10).fill(.purple.gradient) }
            }
                .scaledToFill().frame(width: width, height: height)
                .colorEffect(ShaderLibrary.packFoil(
                    .float2(width, height),
                    .float(timeline.date.timeIntervalSinceReferenceDate),
                    .float2(width * CGFloat(0.18 + cutProgress * 0.68), height * 0.12),
                    .float(reduceMotion ? 0 : 1)
                ))
        }
    }

    private func seamControl(width: CGFloat, seamY: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
            Path { path in
                path.move(to: CGPoint(x: 0, y: 36))
                let end = width * cutProgress
                stride(from: CGFloat.zero, through: end, by: 5).forEach { x in
                    path.addLine(to: CGPoint(x: x, y: 36 + sin(x * 0.15) * 2.5))
                }
            }
            .stroke(LinearGradient(colors: [.cyan, .white, .yellow], startPoint: .leading, endPoint: .trailing), lineWidth: 4)
            .shadow(color: .cyan, radius: 8)

            if cutProgress == 0 {
                HStack(spacing: 7) {
                    Image(systemName: "hand.draw.fill")
                    Text("SWIPE TO CUT").font(.caption2.bold()).tracking(1.2)
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.68), in: Capsule())
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width, height: 76)
        .offset(y: seamY - 38)
        .allowsHitTesting(entranceComplete && cards.count == 10)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                let progress = interaction.cutProgress(
                    translationX: value.translation.width,
                    translationY: value.translation.height,
                    availableWidth: width
                )
                cutProgress = progress
                phase = progress > 0 ? .cutting(progress: progress) : .sealed
            }
            .onEnded { _ in
                if interaction.commits(progress: cutProgress) { openPack() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { cutProgress = 0; phase = .sealed } }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cut pack open")
        .accessibilityHint("Swipe from left to right across the top of the pack")
        .accessibilityIdentifier("pack-cut-control")
        .accessibilityAction { openPack() }
    }

    private func preparationGauge(width: CGFloat, seamY: CGFloat) -> some View {
        VStack(spacing: 7) {
            ProgressView(value: Double(preparedImageCount), total: 10)
                .progressViewStyle(.circular)
                .tint(.yellow)
                .scaleEffect(1.25)
            Text("\(preparedImageCount)/10")
                .font(.caption.bold()).monospacedDigit().foregroundStyle(.yellow)
            Text("PREPARING CARDS")
                .font(.caption2.bold()).tracking(1.1).foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 16))
        .frame(width: width)
        .offset(y: seamY - 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing cards, \(preparedImageCount) of 10")
        .accessibilityIdentifier("pack-preparation-progress")
    }

    private func cardStack(width: CGFloat, height: CGFloat) -> some View {
        let current = revealIndex
        return ZStack {
            ForEach(Array(cards.indices.reversed()), id: \.self) { index in
                if index >= current {
                    cardSurface(for: cards[index], faceUp: index == current && cardIsFaceUp)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.7)))
                        .shadow(color: .black.opacity(0.58), radius: 16, y: 10)
                        .offset(x: index == current ? cardDrag.width : CGFloat(index - current) * 3,
                                y: index == current ? cardDrag.height * 0.12 : CGFloat(index - current) * -5)
                        .rotationEffect(.degrees(index == current ? Double(cardDrag.width / 22) : Double(index - current) * 0.7))
                        .rotation3DEffect(.degrees(index == current ? cardTurns : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.58)
                        .zIndex(Double(cards.count - index))
                        .accessibilityIdentifier(index == current ? (cardIsFaceUp ? "pack-card-front" : "pack-card-back") : "pack-card-under-\(index)")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { flipCurrentCard() }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { value in if case .revealing = phase, cardIsFaceUp { cardDrag = value.translation } }
            .onEnded { value in
                guard case .revealing(let index) = phase, cardIsFaceUp else { return }
                if abs(value.predictedEndTranslation.width) > 150 || abs(value.translation.width) > width * 0.28 {
                    removeCard(index: index, direction: value.predictedEndTranslation.width < 0 ? -1 : 1)
                } else { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { cardDrag = .zero } }
            })
        .accessibilityLabel(current < cards.count ? (cardIsFaceUp ? "\(cards[current].card.summary.name), card \(current + 1) of \(cards.count)" : "Face-down card \(current + 1) of \(cards.count)") : "Pack complete")
        .accessibilityAction(named: "Flip card") { flipCurrentCard() }
    }

    @ViewBuilder private func cardSurface(for sampled: SampledBoosterCard, faceUp: Bool) -> some View {
        if faceUp {
            ZStack {
                Color.white
                if let url = sampled.card.summary.largeImageURL ?? sampled.card.summary.smallImageURL {
                    CatalogImageView(url: url, repository: model.imageRepository, placeholderID: nil).scaledToFit()
                } else {
                    LinearGradient(colors: [.indigo, .purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 54)).foregroundStyle(.yellow)
                        Text(sampled.card.summary.name).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(sampled.card.summary.rarity ?? "Pokémon card").font(.caption.bold()).foregroundStyle(.white.opacity(0.72))
                    }.padding().foregroundStyle(.white)
                }
            }
        } else {
            Image("CardBack").resizable().scaledToFill()
        }
    }

    @ViewBuilder private var controls: some View {
        switch phase {
        case .sealed, .cutting:
            Text(isLoadingCards ? "Choosing ten cards from \(pack.name)…" : (cards.count == 10 ? (entranceComplete ? "Drag across the upper seam to slice the foil." : "Preparing your pack…") : "This pack could not be prepared."))
                .foregroundStyle(.white.opacity(0.72))
        case .opening:
            Text("Opening…").foregroundStyle(.white.opacity(0.72))
        case .revealing(let index):
            VStack(spacing: 9) {
                Text("CARD \(index + 1) OF \(cards.count)").font(.caption.bold()).tracking(1.8).foregroundStyle(.yellow)
                    .accessibilityIdentifier("pack-card-index")
                Text(cardIsFaceUp ? "Swipe left or right for the next card" : "Tap the card to reveal it")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.72))
            }
        case .completed:
            VStack(spacing: 9) {
                Text("PACK COMPLETE").font(.headline.bold()).foregroundStyle(.yellow)
                Button("Open Another", action: reset).buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
            }
        }
    }

    private var cardsVisible: Bool {
        switch phase { case .opening, .revealing, .completed: true; default: false }
    }

    private var revealIndex: Int {
        if case .revealing(let index) = phase { return index }
        return phase == .completed ? cards.count : 0
    }

    private func openPack() {
        guard entranceComplete, cards.count == 10, !cardsVisible else { return }
        phase = .opening
        cutProgress = 1
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.95)
        withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.42)) { topDeparture = 1 }
        withAnimation(.spring(response: reduceMotion ? 0.01 : 0.72, dampingFraction: 0.76).delay(reduceMotion ? 0 : 0.18)) { cardsRise = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 5 : 300))
            withAnimation(.easeIn(duration: reduceMotion ? 0.01 : 0.42)) {
                wrapperDeparture = 1
                topDeparture = 3
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 20 : 820))
            phase = .revealing(index: 0)
            UIAccessibility.post(notification: .announcement, argument: "Pack opened. Card 1 of \(cards.count).")
        }
    }

    private func removeCard(index: Int, direction: CGFloat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65)
        withAnimation(.easeIn(duration: reduceMotion ? 0.01 : 0.24)) { cardDrag.width = direction * 900 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 15 : 250))
            cardDrag = .zero
            cardIsFaceUp = false
            cardTurns = 0
            phase = interaction.nextPhase(afterReveal: index, cardCount: cards.count)
            if phase == .completed { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    private func flipCurrentCard() {
        guard case .revealing = phase, !cardIsFaceUp else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
        if reduceMotion {
            cardIsFaceUp = true
            return
        }
        withAnimation(.linear(duration: 0.62)) { cardTurns = 360 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(310))
            cardIsFaceUp = true
        }
    }

    private func reset() {
        cardDrag = .zero; cardIsFaceUp = false; cardTurns = 0; cutProgress = 0; topDeparture = 0; wrapperDeparture = 0; cardsRise = 0; phase = .sealed
    }

    private func animateEntrance() {
        guard !entranceComplete else { return }
        if reduceMotion {
            entranceScale = 1
            entranceComplete = true
            return
        }
        withAnimation(.easeOut(duration: 0.78)) {
            entranceTurns = 1080
            entranceScale = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            entranceComplete = true
            UIAccessibility.post(notification: .announcement, argument: "\(pack.name) ready to open.")
        }
    }

    private func loadPackCards() async {
        isLoadingCards = true
        preparedImageCount = 0
        cards = BoosterPackSampler.sample(from: await model.cards(inSet: pack.setID))
        guard cards.count == 10 else { isLoadingCards = false; return }
        if let repository = model.imageRepository {
            let urls = cards.compactMap { $0.card.summary.largeImageURL ?? $0.card.summary.smallImageURL }
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { _ = try? await repository.data(for: url) }
                }
                for await _ in group { preparedImageCount += 1 }
            }
            preparedImageCount += 10 - urls.count
        } else {
            preparedImageCount = 10
        }
        isLoadingCards = false
        if cards.count == 10 {
            UIAccessibility.post(notification: .announcement, argument: "Ten cards selected from \(pack.name).")
        }
    }

    private func loadPackArtwork() async {
        guard let repository = model.packArtworkRepository,
              let data = try? await repository.data(recordID: pack.recordID, resolution: .full) else { return }
        remotePackArtwork = UIImage(data: data)
    }
}

private struct PackTopShape: Shape {
    let seamY: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: .zero); path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: seamY)); path.addLine(to: CGPoint(x: rect.width * 0.72, y: seamY - 2))
        path.addLine(to: CGPoint(x: rect.width * 0.43, y: seamY + 3)); path.addLine(to: CGPoint(x: rect.width * 0.18, y: seamY - 2))
        path.addLine(to: CGPoint(x: 0, y: seamY)); path.closeSubpath(); return path
    }
}

private struct PackBodyShape: Shape {
    let seamY: CGFloat
    let opening: Double
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: 0, y: seamY))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: seamY), control: CGPoint(x: rect.midX, y: seamY + CGFloat(opening) * 18))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height)); path.addLine(to: CGPoint(x: 0, y: rect.height)); path.closeSubpath(); return path
    }
}

private struct PackLabBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.025, blue: 0.075).ignoresSafeArea()
            RadialGradient(colors: [.purple.opacity(0.38), .clear], center: .center, startRadius: 20, endRadius: 520).ignoresSafeArea()
            Canvas { context, size in
                for index in 0..<28 {
                    let x = Double((index * 83) % 101) / 101 * size.width
                    let y = Double((index * 47) % 97) / 97 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.22)))
                }
            }.ignoresSafeArea()
        }
    }
}
