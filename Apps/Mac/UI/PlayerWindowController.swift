import AppKit

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private let playerVC: PlayerViewController
    var playerViewController: PlayerViewController { playerVC }

    // Empty windows use the welcome view's fixed 640x360 size. Cold launches
    // and Dock reopens return to this size; opening media lets
    // resizeWindowToVideoAspect choose a larger width within the screen bounds.
    static let defaultContentSize = WelcomeView.contentSize

    static func mediaContentSize(on screen: NSScreen?) -> NSSize {
        let vis = (screen ?? NSScreen.main)?.visibleFrame.size ?? .zero
        return LaunchWindowSize.mediaContentSize(visible: vis)
    }

    private static let audioOnlyExtensions: Set<String> =
        Set(SPDefaultPlayer.formats.filter { !$0.isVideo }.flatMap { $0.exts })

    init(deferCore: Bool = false, mediaSize: Bool = false) {
        let contentSize = mediaSize ? Self.mediaContentSize(on: NSScreen.main)
                                    : Self.defaultContentSize

        playerVC = PlayerViewController(deferCoreCreation: deferCore,
                                        contentSize: contentSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        spLaunchMark("NSWindow 已建")

        window.acceptsMouseMovedEvents = true
        // The video and empty scrim can drag the window without requiring the
        // title bar. Interactive controls opt out: buttons and sliders already
        // do so, the timeline overrides mouseDownCanMoveWindow, and transient
        // overlays pass hit testing through.
        window.isMovableByWindowBackground = true

        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.center()
        // The app name is identical across locales. Use a literal during bootstrap
        // to avoid loading the localization catalog before the first window appears.
        // A media filename replaces it on open; idle states use L("app.displayName").
        window.title = "Khua"
        window.minSize = NSSize(width: 480, height: 270)
        window.isReleasedWhenClosed = false

        window.isRestorable = false
        spLaunchMark("窗口属性已设")
        super.init(window: window)
        window.contentViewController = playerVC
        spLaunchMark("contentVC 已挂（含 loadView）")
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PlayerWindowController: no coder path") }

    // AppDelegate owns multi-window close semantics: destroy non-final windows
    // and return the final one to the welcome state. Without a callback, keep
    // the conservative single-window behavior of stopping and showing welcome.
    var onWillClose: (@MainActor (PlayerWindowController) -> Void)?

    func windowWillClose(_ notification: Notification) {
        if let onWillClose {
            onWillClose(self)
        } else {
            playerVC.handleWindowClose()
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        playerVC.fullscreenTransitionFailed()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        playerVC.fullscreenTransitionFailed()
    }

    func open(url: URL) {

        prepareContentSizeBeforeFirstShow(for: url)

        window?.makeKeyAndOrderFront(nil)
        playerVC.open(url: url)
    }

    private func prepareContentSizeBeforeFirstShow(for url: URL) {
        guard let window, !window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let target = Self.audioOnlyExtensions.contains(url.pathExtension.lowercased())
            ? Self.defaultContentSize
            : Self.mediaContentSize(on: window.screen)
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - target.width) >= 1
                || abs(current.height - target.height) >= 1 else { return }

        if NSApp.windows.contains(where: { $0 !== window && $0.isVisible }) {
            window.spSetContentSizeKeepingCenter(target)
        } else {
            window.setContentSize(target)
            window.center()
        }
    }

    func showWindowForReopen() {
        guard let window else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        if !playerVC.hasOpenMedia, !window.styleMask.contains(.fullScreen) {
            // Closing already restores this size. Avoid an equal-size AppKit
            // mutation; exact comparison still repairs fractional mismatches.
            let current = window.contentRect(forFrameRect: window.frame).size
            if current != Self.defaultContentSize {
                window.setContentSize(Self.defaultContentSize)
            }
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        playerVC.noteWindowReexposed() // Retry work suppressed while the window was closed.
        if spDebugEnabled {
            NSLog("[UI] 热重开亮相耗时 %.1fms（进程常驻，Dock 点击→窗口上屏）",
                  (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
    }
}

extension NSWindow {

    func spSetContentSizeKeepingCenter(_ size: NSSize) {
        let before = frame
        setContentSize(size)
        var origin = NSPoint(x: (before.midX - frame.width / 2).rounded(),
                             y: (before.midY - frame.height / 2).rounded())
        if let vis = (screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(vis.minX, min(origin.x, vis.maxX - frame.width))
            origin.y = max(vis.minY, min(origin.y, vis.maxY - frame.height))
        }
        setFrameOrigin(origin)
    }
}
