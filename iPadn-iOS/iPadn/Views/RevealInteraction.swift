import SwiftUI
import UIKit
import Combine

// Native gesture recognizer from Telegram-iOS commit
// 24638bc69bd083981b178dd1e7f921eebbf7fc46, GPL-2.0-or-later.

/// A public-API recognizer with the reference's 25-point horizontal hysteresis.
/// It fails early on vertical movement so the hosting scroll view can take over.
final class ItemListRevealTouchGestureRecognizer: UIGestureRecognizer {
    var canBegin: ((CGPoint, CGFloat) -> Bool)?
    var horizontalIntent: (() -> Void)?
    private(set) var translation: CGFloat = 0
    private(set) var horizontalVelocity: CGFloat = 0
    private(set) var initialDirection: CGFloat = 0
    private(set) var location: CGPoint = .zero
    private var origin: CGPoint = .zero
    private var recognizedOrigin: CGFloat = 0
    private var samples: [(time: TimeInterval, x: CGFloat)] = []
    private var trackedTouch: UITouch?
    private var reportedHorizontalIntent = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = state == .began || state == .changed ? .cancelled : .failed
            return
        }
        trackedTouch = touch
        origin = touch.location(in: view); location = origin
        recognizedOrigin = origin.x
        samples = [(touch.timestamp, origin.x)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for point in event.coalescedTouches(for: touch) ?? [touch] { sample(point) }
        let dx = location.x - origin.x, dy = location.y - origin.y
        if state == .possible {
            if abs(dy) > 10 && abs(dy) >= abs(dx) { state = .failed; return }
            // Telegram's context gesture permits simultaneous non-pan gestures.
            // Cancel its pending long press on movement, without beginning the
            // reveal before the reference's 25-point recognition threshold.
            if !reportedHorizontalIntent && abs(dx) > 10 && abs(dx) > abs(dy) && canBegin?(origin, dx < 0 ? -1 : 1) != false {
                reportedHorizontalIntent = true
                horizontalIntent?()
            }
            if abs(dx) >= 25.0 && abs(dx) > abs(dy) {
                initialDirection = dx < 0 ? -1 : 1
                if let canBegin = self.canBegin, !canBegin(self.origin, self.initialDirection) {
                    self.state = .failed
                    return
                }
                // UIPan's observed translation starts at zero after its hysteresis.
                recognizedOrigin = origin.x + (dx < 0 ? -1 : 1) * 25.0
                translation = location.x - recognizedOrigin
                state = .began
            }
        } else if state == .began || state == .changed {
            translation = location.x - recognizedOrigin
            state = .changed
        }
    }

    private func sample(_ touch: UITouch) {
        let point = touch.location(in: view)
        location = point
        samples.append((touch.timestamp, point.x))
        samples.removeAll { touch.timestamp - $0.time > 0.08 }
        // Least-squares velocity tolerates coalesced samples and uneven event intervals.
        let count = CGFloat(samples.count)
        guard count > 1 else { return }
        let firstTime = samples[0].time
        let meanT = samples.reduce(0.0) { $0 + ($1.time - firstTime) } / Double(count)
        let meanX = samples.reduce(CGFloat.zero) { $0 + $1.x } / count
        var numerator = 0.0, denominator = 0.0
        for s in samples {
            let t = s.time - firstTime - meanT
            numerator += t * Double(s.x - meanX); denominator += t * t
        }
        if denominator > 0.000001 { horizontalVelocity = numerator / denominator }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        // UIPan retains the last movement velocity while a stationary finger is
        // held. The reference's ended callback confirms this; don't zero on lift.
        state = state == .began || state == .changed ? .ended : .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .began || state == .changed ? .cancelled : .failed
    }
    override func reset() {
        super.reset(); trackedTouch = nil; samples.removeAll(keepingCapacity: true)
        translation = 0; horizontalVelocity = 0; initialDirection = 0; location = .zero
        reportedHorizontalIntent = false
    }
}

