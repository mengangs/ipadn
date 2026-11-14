import XCTest
import SwiftUI
import UIKit
@testable import iPadn

final class VisualTests: XCTestCase {
    /// Assertions below check the Chinese copy: pin the language instead of
    /// following whatever the simulator is set to. Set `locale:` on the
    /// formatting calls whose numbers or currency symbols are asserted.
    override func setUp() {
        super.setUp()
        AppText.locale = Locale(identifier: "zh-Hans")
    }

    @MainActor
    func testNativeScreenLayouts() async throws {
        let a = StoreApp(id: "preview-1", name: "像素日记", bundleID: "example.pixel", version: "3.2.1", category: "摄影与录像", size: 128_000_000)
        let b = StoreApp(id: "preview-2", name: "专注时刻 · 记录每一次进步", bundleID: "example.focus", version: "2.8", category: "效率", size: 48_000_000)
        let jobs = [DownloadJob(app: a, status: .running, downloaded: 74_000_000, expected: 128_000_000), DownloadJob(app: b, status: .paused), DownloadJob(app: a, status: .completed), DownloadJob(app: b, status: .failed, error: "网络连接已中断，请检查网络后重新尝试。")]
        let store = ToolStore(downloadManager: DownloadManager(previewJobs: jobs))
        store.prepareVisualPreview()
        try await capture("01-discover-light", view: RootView(), store: store)
        try await capture("02-discover-dark", view: RootView(), store: store, dark: true)
        store.tab = 1
        try await capture("03-downloads-light", view: RootView(), store: store)
        try await capture("04-downloads-large-text", view: RootView(), store: store, textSize: .accessibility2)
        try await capture("05-login", view: NavigationStack { LoginView() }, store: store)
        try await capture("06-app-detail", view: NavigationStack { AppDetailView(app: a) }, store: store)
        store.prepareAccountPreview(); store.tab = 3
        try await capture("08-accounts", view: RootView(), store: store)
        store.tab = 2
        try await capture("09-purchased", view: RootView(), store: store)
        store.tab = 0
        try await capture("07-tablet-layout", view: RootView(), store: store, size: CGSize(width: 1024, height: 1366), regular: true)
    }

    @MainActor
    private func capture<V: View>(_ name: String, view: V, store: ToolStore, size: CGSize = CGSize(width: 390, height: 844), dark: Bool = false, textSize: DynamicTypeSize = .large, regular: Bool = false) async throws {
        let content = view
            .environmentObject(store).environmentObject(store.tabs).environmentObject(store.apple).environmentObject(store.downloads).environmentObject(store.signer)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.horizontalSizeClass, regular ? .regular : .compact)
            .tint(UX.tint).frame(width: size.width, height: size.height)
        let controller = UIHostingController(rootView: content)
        // A window in the test host's scene, so the system composites
        // everything (tab pages, materials) and drawHierarchy can see it.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        // layer.render(in:) leaves out what the system composites (other
        // tabs' pages, blur); drawHierarchy captures the screen as shown.
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if !controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) {
                controller.view.layer.render(in: context.cgContext)
            }
        }
        XCTAssertEqual(image.size.width, size.width)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShimmerBeginTimeSynchronizesPhaseAcrossMounts() {
        let period = ShimmerLayoutMath.period
        let t1 = 100.25
        let t2 = 100.75
        let begin1 = ShimmerLayoutMath.beginTime(forWallClock: t1, layerTime: t1, period: period)
        let begin2 = ShimmerLayoutMath.beginTime(forWallClock: t2, layerTime: t2, period: period)
        let phase1 = (500.0 - begin1).truncatingRemainder(dividingBy: period)
        let phase2 = (500.0 - begin2).truncatingRemainder(dividingBy: period)
        XCTAssertEqual(phase1, phase2, accuracy: 0.0001)
    }

    func testShimmerSweepEndpointsMapWindowSpanToLocalUnitSpace() {
        let endpoints = ShimmerLayoutMath.unitSweepEndpoints(
            viewFrameInContainer: CGRect(x: 20, y: 120, width: 350, height: 64),
            containerWidth: 390
        )
        XCTAssertLessThan(endpoints.endFrom.x, 0)
        XCTAssertGreaterThan(endpoints.startTo.x, 1)
        XCTAssertGreaterThan(endpoints.endTo.x, endpoints.startTo.x)

        let zeroWidth = ShimmerLayoutMath.unitSweepEndpoints(
            viewFrameInContainer: .zero,
            containerWidth: 0
        )
        XCTAssertTrue(zeroWidth.startFrom.x.isFinite && zeroWidth.endTo.x.isFinite)
    }
}
