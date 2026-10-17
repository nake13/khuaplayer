import Foundation

@main
@MainActor
struct PlaybackPinchGestureChecks {
    static var checks = 0

    static func expect(_ actual: SPPlaybackPinchGesture.Effect?,
                       _ expected: SPPlaybackPinchGesture.Effect?,
                       _ description: String) {
        checks += 1
        let matches: Bool
        switch (actual, expected) {
        case (.resize(let a), .resize(let b)):
            matches = a.width.isFinite && a.height.isFinite &&
                abs(a.width - b.width) < 0.000001 &&
                abs(a.height - b.height) < 0.000001
        default:
            matches = actual == expected
        }
        guard matches else {
            fatalError("\(description): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }

    static func step(_ gesture: inout SPPlaybackPinchGesture,
                     _ magnification: Double,
                     phase: SPPlaybackScrollGesture.Phase = .began,
                     mode: SPPlaybackPinchGesture.Mode = .resizeWindow,
                     size: CGSize = CGSize(width: 800, height: 400),
                     minimum: CGSize = CGSize(width: 400, height: 200),
                     maximum: CGSize = CGSize(width: 1600, height: 1000),
                     fullscreen: Bool = false) -> SPPlaybackPinchGesture.Effect? {
        gesture.update(magnification: magnification, phase: phase, mode: mode,
                       contentSize: size, minimum: minimum, maximum: maximum,
                       isFullscreen: fullscreen)
    }

    static func main() {
        geometryChecks()
        fullscreenChecks()
        lifecycleChecks()
        validationChecks()
        print("Playback pinch gesture checks passed (\(checks) assertions).")
    }

    static func geometryChecks() {
        var gesture = SPPlaybackPinchGesture()
        expect(step(&gesture, 0.1), .resize(CGSize(width: 880, height: 440)),
               "Spread resizes both dimensions with the original aspect ratio")
        expect(step(&gesture, 0.1, phase: .changed,
                    size: CGSize(width: 880, height: 440)),
               .resize(CGSize(width: 968, height: 484)),
               "Incremental magnification accumulates from the gesture's starting size")
        expect(step(&gesture, -0.5), .resize(CGSize(width: 400, height: 200)),
               "Pinch contracts the window")
        expect(step(&gesture, -0.99,
                    minimum: CGSize(width: 400, height: 300)),
               .resize(CGSize(width: 600, height: 300)),
               "Minimum height clamps uniformly without changing aspect ratio")
        expect(step(&gesture, 3, maximum: CGSize(width: 1200, height: 500)),
               .resize(CGSize(width: 1000, height: 500)),
               "Screen height takes priority when it is the tighter maximum")
        expect(step(&gesture, 3, maximum: CGSize(width: 1000, height: 800)),
               .resize(CGSize(width: 1000, height: 500)),
               "Screen width clamps both dimensions uniformly")
        expect(step(&gesture, 0,
                    minimum: CGSize(width: 2000, height: 1000),
                    maximum: CGSize(width: 1000, height: 800)),
               .resize(CGSize(width: 1000, height: 500)),
               "A screen smaller than the minimum still bounds the window")
        expect(step(&gesture, -0.5, minimum: CGSize(width: -1, height: -1)),
               .resize(CGSize(width: 400, height: 200)),
               "Negative minimum dimensions do not make the result negative")
        expect(step(&gesture, 0.5, fullscreen: true), nil,
               "Window resize is suppressed while already fullscreen")
    }

    static func fullscreenChecks() {
        var gesture = SPPlaybackPinchGesture()
        expect(step(&gesture, 0.05, mode: .fullscreen), nil,
               "Small spread does not enter fullscreen")
        expect(step(&gesture, 0.05, phase: .changed, mode: .fullscreen),
               .setFullscreen(true), "Accumulated spread crosses the fullscreen threshold")
        expect(step(&gesture, -0.5, phase: .changed, mode: .fullscreen,
                    fullscreen: true), nil,
               "Reversing after fullscreen entry does not toggle it back")
        expect(step(&gesture, 0, phase: .ended, mode: .fullscreen,
                    fullscreen: true), nil,
               "Ending a consumed sequence does not request fullscreen again")
        expect(step(&gesture, -0.04, mode: .fullscreen, fullscreen: true), nil,
               "Small pinch does not exit fullscreen")
        expect(step(&gesture, -0.04, phase: .changed, mode: .fullscreen,
                    fullscreen: true), nil,
               "Contraction below the exit threshold keeps fullscreen")
        expect(step(&gesture, -0.04, phase: .changed, mode: .fullscreen,
                    fullscreen: true), .setFullscreen(false),
               "Accumulated pinch crosses the fullscreen exit threshold")
        expect(step(&gesture, 0.5, phase: .changed, mode: .fullscreen), nil,
               "Reversing after fullscreen exit does not re-enter")
        expect(step(&gesture, 0.5, mode: .fullscreen, fullscreen: true), nil,
               "Spreading while fullscreen does not request another entry")
        expect(step(&gesture, -0.5, mode: .fullscreen), nil,
               "Pinching a window does not request a fullscreen exit")
        expect(step(&gesture, 0.1, mode: .fullscreen), .setFullscreen(true),
               "Entry threshold includes its boundary")
        expect(step(&gesture, -0.1, mode: .fullscreen, fullscreen: true),
               .setFullscreen(false), "Exit threshold includes its boundary")
    }

    static func lifecycleChecks() {
        var gesture = SPPlaybackPinchGesture()
        _ = step(&gesture, 0.1)
        expect(step(&gesture, 0, phase: .ended),
               .resize(CGSize(width: 880, height: 440)),
               "Terminal resize can commit the final accumulated geometry")
        expect(step(&gesture, 0.1, phase: .changed,
                    size: CGSize(width: 600, height: 300)),
               .resize(CGSize(width: 660, height: 330)),
               "An end event clears starting size and accumulated scale")
        expect(step(&gesture, 2, phase: .cancelled), nil,
               "Cancellation ignores its payload")
        expect(step(&gesture, 0.1, phase: .changed,
                    size: CGSize(width: 1000, height: 500)),
               .resize(CGSize(width: 1100, height: 550)),
               "A changed event after cancellation starts from fresh geometry")
        expect(step(&gesture, 2, phase: .changed, mode: .disabled), nil,
               "Disabled mode clears in-flight geometry without effects")
        expect(step(&gesture, 0.1, phase: .changed),
               .resize(CGSize(width: 880, height: 440)),
               "Re-enabling pinch starts with a clean scale")
        gesture.reset()
        expect(step(&gesture, 0.1, phase: .changed),
               .resize(CGSize(width: 880, height: 440)),
               "Explicit reset discards previously accumulated magnification")
        expect(step(&gesture, 0.1, phase: .none),
               .resize(CGSize(width: 880, height: 440)),
               "Unphased pinch is a self-contained resize")
        expect(step(&gesture, 0.1, phase: .none),
               .resize(CGSize(width: 880, height: 440)),
               "Repeated unphased input does not keep hidden scale")
        _ = step(&gesture, 0.05, mode: .fullscreen)
        expect(step(&gesture, .nan, phase: .ended, mode: .fullscreen), nil,
               "Invalid terminal input still ends the sequence")
        expect(step(&gesture, 0.05, phase: .changed, mode: .fullscreen), nil,
               "An invalid end event also clears pending fullscreen intent")
        gesture.reset()
        expect(step(&gesture, 0.05, phase: .changed, mode: .fullscreen), nil,
               "Explicit reset clears fullscreen scale")
    }

    static func validationChecks() {
        var gesture = SPPlaybackPinchGesture()
        for invalid in [Double.nan, .infinity, -.infinity, -1, -2] {
            expect(step(&gesture, invalid), nil,
                   "Nonfinite or nonpositive scale factors are rejected")
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            expect(step(&gesture, 0.1, size: CGSize(width: invalid, height: 400)), nil,
                   "Invalid starting width cannot resize")
            expect(step(&gesture, 0.1, size: CGSize(width: 800, height: invalid)), nil,
                   "Invalid starting height cannot resize")
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            expect(step(&gesture, 0.1, minimum: CGSize(width: invalid, height: 200)), nil,
                   "Nonfinite minimum width is rejected")
            expect(step(&gesture, 0.1, minimum: CGSize(width: 400, height: invalid)), nil,
                   "Nonfinite minimum height is rejected")
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            expect(step(&gesture, 0.1, maximum: CGSize(width: invalid, height: 1000)), nil,
                   "Invalid maximum width is rejected")
            expect(step(&gesture, 0.1, maximum: CGSize(width: 1600, height: invalid)), nil,
                   "Invalid maximum height is rejected")
        }
        _ = step(&gesture, Double.greatestFiniteMagnitude)
        expect(step(&gesture, Double.greatestFiniteMagnitude, phase: .changed), nil,
               "Overflowing accumulated magnification is rejected")
        expect(step(&gesture, 0.1, phase: .changed),
               .resize(CGSize(width: 880, height: 440)),
               "Scale overflow resets the sequence for subsequent valid input")
        expect(step(&gesture, 0.1,
                    size: CGSize(width: Double.leastNonzeroMagnitude,
                                 height: Double.leastNonzeroMagnitude),
                    minimum: CGSize(width: 10, height: 10),
                    maximum: CGSize(width: 100, height: 100)), nil,
               "Finite inputs must not produce nonfinite resize geometry")
    }
}
