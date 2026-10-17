import Foundation

/// Converts pointer scrolls into playback actions without depending on AppKit.
struct SPPlaybackScrollGesture {
    enum Phase {
        case none, began, changed, ended, cancelled
    }

    enum Effect: Equatable {
        case beginSeek
        case seek(Double)
        case endSeek
        case volume(Double)
    }

    private enum Axis { case horizontal, vertical }

    private var axis: Axis?
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var seeking = false

    /// Natural scrolling reverses AppKit's horizontal and vertical deltas.
    /// Normalize them so moving right seeks forward and moving up gets louder.
    mutating func update(deltaX: Double, deltaY: Double, precise: Bool,
                         inverted: Bool, phase: Phase, momentum: Bool,
                         horizontalEnabled: Bool = true,
                         verticalEnabled: Bool = true,
                         sensitivity: Double = 1) -> [Effect] {
        var effects: [Effect] = []
        if phase == .began || phase == .none {
            effects += reset()
        }
        if phase == .ended || phase == .cancelled || momentum {
            return effects + reset()
        }

        // A settings change must never leave a paused seek open.
        if seeking && !horizontalEnabled {
            seeking = false
            effects.append(.endSeek)
        }
        guard deltaX.isFinite, deltaY.isFinite,
              sensitivity.isFinite, sensitivity > 0 else { return effects }

        let x = deltaX * (inverted ? 1 : -1)
        let y = deltaY * (inverted ? -1 : 1)
        let gain = min(sensitivity, 10)

        if phase == .none {
            guard let oneShotAxis = Self.dominantAxis(x: x, y: y) else { return effects }
            return effects + Self.deltaEffect(axis: oneShotAxis, x: x, y: y,
                                             precise: precise, gain: gain,
                                             horizontalEnabled: horizontalEnabled,
                                             verticalEnabled: verticalEnabled)
        }

        var actionX = x
        var actionY = y
        if axis == nil {
            accumulatedX += x
            accumulatedY += y
            guard accumulatedX.isFinite, accumulatedY.isFinite else {
                return effects + reset()
            }
            let threshold = precise ? 3.0 : Self.minimumDelta
            guard max(abs(accumulatedX), abs(accumulatedY)) >= threshold,
                  let selected = Self.dominantAxis(x: accumulatedX, y: accumulatedY)
            else { return effects }
            axis = selected
            actionX = accumulatedX
            actionY = accumulatedY
            accumulatedX = 0
            accumulatedY = 0
        }

        guard let axis else { return effects }
        let delta = Self.deltaEffect(axis: axis, x: actionX, y: actionY,
                                     precise: precise, gain: gain,
                                     horizontalEnabled: horizontalEnabled,
                                     verticalEnabled: verticalEnabled)
        if axis == .horizontal && !delta.isEmpty && !seeking {
            seeking = true
            effects.append(.beginSeek)
        }
        return effects + delta
    }

    /// Returns the matching completion action before clearing gesture state.
    mutating func reset() -> [Effect] {
        let effects: [Effect] = seeking ? [.endSeek] : []
        axis = nil
        accumulatedX = 0
        accumulatedY = 0
        seeking = false
        return effects
    }

    private static let minimumDelta = 0.0001

    private static func dominantAxis(x: Double, y: Double) -> Axis? {
        let horizontal = abs(x)
        let vertical = abs(y)
        guard max(horizontal, vertical) >= minimumDelta else { return nil }
        if horizontal > vertical { return .horizontal }
        if vertical > horizontal { return .vertical }
        return nil
    }

    private static func deltaEffect(axis: Axis, x: Double, y: Double,
                                    precise: Bool, gain: Double,
                                    horizontalEnabled: Bool,
                                    verticalEnabled: Bool) -> [Effect] {
        switch axis {
        case .horizontal:
            guard horizontalEnabled, abs(x) >= minimumDelta else { return [] }
            let seconds = x * (precise ? 0.1 : 5) * gain
            return seconds.isFinite ? [.seek(seconds)] : []
        case .vertical:
            guard verticalEnabled, abs(y) >= minimumDelta else { return [] }
            let percent = y * (precise ? 0.25 : 5) * gain
            return percent.isFinite ? [.volume(percent)] : []
        }
    }
}
