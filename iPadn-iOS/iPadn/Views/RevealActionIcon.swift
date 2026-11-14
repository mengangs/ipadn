import SwiftUI
import UIKit

/// Complete, time-based playback, not a pose tied to finger distance. Trash
/// artwork is adapted from Telegram-iOS; see vendor/TelegramRevealAnimations.
/// Share keeps iPadn's familiar glyph with an original lift/return/settle cycle.
struct RevealActionIcon: UIViewRepresentable {
    let symbol: String
    let visibility: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Match `RevealIconPlayback`'s discrete hysteresis thresholds so continuous
    /// display-link spring frames don't re-bridge SwiftUI -> UIKit at 120 Hz.
    static func quantizedVisibility(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        if raw <= 0.01 { return 0 }
        if raw >= 0.1 { return 1 }
        return 0.05
    }

    func makeUIView(context: Context) -> RevealIconView { RevealIconView() }
    func updateUIView(_ view: RevealIconView, context: Context) {
        view.configure(symbol: symbol, visibility: visibility, reduced: reduceMotion)
    }
    static func dismantleUIView(_ view: RevealIconView, coordinator: ()) { view.stop() }
}

enum RevealAnimationKind: String, CaseIterable, Sendable {
    case trash, share
    case tabSearch = "tab_search"
    case tabDownloads = "tab_downloads"
    case tabPurchased = "tab_purchased"
    case tabAccount = "tab_account"
    init?(symbol: String) {
        if symbol.hasPrefix("trash") { self = .trash }
        else if symbol == "square.and.arrow.up" || symbol == "square.and.arrow.up.fill" { self = .share }
        else { return nil }
    }
}

/// Generated, local-only vector data; no animation engine or network loading.
struct RevealAnimationAsset: Decodable, Sendable {
    struct Contour: Decodable, Sendable {
        let closed: Bool
        /// Move(x,y), followed by cubic(c1x,c1y,c2x,c2y,endx,endy) commands.
        let points: [Double]
        func makePath(in path: CGMutablePath) {
            path.move(to: CGPoint(x: points[0], y: points[1]))
            for i in stride(from: 2, to: points.count, by: 6) {
                path.addCurve(to: CGPoint(x: points[i + 4], y: points[i + 5]),
                              control1: CGPoint(x: points[i], y: points[i + 1]),
                              control2: CGPoint(x: points[i + 2], y: points[i + 3]))
            }
            if closed { path.closeSubpath() }
        }
    }
    struct Frame: Decodable, Sendable {
        let opacity: Float
        let width: Double
        let contours: [Contour]
        func makePath() -> CGPath {
            let path = CGMutablePath()
            for contour in contours { contour.makePath(in: path) }
            return path.copy()!
        }
    }
    struct Track: Decodable, Sendable {
        let stroke: Bool
        let evenOdd: Bool
        let lineCap: Int
        let lineJoin: Int
        let frames: [Frame]
    }
    let version: Int
    let canvas: [Double]
    let duration: Double
    let sourceSHA256: String
    let sourceCommit: String
    let tracks: [Track]

    var isValid: Bool {
        guard version == 1, canvas.count == 2,
              canvas.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 512 }),
              duration.isFinite, duration > 0, duration <= 3,
              !tracks.isEmpty, tracks.count <= 8,
              let count = tracks.first?.frames.count, (2...180).contains(count) else { return false }
        for track in tracks {
            guard track.frames.count == count, let first = track.frames.first,
                  !first.contours.isEmpty, first.contours.count <= 16 else { return false }
            for frame in track.frames {
                guard frame.opacity.isFinite, (0...1).contains(frame.opacity),
                      frame.width.isFinite, (0...20).contains(frame.width),
                      frame.contours.count == first.contours.count else { return false }
                for (contour, initial) in zip(frame.contours, first.contours) {
                    guard contour.closed == initial.closed, contour.points.count == initial.points.count,
                          (8...2048).contains(contour.points.count), (contour.points.count - 2) % 6 == 0,
                          contour.points.allSatisfy({ $0.isFinite && abs($0) <= 2048 }) else { return false }
                }
            }
        }
        return true
    }

    static func load(_ kind: RevealAnimationKind, bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: kind.rawValue, withExtension: "json", subdirectory: "RevealAnimations"),
              let data = try? Data(contentsOf: url), data.count <= 512 * 1024,
              let result = try? JSONDecoder().decode(Self.self, from: data), result.isValid else { return nil }
        return result
    }
}

