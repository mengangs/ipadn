import UIKit
import XCTest
@testable import iPadn

final class RevealIconPathTests: XCTestCase {
    func testOriginalTrashAssetHasCompleteBodyHolesAndLid() throws {
        let asset = try XCTUnwrap(RevealAnimationAsset.load(.trash))
        XCTAssertTrue(asset.isValid)
        XCTAssertEqual(asset.sourceCommit, "24638bc69bd083981b178dd1e7f921eebbf7fc46")
        XCTAssertEqual(asset.sourceSHA256, "64158b35934cfedf33a6416da3c7a1bf2880a263c4a90dd416051d8741d22a8b")
        XCTAssertEqual(asset.duration, 25.0 / 60, accuracy: 0.000001)
        XCTAssertEqual(asset.tracks.count, 2)
        let body = try XCTUnwrap(asset.tracks.first { $0.frames[0].contours.count == 4 })
        XCTAssertTrue(body.frames.allSatisfy { $0.contours.allSatisfy(\.closed) })
        XCTAssertEqual(body.frames[0].contours.map { $0.points.count }, [38, 38, 38, 38])
        let lid = try XCTUnwrap(asset.tracks.first { $0.frames[0].contours.count == 1 })
        XCTAssertEqual(lid.frames[0].contours[0].points.count, 62)
        XCTAssertNotEqual(lid.frames[0].contours[0].points, lid.frames[25].contours[0].points)
    }

    func testShareKeepsConnectedTrayAndBothArrowheadSidesThroughoutPlayback() throws {
        let asset = try XCTUnwrap(RevealAnimationAsset.load(.share))
        XCTAssertTrue(asset.isValid)
        XCTAssertEqual(asset.sourceCommit, "iPadn-original")
        XCTAssertEqual(asset.duration, 0.65, accuracy: 0.000001)
        let tray = try XCTUnwrap(asset.tracks.first { $0.frames[0].contours.count == 1 })
        let arrow = try XCTUnwrap(asset.tracks.first { $0.frames[0].contours.count == 2 })
        for frame in tray.frames {
            XCTAssertEqual(frame.contours[0].points.count, 32) // Five connected cubics.
            XCTAssertEqual(frame.opacity, 1)
        }
        for frame in arrow.frames {
            XCTAssertEqual(frame.contours.map { $0.points.count }, [8, 14]) // Shaft, two-sided head.
            XCTAssertEqual(frame.opacity, 1, "Share must not become a blank tray or success checkmark")
        }
        XCTAssertEqual(arrow.frames[0].contours.map(\.points), arrow.frames[39].contours.map(\.points))
        XCTAssertNotEqual(arrow.frames[0].contours.map(\.points), arrow.frames[13].contours.map(\.points))
    }

    func testTabIconsReturnToInitialRestingSilhouetteAfterPlayback() throws {
        let cases: [(RevealAnimationKind, Int)] = [
            (.tabSearch, 3),
            (.tabDownloads, 1),
            (.tabPurchased, 2),
            (.tabAccount, 1),
        ]
        for (kind, trackCount) in cases {
            let asset = try XCTUnwrap(RevealAnimationAsset.load(kind))
            XCTAssertTrue(asset.isValid)
            XCTAssertEqual(asset.sourceCommit, "iPadn-original")
            XCTAssertEqual(asset.tracks.count, trackCount)
            for track in asset.tracks {
                XCTAssertGreaterThan(track.frames.count, 10)
                let first = track.frames[0]
                let last = track.frames[track.frames.count - 1]
                XCTAssertEqual(first.opacity, last.opacity, accuracy: 0.0001)
                let mid = track.frames[track.frames.count / 2]
                let differs = (first.contours.map(\.points) != mid.contours.map(\.points))
                    || abs(first.opacity - mid.opacity) > 0.05
                XCTAssertTrue(differs, "\(kind.rawValue) must animate away from rest mid-cycle")
            }
        }
    }

