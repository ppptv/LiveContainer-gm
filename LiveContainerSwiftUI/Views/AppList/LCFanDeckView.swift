//
//  LCFanDeckView.swift
//
//  Cover-Flow app deck. Built fresh on top of the v79 baseline instead of
//  patching the previous attempt, which had accumulated layout hacks
//  (drawingGroup under a 3D transform, per-card "avoidance" offsets, an
//  implicit-centre ZStack, a clipped page used as a positioning container)
//  that fought each other and ended up with an off-centre deck, a vanished
//  top bar and cards that could leave the screen entirely.
//
//  DESIGN RULES THIS FILE OBEYS — these are the invariants the old code broke:
//
//  1. ONE coordinate space. The deck is a fixed-size canvas whose width is the
//     page width passed in from the parent. Cards are placed with `.position`
//     from THAT canvas's centre, never from an intrinsic or measured frame.
//     Nothing inside can widen the canvas, so ancestors can never be pushed
//     off-centre.
//
//  2. ONE progress value drives everything. `phase` ∈ [0,1] is the gesture
//     progress; every card's geometry is a pure function of its slot index
//     minus that progress. No card can drift ahead of the others, and there is
//     always exactly one card nearest the centre.
//
//  3. The canvas is clipped, so a card parked outside the screen is not drawn
//     and cannot affect layout.
//
//  4. No `.drawingGroup()` anywhere near a 3D transform: it re-rasterises the
//     bitmap every frame (the stutter) and its blurred bounds skew centring.
//
//  Structure is deliberately flat: a background layer, the deck, the top bar,
//  and the dock. Each is in its own overlay so a change to one cannot move
//  another.
//

import SwiftUI

// MARK: - Palette

enum FanDeckTheme {
    static let page      = Color(red: 0.945, green: 0.949, blue: 0.961)
    static let ink       = Color(red: 0.133, green: 0.133, blue: 0.161)
    static let muted     = Color(red: 0.604, green: 0.608, blue: 0.667)
    static let desc      = Color(red: 0.553, green: 0.553, blue: 0.600)
    static let pink      = Color(red: 0.937, green: 0.545, blue: 0.608)
    static let pinkSoft  = Color(red: 0.992, green: 0.894, blue: 0.910)
    static let chip      = Color(red: 0.941, green: 0.945, blue: 0.961)
    static let shadow    = Color(red: 0.149, green: 0.125, blue: 0.204)
    static let deckShade = Color(red: 0.094, green: 0.075, blue: 0.129)
}

// MARK: - One card

/// Equatable so a pose change during a gesture does NOT rebuild the card body.
/// The body only invalidates when the app identity, its cover generation or
/// the card size changes.
private struct FanDeckCard: View, Equatable {
    let id: String
    let name: String
    let cover: UIImage
    let accent: Color
    let genre: String
    let version: String
    let size: String
    let intro: String
    let cardSize: CGSize
    let generation: Int

    static func == (a: FanDeckCard, b: FanDeckCard) -> Bool {
        a.id == b.id && a.generation == b.generation && a.cardSize == b.cardSize
    }

    private var scaleF: CGFloat { cardSize.width / 328.0 }
    private var radius: CGFloat { 34 * scaleF }

    var body: some View {
        VStack(spacing: 0) {
            // Artwork. 328:400 in the reference design.
            Color.clear
                .frame(height: cardSize.height * 0.663)
                .overlay {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 22 * scaleF, weight: .heavy))
                    .foregroundStyle(FanDeckTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6 * scaleF) {
                    metaChip("\(genre) · \(version)")
                    metaChip(size)
                }
                .padding(.top, 6 * scaleF)

                Text(intro)
                    .font(.system(size: 12.5 * scaleF))
                    .foregroundStyle(FanDeckTheme.desc)
                    .lineSpacing(3 * scaleF)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10 * scaleF)

                Spacer(minLength: 4)