private struct RevealGestureAttachment: UIViewRepresentable {
    let enabled: Bool
    let offset: CGFloat
    let close: () -> Void
    let changed: (UIGestureRecognizer.State, CGFloat, CGFloat, CGPoint, CGFloat) -> Void
    final class Anchor: UIView {
        var moved: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); moved?() }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RevealGestureAttachment
        weak var anchor: Anchor?
        weak var host: UIView?
        let recognizer = ItemListRevealTouchGestureRecognizer()
        let closeTap = UITapGestureRecognizer()
        init(_ parent: RevealGestureAttachment) {
            self.parent = parent
            super.init()
            recognizer.addTarget(self, action: #selector(handle))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = true
            closeTap.addTarget(self, action: #selector(closeRow))
            closeTap.delegate = self
            closeTap.require(toFail: recognizer)
            recognizer.canBegin = { [weak self] origin, direction in
                guard let self, let anchor = self.anchor, let host = self.host, self.parent.enabled else { return false }
                let point = anchor.convert(origin, from: host)
                return !(point.x < 20 && direction > 0)
            }
            recognizer.horizontalIntent = { [weak self] in self?.cancelRowPresses() }
        }
        private func cancelRowPresses() {
            guard let host else { return }
            var views = [host]
            while let view = views.popLast() {
                views.append(contentsOf: view.subviews)
                for other in view.gestureRecognizers ?? [] where other !== recognizer && other !== closeTap && !(other is UIPanGestureRecognizer) {
                    other.isEnabled = false; other.isEnabled = true
                }
            }
        }
        func install() {
            guard let anchor, anchor.window != nil else { detach(); return }
            var candidate: UIView? = anchor.superview
            var cell: UIView?
            var scroll: UIScrollView?
            while let view = candidate {
                if cell == nil && (view is UICollectionViewCell || view is UITableViewCell) { cell = view }
                if scroll == nil, let view = view as? UIScrollView { scroll = view }
                candidate = view.superview
            }
            guard let target = cell ?? anchor.window else { return }
            if host !== target {
                detach(); host = target
                target.addGestureRecognizer(recognizer)
                target.addGestureRecognizer(closeTap)
                scroll?.panGestureRecognizer.require(toFail: recognizer)
                #if DEBUG
                print("Reveal host: \(type(of: target)); bounds: \(anchor.bounds)")
                #endif
            }
            if recognizer.isEnabled != parent.enabled { recognizer.isEnabled = parent.enabled }
            let canClose = parent.enabled && abs(parent.offset) > 1
            if closeTap.isEnabled != canClose { closeTap.isEnabled = canClose }
        }
        func detach() {
            recognizer.isEnabled = false; closeTap.isEnabled = false
            host?.removeGestureRecognizer(recognizer); host?.removeGestureRecognizer(closeTap); host = nil
        }
        @objc private func closeRow() { parent.close() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard parent.enabled, let anchor else { return false }
            let point = touch.location(in: anchor)
            guard anchor.bounds.contains(point) else { return false }
            // The exposed operation stays a normal button, not a new swipe.
            if parent.offset < 0 && point.x > anchor.bounds.width + parent.offset { return false }
            if parent.offset > 0 && point.x < parent.offset { return false }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Let the native recognizer observe movement while SwiftUI's
            // press recognizer is active; horizontal intent cancels that press.
            !(otherGestureRecognizer is UIPanGestureRecognizer)
        }
        @objc private func handle() {
            guard let anchor, let host else { return }
            #if DEBUG
            if recognizer.state != .changed { print("Reveal event: \(recognizer.state.rawValue), translation: \(recognizer.translation)") }
            #endif
            parent.changed(recognizer.state, recognizer.translation, recognizer.horizontalVelocity,
                           anchor.convert(recognizer.location, from: host), recognizer.initialDirection)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        context.coordinator.anchor = view
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.install() }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.parent = self
        context.coordinator.install()
    }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.detach(); view.moved = nil }
}


