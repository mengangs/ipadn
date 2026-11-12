import ActivityKit
import Foundation

/// The app's copy of the download Live Activity type. The extension in
/// iPadnLiveActivity has one with the same name and fields; keep them equal.
@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0 downloading, 1 preparing the package, 2 finished, 3 waiting.
        var phase: Int
        /// The app being downloaded (the first one when there are several).
        var name: String
        /// Downloads not yet finished, this one included.
        var count: Int
        var written: Int64
        var expected: Int64
        /// When these numbers were measured.
        var updated: Date
        /// When the current downloads should be done at the measured speed;
        /// the bar keeps moving towards it while iPadn is suspended.
        var estimatedEnd: Date?
    }
}