                HStack(spacing: 12 * scaleF) {
                    Text("启动")
                        .font(.system(size: 15 * scaleF, weight: .heavy))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54 * scaleF)
                        .background(
                            FanDeckTheme.pinkSoft,
                            in: Capsule()
                        )
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20 * scaleF, weight: .bold))
                        .foregroundStyle(Color(red: 0.557, green: 0.561, blue: 0.616))
                        .frame(width: 54 * scaleF, height: 54 * scaleF)
                        .background(FanDeckTheme.chip, in: Circle())
                }
            }
            .padding(.horizontal, 24 * scaleF)
            .padding(.top, 20 * scaleF)
            .padding(.bottom, 22 * scaleF)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.60), .white.opacity(0.10), .black.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        // Shadows live OUTSIDE any rasterisation group: they must not inflate
        // the view's bounds, or `.position` would centre the blur margin.
        .shadow(color: FanDeckTheme.shadow.opacity(0.42), radius: 12, x: 0, y: 8)
        .shadow(color: FanDeckTheme.shadow.opacity(0.20), radius: 50, x: 0, y: 36)
        .shadow(color: FanDeckTheme.shadow.opacity(0.14), radius: 3, x: 0, y: 1.5)
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5 * scaleF, weight: .semibold))
            .foregroundStyle(FanDeckTheme.muted)
            .lineLimit(1)
            .padding(.horizontal, 8 * scaleF)
            .padding(.vertical, 3 * scaleF)
            .background(FanDeckTheme.chip, in: Capsule())
    }
}

// MARK: - Deck geometry

/// A card's appearance on the rail. Every field is derived from `d`, the
/// signed distance (in slots) between this card and the centre.
private struct FanDeckPose {
    var x: CGFloat
    var yaw: Double
    var scale: CGFloat
    var opacity: Double
    var z: Double
    var shade: Double
}

// MARK: - The page

struct LCFanDeckView: View {
    let apps: [LCAppModel]
    let sortType: AppSortType
    let revision: Int
    let sideStoreIcon: UIImage?

    var onLaunch: (LCAppModel) -> Void
    var onOpenSettings: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onSortChange: (AppSortType) -> Void
    var onCustomSort: () -> Void
    var onInstallIPA: () -> Void
    var onInstallURL: () -> Void
    var onOpenLink: () -> Void
    var onOpenSideStore: () -> Void
    var onRequestCover: (LCAppModel) -> Void
    @Binding var topBeadHidden: Bool

    @State private var head = 0
    @State private var phase: CGFloat = 0
    @State private var dir = 1
    @State private var busy = false
    @State private var mode = 0            // 0 = deck, 1 = list
    @State private var sortShown = false