/// A single owner across tabs: opening another row closes the previous one.
@MainActor
private final class RevealCoordinator: ObservableObject {
    static let shared = RevealCoordinator()
    @Published var active: String?
}

/// Only the actively moving row gets display-link updates. Telegram's pure
/// motion model supplies resistance, velocity transfer and interruptible springs.
@MainActor
private final class RevealDriver: NSObject, ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var blocksPress = false
    private var pressReset: Task<Void, Never>?
    private var motion = ItemListRevealMotion()
    private var direction: CGFloat = 1
    private var displayLink: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var reduced = false
    private var feedback: UISelectionFeedbackGenerator?
    @MainActor private final class Target: NSObject {
        weak var owner: RevealDriver?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private let target = Target()
    var dragging: Bool { motion.state == .dragging }
    var actionScale: CGFloat { CGFloat(motion.buttonGeometry.first?.scale ?? 0) }
    var actionOpacity: Double { motion.buttonGeometry.first?.opacity ?? 0 }
    var actionWidth: CGFloat { CGFloat(motion.buttonGeometry.first?.width ?? 56) }

    func begin(width: CGFloat, direction: CGFloat, reduced: Bool, actionWidth: CGFloat) {
        pressReset?.cancel(); blocksPress = true
        self.direction = direction; self.reduced = reduced
        var parameters = ItemListRevealMotionParameters()
        parameters.width = Double(width); parameters.count = 1
        parameters.buttonWidth = Double(actionWidth); parameters.isDestructive = true
        parameters.displayScale = Double(UIScreen.main.scale)
        motion.configure(parameters)
        motion.begin()
        if !reduced { feedback = UISelectionFeedbackGenerator(); feedback?.prepare() }
    }
    func change(translation: CGFloat, velocity: CGFloat, distanceFromEdge: CGFloat) {
        let armed = motion.isArmed
        motion.change(translation: Double(translation * direction), velocity: Double(velocity * direction),
                      distanceFromCommitEdge: Double(distanceFromEdge), reduceMotion: reduced)
        if armed != motion.isArmed { feedback?.selectionChanged(); feedback?.prepare() }
        render(); animate()
    }
    func end(translation: CGFloat, velocity: CGFloat) -> Bool {
        let commit = motion.end(translation: Double(translation * direction), velocity: Double(velocity * direction), cancelled: false, animated: !reduced)
        feedback = nil; render(); animate(); releasePress()
        return commit
    }
    func close(immediately: Bool = false) {
        motion.settle(to: 0, velocity: 0, animated: !immediately && !reduced)
        feedback = nil; render()
        if immediately || reduced { stop() } else { animate() }
        if immediately { pressReset?.cancel(); blocksPress = false } else { releasePress() }
    }
    private func releasePress() {
        guard blocksPress else { return }
        pressReset?.cancel()
        pressReset = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.blocksPress = false
        }
    }
    private func render() { offset = CGFloat(max(0, motion.body.value)) * direction }
    private func animate() {
        guard !reduced, !motion.isAtRest, displayLink == nil else { return }
        target.owner = self; lastTime = 0
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common); displayLink = link
    }
    private func tick(_ link: CADisplayLink) {
        let dt = lastTime == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastTime
        lastTime = link.timestamp
        motion.advance(by: min(0.05, max(0, dt))); render()
        if motion.isAtRest { stop() }
    }
    private func stop() { displayLink?.invalidate(); displayLink = nil; lastTime = 0 }
    deinit { displayLink?.invalidate(); pressReset?.cancel() }
}

enum RevealActionStyle { case compact, round }

private struct RevealDeleteModifier: ViewModifier {
    let id: String
    let enabled: Bool
    let title: String
    let style: RevealActionStyle
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var actionSize: CGFloat = 52
    @ScaledMetric(relativeTo: .subheadline) private var compactHeight: CGFloat = 36
    @StateObject private var driver = RevealDriver()
    @ObservedObject private var coordinator = RevealCoordinator.shared
    @State private var width: CGFloat = 0
    @State private var direction: CGFloat = 1
    @State private var lastVisibleY: CGFloat?