    func testAllNativePathsHaveStableTopologyAndFitTheirViewport() throws {
        for kind in RevealAnimationKind.allCases {
            let asset = try XCTUnwrap(RevealAnimationAsset.load(kind))
            XCTAssertTrue(asset.isValid)
            XCTAssertEqual(asset.canvas, [52, 52])
            for track in asset.tracks {
                let counts = track.frames[0].contours.map { $0.points.count }
                for frame in track.frames {
                    XCTAssertEqual(frame.contours.map { $0.points.count }, counts)
                    let bounds = frame.makePath().boundingBoxOfPath
                    XCTAssertFalse(bounds.isEmpty)
                    XCTAssertGreaterThanOrEqual(bounds.minX, 0)
                    XCTAssertGreaterThanOrEqual(bounds.minY, 0)
                    XCTAssertLessThanOrEqual(bounds.maxX, 52)
                    XCTAssertLessThanOrEqual(bounds.maxY, 52)
                }
            }
        }
    }

    func testMissingCubicCoordinateIsRejectedRatherThanCrashingTheRenderer() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "trash", withExtension: "json", subdirectory: "RevealAnimations"))
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        var frames = try XCTUnwrap(tracks[0]["frames"] as? [[String: Any]])
        var contours = try XCTUnwrap(frames[0]["contours"] as? [[String: Any]])
        var points = try XCTUnwrap(contours[0]["points"] as? [Double])
        points.removeLast()
        contours[0]["points"] = points
        frames[0]["contours"] = contours
        tracks[0]["frames"] = frames
        json["tracks"] = tracks
        let invalid = try JSONDecoder().decode(RevealAnimationAsset.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(invalid.isValid)
    }

    @MainActor
    func testTabBarVectorAttachmentDefersUnlaidOutBarAndCleansPartialOverlaysOnUnsupportedHierarchy() {
        let kinds: [RevealAnimationKind] = [.tabSearch, .tabDownloads, .tabPurchased, .tabAccount]
        let sampleImage = UIImage(systemName: "circle")
        let unattachedBar = UITabBar(frame: CGRect(x: 0, y: 0, width: 390, height: 83))
        unattachedBar.items = kinds.enumerated().map { UITabBarItem(title: "\($0.offset)", image: sampleImage, tag: $0.offset) }
        XCTAssertEqual(TabReselectScroll.attachVectorIcons(in: unattachedBar, kinds: kinds), .deferred)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UITabBarController()
        let tabs = (0..<4).map { index -> UIViewController in
            let vc = UIViewController()
            vc.tabBarItem = UITabBarItem(title: "\(index)", image: sampleImage, tag: index)
            return vc
        }
        controller.viewControllers = tabs
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        let liveBar = controller.tabBar
        XCTAssertEqual(TabReselectScroll.attachVectorIcons(in: liveBar, kinds: kinds), .attached)

        // When UIKit no longer exposes matching image slots (even if a stale
        // vector overlay was attached earlier), fallback must return unsupported
        // and strip every vector overlay so native SF Symbols aren't obscured.
        let brokenBar = UITabBar(frame: CGRect(x: 0, y: 0, width: 390, height: 83))
        brokenBar.items = kinds.enumerated().map { UITabBarItem(title: "\($0.offset)", image: sampleImage, tag: $0.offset) }
        window.addSubview(brokenBar)
        brokenBar.layoutIfNeeded()
        XCTAssertEqual(TabReselectScroll.attachVectorIcons(in: brokenBar, kinds: kinds), .attached)

        brokenBar.items = kinds.enumerated().map { UITabBarItem(title: "\($0.offset)", image: nil, tag: $0.offset) }
        brokenBar.setNeedsLayout()
        brokenBar.layoutIfNeeded()
        XCTAssertEqual(TabReselectScroll.attachVectorIcons(in: brokenBar, kinds: kinds), .unsupportedHierarchy)
        func hasVectorIcon(_ view: UIView) -> Bool {
            String(describing: type(of: view)).contains("TabVectorIconView") || view.subviews.contains(where: hasVectorIcon)
        }
        XCTAssertFalse(hasVectorIcon(brokenBar))
    }
}
