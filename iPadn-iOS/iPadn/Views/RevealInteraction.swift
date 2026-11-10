import SwiftUI
import UIKit
import Combine

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

    func begin(width: CGFloat, direction: CGFloat, reduced: Bool) {
        self.direction = direction; self.reduced = reduced
        var parameters = ItemListRevealMotionParameters()
        parameters.width = Double(width); parameters.count = 1
        parameters.buttonWidth = 56; parameters.isDestructive = true
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
        feedback = nil; render(); animate()
        return commit
    }
    func close(immediately: Bool = false) {
        motion.settle(to: 0, velocity: 0, animated: !immediately && !reduced)
        feedback = nil; render()
        if immediately || reduced { stop() } else { animate() }
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
    deinit { displayLink?.invalidate() }
}

private struct RevealDeleteModifier: ViewModifier {
    let id: String
    let enabled: Bool
    let title: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var driver = RevealDriver()
    @ObservedObject private var coordinator = RevealCoordinator.shared
    @State private var width: CGFloat = 0
    @State private var direction: CGFloat = 1
    @State private var rejected = false
    @State private var previousSample: (time: Date, x: CGFloat)?
    @State private var velocity: CGFloat = 0
    @GestureState private var touching = false

    func body(content: Content) -> some View {
        content
            .offset(x: driver.offset)
            .background(alignment: driver.offset >= 0 ? .leading : .trailing) {
                if abs(driver.offset) > 1 {
                    Button(role: .destructive, action: commit) {
                        Label(title, systemImage: "trash").labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: max(0, abs(driver.offset)), height: nil)
                            .frame(maxHeight: .infinity).background(Color.red)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(title)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 25)
                .updating($touching) { _, touching, _ in touching = true }
                .onChanged { value in
                    guard enabled, !rejected, width > 0 else { return }
                    if !driver.dragging {
                        guard abs(value.translation.width) > abs(value.translation.height) else { coordinator.active = nil; rejected = true; return }
                        // Leave the leading-edge interactive navigation gesture alone.
                        if value.startLocation.x < 20 && value.translation.width > 0 { rejected = true; return }
                        direction = driver.offset == 0 ? (value.translation.width > 0 ? 1 : -1) : (driver.offset > 0 ? 1 : -1)
                        coordinator.active = id
                        driver.begin(width: width, direction: direction, reduced: reduceMotion)
                    }
                    let now = Date()
                    if let previousSample {
                        let dt = now.timeIntervalSince(previousSample.time)
                        if dt > 0 { velocity = (value.translation.width - previousSample.x) / dt }
                    }
                    previousSample = (now, value.translation.width)
                    driver.change(translation: value.translation.width, velocity: velocity,
                                  distanceFromEdge: direction > 0 ? width - value.location.x : value.location.x)
                }
                .onEnded { value in
                    defer { rejected = false; previousSample = nil; velocity = 0 }
                    guard driver.dragging else { return }
                    if driver.end(translation: value.translation.width, velocity: velocity) { commit() }
                }, including: enabled ? .all : .none)
            .onChange(of: coordinator.active) { _, active in if active != id { driver.close() } }
            .onChange(of: enabled) { _, enabled in if !enabled { driver.close(immediately: true) } }
            .onChange(of: reduceMotion) { _, _ in driver.close(immediately: true) }
            .onChange(of: touching) { _, touching in
                if !touching && driver.dragging {
                    driver.close(); rejected = false; previousSample = nil; velocity = 0
                }
            }
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
    func dismissRevealsOnTap() -> some View {
        simultaneousGesture(TapGesture().onEnded { RevealCoordinator.shared.active = nil })
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) { RevealCoordinator.shared.active = nil }
            })
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                RevealCoordinator.shared.active = nil
            }
    }
    func revealDelete(id: String, enabled: Bool = true, title: String = "删除", action: @escaping () -> Void) -> some View {
        modifier(RevealDeleteModifier(id: id, enabled: enabled, title: title, action: action))
    }
}
