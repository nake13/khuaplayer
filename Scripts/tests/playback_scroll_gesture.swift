import Foundation

@main
@MainActor
struct PlaybackScrollGestureChecks {
    static var checks = 0

    static func expect(_ actual: [SPPlaybackScrollGesture.Effect],
                       _ expected: [SPPlaybackScrollGesture.Effect],
                       _ description: String) {
        checks += 1
        guard actual.count == expected.count,
              zip(actual, expected).allSatisfy({ lhs, rhs in
                  switch (lhs, rhs) {
                  case (.seek(let a), .seek(let b)), (.volume(let a), .volume(let b)):
                      return abs(a - b) < 0.000001
                  default:
                      return lhs == rhs
                  }
              }) else {
            fatalError("\(description): expected \(expected), got \(actual)")
        }
    }

    static func main() {
        directionChecks()
        axisAndDeadzoneChecks()
        pendingRecoveryChecks()
        lifecycleChecks()
        oneShotChecks()
        validationChecks()
        print("Playback scroll gesture checks passed (\(checks) assertions).")
    }

    static func directionChecks() {
        for inverted in [false, true] {
            var gesture = SPPlaybackScrollGesture()
            let right = inverted ? 4.0 : -4.0
            let up = inverted ? -4.0 : 4.0
            expect(gesture.update(deltaX: right, deltaY: 0, precise: true,
                                  inverted: inverted, phase: .began, momentum: false),
                   [.beginSeek, .seek(0.4)], "Physical right seeks forward")
            expect(gesture.reset(), [.endSeek], "Direction check closes seek")
            expect(gesture.update(deltaX: -right, deltaY: 0, precise: true,
                                  inverted: inverted, phase: .began, momentum: false),
                   [.beginSeek, .seek(-0.4)], "Physical left seeks backward")
            _ = gesture.reset()
            expect(gesture.update(deltaX: 0, deltaY: up, precise: true,
                                  inverted: inverted, phase: .began, momentum: false),
                   [.volume(1)], "Physical up raises volume")
            _ = gesture.reset()
            expect(gesture.update(deltaX: 0, deltaY: -up, precise: true,
                                  inverted: inverted, phase: .began, momentum: false),
                   [.volume(-1)], "Physical down lowers volume")
        }
    }