/// CGPaths here are immutable copies, prepared off-main and shared read-only.
struct PreparedRevealAnimation: @unchecked Sendable {
    let asset: RevealAnimationAsset
    let paths: [[CGPath]]
    init(_ asset: RevealAnimationAsset) {
        self.asset = asset
        paths = asset.tracks.map { $0.frames.map { $0.makePath() } }
    }

    @MainActor
    func makeShapeLayers(color: CGColor, into container: CALayer) -> [CAShapeLayer] {
        asset.tracks.map { track in
            let shape = CAShapeLayer()
            shape.frame = CGRect(x: 0, y: 0, width: asset.canvas[0], height: asset.canvas[1])
            shape.fillColor = track.stroke ? nil : color
            shape.strokeColor = track.stroke ? color : nil
            shape.fillRule = track.evenOdd ? .evenOdd : .nonZero
            shape.lineCap = track.lineCap == 2 ? .round : (track.lineCap == 3 ? .square : .butt)
            shape.lineJoin = track.lineJoin == 2 ? .round : (track.lineJoin == 3 ? .bevel : .miter)
            container.addSublayer(shape)
            return shape
        }
    }

    @MainActor
    func applyColors(_ color: CGColor, to shapes: [CAShapeLayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, shape) in shapes.enumerated() where index < asset.tracks.count {
            let stroke = asset.tracks[index].stroke
            shape.fillColor = stroke ? nil : color
            shape.strokeColor = stroke ? color : nil
        }
        CATransaction.commit()
    }

    @MainActor
    func applyFrame(last: Bool, to shapes: [CAShapeLayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, shape) in shapes.enumerated() where index < asset.tracks.count {
            let frames = asset.tracks[index].frames
            let frame = last ? frames.count - 1 : 0
            shape.path = paths[index][frame]
            shape.opacity = frames[frame].opacity
            shape.lineWidth = frames[frame].width
        }
        CATransaction.commit()
    }

    @MainActor
    func play(on shapes: [CAShapeLayer], in window: UIWindow?, beginTime: CFTimeInterval? = nil, key: String = "reveal.icon") {
        for shape in shapes { shape.removeAllAnimations() }
        applyFrame(last: true, to: shapes)
        let time = beginTime ?? CACurrentMediaTime()
        let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond)
        let frameRate = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
        for (index, shape) in shapes.enumerated() where index < asset.tracks.count {
            let track = asset.tracks[index]
            let times = (0..<track.frames.count).map { NSNumber(value: Double($0) / Double(track.frames.count - 1)) }
            let path = CAKeyframeAnimation(keyPath: "path")
            path.values = paths[index]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = track.frames.map { NSNumber(value: $0.opacity) }
            let width = CAKeyframeAnimation(keyPath: "lineWidth")
            width.values = track.frames.map { NSNumber(value: $0.width) }
            for animation in [path, opacity, width] {
                animation.keyTimes = times
                animation.duration = asset.duration
                animation.calculationMode = .linear
                animation.preferredFrameRateRange = frameRate
            }
            let group = CAAnimationGroup()
            group.animations = [path, opacity, width]
            group.duration = asset.duration
            group.preferredFrameRateRange = frameRate
            group.beginTime = shape.convertTime(time, from: nil)
            shape.add(group, forKey: key)
        }
    }
}

