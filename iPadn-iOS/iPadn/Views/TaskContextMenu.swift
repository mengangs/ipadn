import SwiftUI
import UIKit

/// Attaches to the actual list cell: its snapshot retains the row's geometry,
/// rather than reconstructing a second SwiftUI row in the middle of the page.
struct TaskContextAttachment: UIViewRepresentable {
    let enabled: Bool
    let requested: Bool
    let name: String
    let items: [TaskMenuItem]
    let opened: () -> Void
    let closed: () -> Void

    final class Anchor: UIView {
        var moved: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); moved?() }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TaskContextAttachment
        weak var anchor: Anchor?
        weak var cell: UIView?
        private let press = UILongPressGestureRecognizer()
        private var presentation: TaskContextPresentation?
        init(_ parent: TaskContextAttachment) {
            self.parent = parent
            super.init()
            press.minimumPressDuration = 0.4
            press.addTarget(self, action: #selector(pressed))
            press.delegate = self
        }
        func install() {
            guard let anchor, anchor.window != nil else { detach(); return }
            var ancestor = anchor.superview
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell {
                    if cell !== view {
                        detach()
                        cell = view
                        view.addGestureRecognizer(press)
                    }
                    press.isEnabled = parent.enabled
                    if !parent.enabled { presentation?.dismiss(animated: false) }
                    return
                }
                ancestor = view.superview
            }
        }
        func detach() {
            presentation?.dismiss(animated: false)
            cell?.removeGestureRecognizer(press)
            cell = nil
        }
        @objc private func pressed() {
            guard press.state == .began else { return }
            show()
        }
        func show() {
            guard parent.enabled, presentation == nil, let cell, let window = cell.window,
                  let snapshot = cell.snapshotView(afterScreenUpdates: false) else { return }
            let controller = TaskContextPresentation(window: window, source: cell, snapshot: snapshot,
                                                     name: parent.name, items: parent.items) { [weak self] in
                self?.presentation = nil
                self?.parent.closed()
            }
            presentation = controller
            parent.opened()
            UX.feedback()
            controller.show()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The list must win a drag. A recognized long press cancels the
            // row button's touch; releasing it cannot open the details sheet.
            false
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
        if requested {
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                if coordinator?.parent.requested == true { coordinator?.show() }
            }
        }
    }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.detach()
        view.moved = nil
    }
}

