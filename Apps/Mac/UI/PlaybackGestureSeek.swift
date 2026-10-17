import Foundation

/// Batches relative scrub movement while giving an active preview time to finish.
struct SPPlaybackGestureSeek {
    private static let minimumDwell: TimeInterval = 0.05
    private static let maximumDwell: TimeInterval = 0.3
    private static let settlePoll: TimeInterval = 0.01
    private static let movementTolerance = 0.0005
    private static let clockTolerance: TimeInterval = 0.000000001

    private var pending = 0.0
    private var lastIssuedAt: TimeInterval?

    var hasPending: Bool { abs(pending) >= Self.movementTolerance }

    mutating func submit(_ delta: Double) {
        guard delta.isFinite else { return }
        let accumulated = pending + delta
        guard accumulated.isFinite else { return }
        pending = accumulated
    }

    mutating func next(now: TimeInterval, settled: Bool) -> Double? {
        guard let delay = retryDelay(now: now, settled: settled), delay == 0
        else { return nil }
        let delta = pending
        pending = 0
        lastIssuedAt = now
        return delta
    }

    /// Release drains only movement not yet sent; it never repeats an issued seek.
    mutating func finish() -> Double? {
        let delta: Double? = hasPending ? pending : nil
        reset()
        return delta
    }

    mutating func reset() {
        pending = 0
        lastIssuedAt = nil
    }

    /// Zero means ready now; nil means there is no valid pending clock sample.
    func retryDelay(now: TimeInterval, settled: Bool) -> TimeInterval? {
        guard hasPending, now.isFinite else { return nil }
        guard let issuedAt = lastIssuedAt else { return 0 }
        let elapsed = now - issuedAt
        guard elapsed.isFinite else { return nil }
        if elapsed + Self.clockTolerance < Self.minimumDwell {
            return Self.minimumDwell - elapsed
        }
        if settled || elapsed + Self.clockTolerance >= Self.maximumDwell { return 0 }
        return Self.settlePoll
    }
}
