import Foundation
import CoreGraphics

/// Geometry and one-shot fullscreen intent, independent of AppKit event delivery.
struct SPPlaybackPinchGesture {
    enum Mode: Equatable { case resizeWindow, fullscreen, disabled }
    enum Effect: Equatable {
        case resize(CGSize)
        case setFullscreen(Bool)
    }

    private var startingSize: CGSize?
    private var scale = 1.0
    private var requestedFullscreen = false

    mutating func reset() {
        startingSize = nil
        scale = 1
        requestedFullscreen = false
    }

    mutating func update(magnification: Double,
                         phase: SPPlaybackScrollGesture.Phase,
                         mode: Mode, contentSize: CGSize,
                         minimum: CGSize, maximum: CGSize,
                         isFullscreen: Bool) -> Effect? {
        if phase == .cancelled || mode == .disabled {
            reset()
            return nil
        }
        if phase == .began || phase == .none || startingSize == nil {
            reset()
            startingSize = contentSize
        }
        defer {
            if phase == .ended || phase == .none { reset() }
        }
        guard magnification.isFinite, magnification > -1,
              let start = startingSize,
              start.width.isFinite, start.height.isFinite,
              start.width > 0, start.height > 0 else { return nil }
        scale *= 1 + magnification
        guard scale.isFinite else { reset(); return nil }

        switch mode {
        case .disabled:
            return nil
        case .fullscreen:
            guard !requestedFullscreen else { return nil }
            if scale >= 1.1, !isFullscreen {
                requestedFullscreen = true
                return .setFullscreen(true)
            }
            if scale <= 0.9, isFullscreen {
                requestedFullscreen = true
                return .setFullscreen(false)
            }
            return nil
        case .resizeWindow:
            guard !isFullscreen,
                  minimum.width.isFinite, minimum.height.isFinite,
                  maximum.width.isFinite, maximum.height.isFinite,
                  maximum.width > 0, maximum.height > 0 else { return nil }
            let upper = min(maximum.width / start.width,
                            maximum.height / start.height)
            let lower = min(upper, max(max(0, minimum.width) / start.width,
                                       max(0, minimum.height) / start.height))
            let bounded = min(upper, max(lower, scale))
            let size = CGSize(width: start.width * bounded, height: start.height * bounded)
            guard bounded.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return .resize(size)
        }
    }
}