actor RevealAnimationLibrary {
    static let shared = RevealAnimationLibrary()

    private final class PreparedCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [RevealAnimationKind: PreparedRevealAnimation] = [:]
    }
    private static let cache = PreparedCache()

    private var tasks: [RevealAnimationKind: Task<PreparedRevealAnimation?, Never>] = [:]

    static func syncLoad(_ kind: RevealAnimationKind) -> PreparedRevealAnimation? {
        cache.lock.lock()
        if let existing = cache.entries[kind] {
            cache.lock.unlock()
            return existing
        }
        cache.lock.unlock()
        guard let loaded = RevealAnimationAsset.load(kind).map({ PreparedRevealAnimation($0) }) else {
            return nil
        }
        cache.lock.lock()
        cache.entries[kind] = loaded
        cache.lock.unlock()
        return loaded
    }

    func load(_ kind: RevealAnimationKind) async -> PreparedRevealAnimation? {
        if let cached = Self.cacheValue(kind) { return cached }
        if let task = tasks[kind] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            Self.syncLoad(kind)
        }
        tasks[kind] = task
        return await task.value
    }

    private static func cacheValue(_ kind: RevealAnimationKind) -> PreparedRevealAnimation? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.entries[kind]
    }

    func preload() async {
        for kind in RevealAnimationKind.allCases { _ = await load(kind) }
    }
}

@MainActor
final class RevealIconView: UIView {
    private let stage = CALayer()
    private let fallback = UIImageView()
    private var shapes: [CAShapeLayer] = []
    private var prepared: PreparedRevealAnimation?
    private var kind: RevealAnimationKind?
    private var loading: Task<Void, Never>?
    private var playback = RevealIconPlayback()
    private var visibility = 0.0
    private var reduced = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(stage)
        fallback.tintColor = .white
        fallback.contentMode = .scaleAspectFit
        addSubview(fallback)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(symbol: String, visibility: Double, reduced: Bool) {
        self.visibility = visibility
        self.reduced = reduced
        let next = RevealAnimationKind(symbol: symbol)
        if kind != next || fallback.image == nil {
            loading?.cancel()
            stopLayers()
            shapes.forEach { $0.removeFromSuperlayer() }
            shapes.removeAll()
            prepared = nil
            playback = RevealIconPlayback()
            kind = next
            fallback.image = UIImage(systemName: symbol)
            fallback.isHidden = false
            if let next {
                loading = Task { [weak self] in
                    let animation = await RevealAnimationLibrary.shared.load(next)
                    guard !Task.isCancelled, let self, self.kind == next else { return }
                    if let animation { self.install(animation) }
                }
            }
        }
        updatePlayback()
    }

    private func install(_ animation: PreparedRevealAnimation) {
        prepared = animation
        shapes = animation.makeShapeLayers(color: UIColor.white.cgColor, into: stage)
        fallback.isHidden = true
        applyFrame(last: false)
        setNeedsLayout()
        updatePlayback()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallback.frame = bounds.insetBy(dx: bounds.width * 0.26, dy: bounds.height * 0.24)
        if let asset = prepared?.asset {
            stage.anchorPoint = .zero
            stage.position = .zero
            stage.bounds = CGRect(x: 0, y: 0, width: asset.canvas[0], height: asset.canvas[1])
            stage.transform = CATransform3DMakeScale(bounds.width / asset.canvas[0], bounds.height / asset.canvas[1], 1)
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLayers()
            applyFrame(last: reduced)
            playback = RevealIconPlayback()
        } else { updatePlayback() }
    }

    private func updatePlayback() {
        guard prepared != nil, window != nil else { return }
        switch playback.update(visibility: visibility, reduced: reduced) {
        case .none: break
        case .reset: stopLayers(); applyFrame(last: false)
        case .finish: stopLayers(); applyFrame(last: true)
        case .play: playOnce()
        }
    }

    private func applyFrame(last: Bool) {
        prepared?.applyFrame(last: last, to: shapes)
    }

    private func playOnce() {
        // The model stays at the final, complete icon when the animation ends.
        // No repeating timer, SwiftUI animation transaction, or completion task.
        prepared?.play(on: shapes, in: window, key: "reveal.icon")
    }
    private func stopLayers() { for shape in shapes { shape.removeAllAnimations() } }
    func stop() { loading?.cancel(); loading = nil; stopLayers() }
}