    static func axisAndDeadzoneChecks() {
        var gesture = SPPlaybackScrollGesture()
        expect(gesture.update(deltaX: 1, deltaY: 0.5, precise: true,
                              inverted: true, phase: .began, momentum: false),
               [], "Small movement waits for intent")
        expect(gesture.update(deltaX: 2, deltaY: 0.5, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [.beginSeek, .seek(0.3)], "Deadzone accumulates complete displacement")
        expect(gesture.update(deltaX: 1, deltaY: 40, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [.seek(0.1)], "Horizontal gesture keeps its original axis")
        expect(gesture.update(deltaX: 0, deltaY: 1, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [], "Cross-axis movement cannot change volume")
        expect(gesture.reset(), [.endSeek], "Horizontal lock closes")
        expect(gesture.update(deltaX: 3, deltaY: -3, precise: true,
                              inverted: true, phase: .began, momentum: false),
               [], "Equal diagonal movement waits for an axis")
        expect(gesture.update(deltaX: 0, deltaY: -1, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [.volume(1)], "Accumulated vertical intent chooses volume")
        expect(gesture.update(deltaX: 50, deltaY: -2, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [.volume(0.5)], "Vertical gesture ignores horizontal drift")
        expect(gesture.reset(), [], "Volume gesture never pauses playback")
        expect(gesture.update(deltaX: 5, deltaY: 1, precise: true,
                              inverted: true, phase: .began, momentum: false,
                              horizontalEnabled: false),
               [], "Disabled horizontal intent cannot adjust volume")
        expect(gesture.update(deltaX: 1, deltaY: 50, precise: true,
                              inverted: true, phase: .changed, momentum: false,
                              horizontalEnabled: false),
               [], "Disabled gesture retains its locked axis")
    }

    static func pendingRecoveryChecks() {
        var gesture = SPPlaybackScrollGesture()
        expect(gesture.update(deltaX: 2, deltaY: 0, precise: true,
                              inverted: true, phase: .began, momentum: false),
               [], "Pending input stays below the deadzone")
        expect(gesture.update(deltaX: -2, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [], "Opposite jitter cancels pending displacement")
        expect(gesture.update(deltaX: .nan, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [], "Invalid sample does not poison gesture state")
        expect(gesture.update(deltaX: 0, deltaY: -4, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [.volume(1)], "Valid input after jitter still chooses the correct axis")
        _ = gesture.reset()
        expect(gesture.update(deltaX: 0, deltaY: -5, precise: true,
                              inverted: true, phase: .began, momentum: false,
                              verticalEnabled: false),
               [], "Disabled vertical gesture does not change volume")
        expect(gesture.update(deltaX: 10, deltaY: -1, precise: true,
                              inverted: true, phase: .changed, momentum: false,
                              verticalEnabled: false),
               [], "Disabled vertical gesture cannot become a seek")
        _ = gesture.reset()
        _ = gesture.update(deltaX: 2, deltaY: 0, precise: true,
                           inverted: true, phase: .began, momentum: false)
        expect(gesture.reset(), [], "Resetting uncommitted intent does not end a seek")
        expect(gesture.update(deltaX: 1, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [], "Reset discards accumulated displacement")
        expect(gesture.update(deltaX: 2, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: false,
                              sensitivity: 0.5),
               [.beginSeek, .seek(0.15)], "Sensitivity scales action after physical intent detection")
    }

    static func lifecycleChecks() {
        for terminal in [SPPlaybackScrollGesture.Phase.ended, .cancelled] {
            var gesture = SPPlaybackScrollGesture()
            _ = gesture.update(deltaX: 5, deltaY: 0, precise: true,
                               inverted: true, phase: .began, momentum: false)
            expect(gesture.update(deltaX: 50, deltaY: 0, precise: true,
                                  inverted: true, phase: terminal, momentum: false,
                                  horizontalEnabled: false),
                   [.endSeek], "Terminal events close seek even when disabled")
            expect(gesture.reset(), [], "Seek completion occurs once")
        }
        var gesture = SPPlaybackScrollGesture()
        _ = gesture.update(deltaX: 5, deltaY: 0, precise: true,
                           inverted: true, phase: .began, momentum: false)
        expect(gesture.update(deltaX: 100, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: true),
               [.endSeek], "Momentum closes seek without applying inertia")
        expect(gesture.update(deltaX: 100, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: true),
               [], "Continued momentum has no playback effect")
        _ = gesture.update(deltaX: 5, deltaY: 0, precise: true,
                           inverted: true, phase: .began, momentum: false)
        expect(gesture.update(deltaX: 0, deltaY: 0, precise: true,
                              inverted: true, phase: .changed, momentum: false,
                              horizontalEnabled: false),
               [.endSeek], "Disabling seek midgesture releases playback immediately")
        expect(gesture.update(deltaX: 0, deltaY: 0, precise: true,
                              inverted: true, phase: .ended, momentum: false),
               [], "End after disabling does not finish twice")
        _ = gesture.update(deltaX: 5, deltaY: 0, precise: true,
                           inverted: true, phase: .began, momentum: false)
        expect(gesture.update(deltaX: 4, deltaY: 0, precise: true,
                              inverted: true, phase: .began, momentum: false),
               [.endSeek, .beginSeek, .seek(0.4)], "New gesture recovers a missing end")
        expect(gesture.reset(), [.endSeek], "Reset releases an active seek")
        expect(gesture.update(deltaX: 0, deltaY: -4, precise: true,
                              inverted: true, phase: .changed, momentum: false),
               [.volume(1)], "Changed event recovers a missing begin with fresh axis")
    }

    static func oneShotChecks() {
        var gesture = SPPlaybackScrollGesture()
        expect(gesture.update(deltaX: 1, deltaY: 0, precise: false,
                              inverted: true, phase: .none, momentum: false),
               [.seek(5)], "Mouse wheel is a one-shot seek without pausing")
        expect(gesture.reset(), [], "Mouse wheel leaves no seek open")
        expect(gesture.update(deltaX: 0, deltaY: -1, precise: false,
                              inverted: true, phase: .none, momentum: false),
               [.volume(5)], "One wheel tick raises volume by five percent")
        expect(gesture.update(deltaX: 0.5, deltaY: 0, precise: true,
                              inverted: true, phase: .none, momentum: false),
               [.seek(0.05)], "Unphased precise input does not wait for a terminal event")
        _ = gesture.update(deltaX: 4, deltaY: 0, precise: true,
                           inverted: true, phase: .began, momentum: false)
        expect(gesture.update(deltaX: 1, deltaY: 0, precise: false,
                              inverted: true, phase: .none, momentum: false),
               [.endSeek, .seek(5)], "Wheel input releases an unfinished trackpad seek")
        expect(gesture.update(deltaX: 0, deltaY: 0, precise: false,
                              inverted: true, phase: .none, momentum: false),
               [], "Zero wheel input is ignored")
        expect(gesture.update(deltaX: 1, deltaY: 1, precise: false,
                              inverted: true, phase: .none, momentum: false),
               [], "Ambiguous one-shot diagonal input is ignored")
    }

    static func validationChecks() {
        var gesture = SPPlaybackScrollGesture()
        expect(gesture.update(deltaX: 4, deltaY: 0, precise: true,
                              inverted: true, phase: .began, momentum: false,
                              sensitivity: 2),
               [.beginSeek, .seek(0.8)], "Sensitivity scales precise seek")
        _ = gesture.reset()
        expect(gesture.update(deltaX: 0, deltaY: -4, precise: true,
                              inverted: true, phase: .began, momentum: false,
                              sensitivity: 0.5),
               [.volume(0.5)], "Sensitivity scales volume")
        _ = gesture.reset()
        expect(gesture.update(deltaX: 1, deltaY: 0, precise: false,
                              inverted: true, phase: .none, momentum: false,
                              sensitivity: 1_000),
               [.seek(50)], "Extreme finite sensitivity is bounded")
        for invalid in [Double.nan, .infinity, -.infinity] {
            expect(gesture.update(deltaX: invalid, deltaY: 0, precise: true,
                                  inverted: true, phase: .began, momentum: false),
                   [], "Invalid horizontal input is ignored")
            expect(gesture.update(deltaX: 0, deltaY: invalid, precise: true,
                                  inverted: true, phase: .began, momentum: false),
                   [], "Invalid vertical input is ignored")
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            expect(gesture.update(deltaX: 5, deltaY: 0, precise: true,
                                  inverted: true, phase: .began, momentum: false,
                                  sensitivity: invalid),
                   [], "Invalid sensitivity cannot start a seek")
        }
        expect(gesture.update(deltaX: 0.000001, deltaY: 0, precise: true,
                              inverted: true, phase: .began, momentum: false),
               [], "Microscopic movement cannot start playback actions")
        _ = gesture.reset()
        _ = gesture.update(deltaX: 4, deltaY: 0, precise: true,
                           inverted: true, phase: .began, momentum: false)
        expect(gesture.update(deltaX: .nan, deltaY: .infinity, precise: true,
                              inverted: true, phase: .cancelled, momentum: false,
                              sensitivity: .nan),
               [.endSeek], "Invalid terminal payload still completes seek")
        expect(gesture.update(deltaX: .greatestFiniteMagnitude, deltaY: 0,
                              precise: false, inverted: true, phase: .none,
                              momentum: false),
               [], "Overflow cannot escape as a nonfinite effect")
    }
}