    var body: some View {
        // GeometryReader gives the ONE authoritative width/height for this page.
        // Everything below measures from it; nothing measures itself.
        GeometryReader { geo in
            let size = cardSize(in: geo.size)
            ZStack {
                backdrop(coverOf: incomingCover, progress: phase)
                    .ignoresSafeArea()

                deck(size: size, canvasWidth: geo.size.width)
                    // The deck starts BELOW the top bar + hint row (56 + 26).
                    // Left to the ZStack it would be centred in the remaining
                    // height and ride up under the status bar.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, mode == 0 ? 82 : 56)

                topBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if mode == 0 {
                    hintRow
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 56)
                }

                dock
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
            // The page must never report more than the screen. Cards are parked
            // off-screen by design; clipping keeps that overflow local so no
            // ancestor can be widened by it (the off-centre bug).
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .onAppear { topBeadHidden = false }
        .onChange(of: apps.count) { n in
            if n == 0 { head = 0 } else if head >= n { head = n - 1 }
        }
        .onChange(of: revision) { _ in }
    }

    // MARK: Sizing

    /// 328×604 reference. Height is capped first on short screens and the width
    /// follows, so the card never squashes; both stay proportional.
    private func cardSize(in page: CGSize) -> CGSize {
        let maxW = min(328, max(200, page.width - 48))
        var w = maxW
        var h = w * 604.0 / 328.0
        // Chrome around the deck: 56 top bar + 26 hint + 72 dock = 154, plus
        // the 8pt that the dock sits off the home indicator.
        let available = page.height - 56 - 26 - 72 - 8
        if h > available && available > 240 {
            h = available
            w = h * 328.0 / 604.0
        }
        return CGSize(width: w, height: h)
    }

    // MARK: Items

    private var items: [LCAppModel] { apps }

    private func wrapped(_ i: Int) -> Int {
        let n = max(items.count, 1)
        return ((i % n) + n) % n
    }

    private var headModel: LCAppModel? {
        items.indices.contains(head) ? items[head] : nil
    }

    /// The cover that fades IN over the current backdrop while a swipe is live.
    private var incomingCover: UIImage? {
        guard items.count > 1, phase > 0.001 else { return nil }
        let idx = wrapped(head + dir)
        guard items.indices.contains(idx) else { return nil }
        return LCGalleryCoverStore.shared.cover(for: items[idx], wide: false)
    }

    // MARK: Backdrop

    /// Current card's cover, blurred, as the ambient page colour.
    ///
    /// Two pre-blurred layers: the current cover underneath and the incoming
    /// one on top with its alpha tied to `phase`. Because both are already
    /// blurred, the transition is a single alpha composite per frame — no
    /// gaussian is re-run while the finger moves, and it tracks the gesture
    /// instead of snapping when the swipe commits.
    private func backdrop(coverOf incoming: UIImage?, progress: CGFloat) -> some View {
        ZStack {
            FanDeckTheme.page
            if let current = headModel.map({ LCGalleryCoverStore.shared.cover(for: $0, wide: false) }) {
                Image(uiImage: current)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.15)
                    .blur(radius: 34, opaque: true)
                    .opacity(0.40)
            }
            if let incoming {
                Image(uiImage: incoming)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.15)
                    .blur(radius: 34, opaque: true)
                    .opacity(0.40 * Double(progress))
            }
            FanDeckTheme.page.opacity(0.34)
        }
    }

    // MARK: Deck

    /// Signed slot offset from head, as the shortest wrap-around distance.
    private func slot(of index: Int) -> Int? {
        let n = items.count
        guard n > 0 else { return nil }
        var d = index - head
        if d > n / 2 { d -= n }
        if d < -(n / 2) { d += n }
        return abs(d) <= 2 ? d : nil
    }

    /// The rail advances one slot over phase ∈ [0,1], eased so the incoming
    /// card takes the centre during the first half of the gesture. A linear
    /// ramp leaves two equal cards at ±0.5 with nobody owning the middle,
    /// which reads as two cards sliding rather than as Cover Flow.
    private var easedPhase: CGFloat {
        let p = min(max(phase, 0), 1)
        return 1 - pow(1 - p, 2.2)
    }

    private func pose(slot s: Int) -> FanDeckPose {
        let d = CGFloat(s) - easedPhase * CGFloat(dir)
        let ad = abs(d)

        // Constant slot pitch: cards stay adjacent, never split apart.
        let x = d * slotPitch

        // yaw: 0° at centre, ~44° at half a slot, 70° a full slot, 85° at the
        // edge. A linear ramp (27° at half a slot) looked flat, not like CK.
        let yaw: Double = {
            let sign: Double = d >= 0 ? 1 : -1
            if ad <= 1 { return sign * 70 * (1 - pow(1 - Double(ad), 1.4)) }
            return sign * (70 + Double(ad - 1) * 15)
        }()

        let scale: CGFloat = ad <= 1 ? 1 - ad * 0.14 : max(0.70, 0.86 - (ad - 1) * 0.16)
        let opacity: Double = ad <= 1.7 ? 1 : max(0, 1 - Double((ad - 1.7) / 0.32))
        let shade = min(2, Double(ad)) * 0.09
        let z = 3.0 - Double(min(2, ad)) * 0.5

        return FanDeckPose(x: x, yaw: yaw, scale: scale, opacity: opacity, z: z, shade: shade)
    }

    private var slotPitch: CGFloat { 138.0 * (currentCardSize.width / 328.0) }
    private var currentCardSize: CGSize { _cachedSize }

    // cardSize() is needed by the deck and by the pitch maths; keep one value.
    @State private var _cachedSize: CGSize = CGSize(width: 328, height: 604)

    private func deck(size: CGSize, canvasWidth: CGFloat) -> some View {
        // A FIXED canvas: cards may sit far outside it, but its reported size is
        // exactly this frame, so the overflow cannot propagate upward.
        let visible = (-2...2).compactMap { s -> (Int, FanDeckPose)? in
            guard let idx = slotIndex(forSlot: s) else { return nil }
            let p = pose(slot: s)
            return p.opacity > 0.02 ? (idx, p) : nil
        }

        return ZStack {
            ForEach(visible, id: \.0) { pair in
                let idx = pair.0
                let p = pair.1
                cardView(for: idx)
                    .rotation3DEffect(.degrees(p.yaw), axis: (x: 0, y: 1, z: 0),
                                      anchor: .center, anchorZ: 0, perspective: 1 / 900)
                    .scaleEffect(p.scale)
                    .opacity(p.opacity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 34 * (size.width / 328.0),
                                         style: .continuous)
                            .fill(FanDeckTheme.deckShade.opacity(p.shade))
                    )
                    .zIndex(p.z)
                    .allowsHitTesting(abs(p.x) < 8)
                    .position(x: canvasWidth / 2 + p.x,
                              y: size.height / 2)
            }
        }
        // The canvas is exactly one card tall, so `.position` above resolves
        // against a known box and the card lands with its TOP edge at 0.
        // Vertical placement is the caller's job (padding), never a magic +6.
        .frame(width: canvasWidth, height: size.height, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .simultaneousGesture(deckDrag)
        .onAppear { _cachedSize = size }
        .onChange(of: size) { _cachedSize = $0 }
    }

    private func slotIndex(forSlot s: Int) -> Int? {
        let n = items.count
        guard n > 0 else { return nil }
        // A slot only exists if the wrapped index is distinct from the others.
        let idx = wrapped(head + s)
        return items.indices.contains(idx) ? idx : nil
    }

    private func cardView(for index: Int) -> some View {
        let app = items[index]
        let meta = LCGalleryMetaStore.shared.gameMeta(for: app)
        return FanDeckCard(
            id: app.appInfo.bundleIdentifier() ?? app.appInfo.relativeBundlePath ?? "\(index)",
            name: app.displayName,
            cover: LCGalleryCoverStore.shared.cover(for: app, wide: false),
            accent: LCGalleryColorStore.shared.color(for: app),
            genre: meta.genre ?? "应用",
            version: app.version,
            size: LCGallerySizeStore.shared.sizeText(for: app),
            intro: meta.intro.isEmpty ? "长按封面可更换自定义封面。" : meta.intro,
            cardSize: _cachedSize,
            generation: revision
        )
    }

    // MARK: Gesture

    private var travel: CGFloat { min(150, max(100, currentCardSize.width * 0.42)) }

    private var deckDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard !busy, items.count > 1 else { return }
                let dx = v.translation.width
                if abs(dx) > 0.5 { dir = dx < 0 ? 1 : -1 }
                phase = min(1, max(0, abs(dx) / travel))
            }
            .onEnded { v in
                guard !busy, items.count > 1 else { return }
                let projected = abs(v.predictedEndTranslation.width)
                if phase > 0.15 || projected > travel * 1.2 || abs(v.velocity.width) > 400 {
                    settle(to: 1)
                } else {
                    settle(to: 0)
                }
            }
    }

    private func settle(to target: CGFloat) {
        guard !busy else { return }
        busy = true
        let frozen = dir
        if target == 1 { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        let remaining = abs(target - phase)
        let dur = target == 1
            ? 0.30 * Double(max(0.35, remaining))
            : 0.22 * Double(max(0.35, remaining))
        withAnimation(.easeOut(duration: dur)) { phase = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.01) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if target == 1 { head = wrapped(head + frozen) }
                phase = 0
                busy = false
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    sortShown.toggle()
                }
            } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FanDeckTheme.pink)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onOpenSideStore) {
                ZStack {
                    if let icon = sideStoreIcon {
                        Image(uiImage: icon).resizable().scaledToFill()
                    } else {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .background(
                    Circle().fill(
                        LinearGradient(colors: [Color(red: 0.737, green: 0.831, blue: 0.980),
                                                Color(red: 0.588, green: 0.722, blue: 0.937)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .overlay(
            Text("应用卡片")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(FanDeckTheme.ink)
        )
    }

    private var hintRow: some View {
        HStack(spacing: 12) {
            Text("\(items.count) 个应用 · 左右拖动切换")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FanDeckTheme.muted)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 5) {
                ForEach(dotWindow, id: \.self) { i in
                    Capsule()
                        .fill(i == head ? FanDeckTheme.pink
                              : Color(red: 0.851, green: 0.855, blue: 0.890))
                        .frame(width: i == head ? 15 : 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(height: 26)
        .frame(maxWidth: .infinity)
    }

    /// Five dots centred on the head — a bounded window, so a long app list
    /// cannot stretch the row past the screen (which once widened the parent
    /// and moved the whole deck sideways).
    private var dotWindow: [Int] {
        let n = items.count
        guard n > 0 else { return [] }
        var lo = head - 2, hi = head + 2
        if lo < 0 { hi -= lo; lo = 0 }
        if hi >= n { lo -= (hi - n + 1); hi = n - 1 }
        return (max(0, lo)...hi).map { $0 }
    }

    // MARK: Dock

    private var dock: some View {
        HStack(spacing: 10) {
            dockButton("square.grid.2x2.fill", selected: mode == 0) { mode = 0 }
            Button {
                // quick actions
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(FanDeckTheme.pink, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            dockButton("list.bullet", selected: mode == 1) { mode = 1 }
        }
        .padding(.horizontal, 12)
        .frame(width: 212, height: 64)
        .background(
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.white.opacity(0.92))
            }
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
    }

    private func dockButton(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selected ? FanDeckTheme.pink
                                 : Color(red: 0.659, green: 0.663, blue: 0.706))
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(selected ? FanDeckTheme.pinkSoft : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
