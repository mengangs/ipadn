import ActivityKit
import Foundation

/// The app's copy of the download Live Activity type. The extension in
/// iPadnLiveActivity has one with the same name and fields; keep them equal.
@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0 downloading, 1 preparing the package, 2 finished, 3 waiting,
        /// 4 installing automatically, 5 installed, 6 install not finished,
        /// 7 paused, 8 download failed.
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
        /// Aggregate download speed in bytes per second (0 when not actively downloading).
        var speed: Int64

        init(phase: Int, name: String, count: Int, written: Int64, expected: Int64,
             updated: Date, estimatedEnd: Date?, speed: Int64 = 0) {
            self.phase = phase
            self.name = name
            self.count = count
            self.written = written
            self.expected = expected
            self.updated = updated
            self.estimatedEnd = estimatedEnd
            self.speed = speed
        }

        private enum CodingKeys: String, CodingKey {
            case phase, name, count, written, expected, updated, estimatedEnd, speed
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phase = try values.decode(Int.self, forKey: .phase)
            name = try values.decode(String.self, forKey: .name)
            count = try values.decode(Int.self, forKey: .count)
            written = try values.decode(Int64.self, forKey: .written)
            expected = try values.decode(Int64.self, forKey: .expected)
            updated = try values.decode(Date.self, forKey: .updated)
            estimatedEnd = try values.decodeIfPresent(Date.self, forKey: .estimatedEnd)
            speed = try values.decodeIfPresent(Int64.self, forKey: .speed) ?? 0
        }
    }
}