/// The visual overlay is deliberately NOT a full-page touch shield. Background
/// drags still belong to the list's UIScrollView. The window tap recognizer
/// delays button touches until it knows this was a tap, then consumes that tap.
@MainActor private final class TaskContextPresentation: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private weak var source: UIView?
    private let overlay = TaskMenuOverlay()
    private let backdrop = UIVisualEffectView()
    private let snapshot: UIView
    private let actions: UIHostingController<TaskMenuActions>
    private let outsideTap = UITapGestureRecognizer()
    private let outsidePan = UIPanGestureRecognizer()
    private let closed: () -> Void
    private var inactiveObserver: NSObjectProtocol?
    private var dismissed = false
    private var sourceFrame = CGRect.zero
    private var sourceAlpha: CGFloat = 1

    init(window: UIWindow, source: UIView, snapshot: UIView, name: String, items: [TaskMenuItem], closed: @escaping () -> Void) {
        self.window = window
        self.source = source
        self.snapshot = snapshot
        self.closed = closed
        actions = UIHostingController(rootView: TaskMenuActions(items: items, choose: { _ in }))
        super.init()
        snapshot.isAccessibilityElement = true
        snapshot.accessibilityLabel = name
        snapshot.accessibilityIdentifier = "download.menu.preview"
        snapshot.accessibilityTraits = .image
        actions.rootView = TaskMenuActions(items: items) { [weak self] item in
            self?.dismiss(animated: false)
            item.action()
        }
        actions.view.backgroundColor = .clear
        overlay.onEscape = { [weak self] in self?.dismiss() }
        outsideTap.addTarget(self, action: #selector(tappedOutside))
        outsideTap.delegate = self
        outsideTap.cancelsTouchesInView = true
        outsideTap.delaysTouchesBegan = true
        outsidePan.addTarget(self, action: #selector(pannedOutside))
        outsidePan.delegate = self
        outsidePan.cancelsTouchesInView = false
    }

    func show() {
        guard let window, let source else { return }
        sourceFrame = source.convert(source.bounds, to: window)
        sourceAlpha = source.alpha
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.frame = overlay.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.isUserInteractionEnabled = false
        overlay.addSubview(backdrop)
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = false
        snapshot.layer.cornerRadius = 20
        snapshot.layer.masksToBounds = true
        snapshot.frame = sourceFrame
        overlay.addSubview(snapshot)
        actions.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        if let root = window.rootViewController { root.addChild(actions) }
        overlay.addSubview(actions.view)
        actions.didMove(toParent: actions.parent)
        overlay.menuView = actions.view
        overlay.accessibilityViewIsModal = true
        window.addSubview(overlay)

        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 12, dy: 12)
        let width = min(sourceFrame.width, safe.width, 380)
        // Measure the menu before constraining its scroll view's viewport.
        let measurement = UIHostingController(rootView: TaskMenuButtons(items: actions.rootView.items, choose: { _ in }))
        let desired = measurement.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        let height = min(desired, max(44, safe.height - min(sourceFrame.height, safe.height / 2) - 12))
        var card = sourceFrame
        card.size.width = min(card.width, safe.width)
        card.size.height = min(card.height, max(44, safe.height - height - 12))
        card.origin.x = min(max(card.minX, safe.minX), safe.maxX - card.width)
        // Keep the source position if either side fits the menu. Only a row
        // near the middle of a short screen needs to move, and only as far as
        // necessary to keep both the preview and all menu items reachable.
        let below = safe.maxY - card.maxY - 12
        let above = card.minY - safe.minY - 12
        let useAbove = below < height && above >= height
        if !useAbove { card.origin.y = min(card.minY, safe.maxY - height - 12 - card.height) }
        card.origin.y = max(safe.minY, card.minY)
        let menuY = useAbove ? card.minY - height - 12 : card.maxY + 12
        let menuX = window.effectiveUserInterfaceLayoutDirection == .rightToLeft ? card.minX : card.maxX - width
        actions.view.frame = CGRect(x: max(safe.minX, menuX), y: menuY, width: width, height: height)
        actions.view.alpha = 0
        actions.view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        source.alpha = 0
        window.addGestureRecognizer(outsideTap)
        window.addGestureRecognizer(outsidePan)
        // A rotation invalidates the original cell coordinates.
        let initialSize = window.bounds.size
        overlay.resized = { [weak self, weak window] in
            if window?.bounds.size != initialSize { self?.dismiss(animated: false) }
        }
        inactiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
                       delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            self.snapshot.frame = card
            self.actions.view.alpha = 1
            self.actions.view.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: actions.view)
    }

    func dismiss(animated: Bool = true) {
        guard !dismissed else { return }
        dismissed = true
        window?.removeGestureRecognizer(outsideTap)
        window?.removeGestureRecognizer(outsidePan)
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
        inactiveObserver = nil
        // Restore immediately: a drag can now scroll the real row, with no
        // hole left in the list and no second gesture needed.
        source?.alpha = sourceAlpha
        closed()
        let overlay = self.overlay
        let actions = self.actions
        actions.willMove(toParent: nil)
        if animated && !UIAccessibility.isReduceMotionEnabled {
            overlay.isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.15, animations: { overlay.alpha = 0 }) { _ in
                overlay.removeFromSuperview()
                actions.removeFromParent()
            }
        } else {
            overlay.removeFromSuperview()
            actions.removeFromParent()
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    @objc private func tappedOutside() { dismiss() }
    @objc private func pannedOutside() {
        if outsidePan.state == .began { dismiss(animated: false) }
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !actions.view.frame.contains(touch.location(in: overlay))
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A tap consumes the touch instead of firing a row button. A drag is
        // observed alongside the native scroll recognizer, never replacing it.
        recognizer === outsidePan && other is UIPanGestureRecognizer
    }
}

private final class TaskMenuOverlay: UIView {
    weak var menuView: UIView?
    var onEscape: (() -> Void)?
    var resized: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); resized?() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let menuView, menuView.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
    override func accessibilityPerformEscape() -> Bool { onEscape?(); return true }
}

private struct TaskMenuButtons: View {
    let items: [TaskMenuItem]
    let choose: (TaskMenuItem) -> Void
    var body: some View {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { choose(item) } label: {
                        HStack(spacing: 12) {
                            Text(item.title).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: item.symbol)
                        }
                        .font(.body)
                        .foregroundStyle(item.destructive ? Color.red : Color.primary)
                        .frame(minHeight: 44).padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("download.menu." + item.id)
                    if item.id != items.last?.id { Divider().padding(.leading, 16) }
                }
            }
    }
}

private struct TaskMenuActions: View {
    let items: [TaskMenuItem]
    let choose: (TaskMenuItem) -> Void
    var body: some View {
        ScrollView { TaskMenuButtons(items: items, choose: choose) }
            .compatibleScrollBounce()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
