import ActivityKit
import Foundation

/// On-device pairing shown on the Lock Screen and in the Dynamic Island while
/// the user is in Settings. The app and this extension each compile a copy of
/// this type; ActivityKit matches them by name, so the fields must stay equal.
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
