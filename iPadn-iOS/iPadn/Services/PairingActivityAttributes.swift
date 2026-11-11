import ActivityKit
import Foundation

/// The app's copy of the pairing Live Activity type. The extension in
/// iPadnLiveActivity has one with the same name and fields; keep them equal.
@available(iOS 16.1, *)
struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 1: open Settings, 2: device connected, 3: enter the code, 4: done, 0: failed.
        var step: Int
        /// The code to type in Settings, once there is one.
        var code: String?
        /// Shown for the failed step.
        var message: String?
    }
    /// The name Settings shows for iPadn.
    var hostName: String
}
