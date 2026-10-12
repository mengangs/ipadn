import Foundation

/// Session-only samples: never persist a speed across pauses or app launches.
struct TransferMetrics {
    private(set) var bytes: Int64
    private(set) var sampledAt: TimeInterval
    private(set) var bytesPerSecond: Double = 0

    mutating func record(bytes next: Int64, at time: TimeInterval) {
        let duration = time - sampledAt
        guard duration > 0 else { return }
        let delta = next - bytes
        if delta < 0 || duration > 10 { bytesPerSecond = 0 }
        else {
            let sample = Double(delta) / duration
            bytesPerSecond = bytesPerSecond == 0 ? sample : 0.3 * sample + 0.7 * bytesPerSecond
        }
        bytes = next; sampledAt = time
    }

    func rate(at time: TimeInterval) -> Double {
        time >= sampledAt && time - sampledAt < 5 ? bytesPerSecond : 0
    }
    func remaining(expected: Int64, at time: TimeInterval) -> TimeInterval? {
        let speed = rate(at: time)
        guard expected > bytes, bytes >= 0, speed > 0 else { return nil }
        return Double(expected - bytes) / speed
    }
}