    func body(content: Content) -> some View {
        let isActive = coordinator.active == id
        return content
            // Disabling the original control cancels an in-flight SwiftUI
            // press; hit-testing alone still submits that press on touch-up.
            .disabled(driver.blocksPress || abs(driver.offset) > 1)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: style == .compact ? compactHeight * (60.0 / 36) : actionSize * (76.0 / 52), alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .offset(x: driver.offset)
            .overlay(alignment: driver.offset >= 0 ? .leading : .trailing) {
                if abs(driver.offset) > 1 {
                    Button(role: .destructive, action: commit) {
                        Group {
                            if style == .compact {
                                Text(title).font(.subheadline).foregroundStyle(.white)
                                    .frame(width: max(actionSize, driver.actionWidth), height: compactHeight)
                                    .background(Color.red, in: Capsule())
                            } else {
                                VStack(spacing: 6 * actionSize / 52) {
                                    Image(systemName: "trash.fill").font(.system(size: 24 * actionSize / 52, weight: .regular)).foregroundStyle(.white)
                                        .frame(width: driver.actionWidth, height: actionSize)
                                        .background(Color.red, in: Capsule())
                                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                            .scaleEffect(reduceMotion ? 1 : driver.actionScale)
                            .opacity(reduceMotion ? 1 : driver.actionOpacity)
                            .frame(width: max(0, abs(driver.offset)))
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(title).accessibilityElement(children: .ignore)
                }
            }
            .clipped()
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onGeometryChange(for: CGFloat?.self) { geometry in
                isActive ? geometry.frame(in: .global).minY : nil
            } action: { y in
                if let y, let previous = lastVisibleY, abs(y - previous) > 1 { coordinator.active = nil }
                lastVisibleY = y
            }
            .background {
                RevealGestureAttachment(enabled: enabled, offset: driver.offset, close: { coordinator.active = nil }) { state, translation, velocity, location, initialDirection in
                    switch state {
                    case .began:
                        direction = driver.offset == 0 ? initialDirection : (driver.offset > 0 ? 1 : -1)
                        coordinator.active = id
                        driver.begin(width: width, direction: direction, reduced: reduceMotion, actionWidth: actionSize)
                        driver.change(translation: translation, velocity: velocity, distanceFromEdge: direction > 0 ? width - location.x : location.x)
                    case .changed:
                        driver.change(translation: translation, velocity: velocity, distanceFromEdge: direction > 0 ? width - location.x : location.x)
                    case .ended:
                        if driver.end(translation: translation, velocity: velocity) { commit() }
                    case .cancelled, .failed:
                        if driver.dragging { driver.close() }
                    default: break
                    }
                }
            }
            .onChange(of: coordinator.active) { _, active in if active != id { driver.close() } }
            .onChange(of: enabled) { _, enabled in if !enabled { driver.close(immediately: true) } }
            .onChange(of: reduceMotion) { _, _ in driver.close(immediately: true) }
            .onDisappear { driver.close(immediately: true) }
            .accessibilityAction(named: Text(title)) { if enabled { commit() } }
    }
    private func commit() {
        guard enabled else { return }
        coordinator.active = nil; driver.close()
        action()
    }
}

extension View {
    func dismissRevealsWhenTabChanges(_ tab: Int) -> some View {
        onChange(of: tab) { _, _ in RevealCoordinator.shared.active = nil }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                RevealCoordinator.shared.active = nil
            }
    }
    func revealDelete(id: String, enabled: Bool = true, style: RevealActionStyle = .round, title: String = "删除", action: @escaping () -> Void) -> some View {
        modifier(RevealDeleteModifier(id: id, enabled: enabled, title: title, style: style, action: action))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
