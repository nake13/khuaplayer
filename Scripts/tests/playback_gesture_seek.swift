import Foundation

@main
@MainActor
struct PlaybackGestureSeekChecks {
    static var checks = 0

    static func expect(_ actual: Double?, _ expected: Double?, _ description: String) {
        checks += 1
        let matches: Bool
        switch (actual, expected) {
        case (.some(let a), .some(let b)):
            matches = a.isFinite && (a == b || abs(a - b) < 0.000000001)
        case (nil, nil): matches = true
        default: matches = false
        }
        guard matches else {
            fatalError("\(description): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }

    static func expect(_ actual: Bool, _ expected: Bool, _ description: String) {
        checks += 1
        guard actual == expected else {
            fatalError("\(description): expected \(expected), got \(actual)")
        }
    }

    static func main() {
        relativeMovementChecks()
        cadenceChecks()
        releaseChecks()
        validationChecks()
        print("Playback gesture seek checks passed (\(checks) assertions).")
    }

    static func relativeMovementChecks() {
        var scheduler = SPPlaybackGestureSeek()
        expect(scheduler.hasPending, false, "New scheduler contains no movement")
        scheduler.submit(1)
        scheduler.submit(2)
        scheduler.submit(3)
        expect(scheduler.next(now: 0, settled: false), 6,
               "A batch sums relative movement rather than keeping the last absolute value")
        expect(scheduler.hasPending, false, "Issuing movement drains the pending batch")
        expect(scheduler.next(now: 1, settled: true), nil,
               "An empty batch never repeats previously issued movement")
        scheduler.submit(-6)
        expect(scheduler.next(now: 1, settled: true), -6,
               "A reversal after an issued movement is preserved")
        scheduler.submit(-6)
        expect(scheduler.next(now: 1.05, settled: true), -6,
               "Equal successive relative deltas are independent movement")
        scheduler.submit(3)
        scheduler.submit(-3)
        expect(scheduler.hasPending, false, "Opposite unissued deltas cancel within a batch")
        expect(scheduler.next(now: 2, settled: true), nil,
               "A cancelled batch does not seek")
        scheduler.submit(5)
        scheduler.submit(-2)
        expect(scheduler.next(now: 2, settled: true), 3,
               "Partial reversal keeps only the net pending movement")
        scheduler.submit(0)
        expect(scheduler.hasPending, false, "Zero movement has no pending work")
        scheduler.submit(0.0003)
        expect(scheduler.hasPending, false, "Tiny movement does not independently schedule a seek")
        scheduler.submit(0.0003)
        expect(scheduler.hasPending, true, "Small deltas can accumulate into meaningful movement")
        expect(scheduler.next(now: 3, settled: true), 0.0006,
               "A small accumulated batch retains its full displacement")
        scheduler.submit(0.0005)
        expect(scheduler.next(now: 3.05, settled: true), 0.0005,
               "The movement threshold includes its boundary")
        scheduler.submit(-0.0005)
        expect(scheduler.next(now: 3.1, settled: true), -0.0005,
               "Negative movement uses the same threshold")
    }

    static func cadenceChecks() {
        var scheduler = SPPlaybackGestureSeek()
        expect(scheduler.retryDelay(now: 0, settled: true), nil,
               "Idle scheduler does not request a timer")
        scheduler.submit(3)
        expect(scheduler.retryDelay(now: 0, settled: false), 0,
               "Initial movement is immediately eligible")
        expect(scheduler.next(now: 0, settled: false), 3,
               "The first batch does not wait for an acknowledgement")
        scheduler.submit(1)
        scheduler.submit(2)
        expect(scheduler.next(now: 0.01, settled: true), nil,
               "Acknowledgement does not bypass the minimum dwell")
        expect(scheduler.retryDelay(now: 0.01, settled: true), 0.04,
               "Dwell timer uses the exact remaining interval")
        expect(scheduler.next(now: 0.049, settled: true), nil,
               "Movement cannot issue before the dwell expires")
        expect(scheduler.next(now: 0.05, settled: false), nil,
               "An unsettled preview retains time to finish")
        expect(scheduler.retryDelay(now: 0.05, settled: false), 0.01,
               "Waiting for settlement polls without issuing a new seek")
        expect(scheduler.next(now: 0.05, settled: true), 3,
               "Acknowledged preview permits the complete pending batch")
        scheduler.submit(-1)
        expect(scheduler.retryDelay(now: 0.06, settled: true), 0.04,
               "Each issued batch establishes a fresh dwell timestamp")
        expect(scheduler.next(now: 0.1, settled: false), nil,
               "A fresh in-flight preview does not inherit the preceding acknowledgement")
        expect(scheduler.next(now: 0.349, settled: false), nil,
               "Unsettled work remains protected until the recovery bound")
        expect(scheduler.next(now: 0.35, settled: false), -1,
               "Recovery at 300 milliseconds prevents indefinite waiting")
        scheduler.submit(4)
        expect(scheduler.next(now: 0.4, settled: true), 4,
               "Floating point clock boundaries do not add an accidental dwell")
        expect(scheduler.retryDelay(now: 1, settled: false), nil,
               "A drained scheduler does not continue polling the decoder")
    }

    static func releaseChecks() {
        var scheduler = SPPlaybackGestureSeek()
        expect(scheduler.finish(), nil, "Release without movement does not seek")
        scheduler.submit(3)
        expect(scheduler.next(now: 0, settled: false), 3, "Initial movement is issued")
        expect(scheduler.finish(), nil,
               "Finger release never repeats an already issued seek")
        expect(scheduler.finish(), nil, "Repeated release remains a no-op")
        scheduler.submit(2)
        expect(scheduler.next(now: 0.01, settled: false), 2,
               "Release resets cadence for the next gesture")
        scheduler.submit(1)
        scheduler.submit(2)
        expect(scheduler.next(now: 0.02, settled: false), nil,
               "A final unissued batch can remain queued during the dwell")
        expect(scheduler.finish(), 3,
               "Release drains only unissued relative movement regardless of in-flight work")
        expect(scheduler.hasPending, false, "Release clears the pending batch")
        expect(scheduler.finish(), nil, "The final batch is drained once")
        scheduler.submit(4)
        scheduler.submit(-4)
        expect(scheduler.finish(), nil, "Cancelled pending movement needs no release seek")
        scheduler.submit(0.0004)
        expect(scheduler.finish(), nil, "Release discards insignificant residual movement")
        scheduler.submit(0.0002)
        expect(scheduler.hasPending, false, "The next gesture does not inherit discarded residue")
        scheduler.reset()
        scheduler.submit(-5)
        expect(scheduler.finish(), -5, "Release can drain a backward batch before its first issue")
        scheduler.submit(6)
        scheduler.reset()
        expect(scheduler.hasPending, false, "Cancellation discards queued movement")
        expect(scheduler.next(now: 5, settled: true), nil,
               "A stale timer cannot seek after cancellation")
        scheduler.submit(-3)
        expect(scheduler.next(now: 5, settled: false), -3,
               "A gesture after cancellation starts with a fresh cadence")
    }

    static func validationChecks() {
        var scheduler = SPPlaybackGestureSeek()
        for delta in [Double.nan, .infinity, -.infinity] {
            scheduler.submit(delta)
            expect(scheduler.hasPending, false, "Nonfinite movement cannot enter the queue")
        }
        scheduler.submit(3)
        for now in [Double.nan, .infinity, -.infinity] {
            expect(scheduler.next(now: now, settled: true), nil,
                   "Invalid clocks cannot consume pending movement")
            expect(scheduler.retryDelay(now: now, settled: true), nil,
                   "Invalid clocks cannot schedule a nonfinite timer")
            expect(scheduler.hasPending, true, "Invalid clocks preserve valid movement")
        }
        expect(scheduler.next(now: 5, settled: false), 3,
               "Valid clocks recover retained movement")
        scheduler.submit(-2)
        for delta in [Double.nan, .infinity, -.infinity] { scheduler.submit(delta) }
        expect(scheduler.next(now: 4, settled: true), nil,
               "A regressing clock does not bypass the dwell")
        expect(scheduler.retryDelay(now: 4, settled: true), 1.05,
               "Clock regression produces a finite delay to the next eligible issue")
        expect(scheduler.next(now: 5.05, settled: true), -2,
               "Clock recovery issues the retained signed movement")
        scheduler.reset()
        scheduler.submit(Double.greatestFiniteMagnitude)
        scheduler.submit(Double.greatestFiniteMagnitude)
        expect(scheduler.finish(), Double.greatestFiniteMagnitude,
               "Overflowing addition rejects new input while preserving the prior batch")
        scheduler.submit(-Double.greatestFiniteMagnitude)
        scheduler.submit(-Double.greatestFiniteMagnitude)
        expect(scheduler.finish(), -Double.greatestFiniteMagnitude,
               "Negative overflow also preserves the prior finite batch")
        scheduler.submit(Double.greatestFiniteMagnitude)
        scheduler.submit(-Double.greatestFiniteMagnitude)
        expect(scheduler.finish(), nil, "Large finite opposing deltas still cancel")
        scheduler.submit(1)
        expect(scheduler.next(now: -Double.greatestFiniteMagnitude, settled: false), 1,
               "A finite initial clock is accepted without unsafe arithmetic")
        scheduler.submit(-1)
        expect(scheduler.next(now: Double.greatestFiniteMagnitude, settled: true), nil,
               "Overflowing elapsed time cannot issue movement")
        expect(scheduler.retryDelay(now: Double.greatestFiniteMagnitude, settled: true), nil,
               "Overflowing elapsed time cannot create a nonfinite retry")
        expect(scheduler.finish(), -1,
               "Release can drain signed movement even after an invalid elapsed interval")
    }
}
