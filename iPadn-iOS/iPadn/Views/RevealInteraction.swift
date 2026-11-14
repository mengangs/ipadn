import SwiftUI
import UIKit
import Combine
#if DEBUG
import os
#endif

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

/// Recognizes taps outside the currently revealed row without adding a
/// hit-test blocking view over the window, so list scrolling and swiping
/// another row start uninterrupted in the exact same touch while outside taps
/// still dismiss the open row without firing underlying controls.
final class RevealOutsideDismissGestureRecognizer: UIGestureRecognizer {
    static let maxTapMovement: CGFloat = 10
    private var origin: CGPoint = .zero
    private var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = true
        delaysTouchesEnded = true
        cancelsTouchesInView = true
    }

    func beginTracking(at point: CGPoint) {
        origin = point
    }

    func updateTracking(at point: CGPoint) {
        if hypot(point.x - origin.x, point.y - origin.y) > Self.maxTapMovement {
            state = .failed
        }
    }

    func finishTracking(at point: CGPoint) {
        state = hypot(point.x - origin.x, point.y - origin.y) <= Self.maxTapMovement ? .ended : .failed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        trackedTouch = touch
        beginTracking(at: touch.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        updateTracking(at: touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        finishTracking(at: touch.location(in: view))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        origin = .zero
    }
}

/// Manages the single active outside-dismiss recognizer on the window while a
/// row is open. Synchronous `dismissCurrent()` guarantees stale owners can
/// never leave an active tap interceptor installed.
@MainActor
final class RevealDismissOverlay: NSObject, UIGestureRecognizerDelegate {
    private static weak var current: RevealDismissOverlay?
    /// Called synchronously before deleting or switching a row; do not wait for
    /// SwiftUI to dismantle an animated List cell to release the interceptor.
    static func dismissCurrent() {
        current?.detach()
        current = nil
    }

    var isValid: () -> Bool = { true }
    /// The open row's frame in host (window) coordinates; touches there pass through.
    var rowFrame: () -> CGRect? = { nil }
    var onTap: () -> Void = {}

    private weak var hostView: UIView?
    let recognizer = RevealOutsideDismissGestureRecognizer()

    override init() {
        super.init()
        Self.dismissCurrent()
        Self.current = self
        recognizer.addTarget(self, action: #selector(tapped))
        recognizer.delegate = self
    }

    func install(on view: UIView) {
        if hostView !== view {
            detach()
            hostView = view
            view.addGestureRecognizer(recognizer)
        }
        if Self.current !== self {
            Self.dismissCurrent()
            Self.current = self
        }
    }

    func detach() {
        recognizer.isEnabled = false
        hostView?.removeGestureRecognizer(recognizer)
        hostView = nil
        recognizer.isEnabled = true
        if Self.current === self { Self.current = nil }
    }

    var isInstalled: Bool { recognizer.view != nil }

    /// Returns whether a touch at `point` (in `hostView` coordinates) should be
    /// tracked as an outside dismiss candidate. Detaches synchronously if stale.
    func shouldReceivePoint(_ point: CGPoint) -> Bool {
        guard isValid(), let row = rowFrame(), !row.isEmpty else {
            detach()
            return false
        }
        return !row.contains(point)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let hostView else {
            detach()
            return false
        }
        return shouldReceivePoint(touch.location(in: hostView))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is ItemListRevealTouchGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UIPanGestureRecognizer { return false }
        if otherGestureRecognizer is ItemListRevealTouchGestureRecognizer { return false }
        if otherGestureRecognizer is UISwipeGestureRecognizer { return false }
        if let view = recognizer.view, otherGestureRecognizer.view === view { return false }
        return true
    }

    @objc private func tapped() {
        guard recognizer.state == .ended else { return }
        detach()
        onTap()
    }
}

private struct RevealGestureAttachment: UIViewRepresentable {
    let enabled: Bool
    let revealing: Bool
    let isOwner: () -> Bool
    let currentOffset: () -> CGFloat
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
        private weak var observedScrollPan: UIPanGestureRecognizer?
        let recognizer = ItemListRevealTouchGestureRecognizer()
        let closeTap = UITapGestureRecognizer()
        private var dismissOverlay: RevealDismissOverlay?
        /// Inset-grouped Lists also mask the UIKit cell/hosting ancestors.
        /// Our moving card supplies its own rounded mask; temporarily remove
        /// only those ancestor masks, never the scroll view's viewport.
        @MainActor private final class SavedClipping {
            weak var view: UIView?
            let clips: Bool
            let mask: CALayer?
            init(_ view: UIView) {
                self.view = view; clips = view.clipsToBounds; mask = view.layer.mask
            }
            func restore() {
                guard let view else { return }
                view.clipsToBounds = clips
                if view.layer.mask == nil { view.layer.mask = mask }
            }
        }
        private var savedClipping: [SavedClipping] = []
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
                // Leave the leading edge to the system's back swipe.
                return !(self.layoutX(point.x) < 20 && self.layoutSign * direction > 0)
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
            if let host, anchor.isDescendant(of: host) {
                attachScrollPanIfNeeded(from: anchor)
                updateEnabledState()
                return
            }
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
            observeScrollPan(scroll?.panGestureRecognizer)
            updateEnabledState()
        }
        private func attachScrollPanIfNeeded(from view: UIView) {
            guard observedScrollPan == nil else { return }
            var candidate = view.superview
            while let current = candidate {
                if let scroll = current as? UIScrollView {
                    observeScrollPan(scroll.panGestureRecognizer)
                    return
                }
                candidate = current.superview
            }
        }
        private func observeScrollPan(_ pan: UIPanGestureRecognizer?) {
            guard observedScrollPan !== pan else { return }
            observedScrollPan?.removeTarget(self, action: #selector(handleScrollPan(_:)))
            observedScrollPan = pan
            pan?.addTarget(self, action: #selector(handleScrollPan(_:)))
        }
        @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
            guard parent.enabled, parent.revealing, parent.isOwner(), pan.state == .began else { return }
            parent.close()
        }
        private func updateEnabledState() {
            if recognizer.isEnabled != parent.enabled { recognizer.isEnabled = parent.enabled }
            let isOwner = parent.isOwner()
            let canClose = parent.enabled && parent.revealing && isOwner
            updateClipping(revealing: parent.revealing)
            if closeTap.isEnabled != canClose { closeTap.isEnabled = canClose }
            if canClose, let window = anchor?.window { showDismissOverlay(in: window) }
            else if !canClose { hideDismissOverlay() }
        }
        private func updateClipping(revealing: Bool) {
            guard revealing else {
                if !savedClipping.isEmpty { restoreClipping() }
                return
            }
            guard savedClipping.isEmpty else { return }
            var ancestor = anchor?.superview
            while let view = ancestor, !(view is UIScrollView), !(view is UIWindow) {
                savedClipping.append(SavedClipping(view))
                view.clipsToBounds = false
                view.layer.mask = nil
                ancestor = view.superview
            }
        }
        private func restoreClipping() {
            for state in savedClipping.reversed() { state.restore() }
            savedClipping.removeAll()
        }
        func detach() {
            recognizer.isEnabled = false; closeTap.isEnabled = false
            restoreClipping()
            hideDismissOverlay()
            observedScrollPan?.removeTarget(self, action: #selector(handleScrollPan(_:)))
            observedScrollPan = nil
            host?.removeGestureRecognizer(recognizer); host?.removeGestureRecognizer(closeTap); host = nil
        }
        @objc private func closeRow() { parent.close() }
        private func showDismissOverlay(in window: UIWindow) {
            if let existing = dismissOverlay, existing.isInstalled { return }
            let overlay = RevealDismissOverlay()
            overlay.isValid = { [weak self, weak window] in
                guard let self, let window else { return false }
                return self.parent.enabled && abs(self.parent.currentOffset()) > 1
                    && self.parent.isOwner()
                    && self.anchor?.window === window && self.host?.window === window
            }
            overlay.rowFrame = { [weak self] in
                guard let self, let window = self.anchor?.window else { return nil }
                let row: UIView? = (self.host === window || self.host == nil) ? (self.anchor?.superview ?? self.anchor) : self.host
                return row?.convert(row?.bounds ?? .zero, to: window)
            }
            overlay.onTap = { [weak self] in
                self?.hideDismissOverlay()
                self?.parent.close()
            }
            overlay.install(on: window)
            dismissOverlay = overlay
        }
        private func hideDismissOverlay() {
            dismissOverlay?.detach()
            dismissOverlay = nil
        }
        /// UIKit reports touches left to right, while SwiftUI mirrors offsets
        /// and edges in a right-to-left layout; these map touches into the
        /// layout's direction so a swipe follows the finger in Arabic too.
        private var layoutSign: CGFloat {
            anchor?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        }
        private func layoutX(_ x: CGFloat) -> CGFloat {
            guard let anchor, layoutSign < 0 else { return x }
            return anchor.bounds.width - x
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard parent.enabled, let anchor else { return false }
            let point = touch.location(in: anchor)
            guard anchor.bounds.contains(point) else { return false }
            let x = layoutX(point.x)
            // The exposed operation stays a normal button, not a new swipe.
            let offset = parent.currentOffset()
            if offset < 0 && x > anchor.bounds.width + offset { return false }
            if offset > 0 && x < offset { return false }
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
            let location = anchor.convert(recognizer.location, from: host)
            parent.changed(recognizer.state, layoutSign * recognizer.translation, layoutSign * recognizer.horizontalVelocity,
                           CGPoint(x: layoutX(location.x), y: location.y), layoutSign * recognizer.initialDirection)
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


/// A single owner across tabs: opening another row closes the previous one
/// directly via its callback instead of broadcasting `@Published` invalidations
/// to every visible row in the list.
@MainActor
private final class RevealCoordinator {
    static let shared = RevealCoordinator()
    private init() { Task { await RevealAnimationLibrary.shared.preload() } }
    private var closers: [String: (Bool) -> Void] = [:]
    private(set) var active: String?

    func activate(_ id: String, close: @escaping (Bool) -> Void) {
        if let previous = active, previous != id {
            RevealDismissOverlay.dismissCurrent()
            closers.removeValue(forKey: previous)?(UIApplication.shared.applicationState != .active)
        }
        active = id
        closers[id] = close
    }

    func clear(_ id: String? = nil, immediately: Bool? = nil) {
        guard let current = active, id == nil || id == current else { return }
        active = nil
        RevealDismissOverlay.dismissCurrent()
        closers.removeValue(forKey: current)?(immediately ?? (UIApplication.shared.applicationState != .active))
    }

    /// Releases ownership and removes the outside-dismiss recognizer without
    /// pulling a row back to 0 when it is sweeping off via `.filling`.
    func relinquish(_ id: String) {
        guard active == id else { return }
        active = nil
        closers.removeValue(forKey: id)
        RevealDismissOverlay.dismissCurrent()
    }
}

/// Only the actively moving row gets display-link updates. Telegram's pure
/// motion model supplies resistance, velocity transfer and interruptible springs.
@MainActor
private final class RevealDriver: NSObject, ObservableObject {
    /// One revealed button: its center measured from the row's outer edge.
    struct ButtonFrame: Equatable {
        var center: CGFloat
        var width: CGFloat
        var scale: CGFloat
        var opacity: Double
    }
    private struct Presentation: Equatable {
        var offset: CGFloat = 0
        var scale: CGFloat = 0
        var opacity: Double = 0
        var actionWidth: CGFloat = 52
        var rounding: CGFloat = 0
        var buttons: [ButtonFrame] = []
    }
    @Published private var presentation = Presentation()
    @Published private(set) var blocksPress = false
    @Published private(set) var isFilling = false
    private var pressReset: Task<Void, Never>?
    private var motion = ItemListRevealMotion()
    private var direction: CGFloat = 1
    private var displayLink: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var lastVelocity: CGFloat = 0
    private var reduced = false
    private var feedback: UISelectionFeedbackGenerator?
    #if DEBUG
    private let measuresFrames = ProcessInfo.processInfo.arguments.contains("--reveal-metrics")
    private var frameCallbacks = 0
    private var presentations = 0
    private var delayedFrames = 0
    private var worstInterval: Double = 0
    #endif
    @MainActor private final class Target: NSObject {
        weak var owner: RevealDriver?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private let target = Target()
    var dragging: Bool { motion.state == .dragging }
    var offset: CGFloat { presentation.offset }
    var actionScale: CGFloat { presentation.scale }
    var actionOpacity: Double { presentation.opacity }
    var actionWidth: CGFloat { presentation.actionWidth }
    var rounding: CGFloat { presentation.rounding }
    var buttons: [ButtonFrame] { presentation.buttons }

    func begin(width: CGFloat, direction: CGFloat, reduced: Bool, actionWidth: CGFloat, count: Int = 1) {
        #if DEBUG
        frameCallbacks = 0; presentations = 0; delayedFrames = 0; worstInterval = 0
        #endif
        pressReset?.cancel(); blocksPress = true; isFilling = false; lastVelocity = 0
        self.direction = direction; self.reduced = reduced
        var parameters = ItemListRevealMotionParameters()
        parameters.width = Double(width); parameters.count = max(1, count)
        parameters.buttonWidth = Double(actionWidth); parameters.isDestructive = true
        parameters.displayScale = Double(UIScreen.main.scale)
        motion.configure(parameters)
        motion.begin()
        if !reduced { feedback = UISelectionFeedbackGenerator(); feedback?.prepare() }
    }
    func change(translation: CGFloat, velocity: CGFloat, distanceFromEdge: CGFloat) {
        lastVelocity = velocity
        let armed = motion.isArmed
        motion.change(translation: Double(translation * direction), velocity: Double(velocity * direction),
                      distanceFromCommitEdge: Double(distanceFromEdge), reduceMotion: reduced)
        if armed != motion.isArmed { feedback?.selectionChanged(); feedback?.prepare() }
        schedulePresentation()
    }
    func end(translation: CGFloat, velocity: CGFloat) -> Bool {
        lastVelocity = velocity
        let commit = motion.end(translation: Double(translation * direction), velocity: Double(velocity * direction), cancelled: false, animated: !reduced)
        feedback = nil; schedulePresentation(); releasePress()
        return commit
    }
    func fill(width: CGFloat, velocity: CGFloat? = nil) {
        guard !isFilling else { return }
        isFilling = true
        pressReset?.cancel(); blocksPress = true
        var parameters = motion.parameters
        if width > 0 { parameters.width = Double(width) }
        motion.configure(parameters)
        let target = max(Double(width), parameters.openDistance)
        let fillVelocity = max(Double(abs(velocity ?? lastVelocity)), 1400)
        motion.settle(to: target, velocity: fillVelocity, animated: !reduced, filling: true)
        feedback = nil
        if reduced { render(); stop() } else { schedulePresentation() }
    }
    func close(immediately: Bool = false) {
        isFilling = false
        motion.settle(to: 0, velocity: 0, animated: !immediately && !reduced)
        feedback = nil
        if immediately || reduced { render(); stop() } else { schedulePresentation() }
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
    private func render() {
        let all = motion.buttonGeometry
        let geometry = all.first
        let next = Presentation(offset: CGFloat(max(0, motion.body.value)) * direction,
                                scale: CGFloat(geometry?.scale ?? 0), opacity: geometry?.opacity ?? 0,
                                actionWidth: CGFloat(geometry?.width ?? 52),
                                rounding: min(1, max(0, CGFloat(motion.surface.value))),
                                buttons: all.map { ButtonFrame(center: CGFloat($0.center), width: CGFloat($0.width),
                                                               scale: CGFloat($0.scale), opacity: $0.opacity) })
        guard next != presentation else { return }
        #if DEBUG
        if measuresFrames { presentations += 1 }
        #endif
        presentation = next
    }
    private func schedulePresentation() {
        // Touch callbacks only update the model. Publish the latest complete
        // frame once at the display boundary, rather than twice per refresh.
        if reduced || (!dragging && motion.isAtRest) { render(); stop() }
        else { animate() }
    }
    private func animate() {
        guard !reduced, (dragging || !motion.isAtRest), displayLink == nil else { return }
        target.owner = self; lastTime = 0
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common); displayLink = link
    }
    private func tick(_ link: CADisplayLink) {
        let dt = lastTime == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastTime
        #if DEBUG
        if measuresFrames {
            frameCallbacks += 1
            worstInterval = max(worstInterval, dt)
            if dt > (link.targetTimestamp - link.timestamp) * 1.5 { delayedFrames += 1 }
        }
        #endif
        lastTime = link.timestamp
        // These springs use an analytic solution, not Euler integration.
        // Consume real elapsed time: capping it makes a dropped frame slow
        // dismissal down and leaves the row disabled long after the tap.
        motion.advance(by: dt); render()
        if !dragging && motion.isAtRest { stop() }
    }
    private func stop() {
        #if DEBUG
        if measuresFrames && displayLink != nil && !dragging && frameCallbacks > 0 {
            let summary = "Reveal metrics: callbacks=\(frameCallbacks), presentations=\(presentations), delayed=\(delayedFrames), worst-ms=\(worstInterval * 1000)"
            print(summary)
            Logger(subsystem: "app.local.iPadn", category: "Reveal").notice("\(summary, privacy: .public)")
        }
        #endif
        displayLink?.invalidate(); displayLink = nil; lastTime = 0
    }
    deinit { displayLink?.invalidate(); pressReset?.cancel() }
}

enum RevealActionStyle { case compact, round }

/// A button revealed by swiping a row. The first is the primary one: at the
/// outer edge, and what a full swipe does (Telegram's chat list does the same).
struct RevealAction {
    var title: LocalizedStringKey
    var systemImage: String
    var tint: Color
    var role: ButtonRole?
    var fillsOnCommit: Bool = false
    var action: () -> Void

    static func delete(_ title: LocalizedStringKey = "删除", fills: Bool = false, action: @escaping () -> Void) -> RevealAction {
        RevealAction(title: title, systemImage: "trash.fill", tint: .red, role: .destructive, fillsOnCommit: fills, action: action)
    }
}
enum RevealRowGrouping { case standalone, first, middle }

private struct RevealSuppressesPressKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Interaction is temporarily cancelled by a reveal, not unavailable.
    var revealSuppressesPress: Bool {
        get { self[RevealSuppressesPressKey.self] }
        set { self[RevealSuppressesPressKey.self] = newValue }
    }
}

/// Keep the normal row appearance while its original control is cancelled.
/// The Button itself remains disabled; only its noninteractive label renders
/// with the normal enabled appearance. Genuine disabled states still fade.
struct RevealRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.revealSuppressesPress) private var suppressesPress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && !suppressesPress
        configuration.label
            .environment(\.isEnabled, enabled || suppressesPress)
            .opacity(enabled || suppressesPress ? (pressed ? 0.6 : 1) : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.06 : 0.16), value: pressed)
    }
}

private struct RevealDeleteModifier: ViewModifier {
    let id: String
    let enabled: Bool
    let grouping: RevealRowGrouping
    /// Leading inset of the hairline under a grouped row; nil draws none.
    let separatorInset: CGFloat?
    let style: RevealActionStyle
    let restored: Bool
    let actions: [RevealAction]
    private var primary: RevealAction { actions[0] }
    private var title: LocalizedStringKey { primary.title }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .caption) private var actionSize: CGFloat = 52
    @ScaledMetric(relativeTo: .subheadline) private var compactHeight: CGFloat = 36
    @StateObject private var driver = RevealDriver()
    @State private var width: CGFloat = 0
    @State private var direction: CGFloat = 1
    @State private var lastVisibleY: CGFloat?


    private func cardShape(rounding: CGFloat) -> CompatibleCardShape {
        let top: CGFloat = grouping == .middle ? 24 * rounding : 24
        let bottom: CGFloat = grouping == .standalone ? 24 : 24 * rounding
        return CompatibleCardShape(top: top, bottom: bottom)
    }

    func body(content: Content) -> some View {
        let isRevealing = abs(driver.offset) > 1 || driver.dragging
        let cardRounding: CGFloat = grouping == .standalone ? 1 : driver.rounding
        return content
            .buttonStyle(RevealRowButtonStyle())
            .environment(\.revealSuppressesPress, driver.blocksPress || driver.isFilling || abs(driver.offset) > 1)
            // Disabling the original control cancels an in-flight SwiftUI
            // press; hit-testing alone still submits that press on touch-up.
            .disabled(driver.blocksPress || driver.isFilling || abs(driver.offset) > 1)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: style == .compact ? compactHeight * (60.0 / 36) : actionSize * (76.0 / 52), alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape(rounding: cardRounding))
            .overlay {
                cardShape(rounding: cardRounding)
                    .fill(UX.tint.opacity(restored && !reduceMotion ? 0.045 : 0))
                    .overlay {
                        cardShape(rounding: cardRounding)
                            .stroke(UX.tint.opacity(restored && !reduceMotion ? 0.28 : 0), lineWidth: 1.25)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: restored)
                    .allowsHitTesting(false)
            }
            // Clip the surface before translating it, so its background, content
            // and rounded edge move as one. A stationary clip here would shear
            // the translated card at the original row's boundaries.
            .clipShape(cardShape(rounding: cardRounding))
            .offset(x: driver.offset)
            .overlay(alignment: driver.offset >= 0 ? .leading : .trailing) {
                if abs(driver.offset) > 1 && actions.count > 1 {
                    // Several buttons, each where the shared motion model puts it.
                    GeometryReader { box in
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                            if index < driver.buttons.count {
                                let frame = driver.buttons[index]
                                actionButton(item, frame: frame)
                                    .position(x: driver.offset < 0 ? box.size.width - frame.center : frame.center,
                                              y: box.size.height / 2)
                            }
                        }
                    }
                    .frame(width: max(0, abs(driver.offset)))
                    .clipped() // Only the revealed controls have a stationary viewport.
                } else if abs(driver.offset) > 1 {
                    Button(role: .destructive, action: commit) {
                        Group {
                            if style == .compact {
                                Text(title).font(.subheadline).foregroundStyle(.white)
                                    .frame(width: max(actionSize, driver.actionWidth), height: compactHeight)
                                    .background(Color.red, in: Capsule())
                            } else {
                                VStack(spacing: 6 * actionSize / 52) {
                                    RevealActionIcon(symbol: "trash.fill", visibility: RevealActionIcon.quantizedVisibility(min(Double(driver.actionScale), driver.actionOpacity)))
                                        .frame(width: actionSize, height: actionSize)
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
                        .clipped()
                }
            }
            .padding(.vertical, 2)
            .background {
                if grouping != .standalone {
                    // Join the resting accounts to the native Add Account row.
                    // The same reference spring rounds and detaches only the
                    // row being dragged; the remaining group stays intact.
                    cardShape(rounding: 0).fill(Color(.secondarySystemGroupedBackground))
                        .overlay(alignment: .bottom) {
                            if let separatorInset {
                                Rectangle().fill(Color(.separator)).frame(height: 1 / displayScale)
                                    .padding(.leading, separatorInset)
                            }
                        }
                        .opacity(1 - driver.rounding)
                }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onGeometryChange(for: CGFloat?.self) { geometry in
                isRevealing ? geometry.frame(in: .global).minY : nil
            } action: { y in
                if let y, let previous = lastVisibleY, abs(y - previous) > 1 { RevealCoordinator.shared.clear(id, immediately: false) }
                lastVisibleY = y
            }
            .background {
                RevealGestureAttachment(enabled: enabled && !driver.isFilling, revealing: abs(driver.offset) > 1, isOwner: { RevealCoordinator.shared.active == id }, currentOffset: { driver.offset }, close: { RevealCoordinator.shared.clear(id, immediately: false) }) { state, translation, velocity, location, initialDirection in
                    switch state {
                    case .began:
                        direction = driver.offset == 0 ? initialDirection : (driver.offset > 0 ? 1 : -1)
                        RevealCoordinator.shared.activate(id) { [driver] immediately in
                            driver.close(immediately: immediately)
                        }
                        driver.begin(width: width, direction: direction, reduced: reduceMotion, actionWidth: actionSize, count: actions.count)
                        driver.change(translation: translation, velocity: velocity, distanceFromEdge: direction > 0 ? width - location.x : location.x)
                    case .changed:
                        driver.change(translation: translation, velocity: velocity, distanceFromEdge: direction > 0 ? width - location.x : location.x)
                    case .ended:
                        if driver.end(translation: translation, velocity: velocity) { commit() }
                    case .cancelled, .failed:
                        if driver.dragging {
                            if RevealCoordinator.shared.active == id { RevealCoordinator.shared.clear(id, immediately: false) }
                            else { driver.close() }
                        }
                    default: break
                    }
                }
            }
            .compatibleOnChange(of: enabled) { enabled in
                if !enabled {
                    RevealCoordinator.shared.clear(id, immediately: true)
                    driver.close(immediately: true)
                }
            }
            .compatibleOnChange(of: reduceMotion) { _ in
                RevealCoordinator.shared.clear(id, immediately: true)
                driver.close(immediately: true)
            }
            .onAppear {
                if driver.isFilling || (abs(driver.offset) > 1 && RevealCoordinator.shared.active != id) {
                    driver.close(immediately: true)
                }
            }
            .compatibleOnChange(of: restored) { isRestored in
                if isRestored && (driver.isFilling || abs(driver.offset) > 1) {
                    RevealCoordinator.shared.relinquish(id)
                    driver.close(immediately: true)
                }
            }
            .onDisappear {
                RevealCoordinator.shared.clear(id, immediately: true)
                driver.close(immediately: true)
            }
            .accessibilityActions {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { if enabled { commit(item) } }
                }
            }
    }
    private func actionButton(_ item: RevealAction, frame: RevealDriver.ButtonFrame) -> some View {
        Button(role: item.role) { commit(item) } label: {
            VStack(spacing: 6 * actionSize / 52) {
                RevealActionIcon(symbol: item.systemImage, visibility: RevealActionIcon.quantizedVisibility(min(Double(frame.scale), frame.opacity)))
                    .frame(width: actionSize, height: actionSize)
                    .frame(width: frame.width, height: actionSize)
                    .background(item.tint, in: Capsule())
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .scaleEffect(reduceMotion ? 1 : frame.scale)
            .opacity(reduceMotion ? 1 : frame.opacity)
            .frame(width: frame.width + 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityElement(children: .ignore)
    }
    private func commit() { commit(primary) }
    private func commit(_ item: RevealAction) {
        guard enabled, !driver.isFilling else { return }
        if item.fillsOnCommit && !reduceMotion && width > 1 {
            RevealCoordinator.shared.relinquish(id)
            driver.fill(width: width)
        } else if RevealCoordinator.shared.active == id {
            RevealCoordinator.shared.clear(id, immediately: false)
        } else {
            driver.close()
        }
        item.action()
    }
}

extension View {
    func dismissRevealsWhenTabChanges(_ tab: Int) -> some View {
        compatibleOnChange(of: tab) { _ in RevealCoordinator.shared.clear(immediately: false) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                RevealCoordinator.shared.clear(immediately: true)
            }
    }
    func revealDelete(id: String, enabled: Bool = true, grouping: RevealRowGrouping = .standalone, separatorInset: CGFloat? = nil, style: RevealActionStyle = .round, title: LocalizedStringKey = "删除", fills: Bool = false, restored: Bool = false, action: @escaping () -> Void) -> some View {
        revealActions(id: id, enabled: enabled, grouping: grouping, separatorInset: separatorInset, style: style, restored: restored, [.delete(title, fills: fills, action: action)])
    }
    /// Swipe to reveal several buttons; the first is the primary (full swipe).
    func revealActions(id: String, enabled: Bool = true, grouping: RevealRowGrouping = .standalone, separatorInset: CGFloat? = nil, style: RevealActionStyle = .round, restored: Bool = false, _ actions: [RevealAction]) -> some View {
        modifier(RevealDeleteModifier(id: id, enabled: enabled, grouping: grouping, separatorInset: grouping == .standalone ? nil : separatorInset, style: style, restored: restored, actions: actions))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
