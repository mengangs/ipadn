import XCTest
import SwiftUI
import UIKit
@testable import iPadn

final class VisualTests: XCTestCase {
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
        store.tab = 0
        try await capture("07-tablet-layout", view: RootView(), store: store, size: CGSize(width: 1024, height: 1366), regular: true)
    }

    @MainActor
    private func capture<V: View>(_ name: String, view: V, store: ToolStore, size: CGSize = CGSize(width: 390, height: 844), dark: Bool = false, textSize: DynamicTypeSize = .large, regular: Bool = false) async throws {
        let content = view
            .environmentObject(store).environmentObject(store.apple).environmentObject(store.downloads).environmentObject(store.signer)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.horizontalSizeClass, regular ? .regular : .compact)
            .tint(UX.tint).frame(width: size.width, height: size.height)
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        XCTAssertEqual(image.size.width, size.width)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
