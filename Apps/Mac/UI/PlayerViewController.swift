import AppKit
import UniformTypeIdentifiers

/// Cooperative cancellation for the CPU-only subtitle ranking attached to a
/// directory snapshot. Rapid Previous/Next must not leave a trail of obsolete
/// Unicode normalization/sort jobs competing with foreground playback.
private final class SPDirectorySubtitleRankingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let result = cancelled
        lock.unlock()
        return result
    }
}

@MainActor
private final class LegacyChromeAdapter: PlayerChromePresenting {
    private var lastRenderedModel: ChromePresentation?
    private let renderPlaying: (Bool) -> Void
    private let renderTimeline: (Double, Double, Double) -> Void
    private let renderVolume: (Double, Bool, VolumeBoostPresentation) -> Void
    private let showHandler: () -> Void
    private let hideHandler: () -> Void
    private let layoutHandler: (NSRect) -> Void

    init(renderPlaying: @escaping (Bool) -> Void,
         renderTimeline: @escaping (Double, Double, Double) -> Void,
         renderVolume: @escaping (Double, Bool, VolumeBoostPresentation) -> Void,
         show: @escaping () -> Void,
         hide: @escaping () -> Void,
         layout: @escaping (NSRect) -> Void) {
        self.renderPlaying = renderPlaying
        self.renderTimeline = renderTimeline
        self.renderVolume = renderVolume
        self.showHandler = show
        self.hideHandler = hide
        self.layoutHandler = layout
    }

    func render(_ presentation: ChromePresentation) {
        let previous = lastRenderedModel
        if previous == nil || previous?.isPlaying != presentation.isPlaying {
            renderPlaying(presentation.isPlaying)
        }
        if previous == nil || previous?.position != presentation.position ||
           previous?.duration != presentation.duration ||
           previous?.playbackRate != presentation.playbackRate {
            renderTimeline(presentation.position, presentation.duration,
                           presentation.playbackRate)
        }
        if previous == nil || previous?.volumePercent != presentation.volumePercent ||
           previous?.isMuted != presentation.isMuted ||
           previous?.volumeBoost != presentation.volumeBoost {
            renderVolume(presentation.volumePercent, presentation.isMuted,
                         presentation.volumeBoost)
        }
        lastRenderedModel = presentation
    }

    func show() { showHandler() }
    func hide() { hideHandler() }
    func layout(in parentBounds: NSRect) { layoutHandler(parentBounds) }
    func cancelTransientInteraction() {}
}

final class PlayerViewController: NSViewController, SPPlayerCoreDelegate, NSMenuItemValidation {
    /// One low-priority lane process-wide. Subtitle ranking is CPU-only and may
    /// cover thousands of names; serializing it prevents several player windows
    /// from turning a background convenience into a burst of foreground CPU.
    private static let directorySubtitleRankingQueue = DispatchQueue(
        label: "dev.khuaplayer.directory-subtitle-ranking", qos: .utility)

    private let playerView = PlayerView()
    private var core: SPPlayerCore?
    private let playbackSleep = SPPlaybackSleepController()

    private lazy var dragEffect = WindowDragEffect()

    private func handleVideoMouseDown(_ event: NSEvent) {
        noteVideoMouseDown(event)
        guard let core, core.hasEverPresentedThisSession, WindowDragEffect.enabled else { return }

        guard dragEffect.mouseDown(event, in: playerView) else { return }
        core.prewarmWindowDragEffect()
    }
    private var welcomeReloadPending = false

    static let dbg = spDebugEnabled
    // Read once, after the first frame when the hook is first consulted. The
    // ordinary 30 Hz UI callback must not recreate the environment dictionary.
    private static let captionsAutomationSpec: String? = {
#if SP_APP_STORE
        return nil
#else
        let environment = ProcessInfo.processInfo.environment
        guard spDebugEnabled || environment["SP_AUTOMATION"] != nil,
              let spec = environment["SP_CAPTIONS_AUTO"], !spec.isEmpty else { return nil }
        return spec
#endif
    }()
#if SP_APP_STORE
    static let useNewUI = true
    static let pinControls = false
#else

    static let useNewUI = ProcessInfo.processInfo.environment["SP_UI"] != "legacy"

    static let pinControls = ProcessInfo.processInfo.environment["SP_UI_PIN"] != nil
#endif
    private var chrome: SPChromeView?
    private var chromePresenter: PlayerChromePresenting?
    private var chromePresentation: ChromePresentation = .empty
    // Boosting requires a second action beyond 100% and locks again at or below 100%.
    private var volumeBoostUnlocked = false
    private var volumeBoostPrompted = false

    private lazy var controlBar = NSVisualEffectView()
    private lazy var playButton = NSButton()
    private lazy var rewindButton = NSButton()
    private lazy var forwardButton = NSButton()
    private lazy var timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private lazy var slider = ScrubSlider()
    private lazy var rateLabel = NSTextField(labelWithString: "1.0x")
    private lazy var volumeSlider = NSSlider()
    private lazy var volumeLabel = NSTextField(labelWithString: "100%")
    private lazy var muteButton = NSButton()
    private lazy var hoverTimeLabel = NSTextField(labelWithString: "")
    private var isScrubbing = false
    private var scrollGesture = SPPlaybackScrollGesture()
    private var pinchGesture = SPPlaybackPinchGesture()
    private var scrollSeekTarget: Double?
    private var scrollSeekWasPlaying = false
    private var scrollGestureTimeout: Timer?
    private var gestureSeek = SPPlaybackGestureSeek()
    private var gestureSeekTimer: Timer?
    private var gestureFullscreenTransition = false
    private var scrubMuteEngaged = false
    private var scrubMuteAllowed = false

    private var idleHint: NSTextField?
    // The welcome view is lazy: install it only after viewDidAppear remains idle
    // for 0.3 seconds, so file launches perform no welcome construction. The
    // welcome state uses a fixed non-resizable 640x360 window.
    private var welcome: WelcomeView?

    private var failureTracker = PlayerFailureTracker()
    private var lastOpenRequestURL: URL?
    private var lastFailedOpenURL: URL?
    private var shownFailureReason: PlayerFailureReason?

    private var everStartedPlayback = false

    private var windowAwaitingFirstMediaFit = true

    private var recentRecordedThisOpen = false

    private var replayResumeResetArmedPath: String?
    private var screenObserverInstalled = false

    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    private var compareActive = false
    private var compareOverlay: NSView?
    private var compareDivider: NSView?
    private var compareLeftLabel: NSTextField?
    private var compareRightLabel: NSTextField?

    private var turbo = SPTurboGesture()
    private var turboTimer: Timer?
    private var turboHUD: SPTurboHUDView?
    private var playbackNotice: SPPlaybackNoticeView?
    private var fullscreenApplied = false
    private var hideControlsTimer: Timer?
    private var playbackCursor: SPPlaybackCursorController?
    private var isControlBarVisible = false

    private var repeatTimer: Timer?
    private var repeatAction: (() -> Void)?

    private var repeatNextInterval: (() -> TimeInterval)?

    private var seekStepInFlight = false
    private var seekStepIssuedAt: TimeInterval = 0
    private var burstTarget: Double = 0
    private var burstStepCount = 0

    private var burstWasPlaying = false

    private var mediaList: [URL] = []
    private var currentMediaIndex = -1
    private var playlistScanGeneration: UInt64 = 0
    /// Last directory snapshot stays with the window across Previous/Next.
    /// The process-wide index coalesces physical listings across windows; this
    /// local reference makes navigation publish the next list immediately.
    private var directorySnapshot: SPDirectoryMediaSnapshot?
    private struct PendingDirectoryScan {
        let mediaURL: URL
        let generation: UInt64
        let uiLanguage: String
        let forceRefresh: Bool
    }
    private var pendingDirectoryScan: PendingDirectoryScan?
    private var directoryScanPollScheduledFor: UInt64?
    private var directoryScanPollDeadline: TimeInterval = 0
    private var directoryScanPollSequence: UInt64 = 0
    private var directoryScanPollAttempt = 0
    private var directoryScanNotBefore: TimeInterval = 0
    private var directoryStorageAdmissionNextCheck: TimeInterval = 0
    private var directorySnapshotRequest: SPDirectoryMediaRequest?
    private var directorySubtitleRankingCancellation:
        SPDirectorySubtitleRankingCancellation?
#if SP_APP_STORE
    // NSOpenPanel/Finder grants arrive already active in the App Sandbox. Keep
    // exactly one balanced grant for the current media and external subtitle.
    private var activeGrantedDocumentURL: URL?
    private var activeGrantedSubtitleURL: URL?

    private func releaseActiveDocumentGrant() {
        activeGrantedDocumentURL?.stopAccessingSecurityScopedResource()
        activeGrantedDocumentURL = nil
    }

    private func releaseActiveSubtitleGrant() {
        activeGrantedSubtitleURL?.stopAccessingSecurityScopedResource()
        activeGrantedSubtitleURL = nil
    }

    private var failedDocumentGrantURL: URL?

    private func retainFailedDocumentGrant() {
        releaseFailedDocumentGrant()
        failedDocumentGrantURL = activeGrantedDocumentURL
        activeGrantedDocumentURL = nil
    }

    private func releaseFailedDocumentGrant() {
        failedDocumentGrantURL?.stopAccessingSecurityScopedResource()
        failedDocumentGrantURL = nil
    }

#endif

    deinit {
#if SP_APP_STORE
        activeGrantedDocumentURL?.stopAccessingSecurityScopedResource()
        activeGrantedSubtitleURL?.stopAccessingSecurityScopedResource()
        failedDocumentGrantURL?.stopAccessingSecurityScopedResource()
#endif
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }

        if let monitor = clickUpMonitor {
            MainActor.assumeIsolated { NSEvent.removeMonitor(monitor) }
        }

        if spDebugEnabled {
            NSLog("[UI] PlayerViewController 已销毁（窗口关闭释放）")
        }
    }

    private var hasMediaSession = false

    var hasOpenMedia: Bool { hasMediaSession }

    private var warmerStreamingEngaged = false

    private(set) var openMediaPath: String?

    private var externalSubtitleCandidates: [URL] = []
    private var directoryAutoSubtitleCandidates: [URL] = []
    private var activeExternalSubtitleURL: URL?
    private var pendingSubtitleAutoload = false

    private var pendingExternalSubtitleURL: URL?
    private var userTouchedSubtitleSelection = false

    private var captionsControllerStorage: AnyObject?
    private var captionsAutomationFired = false
    private var captionsAttachChecked = false
    @available(macOS 26.0, *)
    private var captions: CaptionsController? {
        captionsControllerStorage as? CaptionsController
    }
    @available(macOS 26.0, *)
    private func captionsController() -> CaptionsController {
        if let c = captions { return c }
        let c = CaptionsController()

        c.onDisplayAttached = { [weak self] in
            guard let self else { return }
            self.activeExternalSubtitleURL = nil
            self.userTouchedSubtitleSelection = true
        }
        c.onDisplaySelection = { [weak self] in
            self?.core?.cancelPendingSubtitleLoad()
        }
        captionsControllerStorage = c
        return c
    }
    private var lastSaveTime: TimeInterval = 0

    private static let mediaExtensions: Set<String> =
        Set(SPDefaultPlayer.formats.flatMap { $0.exts })

    override func loadView() {

        view = NSView(frame: NSRect(origin: .zero, size: initialContentSize))

        playerView.frame = view.bounds
        playerView.autoresizingMask = [.width, .height]
        playerView.onDoubleClick = { [weak self] in
            guard let self else { return }

            showControlsTemporarily()
            perform(.toggleFullscreen)
        }
        playerView.onMouseDown = { [weak self] event in self?.handleVideoMouseDown(event) }
        playerView.onMouseUp = { [weak self] event in self?.resolveClickCandidate(event) }
        dragEffect.apply = { [weak self] strength, colorStrength, anchor in
            self?.core?.setWindowDragEffectStrength(strength, colorStrength: colorStrength, anchorPx: anchor)
        }
        playerView.onKeyDown = { [weak self] event in self?.handleKey(event) }
        playerView.onKeyUp = { [weak self] event in self?.handleKeyUp(event) }
        playerView.onScrollWheel = { [weak self] event in
            self?.handlePlaybackScroll(event) ?? false
        }
        playerView.onMagnify = { [weak self] event in
            self?.handlePlaybackMagnify(event) ?? false
        }
        playerView.onFileDropped = { [weak self] url in self?.open(url: url) }
        view.addSubview(playerView)

        if !deferCoreCreation {
            ensureCore()
        }

    }

    private let deferCoreCreation: Bool
    private let initialContentSize: NSSize

    init(deferCoreCreation: Bool = false,
         contentSize: NSSize = WelcomeView.contentSize) {
        self.deferCoreCreation = deferCoreCreation
        self.initialContentSize = contentSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PlayerViewController: no coder path") }

    func ensureCore() {
        guard core == nil else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let c = SPPlayerCore(view: playerView)
        c.delegate = self

        core = c

        if view.window != nil { c.displayScreenChanged() }
        if Self.dbg {
            NSLog("[UI] SPPlayerCore 创建耗时 %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
    }

    private var chromeInstalled = false

    private var chromeInstallPending = false
    static let chromeInstallFallback: TimeInterval = 0.3

    private func scheduleChromeInstallAfterFirstFrame() {
        guard !chromeInstalled else { return }
        chromeInstallPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeInstallFallback) { [weak self] in
            self?.installPendingChrome()
        }
    }

    private func installPendingChromeSoon() {
        guard chromeInstallPending else { return }
        DispatchQueue.main.async { [weak self] in self?.installPendingChrome() }
    }

    private func installPendingChrome() {
        guard chromeInstallPending else { return }
        chromeInstallPending = false
        installChromeIfNeeded()
        (NSApp.delegate as? AppDelegate)?.ensureMainMenu()
    }

    private func installChromeIfNeeded() {
        guard !chromeInstalled, view.window != nil else { return }
        chromeInstalled = true
        let tChrome = CFAbsoluteTimeGetCurrent()
        if Self.useNewUI {
            setupNewChrome()
        } else {
            setupControlBar()
        }
        replayCoreState()
        playbackCursor = SPPlaybackCursorController(view: playerView)
        playbackCursor?.setHasVideo(hasVideoSession)

        if hasMediaSession { showControlsTemporarily() }
        playbackCursor?.setChromeHidden(!isControlBarVisible)
        if spDebugEnabled {
            NSLog("[UI] chrome 延迟安装耗时 %.1fms",
                  (CFAbsoluteTimeGetCurrent() - tChrome) * 1000)
        }
    }

    private func replayCoreState() {
        guard let core else { return }
        transitionPresentation(.stateChanged(presentationLifecycle(for: core.state),
                                             presentationSnapshot(core: core)))
    }

    private func transitionPresentation(_ event: PlayerPresentationEvent) {
        chromePresentation = PlayerPresentationReducer.reduce(chromePresentation, event)
        chromePresenter?.render(chromePresentation)
    }

    private func presentationSnapshot(core: SPPlayerCore) -> PlayerPresentationSnapshot {
        PlayerPresentationSnapshot(
            position: core.position,
            duration: core.duration,
            playbackRate: core.playbackRate,
            volumePercent: Double(core.volume) * 100,
            isMuted: core.isMuted,
            volumeBoost: currentVolumeBoostPresentation,
            hdrDescription: core.hdrDescription,
            hdrDetail: core.hdrDetailDescription,
            motion: currentMotionPresentation(core: core),
            xdr: currentXDRPresentation(core: core)
        )
    }

    private func presentationLifecycle(for state: SPPlayerState) -> PlayerPresentationLifecycle {
        if !hasMediaSession && state != .failed { return .empty }
        switch state {
        case .idle: return .idle
        case .opening: return .opening
        case .ready: return .paused
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .failed: return .failed
        @unknown default: return .idle
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(playerView)
        installTrackingArea()

        if welcomeReloadPending, let w = welcome, !w.isHidden {
            welcomeReloadPending = false
            w.reload()
        }

#if !SP_APP_STORE
        // SP_FULLSCREEN=1 starts in fullscreen for repeatable rendering-load
        // measurements. GPU work scales with output pixels, so a fixed fullscreen
        // surface removes window-size variance. Apply it only once so a manual
        // fullscreen exit remains respected.
        if !fullscreenApplied,
           ProcessInfo.processInfo.environment["SP_FULLSCREEN"] != nil,
           let win = view.window, !win.styleMask.contains(.fullScreen) {
            fullscreenApplied = true
            win.toggleFullScreen(nil)
        }
#endif

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let core = self.core, core.state == .idle,
                  !self.hasMediaSession,
                  self.welcome == nil || self.welcome?.isHidden == true else { return }
            self.showEmptyState()
        }

        let warmDelay: TimeInterval = (core?.state ?? .idle) == .idle ? 0.5 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + warmDelay) {

            OpenPanelWarmer.warm(trigger: .idle)
        }

        if !screenObserverInstalled, let win = view.window {
            screenObserverInstalled = true
            installWindowObservers(win)
        }
    }

    private func installWindowObservers(_ win: NSWindow) {
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: SPPlaybackGestureSettings.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelPlaybackScroll()
                self?.pinchGesture.reset()
            }
        })
        for name in [NSWindow.willEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification] {
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: win, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.gestureFullscreenTransition = true
                    self?.cancelPlaybackScroll()
                }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: win, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.gestureFullscreenTransition = false }
            })
        }
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: win, queue: .main
        ) { [weak self] _ in
            self?.core?.displayScreenChanged()
        })

        let reevaluateThumbSuspension = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let key = NSApp.keyWindow
                self.core?.setTimelinePreviewSuspended(
                    key != nil && key !== self.view.window)
            }
        }
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main
        ) { [weak self] _ in
            reevaluateThumbSuspension()

            self?.core?.setWindowVisibleForRendering(true)
            self?.runPendingDirectoryScanWhenFirstFramePresented()
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: win, queue: .main
        ) { [weak self] _ in
            self?.setMotionCompare(false)
            self?.stopRepeat()
            self?.endTurbo(reason: "resignKey")
            MainActor.assumeIsolated {
                self?.cancelPlaybackScroll()
                if self?.gestureFullscreenTransition != true { self?.pinchGesture.reset() }
            }
            reevaluateThumbSuspension()
        })

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: win, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            let visible = w.occlusionState.contains(.visible)
            self.core?.setWindowVisibleForRendering(visible)
            if visible { self.runPendingDirectoryScanWhenFirstFramePresented() }
            else { self.scheduleQuietOpenPanelPrewarm() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: win, queue: .main
        ) { [weak self] _ in
            self?.core?.setWindowVisibleForRendering(true)
            self?.runPendingDirectoryScanWhenFirstFramePresented()
        })

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.core?.displayScreenChanged()
        })

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .spRecentPlaysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let w = self.welcome, !w.isHidden else { return }

            guard self.view.window?.isVisible == true else {
                self.welcomeReloadPending = true
                return
            }
            w.reload()
        })

        core?.displayScreenChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        guard chromeInstalled else { return }
        chromePresenter?.layout(in: view.bounds)
        if let idleHint, !idleHint.isHidden { layoutIdleHint() }
        if let overlay = compareOverlay, !overlay.isHidden { layoutCompareOverlay() }
        if let hud = turboHUD, !hud.isHidden { layoutTurboHUD() }
        if let notice = playbackNotice, !notice.isHidden { layoutPlaybackNotice() }

        core?.notePausedLayoutChange()
    }

    private func installTrackingArea() {
        for ta in view.trackingAreas { view.removeTrackingArea(ta) }
        view.addTrackingArea(NSTrackingArea(rect: .zero,

                                            options: [.activeAlways, .inVisibleRect, .mouseMoved,
                                                      .mouseEnteredAndExited],
                                            owner: self))
    }

    private func setupNewChrome() {
        let c = SPChromeView()
        c.onPlayPause = { [weak self] in self?.perform(.togglePlayback) }
        c.onSeekRelative = { [weak self] d in self?.perform(.seekRelative(d)) }
        // Clicks and drags remain coarse keyframe seeks. This keeps each step
        // visible and its latency independent of GOP decode length.
        c.onScrubBegan = { [weak self] target in
            guard let self, !self.turbo.blocksPlaybackControls else { return }
            self.cancelPlaybackScroll()
            self.yieldDirectoryScanToForegroundIO()

            self.thumbTrailingRequest?.cancel()
            self.isScrubbing = true

            self.scrubMuteAllowed = false
            self.lastCoarseTarget = -1
            self.scrubCoarse(to: target)
        }
        c.onScrubCoarse = { [weak self] target in

            guard let self, !self.turbo.blocksPlaybackControls else { return }
            self.scrubMuteAllowed = true
            self.scrubCoarse(to: target)
        }

        c.onHoverTime = { [weak self] seconds in
            guard let self, let core = self.core else { return }
            self.yieldDirectoryScanToForegroundIO()
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastHoverHintAt >= 0.12,
               abs(seconds - self.lastHoverHintSec) >= 2.0 {
                self.lastHoverHintAt = now
                self.lastHoverHintSec = seconds
                core.prefetchScrubHint(at: seconds)
            }
        }

        c.previewImageProvider = { [weak self] t in

            var exact = ObjCBool(false)
            guard let obj = self?.core?.timelinePreviewImage(at: t, isExact: &exact),
                  CFGetTypeID(obj as CFTypeRef) == CGImage.typeID else { return nil }
            return (image: (obj as! CGImage), exact: exact.boolValue)
        }
        c.onHoverPreviewRequest = { [weak self] t in
            guard let self else { return }

            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastThumbReqAt >= 0.09 {
                self.lastThumbReqAt = now
                self.core?.requestTimelinePreview(at: t)
            }
            if self.thumbTrailingRequest == nil {
                self.thumbTrailingRequest = SPTrailingPreviewRequest { [weak self] t in
                    guard let self else { return }
                    self.lastThumbReqAt = ProcessInfo.processInfo.systemUptime
                    self.core?.requestTimelinePreview(at: t)
                }
            }
            self.thumbTrailingRequest?.submit(t)
        }
        c.onHoverPreviewCommit = { [weak self] t in
            guard let self else { return }
            self.yieldDirectoryScanToForegroundIO()

            self.thumbTrailingRequest?.cancel()
            self.lastThumbReqAt = ProcessInfo.processInfo.systemUptime
            self.core?.requestTimelinePreview(at: t)
        }
        c.onHoverExit = { [weak self] in
            guard let self else { return }

            self.thumbTrailingRequest?.cancel()
            self.core?.cancelTimelinePreview()
        }
        c.onScrubEnded = { [weak self] _, _ in
            guard let self else { return }

            self.commitPendingScrubSeek()
            self.isScrubbing = false

            if let core = self.core {
                self.transitionPresentation(.timelineChanged(
                    position: core.position,
                    duration: core.duration,
                    rate: core.playbackRate
                ))
            }
            if self.scrubMuteEngaged {
                self.scrubMuteEngaged = false
                self.core?.setMuted(false)
                self.publishVolumePresentation()
            }
            self.showControlsTemporarily()
        }
        c.onVolume = { [weak self] pct in self?.perform(.setVolumePercent(pct)) }
        c.onVolumeBoostIntent = { [weak self] in self?.handleVolumeBoostIntent() }
        c.onMute = { [weak self] in self?.perform(.toggleMute) }
        c.onFullscreen = { [weak self] in self?.perform(.toggleFullscreen) }
        c.onRateSelected = { [weak self] rate in self?.perform(.setPlaybackRate(rate)) }
        c.onMotionSmoothingToggle = { [weak self] in
            self?.perform(.toggleFrameInterpolation)
        }
        c.onXDRToggle = { [weak self] in self?.perform(.toggleXDR) }
        c.durationProvider = { [weak self] in self?.core?.duration ?? 0 }
        c.dustSnapshotProvider = { [weak self] in self?.core?.timelineDustSnapshot() }
        c.damageSnapshotProvider = { [weak self] in self?.core?.damageSnapshot() }
        view.addSubview(c, positioned: .above, relativeTo: playerView)
        c.layoutChrome(in: view.bounds)
        chrome = c
        chromePresenter = c
#if !SP_APP_STORE
        installChromeAutomationHooks()
#endif
    }

#if !SP_APP_STORE
    private var timelineSimTimer: DispatchSourceTimer?

    private func installTimelineSimulator(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return }
        let mode = parts[0]
        let tickMs = max(4.0, Double(parts[1]) ?? 16)
        let sweepS = max(0.5, Double(parts[2]) ?? 8)
        let lo = parts.count > 3 ? (Double(parts[3]) ?? 0.05) : 0.05
        let hi = parts.count > 4 ? (Double(parts[4]) ?? 0.95) : 0.95
        let ticksPerSweep = max(2, Int(sweepS * 1000 / tickMs))
        var tick = 0, sweep = 0
        var entered = false, pressing = false

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0,
                       repeating: .milliseconds(Int(tickMs)), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let chrome = self.chrome else { return }
            let i = tick % ticksPerSweep
            let u = Double(i) / Double(ticksPerSweep - 1)
            let r = sweep % 2 == 0 ? lo + (hi - lo) * u : hi - (hi - lo) * u
            if !entered { chrome.simulateTimelinePointer(.enter, ratio: r); entered = true }
            let wantScrub = mode == "scrub" || (mode == "mixed" && sweep % 2 == 1)
            if i == 0 {
                if wantScrub { chrome.simulateTimelinePointer(.press, ratio: r); pressing = true }
                else { chrome.simulateTimelinePointer(.move, ratio: r) }
            } else if i == ticksPerSweep - 1 {
                if pressing { chrome.simulateTimelinePointer(.release, ratio: r); pressing = false }
                else { chrome.simulateTimelinePointer(.move, ratio: r) }
                sweep += 1
            } else {
                chrome.simulateTimelinePointer(pressing ? .drag : .move, ratio: r)
            }
            tick += 1
        }
        timer.resume()
        timelineSimTimer = timer
    }

    private func installChromeAutomationHooks() {

        if ProcessInfo.processInfo.environment["SP_UI_HOVERTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let core = self.core, core.duration > 0 else { return }
                NSLog("[UITest] 模拟悬停请求 60%%")
                self.chrome?.onHoverPreviewRequest?(core.duration * 0.6)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self, let core = self.core, core.duration > 0 else { return }
                for pct in [0.1, 0.35, 0.6, 0.9] {
                    let r = self.chrome?.previewImageProvider?(core.duration * pct)
                    NSLog("[UITest] 预览查询 %.0f%%: %@", pct * 100,
                          r.map { "\($0.image.width)x\($0.image.height) exact=\($0.exact)" } ?? "nil")
                }
            }
        }

        if ProcessInfo.processInfo.environment["SP_UI_SEEKTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let chrome = self.chrome, let core = self.core, core.duration > 0 else { return }
                NSLog("[UITest] 模拟单击 60%%")
                chrome.onScrubBegan?(core.duration * 0.6)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    chrome.onScrubEnded?(core.duration * 0.6, false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                guard let self, let chrome = self.chrome, let core = self.core, core.duration > 0 else { return }
                NSLog("[UITest] 模拟拖动 30%%→70%%")
                chrome.onScrubBegan?(core.duration * 0.3)
                for i in 1...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.06) {
                        chrome.onScrubCoarse?(core.duration * (0.3 + 0.4 * Double(i) / 6.0))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    chrome.onScrubEnded?(core.duration * 0.7, true)
                }
            }
        }
        let env = ProcessInfo.processInfo.environment
        if spDebugEnabled || env["SP_AUTOMATION"] != nil,
           let spec = env["SP_UI_TLSIM"], !spec.isEmpty {
            installTimelineSimulator(spec)
        }
    }
#endif

    private func commitPendingScrubSeek() {
        scrubTimer?.invalidate()
        scrubTimer = nil
        guard core != nil, let target = pendingScrubTarget else { return }
        pendingScrubTarget = nil
        lastCoarseSeekAt = ProcessInfo.processInfo.systemUptime
        issueForegroundSeek(to: target, precise: false)
    }

    private func scrubCoarse(to target: Double) {
        guard let core, core.duration > 0 else { return }
        yieldDirectoryScanToForegroundIO()
        lastRelSeekTarget = -1

        if isScrubbing && scrubMuteAllowed && !scrubMuteEngaged && !core.isMuted {
            scrubMuteEngaged = true
            core.setMuted(true)
        }
        if abs(target - lastCoarseTarget) < 0.0005 { return }
        lastCoarseTarget = target
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCoarseSeekAt >= 0.05 {
            lastCoarseSeekAt = now
            scrubTimer?.invalidate()
            scrubTimer = nil
            pendingScrubTarget = nil
            issueForegroundSeek(to: target, precise: false)
        } else {
            scrubTimer?.invalidate()
            pendingScrubTarget = target
            scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self, self.core != nil else { return }

                guard let t = self.pendingScrubTarget else { return }
                self.pendingScrubTarget = nil
                self.scrubTimer = nil
                self.lastCoarseSeekAt = ProcessInfo.processInfo.systemUptime
                self.issueForegroundSeek(to: t, precise: false)
            }
        }
    }

    private func setupControlBar() {
        controlBar.material = .hudWindow
        controlBar.blendingMode = .withinWindow
        controlBar.state = .active
        controlBar.wantsLayer = true
        controlBar.layer?.cornerRadius = 8
        controlBar.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 48)

        controlBar.autoresizingMask = [.width, .maxYMargin]
        controlBar.alphaValue = 0

        for b in [playButton, rewindButton, forwardButton, muteButton] {
            b.refusesFirstResponder = true
            b.bezelStyle = .texturedRounded
            b.target = self
        }
        playButton.title = "⏸"
        playButton.action = #selector(playPauseTapped)
        rewindButton.title = "⏪ 5s"
        rewindButton.action = #selector(rewindTapped)
        forwardButton.title = "5s ⏩"
        forwardButton.action = #selector(forwardTapped)
        muteButton.title = "🔊"
        muteButton.action = #selector(muteTapped)

        slider.refusesFirstResponder = true
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onTrackBegan = { [weak self] in self?.sliderTrackingBegan() }
        slider.onTrackEnded = { [weak self] in self?.sliderTrackingEnded() }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.alignment = .center

        rateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rateLabel.textColor = .white
        rateLabel.alignment = .center

        volumeSlider.refusesFirstResponder = true
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = 100
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)

        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeLabel.textColor = .white
        volumeLabel.alignment = .right

        hoverTimeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hoverTimeLabel.textColor = .white
        hoverTimeLabel.wantsLayer = true
        hoverTimeLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hoverTimeLabel.isHidden = true

        for v in [playButton, rewindButton, forwardButton, slider, timeLabel,
                  rateLabel, volumeSlider, volumeLabel, muteButton] as [NSView] {
            v.autoresizingMask = []
            controlBar.addSubview(v)
        }
        view.addSubview(controlBar, positioned: .above, relativeTo: playerView)

        view.addSubview(hoverTimeLabel, positioned: .above, relativeTo: controlBar)
        layoutControls()
        chromePresenter = LegacyChromeAdapter(
            renderPlaying: { [weak self] playing in
                self?.playButton.title = playing ? "⏸" : "▶"
            },
            renderTimeline: { [weak self] position, duration, rate in
                guard let self else { return }
                self.timeLabel.stringValue = Self.formatTime(position, duration)
                self.slider.doubleValue = duration > 0 ? position / duration : 0
                self.rateLabel.stringValue = String(format: "%.1fx", rate)
            },
            renderVolume: { [weak self] percent, muted, boost in
                guard let self else { return }
                // Keep the legacy slider range aligned with the boost state.
                self.volumeSlider.maxValue = boost == .unlocked ? 500 : 100
                self.volumeSlider.doubleValue = percent
                self.volumeLabel.stringValue = "\(Int(percent.rounded()))%"
                self.muteButton.title = muted || percent == 0 ? "🔇" : "🔊"
            },
            show: { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.controlBar.animator().alphaValue = 1
                }
            },
            hide: { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    self.controlBar.animator().alphaValue = 0
                }
            },
            layout: { [weak self] _ in self?.layoutControls() }
        )
    }

    private func layoutControls() {
        let W = controlBar.bounds.width
        let btnY: CGFloat = 8, btnH: CGFloat = 32
        let midY: CGFloat = 16, midH: CGFloat = 16
        let gap: CGFloat = 8

        playButton.frame    = NSRect(x: gap, y: btnY, width: 36, height: btnH)
        rewindButton.frame  = NSRect(x: playButton.frame.maxX + 4, y: btnY, width: 54, height: btnH)
        forwardButton.frame = NSRect(x: rewindButton.frame.maxX + 4, y: btnY, width: 54, height: btnH)
        timeLabel.frame     = NSRect(x: forwardButton.frame.maxX + gap, y: midY, width: 120, height: midH)

        muteButton.frame    = NSRect(x: W - gap - 44, y: btnY, width: 44, height: btnH)
        volumeSlider.frame  = NSRect(x: muteButton.frame.minX - 4 - 80, y: midY, width: 80, height: midH)
        volumeLabel.frame   = NSRect(x: volumeSlider.frame.minX - 4 - 42, y: midY, width: 42, height: midH)
        rateLabel.frame     = NSRect(x: volumeLabel.frame.minX - gap - 40, y: midY, width: 40, height: midH)

        let sliderX = timeLabel.frame.maxX + gap
        let sliderW = max(rateLabel.frame.minX - gap - sliderX, 60)
        slider.frame = NSRect(x: sliderX, y: 14, width: sliderW, height: 20)
    }

    private var hideDeadline: TimeInterval = 0

    private func showControlsTemporarily() {

        guard hasMediaSession else { return }
        hideDeadline = ProcessInfo.processInfo.systemUptime + 2.5
        guard !isControlBarVisible else { return }
        isControlBarVisible = true
        if Self.dbg { NSLog("[Chrome] 显示") }
        chromePresenter?.show()
        playbackCursor?.setChromeHidden(false)
        armHideTimer(after: 2.5)
    }

    private func armHideTimer(after t: TimeInterval) {
        hideControlsTimer?.invalidate()
        guard !Self.pinControls else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            guard let self else { return }
            let remain = self.hideDeadline - ProcessInfo.processInfo.systemUptime
            if remain > 0.05 {
                self.armHideTimer(after: remain)
            } else {
                self.hideControls()
            }
        }
        timer.tolerance = 0.5
        hideControlsTimer = timer
    }

    private func hideControls() {
        guard isControlBarVisible else { return }
        if isScrubbing { armHideTimer(after: 1.0); return }

        if Self.useNewUI, let chrome, !chrome.isHidden, let win = view.window {
            let p = view.convert(win.mouseLocationOutsideOfEventStream, from: nil)
            if chrome.hitTest(p) != nil { armHideTimer(after: 1.0); return }
        }
        isControlBarVisible = false
        if Self.dbg { NSLog("[Chrome] 空闲隐藏") }
        chromePresenter?.hide()
        playbackCursor?.setChromeHidden(true)
    }

    private func dismissControlsNow() {
        guard isControlBarVisible, !Self.pinControls else { return }
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        isControlBarVisible = false
        chromePresenter?.hide()
        playbackCursor?.setChromeHidden(true)
    }

    private var clickCandidate: (origin: NSPoint, pointer: NSPoint)?

    nonisolated(unsafe) private var clickUpMonitor: Any?
    private static let clickSlop: CGFloat = 4

    private func noteVideoMouseDown(_ event: NSEvent) {
        clickCandidate = nil

        guard event.type == .leftMouseDown, event.clickCount == 1,
              !event.modifierFlags.contains(.control),
              hasMediaSession, let win = view.window else { return }
        clickCandidate = (win.frame.origin, NSEvent.mouseLocation)
        if clickUpMonitor == nil {

            clickUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDragged]) { [weak self] ev in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ev.type == .leftMouseDragged {
                        self.cancelClickCandidateIfDragged()
                    } else {
                        self.resolveClickCandidate(ev)
                    }
                }
                return ev
            }
        }
    }

    private func cancelClickCandidateIfDragged() {
        guard let cand = clickCandidate, let win = view.window else { return }
        let p = NSEvent.mouseLocation
        if win.frame.origin != cand.origin || hypot(p.x - cand.pointer.x, p.y - cand.pointer.y) > Self.clickSlop {
            clickCandidate = nil
        }
    }

    private func resolveClickCandidate(_ event: NSEvent) {
        guard let cand = clickCandidate else { return }
        clickCandidate = nil
        guard let win = view.window, event.window === win else { return }
        let p = NSEvent.mouseLocation
        let dist = hypot(p.x - cand.pointer.x, p.y - cand.pointer.y)
        if win.frame.origin != cand.origin || dist > Self.clickSlop {
            if Self.dbg { NSLog("[Chrome] 松开=拖动 位移=%.1fpt 窗口动=%d", dist, win.frame.origin != cand.origin ? 1 : 0) }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Self.dbg { NSLog("[Chrome] 单击 → %@", self.isControlBarVisible ? "隐藏" : "唤出") }
            if self.isControlBarVisible { self.dismissControlsNow() } else { self.showControlsTemporarily() }
        }
    }

    override func mouseExited(with event: NSEvent) {

        guard isControlBarVisible, !isScrubbing, let win = view.window,
              !win.frame.contains(NSEvent.mouseLocation) else { return }
        if Self.dbg { NSLog("[Chrome] 指针离开窗口 → 隐藏") }
        dismissControlsNow()
    }

    override func mouseMoved(with event: NSEvent) {

        guard view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
        showControlsTemporarily()
        if Self.useNewUI { return }

        let p = view.convert(event.locationInWindow, from: nil)
        if let core, core.duration > 0, slider.frame.contains(p) {
            let ratio = max(0, min(1, (p.x - slider.frame.minX) / max(slider.frame.width, 1)))
            let t = ratio * core.duration
            hoverTimeLabel.stringValue = Self.formatTime(t, core.duration)
            hoverTimeLabel.isHidden = false
            hoverTimeLabel.frame = NSRect(x: min(max(p.x - 40, 4), view.bounds.width - 88),
                                          y: controlBar.frame.maxY + 4, width: 84, height: 16)
        } else {
            hoverTimeLabel.isHidden = true
        }
    }

    // Opening text uses the glimmer unless Reduce Motion is enabled.
    // Instantiate the fallback label only when it is shown.
    private func setIdleHintVisible(_ visible: Bool, text: String? = nil) {
        if visible {
            if text != nil,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                idleHint?.isHidden = true
                scheduleOpeningGlimmer()
                return
            }
            let label: NSTextField
            if let existing = idleHint {
                label = existing
            } else {
                label = NSTextField(labelWithString: L("hint.dropOrOpen"))
                label.font = .systemFont(ofSize: 15, weight: .medium)
                label.textColor = NSColor(white: 1, alpha: 0.45)
                label.alignment = .center
                view.addSubview(label)
                idleHint = label
            }
            label.stringValue = text ?? L("hint.dropOrOpen")
            layoutIdleHint()
            label.isHidden = false
        } else {
            idleHint?.isHidden = true
            dismissOpeningGlimmer()
        }
    }

    // Show the opening glimmer only after 300 ms, then remove it as soon as the
    // opening state ends. Fast local opens never install the view.
    private var openingGlimmerView: SPOpeningGlimmerView?
    private var openingGlimmerToken = 0
    private var openingGlimmerShownAt: CFTimeInterval = 0
#if SP_INTERNAL_BUILD && !SP_APP_STORE
    // Internal demo mode bypasses the delay and holds the effect for N seconds.
    private static let openFxDemoHold: Double? = {
        guard let v = ProcessInfo.processInfo.environment["SP_OPENFX_DEMO"],
              let s = Double(v), s > 0 else { return nil }
        return s
    }()
#else
    private static let openFxDemoHold: Double? = nil
#endif

    private func scheduleOpeningGlimmer() {
        openingGlimmerToken &+= 1
        let token = openingGlimmerToken
        let threshold = Self.openFxDemoHold != nil ? 0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold) { [weak self] in
            guard let self, token == self.openingGlimmerToken,
                  self.openingGlimmerView == nil,
                  self.core?.state == .opening || Self.openFxDemoHold != nil
            else { return }
            let size = SPOpeningGlimmerView.preferredSize
            let v = SPOpeningGlimmerView(frame: NSRect(
                x: (self.view.bounds.width - size.width) / 2,
                y: (self.view.bounds.height - size.height) / 2,
                width: size.width, height: size.height))
            v.autoresizingMask = [.minXMargin, .maxXMargin,
                                  .minYMargin, .maxYMargin]
            v.alphaValue = 0
            self.view.addSubview(v, positioned: .above,
                                 relativeTo: self.playerView)
            self.openingGlimmerView = v
            self.openingGlimmerShownAt = CACurrentMediaTime()
            if Self.dbg { NSLog("[UI] Opening glimmer installed") }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                v.animator().alphaValue = 1
            }
        }
    }

    private func dismissOpeningGlimmer() {
        openingGlimmerToken &+= 1 // Invalidate a delayed installation.
        guard let v = openingGlimmerView else { return }
        openingGlimmerView = nil
        // Internal holds detach this instance from subsequent open cycles.
        if let hold = Self.openFxDemoHold {
            let remaining = hold - (CACurrentMediaTime() - openingGlimmerShownAt)
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                    Self.fadeOutGlimmer(v)
                }
                return
            }
        }
        Self.fadeOutGlimmer(v)
    }

    private static func fadeOutGlimmer(_ v: SPOpeningGlimmerView) {
        if dbg { NSLog("[UI] Opening glimmer removed") }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            v.animator().alphaValue = 0
        }, completionHandler: { v.removeFromSuperview() })
    }

    private func layoutIdleHint() {
        guard let label = idleHint else { return }
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (view.bounds.width - label.frame.width) / 2,
                                     y: (view.bounds.height - label.frame.height) / 2)
    }

    func showWelcomeNotice(_ text: String) {
        welcome?.showTransientNotice(text)
    }

    func showEmptyState() {
        setIdleHintVisible(false)

        if let window = view.window, !window.styleMask.contains(.fullScreen) {
            window.styleMask.remove(.resizable)
            window.contentAspectRatio = .zero
            let target = WelcomeView.contentSize
            let current = window.contentRect(forFrameRect: window.frame).size
            if abs(current.width - target.width) >= 1
                || abs(current.height - target.height) >= 1 {
                window.setContentSize(target)
                if !window.isVisible || !everStartedPlayback {

                    window.center()
                }
            }

            window.titleVisibility = .hidden
            windowAwaitingFirstMediaFit = true
        }
        let w: WelcomeView
        if let existing = welcome {
            w = existing
        } else {
            let t0 = CFAbsoluteTimeGetCurrent()
            w = WelcomeView(frame: view.bounds)
            w.autoresizingMask = [.width, .height]
            w.onOpenFile = { [weak self] in self?.presentOpenDocumentPanel() }
            // A 120 ms hover dwell filters incidental pointer crossings.
            // Leaving cancels pending preparation. Once synchronous construction
            // starts, newly queued keyboard input waits for it to finish.
            w.onOpenIntent = { [weak self] in self?.scheduleOpenPanelHoverPrewarm() }
            w.onOpenIntentEnd = { [weak self] in self?.cancelOpenPanelHoverPrewarm() }
            w.onPlay = { [weak self] entry in self?.openRecentEntry(path: entry.path) }
            w.onClearAll = { (NSApp.delegate as? AppDelegate)?.clearAllHistoryAction(nil) }
#if !SP_APP_STORE
            w.onSetDefault = { [weak self, weak w] in
                SPDefaultPlayer.presentDialog(over: self?.view.window,
                                              onApplied: { w?.hideSetDefaultOffer() })
            }
            // Dismiss the offer permanently and point to the menu entry.
            w.onSetDefaultDismiss = { [weak w] in
                SPDefaultPlayer.markWelcomeDismissed()
                w?.showTransientNotice(L("welcome.setDefault.dismissed"))
            }
#endif
            view.addSubview(w)
            welcome = w
            if Self.dbg {
                NSLog("[UI] 欢迎屏安装耗时 %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
        w.reload()
        w.isHidden = false
        w.prepareTextureIfNeeded()
        scheduleSetDefaultOfferEvaluation()
        scheduleRecentPlaysWarm()
    }

    /// Resume welcome-page background work when a hidden window is shown again.
    func noteWindowReexposed() {

        if !hasMediaSession { dismissFailurePresentation() }
        guard core?.state == .idle, !hasMediaSession,
              welcome?.isHidden == false else { return }
        scheduleSetDefaultOfferEvaluation()
        scheduleRecentPlaysWarm()
    }

    /// Warm visible recent items and retry once when foreground I/O is active.
    private func scheduleRecentPlaysWarm(attempt: Int = 0) {
#if SP_APP_STORE
        // Sandboxed builds cannot reuse recent paths without scoped access.
        return
#else
        // Reset automatic prefetch priority for each welcome presentation.
        if attempt == 0 {
            RecentPlaysWarmer.beginAutoWarmCycle()

            RecentPlaysWarmer.registerWelcomeHeartbeat(owner: self) { [weak self] in
                self?.welcomeHeartbeatState() ?? .gone
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (attempt == 0 ? 0.15 : 1.2)) { [weak self] in
            guard let self, !self.hasMediaSession, !self.windowDestructionPending,
                  let welcome = self.welcome, !welcome.isHidden,
                  self.view.window?.isVisible == true else { return }
            if OpenPanelWarmer.foregroundIOActive {
                if attempt == 0 { self.scheduleRecentPlaysWarm(attempt: 1) }
                return
            }
            // Use the same resume source as open: saved positions can be
            // newer than the recent-entry snapshot. Completed media restarts.
            let defaults = UserDefaults.standard
            let entries = RecentPlays.load()
                .prefix(WelcomeView.visibleEntryCount)
                .map { entry in
                    let position = defaults.object(
                        forKey: "sp.pos." + entry.path) as? Double
                        ?? entry.position
                    let fraction = entry.duration > 0 && !entry.isCompleted
                        ? min(1, max(0, position / entry.duration)) : 0
                    return (path: entry.path, resumeFraction: fraction)
                }
            RecentPlaysWarmer.warmForWelcome(entries: entries)
            // Prefetch the newest entry unless a real hover selected another item.
            if let first = entries.first {
                RecentPlaysWarmer.warmEntryAutoIntent(path: first.path)
            }
        }
#endif
    }

#if !SP_APP_STORE

    private func welcomeHeartbeatState() -> WelcomeHeartbeatState {
        guard !hasMediaSession, !windowDestructionPending,
              let welcome, !welcome.isHidden, let window = view.window else { return .gone }
        if window.isMiniaturized || NSApp.isHidden || !window.isVisible { return .paused }
        return .active
    }
#endif

    /// Evaluate the default-player offer after the welcome window is visible.
    private func scheduleSetDefaultOfferEvaluation() {
#if SP_APP_STORE
        // Sandboxed builds do not offer to change system file associations.
        return
#else
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.core?.state == .idle, !self.hasMediaSession,
                  let welcome = self.welcome, !welcome.isHidden,
                  self.view.window?.isVisible == true else { return }
            SPDefaultPlayer.evaluateWelcomeOffer { [weak self] offer in
                // Recheck presentation state after the asynchronous query.
                guard offer != .none, let self, self.core?.state == .idle,
                      let welcome = self.welcome, !welcome.isHidden,
                      self.view.window?.isVisible == true else { return }
                // Show the first-run prompt only when no playback history exists.
                if offer == .setup, SPDefaultPlayer.shouldPresentFirstRunPrompt,
                   RecentPlays.load().isEmpty {
                    if Self.dbg { NSLog("[UI] Presenting default-player prompt") }
                    // Keep the welcome-page offer available after deferral.
                    SPDefaultPlayer.presentFirstRunPrompt(
                        over: self.view.window,
                        onDeferred: { [weak self] in
                            guard let self, self.core?.state == .idle,
                                  let welcome = self.welcome,
                                  !welcome.isHidden else { return }
                            welcome.showSetDefaultOffer(
                                title: L("defaultPlayer.title"))
                        })
                    return
                }
                if Self.dbg {
                    NSLog("[UI] Showing default-player offer: %@", String(describing: offer))
                }
                welcome.showSetDefaultOffer(title: offer == .restore
                    ? L("welcome.restoreDefault") : L("defaultPlayer.title"))
            }
        }
#endif
    }

    private func dismissEmptyStateForOpening() {
        welcome?.isHidden = true
        view.window?.styleMask.insert(.resizable)
        view.window?.titleVisibility = .visible
    }

    private var recentOpenToken = 0

    private static var recentExistsProbesInFlight = Set<String>()

    private struct RecentProbeRequester {
        weak var controller: PlayerViewController?
        let token: Int
    }
    private static var recentProbeRequesters: [String: RecentProbeRequester] = [:]
    private var recentOpenSettled = 0

    func openRecentEntry(path: String) {
        let requestedAt = spDebugEnabled ? ProcessInfo.processInfo.systemUptime : 0
        let diagnosticWindow = view.window?.windowNumber ?? -1
        // Yield speculative reads before the existence check and actual open,
        // covering the interval before the playback state changes to opening.
        SPBackgroundStorageGate.noteForegroundActivity()
        RecentPlaysWarmer.noteForegroundOpen(path: path)
        recentOpenToken &+= 1
        let token = recentOpenToken
        if spDebugEnabled {
            NSLog("[RecentOpen] window=%ld token=%ld requested file=%@",
                  diagnosticWindow, token, (path as NSString).lastPathComponent)
        }

        SPMainThreadSentinel.phase("recent.focus") {
            view.window?.makeKeyAndOrderFront(nil)
        }

        Self.recentProbeRequesters[path] = RecentProbeRequester(controller: self, token: token)
        if Self.recentExistsProbesInFlight.insert(path).inserted {
        DispatchQueue.global(qos: .userInitiated).async {
#if SP_APP_STORE

            var grantedURL: URL?
            var accessible = true
            var volumeUnavailable = false
            switch SPRecentBookmarks.resolveStartingAccess(path: path) {
            case .granted(let url):
                grantedURL = url
            case .volumeUnavailable:
                volumeUnavailable = true
            case .unavailable:
                accessible = SPFolderGrants.ensureAccess(path: path)
            }
            let targetPath = grantedURL?.path ?? path
#else
            let grantedURL: URL? = nil
            let accessible = true
            let volumeUnavailable = false
            let targetPath = path
#endif
            let probe = accessible && !volumeUnavailable
            let exists = probe && FileManager.default.fileExists(atPath: targetPath)

            let parentExists = exists || (probe && FileManager.default.fileExists(
                atPath: (targetPath as NSString).deletingLastPathComponent))
            if spDebugEnabled {
                NSLog("[RecentOpen] window=%ld token=%ld probe completed +%.0fms exists=%d parentExists=%d",
                      diagnosticWindow, token,
                      (ProcessInfo.processInfo.systemUptime - requestedAt) * 1000,
                      exists ? 1 : 0, parentExists ? 1 : 0)
            }
            DispatchQueue.main.async {
                Self.recentExistsProbesInFlight.remove(path)
                let requester = Self.recentProbeRequesters.removeValue(forKey: path)

                guard let requester, let self = requester.controller,
                      requester.token == self.recentOpenToken,
                      self.recentOpenSettled < requester.token else {
                    if let grantedURL { spReleaseSecurityScopedGrant(grantedURL) }
                    return
                }
                self.recentOpenSettled = requester.token
                if !accessible {
#if SP_APP_STORE
                    self.requestRecentReauthorization(path: path)
#endif
                } else if exists {
                    // Avoid an implicit filesystem probe on the main thread.
                    if let grantedURL {
#if SP_APP_STORE
                        if URL(fileURLWithPath: path).standardizedFileURL.path
                            != grantedURL.standardizedFileURL.path {
                            self.openMovedRecent(grantedURL, recordedPath: path,
                                                 token: requester.token)
                            return
                        }
#endif
                        self.open(url: grantedURL, incomingSecurityScopedGrant: true)
                    } else {
                        self.open(url: URL(fileURLWithPath: targetPath, isDirectory: false),
                                  incomingSecurityScopedGrant: false)
                    }
                } else if !parentExists {
                    if let grantedURL { spReleaseSecurityScopedGrant(grantedURL) }
                    self.welcome?.showTransientNotice(L("welcome.volumeUnavailable"))
                } else {
                    if let grantedURL { spReleaseSecurityScopedGrant(grantedURL) }
                    Self.resumeSaveQueue.async {
                        RecentPlays.remove(path: path)
                        DispatchQueue.main.async { [weak self] in
                            self?.welcome?.reload()
                            self?.welcome?.showTransientNotice(L("welcome.missingRemoved"))
                        }
                    }
                }
            }
        }
        }
#if !SP_APP_STORE

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, token == self.recentOpenToken,
                  self.recentOpenSettled < token else { return }
            self.recentOpenSettled = token
            if spDebugEnabled {
                NSLog("[RecentOpen] window=%ld token=%ld probe fallback +%.0fms",
                      diagnosticWindow, token,
                      (ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
            }
            // Avoid repeating the pending filesystem probe on the main thread.
            self.open(url: URL(fileURLWithPath: path, isDirectory: false),
                      incomingSecurityScopedGrant: false)
        }
#endif
    }

#if SP_APP_STORE

    private func openMovedRecent(_ url: URL, recordedPath: String, token: Int) {
        let newPath = url.path
        if let pending = Self.pendingResumeByPath.removeValue(forKey: recordedPath) {
            Self.pendingResumeByPath[newPath] = pending
        }
        Self.resumeSaveQueue.async {
            RecentPlays.rename(from: recordedPath, to: newPath, title: url.lastPathComponent)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recentOpenToken == token else {
                    spReleaseSecurityScopedGrant(url)
                    return
                }
                self.open(url: url, incomingSecurityScopedGrant: true)
            }
        }
    }

    private func requestRecentReauthorization(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let token = recentOpenToken
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = String(format: L("access.recent.reauthorizeFmt"),
                               url.lastPathComponent)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }

            guard let self, self.recentOpenToken == token else {
                spReleaseSecurityScopedGrant(picked)
                return
            }
            self.open(url: picked, incomingSecurityScopedGrant: true)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
#endif

    private func dismissFailurePresentation() {
        core?.cancelIndexWait()
        shownFailureReason = nil
        failureTracker.reset()
        lastFailedOpenURL = nil
        welcome?.hideFailureNotice()
#if SP_APP_STORE
        releaseFailedDocumentGrant()
#endif
    }

    func open(url: URL, incomingSecurityScopedGrant: Bool = true) {
        let requestedAt = spDebugEnabled ? ProcessInfo.processInfo.systemUptime : 0

        dismissFailurePresentation()
        lastOpenRequestURL = url
        // Correlate a recent-entry request without adding another lifecycle token.
        let diagnosticToken = recentOpenToken
        let diagnosticWindow = view.window?.windowNumber ?? -1
        if spDebugEnabled {
            NSLog("[OpenRequest] window=%ld recentToken=%ld began file=%@",
                  diagnosticWindow, diagnosticToken, url.lastPathComponent)
        }
        defer {
            if spDebugEnabled {
                NSLog("[OpenRequest] window=%ld recentToken=%ld returned %.0fms",
                      diagnosticWindow, diagnosticToken,
                      (ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
            }
        }
        // Cover AppKit, path/defaults access, and post-open setup as well as Core.
        // A slow background prepare is distinct from this synchronous interval.
        SPMainThreadSentinel.phase("open.request") {
            performOpenRequest(url: url,
                               incomingSecurityScopedGrant: incomingSecurityScopedGrant)
        }
    }

    private func performOpenRequest(url: URL, incomingSecurityScopedGrant: Bool) {
        SPBackgroundStorageGate.noteForegroundActivity() // Includes drag-and-drop and menu opens.
        RecentPlaysWarmer.noteForegroundOpen(path: url.path)
        recentOpenToken &+= 1
        recentOpenSettled = recentOpenToken
        SPMainThreadSentinel.phase("open.ensureCore") {
            ensureCore()
        }
        guard let core else {
            if incomingSecurityScopedGrant { spReleaseSecurityScopedGrant(url) }
            return
        }
        // Subtitle files dropped or opened during playback augment the current
        // video rather than starting a new media session.
        if SPSubtitleAutoload.isSubtitleFile(url) {
            if hasMediaSession {
                if core.state == .opening {

                    dropPendingExternalSubtitle()
                    pendingExternalSubtitleURL = url
                } else {
                    loadExternalSubtitle(url: url)
                }
            } else {
                if incomingSecurityScopedGrant { spReleaseSecurityScopedGrant(url) }

                showTransientNotice(L("subtitle.load.noVideo"))
            }
            return
        }
        // One session owns a media path. If another window already has it, focus
        // that window; reopening it here also avoids restarting the session.
        let stdPath = SPMainThreadSentinel.phase("open.normalizePath") {
            url.standardizedFileURL.path
        }
        if let existing = (NSApp.delegate as? AppDelegate)?.windowController(forOpenPath: stdPath),
           existing.playerViewController !== self {
            if existing.playerViewController.handleDuplicateMediaOpen(
                url: url, incomingSecurityScopedGrant: incomingSecurityScopedGrant) {
                return
            }
        }
        if handleDuplicateMediaOpen(
            url: url, incomingSecurityScopedGrant: incomingSecurityScopedGrant) {
            return
        }
        // A new session cannot inherit unfinished scrub or repeat state. Avoid
        // stopRepeat() here because it may resume playback in the outgoing
        // session and interfere with the incoming file.
        yieldDirectoryScanToForegroundIO()
        let shouldResumePreviousPlayback = cancelTransientInteractions()

        flushResumePositionNow(forceDiskSync: false)

        let previousHasMediaSession = hasMediaSession
        let previousTitle = view.window?.title ?? L("app.displayName")
        let previousInterpolationMode = core.frameInterpolationMode
        let previousOpenMediaPath = openMediaPath
        let previousRecentRecordedThisOpen = recentRecordedThisOpen
        let previousReplayResumeResetArmedPath = replayResumeResetArmedPath
        hasMediaSession = true
        captionsRegisterCore(core)
        openMediaPath = stdPath
        recentRecordedThisOpen = false
        replayResumeResetArmedPath = nil
        SPMainThreadSentinel.phase("open.dismissWelcome") {
            dismissEmptyStateForOpening()
        }

        scheduleChromeInstallAfterFirstFrame()

        currentForcedAspectTag = 0
        currentCropTag = 0
        // Install the opening indicator only after openMedia accepts the request.
        view.window?.title = url.lastPathComponent
        transitionPresentation(.stateChanged(.opening, presentationSnapshot(core: core)))

        let resumePath = url.path
        let resume = SPMainThreadSentinel.phase("open.resumeLookup") {
            SPResumePolicy.startPosition(
                path: resumePath,
                pending: Self.pendingResumeByPath[resumePath],
                storedPosition: UserDefaults.standard.object(
                    forKey: "sp.pos." + resumePath) as? Double,
                recents: RecentPlays.load())
        }

        do {
            try SPMainThreadSentinel.phase("core.openMedia") {
                if let resume, resume > 2 {
                    try core.openMedia(at: url, startAt: resume)
                } else {
                    try core.openMedia(at: url)
                }
            }
            // Clear boost only after the replacement session is accepted.
            resetVolumeBoostForNewSource()
        } catch {
#if SP_APP_STORE
            // The rejected candidate has its own automatically-started grant;
            // the previous playing session (and its grant) remain untouched.
            if incomingSecurityScopedGrant { url.stopAccessingSecurityScopedResource() }
#endif

            hasMediaSession = previousHasMediaSession
            if !previousHasMediaSession { captionsMediaWillClose() }
            openMediaPath = previousOpenMediaPath
            recentRecordedThisOpen = previousRecentRecordedThisOpen
            replayResumeResetArmedPath = previousReplayResumeResetArmedPath
            let restoredMode = previousHasMediaSession ? previousInterpolationMode : .off

            if core.frameInterpolationMode.rawValue != restoredMode.rawValue {
                core.frameInterpolationMode = restoredMode
            }

            if shouldResumePreviousPlayback {
                core.play()
            }
            view.window?.title = previousTitle
            if previousHasMediaSession {
                replayCoreState()
            } else {
                transitionPresentation(.sessionClosed)
            }
            if previousHasMediaSession {
                setIdleHintVisible(false)
            } else {
                showEmptyState()
            }

            let nsError = error as NSError
            let action = failureTracker.noteError(domain: nsError.domain,
                                                  diagnosis: nsError.userInfo[SPPlayerErrorDiagnosisKey] as? String,
                                                  terminal: (nsError.userInfo[SPPlayerErrorTerminalKey] as? NSNumber)?.boolValue)
            if previousHasMediaSession || action == .alert {
                failureTracker.reset()
                presentPlaybackError(error)
            } else {
                presentFailureNotice(failureTracker.noteFailedState())
            }
            return
        }
        // Show feedback until the opening state completes or fails.
        setIdleHintVisible(true, text: String(format: L("hint.openingFmt"), url.lastPathComponent))
#if SP_APP_STORE
        // openMedia has accepted the replacement, so the old media/subtitle
        // session can now relinquish its grants without breaking rollback.
        releaseActiveSubtitleGrant()
        releaseActiveDocumentGrant()
        // Never manufacture a future stopAccessing call for a grant we did not own.
        activeGrantedDocumentURL = incomingSecurityScopedGrant ? url : nil

        SPRecentBookmarks.remember(url)
#endif
        playlistScanGeneration &+= 1

        mediaList = [url]
        currentMediaIndex = 0

        externalSubtitleCandidates.removeAll()
        directoryAutoSubtitleCandidates.removeAll()
        activeExternalSubtitleURL = nil
        pendingSubtitleAutoload = false
        dropPendingExternalSubtitle()
        userTouchedSubtitleSelection = false

        captionsMediaWillClose(unregisterCore: false)

        if SPFileAccess.mayScanAfterOpen(directory: url.deletingLastPathComponent()) {
            SPMainThreadSentinel.phase("open.configureDirectory") {
                configureDirectorySnapshot(for: url)
            }
        } else {
#if SP_APP_STORE

            let generation = playlistScanGeneration
            let directory = url.deletingLastPathComponent().path
            SPFolderGrants.checkAccess(path: directory) { [weak self] accessible in
                guard accessible, let self, self.hasMediaSession,
                      self.playlistScanGeneration == generation else {
                    if spDebugEnabled { NSLog("[FileAccess] 无授权，跳过同目录扫描: %@", directory) }
                    return
                }
                self.configureDirectorySnapshot(for: url)
                self.runPendingDirectoryScanWhenFirstFramePresented()
            }
#else
            if spDebugEnabled {
                NSLog("[FileAccess] 无授权，跳过同目录扫描: %@",
                      url.deletingLastPathComponent().path)
            }
#endif
        }
    }

    @discardableResult
    func handleDuplicateMediaOpen(url: URL,
                                  incomingSecurityScopedGrant: Bool = true) -> Bool {
        let path = SPMainThreadSentinel.phase("open.normalizePath") {
            url.standardizedFileURL.path
        }
        guard openMediaPath == path, hasMediaSession, let core else { return false }
        let replaying = core.state == .ended
        switch core.state {
        case .opening, .playing, .paused:
            break
        case .ended:
            yieldDirectoryScanToForegroundIO()
            core.play()
        default:

            return false
        }
        if Self.dbg {
            NSLog("[UI] 同片再次打开 → %@既有窗口: %@",
                  replaying ? "从头重播 " : "聚焦 ",
                  url.lastPathComponent)
        }
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if incomingSecurityScopedGrant { spReleaseSecurityScopedGrant(url) }
        return true
    }

    /// Publish a cached same-directory list immediately, then refresh only
    /// after the foreground session has a first frame. Physical listings are
    /// process-wide single-flight/serialized by SPDirectoryMediaIndex.
    private func configureDirectorySnapshot(for mediaURL: URL) {
        // A previous window-local waiter must detach before this intent is
        // replaced. Other windows attached to the same process-wide flight are
        // unaffected; the index cancels physical I/O only for the last waiter.
        directorySnapshotRequest?.cancel()
        directorySnapshotRequest = nil
        directorySubtitleRankingCancellation?.cancel()
        directorySubtitleRankingCancellation = nil
        let generation = playlistScanGeneration
        let directory = mediaURL.deletingLastPathComponent().standardizedFileURL
        let uiLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let index = SPDirectoryMediaIndex.shared

        let retained: SPDirectoryMediaSnapshot? = {
            guard let snapshot = directorySnapshot,
                  snapshot.directory.standardizedFileURL.path == directory.path,
                  snapshot.contains(mediaURL) else { return nil }
            return snapshot
        }()
        let cached = retained ?? index.cachedSnapshot(
            for: directory, mediaExtensions: Self.mediaExtensions)
        let usable = cached?.contains(mediaURL) == true ? cached : nil
        if let usable {
            applyDirectorySnapshot(usable, for: mediaURL,
                                   generation: generation,
                                   uiLanguage: uiLanguage)
        }

        // The cache provides immediate publication, not authoritative truth.
        // Without filesystem invalidation, a freshness window can hide newly
        // added subtitles. Schedule one physical refresh per open after the
        // first-frame and storage-admission gates on the utility lane.
        pendingDirectoryScan = PendingDirectoryScan(
            mediaURL: mediaURL, generation: generation,
            uiLanguage: uiLanguage, forceRefresh: cached != nil)
        directoryScanPollScheduledFor = nil
        directoryScanPollDeadline = 0
        directoryScanPollSequence &+= 1
        directoryScanPollAttempt = 0
        directoryScanNotBefore = 0
        directoryStorageAdmissionNextCheck = 0
    }

    private func applyDirectorySnapshot(_ snapshot: SPDirectoryMediaSnapshot,
                                        for mediaURL: URL,
                                        generation: UInt64,
                                        uiLanguage: String) {
        guard playlistScanGeneration == generation,
              openMediaPath == mediaURL.standardizedFileURL.path else { return }
        directorySnapshot = snapshot

        // Sorting/filtering/indexing happens once on the utility listing queue.
        // Cached publication must stay constant-time: a 100k-entry NAS folder
        // must not become a main-thread scan every time Previous/Next opens.
        var list = snapshot.mediaFiles
        let currentIndex = snapshot.mediaIndex(of: mediaURL)
        if let currentIndex {
            mediaList = list
            currentMediaIndex = currentIndex
        } else {
            // The file can be unlinked after Core accepted its descriptor.
            // Playback remains valid, but navigation must not point at a list
            // that no longer contains the current session.
            list = [mediaURL]
            mediaList = list
            currentMediaIndex = 0
        }

        scheduleDirectorySubtitleRanking(snapshot, for: mediaURL,
                                         generation: generation,
                                         uiLanguage: uiLanguage)
    }

    /// Cached media navigation is published above without scanning the cached
    /// subtitle array on the main actor. The CPU-only normalization/ranking is
    /// deliberately lower priority and coalesced; publication is accepted only
    /// while the exact media session and snapshot are still current.
    private func scheduleDirectorySubtitleRanking(
        _ snapshot: SPDirectoryMediaSnapshot,
        for mediaURL: URL,
        generation: UInt64,
        uiLanguage: String
    ) {
        directorySubtitleRankingCancellation?.cancel()
        guard !snapshot.subtitleFileNames.isEmpty else {
            directorySubtitleRankingCancellation = nil

            publishDirectorySubtitleNames([], directory: snapshot.directory)
            return
        }

        let cancellation = SPDirectorySubtitleRankingCancellation()
        directorySubtitleRankingCancellation = cancellation
        let mediaPath = mediaURL.standardizedFileURL.path
        let videoFileName = mediaURL.lastPathComponent
        let subtitleFileNames = snapshot.subtitleFileNames
        let directory = snapshot.directory
        let capturedAt = snapshot.capturedAt

        Self.directorySubtitleRankingQueue.async {
            let rankedNames = SPSubtitleAutoload.rankedMatches(
                videoFileName: videoFileName,
                candidates: subtitleFileNames,
                uiLanguage: uiLanguage,
                shouldCancel: { cancellation.isCancelled })
            guard !cancellation.isCancelled else { return }
            let names = Array(rankedNames.prefix(12))
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !cancellation.isCancelled,
                      self.directorySubtitleRankingCancellation === cancellation,
                      self.playlistScanGeneration == generation,
                      self.openMediaPath == mediaPath,
                      self.directorySnapshot?.directory.standardizedFileURL.path ==
                          directory.standardizedFileURL.path,
                      self.directorySnapshot?.capturedAt == capturedAt else { return }
                self.directorySubtitleRankingCancellation = nil

                self.publishDirectorySubtitleNames(names, directory: directory)
            }
        }
    }

    /// Main-actor publication is capped at 12 entries. The auto-discovered set
    /// is replaced wholesale by each publication — a candidate the cache once
    /// saw but the fresh listing no longer contains (deleted/renamed) must
    /// leave the menu. Manual loads and the currently active subtitle are not
    /// part of the auto set and survive every refresh.
    private func publishDirectorySubtitleNames(_ subtitleNames: [String],
                                               directory: URL) {
        let newAuto = subtitleNames.map {
            directory.appendingPathComponent($0)
        }
        if spDebugEnabled, !newAuto.isEmpty {
            NSLog("[SubScan] 命中 %d: %@", newAuto.count,
                  subtitleNames.joined(separator: " | "))
        }
        let oldAuto = Set(directoryAutoSubtitleCandidates.map {
            $0.standardizedFileURL
        })
        let newAutoSet = Set(newAuto.map { $0.standardizedFileURL })
        let activeStandardized = activeExternalSubtitleURL?.standardizedFileURL
        var merged = newAuto
        for existing in externalSubtitleCandidates {
            let standardized = existing.standardizedFileURL
            if newAutoSet.contains(standardized) { continue }
            if oldAuto.contains(standardized),
               standardized != activeStandardized {
                continue
            }
            merged.append(existing)
        }
        directoryAutoSubtitleCandidates = newAuto
        externalSubtitleCandidates = merged
        guard !newAuto.isEmpty else { return }
        pendingSubtitleAutoload = true
        maybeRunSubtitleAutoload()
    }

    private func maybeRunSubtitleAutoload() {
        guard pendingSubtitleAutoload, hasMediaSession,
              let core, core.state == .playing || core.state == .paused,
              !userTouchedSubtitleSelection, activeExternalSubtitleURL == nil,
              !externalSubtitleCandidates.isEmpty else { return }
        pendingSubtitleAutoload = false
        attemptSubtitleAutoload(index: 0)
    }

    private func attemptSubtitleAutoload(index: Int) {
        guard index < externalSubtitleCandidates.count else { return }
        guard !userTouchedSubtitleSelection else { return }
        let gen = playlistScanGeneration
        let url = externalSubtitleCandidates[index]
        let accepted = core?.loadSubtitleFile(url.path, silent: true) { [weak self] ok in
            guard let self, self.playlistScanGeneration == gen else { return }
            if ok {
                if self.activeExternalSubtitleURL == nil,
                   !self.userTouchedSubtitleSelection {
                    self.activeExternalSubtitleURL = url
                    if spDebugEnabled {
                        NSLog("[SubScan] 自动加载: %@", url.lastPathComponent)
                    }
                }
            } else {

                if let bad = self.externalSubtitleCandidates.firstIndex(of: url) {
                    self.externalSubtitleCandidates.remove(at: bad)
                    self.attemptSubtitleAutoload(index: bad)
                }
            }
        } ?? false
        if !accepted { return }
    }

    private func scheduleDirectoryScanPoll(for generation: UInt64,
                                           after delay: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, delay)
        // Keep an already-earlier wake; it will re-check a foreground quiet
        // deadline and extend itself if needed. Replace only a later wake so a
        // prior 2s malformed-frame backoff cannot delay a new 800ms quiet tail.
        if directoryScanPollScheduledFor == generation,
           directoryScanPollDeadline <= deadline { return }
        directoryScanPollSequence &+= 1
        let sequence = directoryScanPollSequence
        directoryScanPollScheduledFor = generation
        directoryScanPollDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay)) { [weak self] in
            guard let self,
                  self.directoryScanPollScheduledFor == generation,
                  self.directoryScanPollSequence == sequence else { return }
            self.directoryScanPollScheduledFor = nil
            self.directoryScanPollDeadline = 0
            guard self.playlistScanGeneration == generation else { return }
            self.runPendingDirectoryScanWhenFirstFramePresented()
        }
    }

    /// Immediate seek/hover work outranks a directory refresh. Keep the refresh
    /// intent, detach only this window's waiter, then retry after a short quiet
    /// tail. Repeated interaction extends the deadline without timer churn.
    private func yieldDirectoryScanToForegroundIO() {
        // Process-wide first: this input must also pause a shared flight owned
        // by another window and any OpenPanel metadata warm in a paused session.
        // O(1) deadline extension; no per-hover timer or flight traversal.
        SPBackgroundStorageGate.noteForegroundActivity()
        guard let request = pendingDirectoryScan,
              request.generation == playlistScanGeneration else { return }
        directorySnapshotRequest?.cancel()
        directorySnapshotRequest = nil
        directoryScanNotBefore = ProcessInfo.processInfo.systemUptime +
            SPDirectoryScanSchedulingPolicy.foregroundQuietPeriod
        scheduleDirectoryScanPoll(
            for: request.generation,
            after: SPDirectoryScanSchedulingPolicy.foregroundQuietPeriod)
    }

    /// The only PlayerVC path that calls Core's seek primitive. Keeping the
    /// foreground-storage notification here prevents future timeline/burst
    /// entry points from silently bypassing the background-I/O priority rule.
    private func issueForegroundSeek(to target: Double,
                                     precise: Bool = true,
                                     forward: Bool = false) {
        yieldDirectoryScanToForegroundIO()
        core?.seek(to: target, precise: precise, forward: forward)
    }

    private func cancelDirectoryScanForSessionBoundary() {
        directorySnapshotRequest?.cancel()
        directorySnapshotRequest = nil
        directorySubtitleRankingCancellation?.cancel()
        directorySubtitleRankingCancellation = nil
        pendingDirectoryScan = nil
        directoryScanPollScheduledFor = nil
        directoryScanPollDeadline = 0
        directoryScanPollSequence &+= 1
        directoryScanPollAttempt = 0
        directoryScanNotBefore = 0
        directoryStorageAdmissionNextCheck = 0
    }

    private func runPendingDirectoryScanWhenFirstFramePresented() {
        guard let request = pendingDirectoryScan, let core,
              request.generation == playlistScanGeneration,
              directorySnapshotRequest == nil else { return }
        guard let window = view.window, window.isVisible,
              window.occlusionState.contains(.visible) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now < directoryScanNotBefore {
            scheduleDirectoryScanPoll(for: request.generation,
                                      after: directoryScanNotBefore - now)
            return
        }
        guard core.hasEverPresentedThisSession || core.audioOnlySession else {
            guard let delay = SPDirectoryScanSchedulingPolicy.firstFramePollDelay(
                attempt: directoryScanPollAttempt) else {
                // Six checks cover ~5.1s without creating a permanent wakeup.
                // A later real first frame calls didUpdatePosition; state and
                // visibility edges are the other deterministic wake sources.
                return
            }
            directoryScanPollAttempt += 1
            scheduleDirectoryScanPoll(for: request.generation, after: delay)
            return
        }

        // A renderer-accepted first frame is necessary but not sufficient on
        // a cold HDD/SMB stream. While playing, require the same current seek
        // generation, 75% compressed-packet runway and 3s starvation quiet
        // used by Core's own opportunistic index I/O. Paused/audio-only states
        // have their dedicated safe rules in Core. Limit the queue-locking
        // probe to 10Hz; normal position edges drive the next check.
        if now < directoryStorageAdmissionNextCheck {
            // A Playing position edge can set the 100ms limit, followed by the
            // sole Paused state edge inside that window. Paused has no future
            // DisplayLink position wake, so preserve this edge with one tail
            // check rather than leaving the catalogue intent stranded.
            scheduleDirectoryScanPoll(
                for: request.generation,
                after: directoryStorageAdmissionNextCheck - now)
            return
        }
        directoryStorageAdmissionNextCheck = now + 0.1
        guard core.backgroundDirectoryScanReady else { return }
        directoryStorageAdmissionNextCheck = 0

        directoryScanPollScheduledFor = nil
        directoryScanPollDeadline = 0
        directoryScanPollSequence &+= 1
        directoryScanPollAttempt = 0
        directoryScanNotBefore = 0
        if spDebugEnabled {
            NSLog("[SubScan] 同目录扫描放行: %@",
                  request.mediaURL.deletingLastPathComponent().lastPathComponent)
        }
        directorySnapshotRequest = SPDirectoryMediaIndex.shared.requestSnapshot(
            for: request.mediaURL.deletingLastPathComponent(),
            mediaExtensions: Self.mediaExtensions,
            forceRefresh: request.forceRefresh
        ) { [weak self] snapshot in
            guard let self,
                  self.playlistScanGeneration == request.generation else { return }
            self.directorySnapshotRequest = nil
            self.pendingDirectoryScan = nil
            if spDebugEnabled {
                NSLog("[SubScan] 目录列举完成: 媒体 %d 字幕 %d", snapshot?.mediaFiles.count ?? -1,
                      snapshot?.subtitleFileNames.count ?? -1)
            }
            guard let snapshot else { return }
            self.applyDirectorySnapshot(snapshot, for: request.mediaURL,
                                        generation: request.generation,
                                        uiLanguage: request.uiLanguage)
        }
    }

    private func dropPendingExternalSubtitle() {
        guard let url = pendingExternalSubtitleURL else { return }
        pendingExternalSubtitleURL = nil
#if SP_APP_STORE
        url.stopAccessingSecurityScopedResource()
#else
        _ = url
#endif
    }

    func loadExternalSubtitle(url: URL) {
        guard let core, hasMediaSession else {
            spReleaseSecurityScopedGrant(url)
            return
        }
        let captionSelection: Int?
        if #available(macOS 26.0, *) {
            captionSelection = captions?.beginExternalSubtitleSelection()
        } else { captionSelection = nil }
        // This path is explicit user input (panel/drop/menu, including a file
        // supplied with the media open), unlike silent directory autoload.
        // Its bounded file read outranks catalogue/OpenPanel background I/O.
        yieldDirectoryScanToForegroundIO()
        userTouchedSubtitleSelection = true
        let gen = playlistScanGeneration
        let accepted = core.loadSubtitleFile(url.path, silent: false) { [weak self] ok in
            guard let self else {
                spReleaseSecurityScopedGrant(url)
                return
            }
            guard self.playlistScanGeneration == gen else {
                spReleaseSecurityScopedGrant(url)
                return
            }
            if #available(macOS 26.0, *), let captionSelection {
                self.captions?.completeExternalSubtitleSelection(captionSelection, succeeded: ok)
            }
            guard ok else {
                spReleaseSecurityScopedGrant(url)
                return
            }
#if SP_APP_STORE
            self.releaseActiveSubtitleGrant()
            self.activeGrantedSubtitleURL = url
#endif
            self.activeExternalSubtitleURL = url
            if spDebugEnabled {
                NSLog("[SubScan] 手动加载生效: %@", url.lastPathComponent)
            }
            let standardized = url.standardizedFileURL
            if !self.externalSubtitleCandidates
                .contains(where: { $0.standardizedFileURL == standardized }) {
                self.externalSubtitleCandidates.append(url)
            }
        }
        if !accepted {
            if #available(macOS 26.0, *), let captionSelection {
                captions?.completeExternalSubtitleSelection(captionSelection, succeeded: false)
            }
            spReleaseSecurityScopedGrant(url)
        }
    }

    // Closing a window persists resume state, stops the pipeline, and clears the
    // final Metal frame so a later Dock reopen presents an unambiguous empty
    // state. core.stop() publishes Idle synchronously (setState calls the
    // delegate inline): a window being destroyed must not install welcome
    // content on that transition, and the last-window path installs it once
    // itself (closingWindowInProgress) — the delegate branch used to build the
    // welcome view and its ~85ms texture, then handleWindowClose rebuilt and
    // rerolled it: three background renders and two list rebuilds per close.
    private var windowDestructionPending = false
    private var closingWindowInProgress = false

    func handleWindowClose(destroyingWindow: Bool = false) {
        playbackSleep.stop()
        playbackCursor?.setHasVideo(false)
        if destroyingWindow { windowDestructionPending = true }
        dismissOpenPanelPresentation() // Close a standalone panel but retain its cached instance.
        openMediaPath = nil
        replayResumeResetArmedPath = nil

        recentOpenToken &+= 1
        recentOpenSettled = recentOpenToken
        playlistScanGeneration &+= 1
        cancelDirectoryScanForSessionBoundary()
        guard let core else {
#if SP_APP_STORE
            releaseActiveSubtitleGrant()
            releaseActiveDocumentGrant()
#endif
            return
        }
        cancelTransientInteractions()
        directorySnapshot = nil
        mediaList.removeAll(keepingCapacity: false)
        currentMediaIndex = -1
        externalSubtitleCandidates.removeAll()
        directoryAutoSubtitleCandidates.removeAll()
        activeExternalSubtitleURL = nil
        pendingSubtitleAutoload = false
        dropPendingExternalSubtitle()
        userTouchedSubtitleSelection = false
        captionsMediaWillClose()

        flushResumePositionNow(forceDiskSync: !destroyingWindow)
        hasMediaSession = false
        resetVolumeBoostForNewSource()
        closingWindowInProgress = true
        defer { closingWindowInProgress = false }
        core.closeMediaSession()
#if SP_APP_STORE
        // Keep the automatically-started grants alive until all Core workers
        // have stopped touching the media and any asynchronous subtitle read.
        releaseActiveSubtitleGrant()
        releaseActiveDocumentGrant()
#endif
        if destroyingWindow { return }

        core.frameInterpolationMode = .off
        core.clearVideoSurface()
        view.window?.title = L("app.displayName")
        transitionPresentation(.sessionClosed)

        dismissFailurePresentation()

        let hadWelcome = welcome != nil
        showEmptyState()
        if hadWelcome { welcome?.rerollTexture() }
    }

    func playNextMedia() {
#if SP_APP_STORE
        if requestPlaylistFolderAccessIfNeeded() { return }
#endif
        guard mediaList.count > 1 else { return }
        let next = (currentMediaIndex + 1) % mediaList.count
        open(url: mediaList[next])
    }

    func playPreviousMedia() {
#if SP_APP_STORE
        if requestPlaylistFolderAccessIfNeeded() { return }
#endif
        guard mediaList.count > 1 else { return }
        let prev = (currentMediaIndex - 1 + mediaList.count) % mediaList.count
        open(url: mediaList[prev])
    }

    private var playlistFolderAccessRequestable: Bool {
#if SP_APP_STORE
        guard hasMediaSession, mediaList.count <= 1,
              currentMediaIndex >= 0, currentMediaIndex < mediaList.count else { return false }
        let directory = mediaList[currentMediaIndex].deletingLastPathComponent().path

        return !Self.declinedPlaylistFolders.contains(directory)
            && !SPFolderGrants.isCovered(path: directory)
#else
        return false
#endif
    }

#if SP_APP_STORE

    private static var declinedPlaylistFolders = Set<String>()
    private var playlistFolderAccessCheckInFlight = false

    private func requestPlaylistFolderAccessIfNeeded() -> Bool {
        guard playlistFolderAccessRequestable else { return false }

        guard view.window?.attachedSheet == nil else { return true }
        guard !playlistFolderAccessCheckInFlight else { return true }
        let mediaURL = mediaList[currentMediaIndex]
        let directory = mediaURL.deletingLastPathComponent()
        let generation = playlistScanGeneration
        let scan = { [weak self] in
            guard let self, self.hasMediaSession,
                  self.playlistScanGeneration == generation else { return }

            self.configureDirectorySnapshot(for: mediaURL)
            self.runPendingDirectoryScanWhenFirstFramePresented()
        }

        playlistFolderAccessCheckInFlight = true
        SPFolderGrants.checkAccess(path: directory.path) { [weak self] accessible in
            guard let self else { return }
            self.playlistFolderAccessCheckInFlight = false

            guard self.hasMediaSession, self.playlistScanGeneration == generation else { return }
            if accessible {
                scan()
                return
            }
            guard self.view.window?.attachedSheet == nil else { return }
            SPFolderGrants.requestAccess(to: directory, message: L("access.folder.playlistMessage"),
                                         window: self.view.window) { granted in
                guard granted else {
                    Self.declinedPlaylistFolders.insert(directory.path)
                    return
                }
                scan()
            }
        }
        return true
    }
#endif

    func playerCore(_ core: SPPlayerCore, didChange state: SPPlayerState) {

        if state != .opening, state != .playing || core.audioOnlySession {
            installPendingChromeSoon()
        }
        playbackSleep.update(isPlaying: state == .playing, hasVideo: hasVideoSession)
        playbackCursor?.setHasVideo(hasVideoSession)
        WindowDragEffect.applyTestHookIfNeeded(core: core, state: state, view: playerView)

        if turbo.phase == .active, state != .playing {
            endTurbo(reason: "state=\(state.rawValue)")
        } else if turbo.phase == .charging, state != .paused, state != .playing {
            endTurbo(reason: "state=\(state.rawValue)")
        }

        let streamingNow = (state == .opening || state == .playing)
        if streamingNow != warmerStreamingEngaged {
            warmerStreamingEngaged = streamingNow
            OpenPanelWarmer.noteStreamingChanged(streamingNow)
        }

        if state != .opening {
            setIdleHintVisible(false)
        }
        if state == .ended {
            persistCompletedResumeState(core)
        } else if state == .playing {
            resetResumeStateForReplayIfNeeded(core)
        }
        if state == .playing || state == .paused {

            if let subURL = pendingExternalSubtitleURL {
                pendingExternalSubtitleURL = nil
                loadExternalSubtitle(url: subURL)
            }
            maybeRunSubtitleAutoload()
        }
        if state == .failed {
            cancelTransientInteractions()

            hasMediaSession = false
            playbackCursor?.setHasVideo(false)
            playlistScanGeneration &+= 1
            cancelDirectoryScanForSessionBoundary()
            openMediaPath = nil
            replayResumeResetArmedPath = nil
            externalSubtitleCandidates.removeAll()
            directoryAutoSubtitleCandidates.removeAll()
            activeExternalSubtitleURL = nil
            pendingSubtitleAutoload = false
            dropPendingExternalSubtitle()
            captionsMediaWillClose()

            core.frameInterpolationMode = .off
#if SP_APP_STORE
            releaseActiveSubtitleGrant()

            retainFailedDocumentGrant()
#endif
        }
        if (state == .idle || state == .failed), !hasMediaSession,
           !windowDestructionPending, !closingWindowInProgress {
            showEmptyState()
            if state == .failed { presentFailureNotice(failureTracker.noteFailedState()) }
        }
        if (state == .playing || state == .paused || state == .ended),
           pendingDirectoryScan != nil {

            runPendingDirectoryScanWhenFirstFramePresented()
        }
        if state == .playing { everStartedPlayback = true }
        if state == .playing, !recentRecordedThisOpen, let fp = core.currentFilePath {
            recentRecordedThisOpen = true
            let title = (fp as NSString).lastPathComponent
            let position = core.position, duration = core.duration
            Self.resumeSaveQueue.async {
                RecentPlays.record(path: fp, title: title, position: position, duration: duration)
            }
        }
        let snapshot = presentationSnapshot(core: core)
        if state == .failed {
            transitionPresentation(.terminalFailure(snapshot))
        } else {
            transitionPresentation(.stateChanged(presentationLifecycle(for: state), snapshot))
        }
        if chromePresentation.shouldRevealControls {
            showControlsTemporarily()
        }
        if state == .playing {
            let info = core.videoInfo
            if info.width > 0 && info.height > 0 {
                let aspect = NSSize(width: CGFloat(info.width), height: CGFloat(info.height))

                if let window = view.window, window.contentAspectRatio != aspect {
                    window.contentAspectRatio = aspect
                }
                // contentAspectRatio constrains future manual resizing but does
                // not resize immediately, so align the window to the media ratio
                // as soon as playback becomes ready.
                resizeWindowToVideoAspect(aspect)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let core = self.core, core.state == .playing else { return }
                self.transitionPresentation(.hdrChanged(
                    description: core.hdrDescription,
                    detail: core.hdrDetailDescription
                ))
                self.refreshXDRControl()
            }
        }
    }

    private func resizeWindowToVideoAspect(_ aspect: NSSize) {
        guard aspect.width > 0, aspect.height > 0,
              let window = view.window,
              !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let chromeH = frame.height - content.height
        var w = content.width

        let fromWelcome = windowAwaitingFirstMediaFit
        if fromWelcome {
            windowAwaitingFirstMediaFit = false
            let maxW = (window.screen?.visibleFrame.width ?? 1280) - 40
            w = min(1280, maxW)
        }
        var h = (w * aspect.height / aspect.width).rounded()
        if let vis = window.screen?.visibleFrame {
            let maxH = vis.height - chromeH
            if h > maxH {
                h = maxH.rounded(.down)
                w = (h * aspect.width / aspect.height).rounded()
            }
        }
        if abs(h - content.height) < 1, abs(w - content.width) < 1 { return }
        if spDebugEnabled {
            NSLog("[UI] 窗口贴合视频比例 %.0fx%.0f → %.0fx%.0f", content.width,
                  content.height, w, h)
        }
        var newFrame = window.frameRect(forContentRect:
            NSRect(x: content.minX, y: content.minY, width: w, height: h))
        if fromWelcome {
            // Grow the centered welcome window around its center so the media
            // window remains centered instead of drifting down and right.
            newFrame.origin.x = (frame.midX - newFrame.width / 2).rounded()
            newFrame.origin.y = (frame.midY - newFrame.height / 2).rounded()
        } else {
            newFrame.origin.y = frame.maxY - newFrame.height
        }
        if let vis = window.screen?.visibleFrame {
            newFrame.origin.x = max(vis.minX, min(newFrame.origin.x, vis.maxX - newFrame.width))
            newFrame.origin.y = max(vis.minY, min(newFrame.origin.y, vis.maxY - newFrame.height))
        }
        // NSMoveHelper's synchronous animation can occupy the main thread for
        // roughly 200-500 ms while the audio clock continues. The animator proxy
        // preserves the transition without blocking frame presentation.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            window.animator().setFrame(newFrame, display: true)
        }
    }

    func playerCore(_ core: SPPlayerCore, didUpdatePosition position: Double, duration: Double) {
        captionsAttachIfNeeded()
        captionsAutomationHookIfNeeded()
        // First-frame presentation publishes a position edge. This makes the
        // catalogue event-driven in the normal path; exponential polling is
        // only a malformed-stream/lost-edge safety net.
        if pendingDirectoryScan != nil,
           core.hasEverPresentedThisSession || core.audioOnlySession {
            runPendingDirectoryScanWhenFirstFramePresented()
        }
        if chromeInstallPending, core.hasEverPresentedThisSession || core.audioOnlySession {
            installPendingChromeSoon()
        }
        if !isScrubbing {
            transitionPresentation(.timelineChanged(
                position: position,
                duration: duration,
                rate: core.playbackRate
            ))
        }

        let motionStatsNow = CACurrentMediaTime()
        if motionStatsNow - lastMotionStatsRefresh >= 0.5 {
            lastMotionStatsRefresh = motionStatsNow
            transitionPresentation(.motionChanged(currentMotionPresentation(core: core)))
        }
        // Save resume position at most every five seconds and only after two
        // seconds of playback. UserDefaults writes can synchronously stall the
        // main thread for about 30 ms, so periodic persistence uses a serialized
        // utility queue. Session-boundary saves preserve ordering, and only
        // quit/close forces disk synchronization.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSaveTime > 5, position > 2, let core = self.core {
            lastSaveTime = now
            if let fp = core.currentFilePath {
                let checkpoint = SPResumeCheckpoint(position: position,
                                                    duration: duration)
                Self.pendingResumeByPath[fp] = checkpoint
                Self.resumeSaveQueue.async {
                    SPResumePositionStore.persist(checkpoint, path: fp)
                }
            }
        }
    }

    static let resumeSaveQueue =
        DispatchQueue(label: "dev.khuaplayer.resume-save", qos: .utility)

    private func persistCompletedResumeState(_ core: SPPlayerCore) {
        guard hasMediaSession, let fp = core.currentFilePath else { return }
        let checkpoint = SPResumePolicy.completedCheckpoint(duration: core.duration)
        Self.pendingResumeByPath[fp] = checkpoint
        replayResumeResetArmedPath = fp
        recentRecordedThisOpen = true
        let title = (fp as NSString).lastPathComponent
        Self.resumeSaveQueue.async {
            SPResumePositionStore.persist(checkpoint, path: fp)
            RecentPlays.record(path: fp, title: title,
                               position: checkpoint.position,
                               duration: checkpoint.duration, insert: false)
        }
    }

    private func resetResumeStateForReplayIfNeeded(_ core: SPPlayerCore) {
        guard let fp = core.currentFilePath,
              replayResumeResetArmedPath == fp else { return }
        replayResumeResetArmedPath = nil
        let checkpoint = SPResumePolicy.replayCheckpoint(
            position: core.position, duration: core.duration)
        Self.pendingResumeByPath[fp] = checkpoint
        Self.resumeSaveQueue.async {
            SPResumePositionStore.persist(checkpoint, path: fp)
        }
        recentRecordedThisOpen = false
    }

    func flushResumePositionNow(forceDiskSync: Bool) {

        let snapshot: (fp: String, position: Double, duration: Double)? = {
            guard let core, core.state != .opening,
                  let fp = core.currentFilePath, core.position > 2 else { return nil }
            return (fp, core.position, core.duration)
        }()
        if let s = snapshot {
            Self.pendingResumeByPath[s.fp] = SPResumeCheckpoint(
                position: s.position, duration: s.duration)
        }
        if forceDiskSync {
            Self.resumeSaveQueue.sync {
                if let s = snapshot {
                    let checkpoint = SPResumeCheckpoint(position: s.position,
                                                        duration: s.duration)
                    SPResumePositionStore.persist(checkpoint, path: s.fp)
                    RecentPlays.record(path: s.fp, title: (s.fp as NSString).lastPathComponent,
                                       position: s.position, duration: s.duration, insert: false)
                }
                UserDefaults.standard.synchronize()
            }
        } else if let s = snapshot {
            Self.resumeSaveQueue.async {
                let checkpoint = SPResumeCheckpoint(position: s.position,
                                                    duration: s.duration)
                SPResumePositionStore.persist(checkpoint, path: s.fp)
                RecentPlays.record(path: s.fp, title: (s.fp as NSString).lastPathComponent,
                                   position: s.position, duration: s.duration, insert: false)
            }
        }
    }

    private static var pendingResumeByPath: [String: SPResumeCheckpoint] = [:]

    func clearAllHistory() {
        Self.pendingResumeByPath.removeAll()
        Self.resumeSaveQueue.sync {
            let defaults = UserDefaults.standard

            if let domain = Bundle.main.bundleIdentifier,
               let keys = defaults.persistentDomain(forName: domain)?.keys {
                for key in keys where key.hasPrefix("sp.pos.") {
                    defaults.removeObject(forKey: key)
                }
            }
            defaults.removeObject(forKey: SPResumePositionIndex.key)
            RecentPlays.clear()
            defaults.removeObject(forKey: "NSOSPLastRootDirectory")
            defaults.synchronize()
        }
        NSDocumentController.shared.clearRecentDocuments(nil)
        // Drop cached panels in every window so a cleared browsing directory
        // cannot survive in an existing panel instance.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.discardAllReusableOpenPanels()
        } else {
            discardReusableOpenPanel()
        }

        if !hasMediaSession { dismissFailurePresentation() }
        welcome?.reload()
        if spDebugEnabled {
            NSLog("[UI] 历史记录已全部清空")
        }
    }

    func playerCore(_ core: SPPlayerCore, didFailWithError error: Error) {

        let nsError = error as NSError
        let diagnosis = nsError.userInfo[SPPlayerErrorDiagnosisKey] as? String

        let terminal = (nsError.userInfo[SPPlayerErrorTerminalKey] as? NSNumber)?.boolValue
        let action = failureTracker.noteError(domain: nsError.domain, diagnosis: diagnosis, terminal: terminal)
        transitionPresentation(.recoverableWarning)
        if spDebugEnabled {
            NSLog("[UI] failure domain=%@ diagnosis=%@ terminal=%d action=%@", nsError.domain, diagnosis ?? "-",
                  terminal.map { $0 ? 1 : 0 } ?? -1, String(describing: action))
        }
        switch action {
        case .alert, .none:

            DispatchQueue.main.async { [weak self] in
                self?.presentPlaybackError(error)
            }
        case .rememberPending:
            break
        case .upgradeShown(let reason):
            presentFailureNotice(reason)
        }
    }

    func playerCoreWaitedSourceBecameReady(_ core: SPPlayerCore) {
        guard core === self.core, shownFailureReason == .waitingForDownload, lastFailedOpenURL != nil else { return }
        retryFailedOpen()
    }

    private func presentFailureNotice(_ reason: PlayerFailureReason) {
        shownFailureReason = reason
        lastFailedOpenURL = lastOpenRequestURL
        guard let w = welcome else { return }
        w.showFailureNotice(title: reason.localizedTitle, reason: reason.localizedReason,
                            retryEnabled: lastFailedOpenURL != nil) { [weak self] in self?.retryFailedOpen() }
        if spDebugEnabled {
            NSLog("[UI] emptyState reason=%@ file=%@", reason.rawValue, lastFailedOpenURL?.lastPathComponent ?? "-")
        }
    }

    private func retryFailedOpen() {
        guard let url = lastFailedOpenURL else { return }
        welcome?.setFailureRetryEnabled(false)
        if spDebugEnabled {
            NSLog("[UI] emptyState retry file=%@", url.lastPathComponent)
        }
#if SP_APP_STORE

        if let grant = failedDocumentGrantURL {
            failedDocumentGrantURL = nil
            open(url: grant, incomingSecurityScopedGrant: true)
            return
        }
#endif
        open(url: url, incomingSecurityScopedGrant: false)
    }

    private func presentPlaybackError(_ error: Error) {
        presentNonBlockingAlert(message: L("alert.playFailed"), informative: error.localizedDescription)
    }

    // A modal NSAlert blocks the main queue, delaying playback callbacks,
    // timers, and later open requests. Prefer an asynchronous window sheet;
    // only the no-window fallback remains modal.
    private func presentNonBlockingAlert(message: String, informative: String) {
        if spDebugEnabled {
            NSLog("[UI] alert message=%@ informative=%@", message, informative)
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        if let window = view.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else if let window = view.window {

            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func playerCoreDidChangeFrameInterpolation(_ core: SPPlayerCore) {
        refreshMotionSmoothingControl()
    }

    func playerCoreDidChangeDecoder(_ core: SPPlayerCore) {
        transitionPresentation(.hdrChanged(description: core.hdrDescription,
                                           detail: core.hdrDetailDescription))
        refreshXDRControl()
    }

    func playerCoreDidChangeSourceGrowth(_ core: SPPlayerCore) {
        guard core === self.core else { return }
        if core.sourceWaitingForIndex {

            if let w = welcome, w.isShowingFailureNotice, let reason = shownFailureReason, reason == .waitingForDownload {
                w.showFailureNotice(title: reason.localizedTitle,
                                    reason: core.sourceStalled ? L("emptyState.reason.waitingForIndexStalled") : reason.localizedReason,
                                    retryEnabled: lastFailedOpenURL != nil) { [weak self] in self?.retryFailedOpen() }
            }
            return
        }
        if let new = core.currentFilePath, let old = openMediaPath, new != old, hasMediaSession {
            followRenamedSource(from: old, to: new)
        }
        if core.sourceWaiting {
            playbackNoticeView().setSticky(core.sourceStalled ? L("playback.notice.downloadStalled")
                                                               : L("playback.notice.waitingForDownload"))
        } else if core.contentSearching {

            playbackNoticeView().setSticky(L("playback.notice.searchingContent"))
        } else {
            playbackNotice?.setSticky(nil)
        }
    }

    private var skipNoticeCount = 0
    private var skipNoticeLastAt: TimeInterval = 0

    func playerCore(_ core: SPPlayerCore, didSkipMissingContentFrom fromSec: Double, to toSec: Double, afterSeek: Bool) {
        guard core === self.core else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let text: String
        if afterSeek {
            skipNoticeCount = 0
            text = String(format: L("playback.notice.seekLandedAfterMissing"),
                          SPTimeText.clock(fromSec), SPTimeText.clock(toSec))
        } else if skipNoticeCount > 0 && now - skipNoticeLastAt < 3 {
            skipNoticeCount += 1
            text = String(format: L("playback.notice.skippedMissingCount"), skipNoticeCount)
        } else {
            skipNoticeCount = 1
            text = String(format: L("playback.notice.skippedMissing"),
                          SPTimeText.clock(fromSec), SPTimeText.clock(toSec))
        }
        skipNoticeLastAt = now
        playbackNoticeView().showTransient(text)
    }

    private func followRenamedSource(from old: String, to new: String) {
        openMediaPath = new
        let title = (new as NSString).lastPathComponent
        view.window?.title = title
        if let pending = Self.pendingResumeByPath.removeValue(forKey: old) {
            Self.pendingResumeByPath[new] = pending
        }
        Self.resumeSaveQueue.async {
            RecentPlays.rename(from: old, to: new, title: title)
        }
    }

    func playerCoreDidUpdateTimelinePreview(_ core: SPPlayerCore) {
        chrome?.refreshHoverPreview()
        chrome?.refreshDust()
        chrome?.refreshDamage()
    }

    private static func formatTime(_ pos: Double, _ dur: Double) -> String {
        "\(SPTimeText.clock(pos)) / \(SPTimeText.clock(dur))"
    }

    private var commandContext: PlayerCommandContext {
        guard let core else { return .empty }
        return PlayerCommandContext(
            hasMedia: hasMediaSession,
            position: core.position,
            duration: core.duration,
            volumePercent: Double(core.volume) * 100,
            volumeBoostUnlocked: volumeBoostUnlocked,
            hasMultipleMedia: mediaList.count > 1 || playlistFolderAccessRequestable,

            frameInterpolationAvailable: core.frameInterpolationAvailable && !core.frameInterpolationContentBypassed,
            frameInterpolationRequested: core.frameInterpolationMode.rawValue != 0,
            xdrAvailable: hasVideoSession && core.xdrAvailable,
            xdrRequested: core.xdrEnabled
        )
    }

    private func perform(_ requestedCommand: PlayerCommand) {

        if turbo.blocksPlaybackControls, SPTurboSpeed.blocksCommand(requestedCommand) { return }
        // A new explicit command supersedes an unfinished trackpad seek.
        if scrollSeekTarget != nil { cancelPlaybackScroll() }

        var context = commandContext
        if case .seekRelative(let delta) = requestedCommand {
            if ProcessInfo.processInfo.systemUptime - lastRelSeekAt < 2.0,
               lastRelSeekTarget >= 0 {

                context.relativeSeekBase = delta > 0
                    ? max(lastRelSeekTarget, context.position)
                    : lastRelSeekTarget
            }

            context.coarseSeekLanding = coarseSeekLandingForBackstep
        }
        guard let command = PlayerCommandPolicy.resolve(requestedCommand,
                                                        in: context) else { return }

        switch command {
        case .togglePlayback:
            togglePlaybackNow()
        case .seekAbsolute(let target):
            lastRelSeekTarget = -1
            issueForegroundSeek(to: target)
        case .seekCoarse(let target, let forward):
            lastRelSeekTarget = target
            lastRelSeekAt = ProcessInfo.processInfo.systemUptime
            issueForegroundSeek(to: target, precise: false, forward: forward)
        case .setPlaybackRate(let rate):
            core?.setPlaybackRate(rate)
            if let core {
                transitionPresentation(.playbackRateChanged(core.playbackRate))
            }
        case .setVolumePercent(let percent):
            // Normalize Float round-off at the 100% interaction boundary.
            let normalizedPercent = abs(percent - 100) < 0.01 ? 100 : percent
            if normalizedPercent > 100 {
                volumeBoostUnlocked = true
                clearVolumeBoostPrompt()
            } else {
                // Returning to the normal range locks boost again.
                volumeBoostUnlocked = false
                clearVolumeBoostPrompt()
            }
            core?.setVolume(Float(normalizedPercent / 100))
            if normalizedPercent > 0 { core?.setMuted(false) }
            publishVolumePresentation()
        case .toggleMute:
            if let core {
                core.setMuted(!core.isMuted)
            }
            publishVolumePresentation()
        case .toggleFullscreen:
            toggleFullscreen()
        case .setLoopPointA:
            if let core { core.setLoopPointA(core.position) }
        case .setLoopPointB:
            if let core { core.setLoopPointB(core.position) }
        case .clearLoop:
            core?.clearLoop()
        case .stepFrame(let delta):
            yieldDirectoryScanToForegroundIO()
            core?.stepFrame(delta)
        case .captureScreenshot:
            captureScreenshot()
        case .openDocument:
            presentOpenDocumentPanel()
        case .loadSubtitle:
            presentSubtitlePanel()
        case .showMediaInfo:
            presentMediaInfo()
        case .selectSubtitleTrack(let index):
            // Positive track changes re-read cues through an internal precise
            // seek; Off is an in-memory reset and needs no storage preemption.
            if index >= 0, core?.currentSubtitleTrackIndex != index {
                yieldDirectoryScanToForegroundIO()
            }
            core?.selectSubtitleTrack(at: index)
        case .selectAudioTrack(let index):
            if core?.currentAudioTrackIndex != index {
                yieldDirectoryScanToForegroundIO()
                resetVolumeBoostForNewSource()
            }
            core?.selectAudioTrack(at: index)
        case .setSubtitleScale(let scale):
            core?.setSubtitleScale(scale)
        case .setFrameInterpolation(let enabled):
            applyFrameInterpolationMode(enabled ? .doubleRate : .off)
        case .setXDR(let enabled):
            core?.xdrEnabled = enabled
            refreshXDRControl()
        case .setRotation(let degrees):
            core?.setRotation(degrees)
        case .setMirror(let mode):
            core?.setMirror(mode)
        case .previousMedia:
            playPreviousMedia()
        case .nextMedia:
            playNextMedia()
        case .seekRelative, .adjustVolumePercent, .toggleFrameInterpolation, .toggleXDR:
            assertionFailure("PlayerCommandPolicy must resolve derived commands")
        }

        if PlayerCommandPolicy.revealsControls(after: command) {
            showControlsTemporarily()
        }
    }

    private func publishVolumePresentation() {
        guard let core else { return }
        transitionPresentation(.volumeChanged(
            percent: Double(core.volume) * 100,
            muted: core.isMuted,
            boost: currentVolumeBoostPresentation
        ))
    }

    private var currentVolumeBoostPresentation: VolumeBoostPresentation {
        if volumeBoostUnlocked { return .unlocked }
        return volumeBoostPrompted ? .prompted : .normal
    }

    /// Pending boost confirmation expires after four seconds.
    private var volumeBoostPromptExpiry: DispatchWorkItem?

    private func armVolumeBoostPrompt() {
        volumeBoostPrompted = true
        volumeBoostPromptExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.volumeBoostPrompted else { return }
            self.volumeBoostPrompted = false
            self.publishVolumePresentation()
        }
        volumeBoostPromptExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func clearVolumeBoostPrompt() {
        volumeBoostPromptExpiry?.cancel()
        volumeBoostPromptExpiry = nil
        volumeBoostPrompted = false
    }

    /// Clear software boost at a new audio-source boundary.
    private func resetVolumeBoostForNewSource() {
        volumeBoostUnlocked = false
        clearVolumeBoostPrompt()
        if let core, core.volume > 1 { core.setVolume(1) }
        publishVolumePresentation()
    }

    /// Handle the two-stage pointer and accessibility boost action.
    private func handleVolumeBoostIntent() {
        guard let core, Double(core.volume) * 100 >= 100 else { return }
        if volumeBoostUnlocked { return }
        if volumeBoostPrompted {
            volumeBoostUnlocked = true
            clearVolumeBoostPrompt()
            // The confirming action enters the boosted range immediately.
            perform(.setVolumePercent(105))
            return
        } else {
            armVolumeBoostPrompt()
        }
        publishVolumePresentation()
        showControlsTemporarily()
    }

    @objc private func volumeChanged() {
        perform(.setVolumePercent(volumeSlider.doubleValue))
    }

    @objc private func muteTapped() {
        perform(.toggleMute)
    }

    @objc private func rewindTapped() {
        perform(.seekRelative(-5))
    }

    @objc private func forwardTapped() {
        perform(.seekRelative(5))
    }

    @objc func mediaInfoAction(_ sender: Any?) {
        perform(.showMediaInfo)
    }

    private func presentMediaInfo() {
        guard let info = core?.mediaInfo() else { return }

        let preferredOrder = [
            L("media.codec"), L("media.resolution"), L("media.rotation"), L("media.fps"), L("media.bitrate"),
            L("media.duration"), L("media.primaries"), L("media.trc"), L("media.depth"),
            L("media.hdrFormat"), L("media.maxcll"), L("media.maxfall"),
            L("media.decoder"), L("media.container"), L("media.audio"),
        ]
        let lines = info.keys.map { String(describing: $0) }
            .sorted { a, b in
                switch (preferredOrder.firstIndex(of: a), preferredOrder.firstIndex(of: b)) {
                case let (ia?, ib?): return ia < ib
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a < b
                }
            }
            .map { "\($0): \(info[$0] ?? "")" }
        presentNonBlockingAlert(message: L("alert.mediaInfo.title"), informative: lines.joined(separator: "\n"))
    }

    // Aspect correction and cropping are orthogonal: correction letterboxes the
    // full image, while cropping removes centered overflow. Each menu is
    // internally exclusive, and the two selections may be combined.

    private var currentForcedAspectTag = 0
    private var currentCropTag = 0

    @objc func forcedAspectAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        core?.setForcedAspect(Double(item.tag) / 1000.0)
        currentForcedAspectTag = item.tag
    }

    @objc func cropAspectAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        core?.setCropAspect(Double(item.tag) / 1000.0)
        currentCropTag = item.tag
    }

    @objc func rotationAction(_ sender: Any?) {
        perform(.setRotation((sender as? NSMenuItem)?.tag ?? 0))
    }

    @objc func mirrorAction(_ sender: Any?) {
        perform(.setMirror((sender as? NSMenuItem)?.tag ?? 0))
    }

    @objc private func playPauseTapped() {
        perform(.togglePlayback)
    }

    private var scrubTimer: Timer?
    private var pendingScrubTarget: Double?
    private var repeatOwnerKeyCode: UInt16?
    private var lastCoarseSeekAt: TimeInterval = 0
    private var lastCoarseTarget: Double = -1
    private var lastHoverHintAt: TimeInterval = 0

    private var lastThumbReqAt: TimeInterval = 0
    private var thumbTrailingRequest: SPTrailingPreviewRequest?
    private var lastHoverHintSec: Double = -1e9

    private var lastRelSeekTarget: Double = -1
    private var lastRelSeekAt: TimeInterval = 0

    private static let backstepFixDisabled: Bool = {
        #if SP_APP_STORE
        return false
        #else
        return ProcessInfo.processInfo.environment["SP_NO_BACKSTEP_FIX"] != nil
        #endif
    }()
    private var coarseSeekLandingForBackstep: Double {
        if Self.backstepFixDisabled { return -1 }
        return core?.lastSettledCoarseSeekLandingSeconds ?? -1
    }

    // Timeline seeking stays on keyframes. Each click or drag step reaches one
    // frame in roughly 20 ms without a second refinement jump. Position updates
    // align the slider to the actual keyframe rather than the requested pixel.
    @objc private func sliderChanged() {
        guard let core, core.duration > 0 else { return }
        yieldDirectoryScanToForegroundIO()
        let target = slider.doubleValue * core.duration
        if Self.dbg {
            NSLog("[UI] sliderChanged value=%.4f target=%.2fs", slider.doubleValue, target)
        }
        timeLabel.stringValue = Self.formatTime(target, core.duration)

        if abs(target - lastCoarseTarget) < 0.0005 { return }
        lastCoarseTarget = target

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCoarseSeekAt >= 0.05 {
            lastCoarseSeekAt = now
            scrubTimer?.invalidate()
            issueForegroundSeek(to: target, precise: false)
        } else {
            scrubTimer?.invalidate()
            scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self, self.core != nil else { return }
                self.lastCoarseSeekAt = ProcessInfo.processInfo.systemUptime
                self.issueForegroundSeek(to: target, precise: false)
            }
        }
    }

    fileprivate func sliderTrackingBegan() {
        cancelPlaybackScroll()
        if Self.dbg { NSLog("[UI] slider 按下") }
        yieldDirectoryScanToForegroundIO()
        isScrubbing = true
        lastCoarseTarget = -1
    }

    fileprivate func sliderTrackingEnded() {
        if Self.dbg { NSLog("[UI] slider 松开") }
        isScrubbing = false
    }

    @objc func recentPlayAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openRecentEntry(path: path)
    }

    // Clear the recent menu without deleting saved resume positions. Serialize
    // with pending history writes so an older write cannot restore cleared rows.
    @objc func clearRecentPlaysAction(_ sender: NSMenuItem) {
        Self.resumeSaveQueue.async {
            RecentPlays.clear() // Notify all welcome windows.
        }
    }

    @objc func openDocumentAction(_ sender: Any?) {
        perform(.openDocument)
    }

    // Reuse one lazily configured panel per window to avoid repeated service
    // initialization. The panel retains its browsing directory between opens.
    private var reusableOpenPanelStorage: NSOpenPanel?
    private lazy var openPanelUsage = SPOpenPanelUsageTracker()
    private var openPanelPresentationObservation: SPOpenPanelPresentationObservation?
    private var openPanelPresentationScheduled = false
    private var openPanelPresentationActive = false
    private var openPanelPresentationGeneration = 0

    /// AppKit panel construction stays on the main thread and can wait for XPC.
    private func reusableOpenPanel(source: SPOpenPanelBuildSource) -> NSOpenPanel {
        if let panel = reusableOpenPanelStorage { return panel }
        let t0 = ProcessInfo.processInfo.systemUptime
        let panel = NSOpenPanel()

        panel.allowedContentTypes = []
        panel.treatsFilePackagesAsDirectories = true
        if spDebugEnabled {
            NSLog("[UI] Open panel construction: %.0fms",
                  (ProcessInfo.processInfo.systemUptime - t0) * 1000)
        }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
#if !SP_APP_STORE
        // NSOpenPanel persists its directory bookmark. Use ~/Movies only when
        // no bookmark exists, because assigning directoryURL would otherwise
        // override the panel service's saved location.
        if UserDefaults.standard.data(forKey: "NSOSPLastRootDirectory") == nil {
            let movies = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies", isDirectory: true)
            if FileManager.default.fileExists(atPath: movies.path) {
                panel.directoryURL = movies
            }
        }
#endif
        reusableOpenPanelStorage = panel
        openPanelUsage.constructed(source: source,
            duration: ProcessInfo.processInfo.systemUptime - t0)
        return panel
    }

    /// Dismiss a standalone panel when its host closes. AppKit manages attached
    /// sheets; keeping the cached instance avoids rebuilding on the next open.
    func dismissOpenPanelPresentation() {
        // Invalidate a queued click even when the panel has not been built yet.
        openPanelPresentationGeneration &+= 1
        openPanelPresentationScheduled = false
        openPanelPresentationObservation?.cancel()
        openPanelPresentationObservation = nil
        guard let panel = reusableOpenPanelStorage,
              panel.sheetParent == nil else { return }
        SPOpenPanelWindowOrder.detach(panel: panel)
        if openPanelPresentationActive || panel.isVisible { panel.cancel(nil) }
        openPanelPresentationActive = false
    }

    func cancelOpenDocumentPanelForTest() {
        guard let panel = reusableOpenPanelStorage, panel.isVisible else { return }
        panel.cancel(nil)
    }

#if SP_INTERNAL_BUILD && !SP_APP_STORE

    func reopenTestClickFirstRowWithEvents() -> Bool {
        guard let window = view.window, let welcome, !welcome.isHidden,
              let p = welcome.firstRecentRowCenterInWindow() else { return false }
        func post(_ type: NSEvent.EventType, _ pt: NSPoint, clicks: Int = 0) {
            guard let e = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clicks, pressure: 0)
            else { return }
            NSApp.postEvent(e, atStart: false)
        }
        post(.mouseMoved, NSPoint(x: p.x - 40, y: p.y + 60))
        post(.mouseMoved, NSPoint(x: p.x - 10, y: p.y + 4))
        post(.mouseMoved, p)
        post(.leftMouseDown, p, clicks: 1)
        post(.leftMouseUp, p, clicks: 1)
        return true
    }
#endif

    func prepareOpenPanelForReopenTest(directory: URL?) {
        let panel = reusableOpenPanel(source: .test)
        if let directory { panel.directoryURL = directory }
    }

    /// Clearing history also discards the panel's in-memory directory state.
    func discardReusableOpenPanel() {
        dismissOpenPanelPresentation()
        guard let panel = reusableOpenPanelStorage else { return }
        if let host = panel.sheetParent {
            host.endSheet(panel, returnCode: .cancel)
        } else if panel.isVisible {
            panel.close()
        }
        reusableOpenPanelStorage = nil
        openPanelUsage.discarded()
    }

    /// Prepare without presenting after an explicit hover dwell.
    func prewarmOpenDocumentPanel(source: SPOpenPanelBuildSource) {
        SPMainThreadSentinel.phase("openPanel.prewarm") {
            _ = reusableOpenPanel(source: source)
        }
    }

    private var openPanelQuietPrewarmWork: DispatchWorkItem?

    func scheduleQuietOpenPanelPrewarm() {
        guard reusableOpenPanelStorage == nil, openPanelQuietPrewarmWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openPanelQuietPrewarmWork = nil
            guard self.reusableOpenPanelStorage == nil,
                  let core = self.core,
                  let window = self.view.window,
                  !SPBackgroundStorageGate.isForegroundActivityActive else { return }

            let quiet = window.isMiniaturized ||
                (window.isVisible && !window.occlusionState.contains(.visible))
            guard quiet, core.state != .opening, !self.turbo.blocksPlaybackControls else { return }

            guard !Self.anyPlayerWindowVisible else { return }
            if Self.dbg {
                NSLog("[UI] Open panel quiet prewarm: state=%d occluded=%d",
                      core.state.rawValue, !window.occlusionState.contains(.visible) ? 1 : 0)
            }
            SPMainThreadSentinel.phase("openPanel.quietPrewarm") {
                _ = self.reusableOpenPanel(source: .occluded)
            }
        }
        openPanelQuietPrewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    static var anyPlayerWindowVisible: Bool {
        NSApp.windows.contains { w in
            w.contentViewController is PlayerViewController &&
                w.isVisible && w.occlusionState.contains(.visible)
        }
    }

    // Pending 120 ms hover dwell; leaving or clicking cancels it.
    private var openPanelHoverPrewarmWork: DispatchWorkItem?

    func scheduleOpenPanelHoverPrewarm() {
        guard reusableOpenPanelStorage == nil, !hasMediaSession,
              openPanelHoverPrewarmWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openPanelHoverPrewarmWork = nil
            // Session, existence-check, and window state may change during dwell.
            guard self.core?.state == .idle, !self.hasMediaSession,
                  self.view.window?.isVisible == true,
                  self.recentOpenSettled == self.recentOpenToken else { return }
            self.prewarmOpenDocumentPanel(source: .hover)
        }
        openPanelHoverPrewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancelOpenPanelHoverPrewarm() {
        openPanelHoverPrewarmWork?.cancel()
        openPanelHoverPrewarmWork = nil
    }

    private func presentOpenDocumentPanel() {
        cancelOpenPanelHoverPrewarm() // The explicit open now owns construction.
        if openPanelPresentationActive {
            reusableOpenPanelStorage?.makeKeyAndOrderFront(nil)
            return
        }
        guard !openPanelPresentationScheduled else { return }
        openPanelPresentationScheduled = true
        openPanelPresentationGeneration &+= 1
        let generation = openPanelPresentationGeneration
        // Warm and cold panels both leave the mouseDown handler before showing.
        // Coalesce repeated input, and do not reopen after the host closes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openPanelPresentationGeneration == generation else { return }
            defer {
                if self.openPanelPresentationGeneration == generation {
                    self.openPanelPresentationScheduled = false
                }
            }
            guard self.view.window?.isVisible == true else { return }
            let cacheHit = self.reusableOpenPanelStorage != nil
            if self.reusableOpenPanelStorage == nil {
                SPMainThreadSentinel.phase("openPanel.lazyBuild") {
                    _ = self.reusableOpenPanel(source: .explicitOpen)
                }
            }
            // Construction can pump a nested AppKit run loop.
            guard self.openPanelPresentationGeneration == generation,
                  self.view.window?.isVisible == true else { return }
            self.beginOpenDocumentPanel(cacheHit: cacheHit)
        }
    }

    private func beginOpenDocumentPanel(cacheHit: Bool) {
        guard let host = view.window else { return }
        let panel = reusableOpenPanel(source: .explicitOpen)
        // Repeated input focuses the existing presentation instead of starting another.
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        openPanelPresentationActive = true
        let generation = openPanelPresentationGeneration
        // Count actual presentation even when faster than the hang threshold.
        // Each attempt owns its observer, including cancellation before it is key.
#if SP_INTERNAL_BUILD && !SP_APP_STORE
        let shouldObservePresentation = true
#else
        let shouldObservePresentation = spDebugEnabled
#endif
        let presentationObservation: SPOpenPanelPresentationObservation?
        if shouldObservePresentation {
            let t0 = ProcessInfo.processInfo.systemUptime
            presentationObservation = SPOpenPanelPresentationObservation(panel: panel) { [weak self] in
                let duration = ProcessInfo.processInfo.systemUptime - t0
                self?.openPanelUsage.presented(duration: duration, cacheHit: cacheHit)
                if spDebugEnabled {
                    NSLog("[UI] Open panel presentation: %.0fms", duration * 1000)
                }
            }
        } else {
            presentationObservation = nil
        }
        openPanelPresentationObservation = presentationObservation
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] resp in
            presentationObservation?.cancel()
            if self?.openPanelPresentationObservation === presentationObservation {
                self?.openPanelPresentationObservation = nil
            }
            guard let panel else { return }
            let ownsPresentation = self?.openPanelPresentationGeneration == generation
                && self?.reusableOpenPanelStorage === panel
            // A late remote completion must not detach a newly reopened
            // presentation of the same cached panel.
            if ownsPresentation || self?.reusableOpenPanelStorage !== panel {
                SPOpenPanelWindowOrder.detach(panel: panel)
            }
            if ownsPresentation {
                self?.openPanelPresentationActive = false
            }
            guard resp == .OK, let url = panel.url else { return }
            guard ownsPresentation, let self,
                  self.view.window?.isVisible == true else {
                spReleaseSecurityScopedGrant(url)
                return
            }
            // Ensure the host is visible before starting playback from a panel.
            self.view.window?.makeKeyAndOrderFront(nil)
            self.open(url: url)
        }

        SPMainThreadSentinel.phase("openPanel.begin") {
            panel.begin(completionHandler: handler)
            presentationObservation?.recordIfVisibleAndKey(panel)
            // begin is modeless: it does not constrain its order relative to
            // the host. Attach only after the remote panel has been presented;
            // attaching before begin adds expensive service setup to this path.
            if openPanelPresentationActive, openPanelPresentationGeneration == generation,
               reusableOpenPanelStorage === panel, view.window === host, host.isVisible {
                SPOpenPanelWindowOrder.attach(panel: panel, to: host)
            }
        }
    }

    @objc func loadSubtitleAction(_ sender: Any?) {
        perform(.loadSubtitle)
    }

    private func presentSubtitlePanel() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ass", "ssa", "srt", "vtt"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }

            guard let self else {
                spReleaseSecurityScopedGrant(url)
                return
            }
            self.loadExternalSubtitle(url: url)
        }
    }

    @objc func subtitleScaleAction(_ sender: NSMenuItem) {
        perform(.setSubtitleScale(Double(sender.tag) / 100.0))
    }

    @objc func frameInterpolationAction(_ sender: NSMenuItem) {
        guard SPFeatures.enhancements else { return }
        guard let mode = SPFrameInterpolationMode(rawValue: sender.tag) else { return }
        perform(.setFrameInterpolation(mode.rawValue != 0))
    }

    private var hasVideoSession: Bool {
        hasMediaSession && !(core?.audioOnlySession ?? false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(frameInterpolationAction(_:)) {
            return hasVideoSession
        }
        if menuItem.action == #selector(generateCaptionsAction(_:)) {
            captionsRefreshMenuTitle(menuItem)
            return captionsMenuAvailable
        }
        if menuItem.action == #selector(forcedAspectAction(_:)) ||
           menuItem.action == #selector(cropAspectAction(_:)) {
            return hasVideoSession
        }
        if let action = menuItem.action { return responds(to: action) }
        return false
    }

    private func applyFrameInterpolationMode(_ mode: SPFrameInterpolationMode) {
        guard let core else { return }

        core.frameInterpolationMode = hasVideoSession ? mode : .off
        refreshMotionSmoothingControl()
    }

    private func refreshMotionSmoothingControl() {
        guard let core else { return }
        transitionPresentation(.motionChanged(currentMotionPresentation(core: core)))
    }

    private func refreshXDRControl() {
        guard let core else { return }
        transitionPresentation(.xdrChanged(currentXDRPresentation(core: core)))
    }

    private func currentXDRPresentation(core: SPPlayerCore? = nil) -> XDRPresentation {
        guard let core = core ?? self.core else { return .idle }
        return XDRPresentation(
            hasMedia: hasVideoSession,
            contentSDR: core.hdrDescription == "SDR",
            displayCapable: core.displayEDRCapable,
            requested: core.xdrEnabled,
            headroom: core.displayEDRHeadroom
        )
    }

    func playerCoreDidChangeXDRAvailability(_ core: SPPlayerCore) {
        refreshXDRControl()
    }

    private var lastMotionStatsRefresh: CFTimeInterval = 0

    private func currentMotionPresentation(core: SPPlayerCore? = nil) -> MotionPresentation {
        guard let core = core ?? self.core else { return .idle }
        return MotionPresentation(
            hasMedia: hasVideoSession,
            requested: core.frameInterpolationMode.rawValue != 0,
            available: core.frameInterpolationAvailable,
            active: core.frameInterpolationActive,
            contentBypassed: core.frameInterpolationContentBypassed,
            outputFPS: core.presentedFrameRate,
            sourceFPS: core.videoInfo.fps,
            coverage: core.frameInterpolationCoverage,
            status: core.frameInterpolationStatus,
            unavailabilityDescription: core.frameInterpolationUnavailableDescription
        )
    }

    @objc func subtitleTrackAction(_ sender: NSMenuItem) {

        userTouchedSubtitleSelection = true
        activeExternalSubtitleURL = nil
        captionsUserSelectedOtherSubtitle()
        perform(.selectSubtitleTrack(sender.tag))
    }

    @objc func externalSubtitleTrackAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard url != activeExternalSubtitleURL else {
            captionsUserSelectedOtherSubtitle()
            return
        }
        loadExternalSubtitle(url: url)
    }

    @objc func audioTrackAction(_ sender: NSMenuItem) {
        perform(.selectAudioTrack(sender.tag))
    }

    @objc func togglePlayPauseAction(_ sender: Any?) { perform(.togglePlayback) }
    @objc func seekForwardAction(_ sender: Any?) { perform(.seekRelative(5)) }
    @objc func seekBackwardAction(_ sender: Any?) { perform(.seekRelative(-5)) }
    @objc func seekForwardBigAction(_ sender: Any?) { perform(.seekRelative(30)) }
    @objc func seekBackwardBigAction(_ sender: Any?) { perform(.seekRelative(-30)) }
    @objc func toggleFullscreenAction(_ sender: Any?) { perform(.toggleFullscreen) }

    private func seekWithRepeat(_ step: Double, ownerKeyCode: UInt16) {

        if repeatOwnerKeyCode != nil, repeatOwnerKeyCode != ownerKeyCode { stopRepeat() }
        seekStepInFlight = false
        burstStepCount = 0
        startRepeat(initialDelay: 0.3, ownerKeyCode: ownerKeyCode,
                    nextInterval: { [weak self] in

            guard let self else { return SeekBurstCadence.dwell }
            let elapsed = self.seekStepInFlight
                ? ProcessInfo.processInfo.systemUptime - self.seekStepIssuedAt
                : 0
            return SeekBurstCadence.nextTickDelay(elapsed: elapsed,
                                                  settled: self.core?.seekSettled ?? true)
        }) { [weak self] in
            guard let self, let core = self.core else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.seekStepInFlight {
                let elapsed = now - self.seekStepIssuedAt

                if elapsed < SeekBurstCadence.dwell { return }

                if !core.seekSettled && elapsed < SeekBurstCadence.settleTimeout { return }
            }
            self.burstStepCount += 1
            if self.burstStepCount == 1 {
                // A single press uses the same coarse-keyframe semantics as the
                // timeline; perform(.seekRelative) owns sticky-base handling.
                self.perform(.seekRelative(step))
                self.burstTarget = self.lastRelSeekTarget >= 0
                    ? self.lastRelSeekTarget
                    : max(0, min(core.position + step, core.duration))
            } else {
                if self.burstStepCount == 2, core.isPlaying {

                    self.burstWasPlaying = true
                    core.pause()
                }

                if step > 0 { self.burstTarget = max(self.burstTarget, core.position) }

                var nominal = self.burstTarget + step
                if step < 0 {
                    nominal = PlayerCommandPolicy.backwardStepTarget(
                        nominal: nominal, position: core.position,
                        landing: self.coarseSeekLandingForBackstep, step: -step)
                }
                let target = max(0, min(nominal, core.duration))
                if abs(target - self.burstTarget) < 0.01 { return }
                self.burstTarget = target
                self.issueForegroundSeek(to: target, precise: false,
                                         forward: step > 0)
            }
            self.seekStepInFlight = true
            self.seekStepIssuedAt = now
        }
    }

    // A held volume key cannot both reach 100% and confirm boost.
    private func volumeWithRepeat(_ delta: Double, ownerKeyCode: UInt16) {
        if repeatOwnerKeyCode != nil, repeatOwnerKeyCode != ownerKeyCode { stopRepeat() }
        var isInitialPhysicalPress = true
        startRepeat(initialDelay: 0.25, repeatInterval: 0.10,
                    ownerKeyCode: ownerKeyCode) { [weak self] in
            guard let self else { return }
            let mayUnlock = isInitialPhysicalPress
            isInitialPhysicalPress = false
            self.applyVolumeStep(delta, mayUnlockBoost: mayUnlock)
        }
    }

    private func applyVolumeStep(_ delta: Double, mayUnlockBoost: Bool) {
        guard let core else { stopRepeat(); return }
        let percent = Double(core.volume) * 100

        if delta > 0, !volumeBoostUnlocked {
            if percent >= 100 {
                if mayUnlockBoost, volumeBoostPrompted {
                    volumeBoostUnlocked = true
                    clearVolumeBoostPrompt()
                    perform(.setVolumePercent(min(500, percent + delta)))
                } else {
                    // Re-arm confirmation when the prompt is absent or expired.
                    armVolumeBoostPrompt()
                    publishVolumePresentation()
                    showControlsTemporarily()
                    // Require a separate physical key press for confirmation.
                    stopRepeat()
                }
                return
            }

            let target = min(100, percent + delta)
            perform(.setVolumePercent(target))
            return
        }

        if delta < 0, volumeBoostPrompted {
            clearVolumeBoostPrompt()
        }
        let limit = volumeBoostUnlocked ? 500.0 : 100.0
        if (delta > 0 && percent >= limit) || (delta < 0 && percent <= 0) {
            publishVolumePresentation()
            stopRepeat()
            return
        }
        perform(.adjustVolumePercent(delta))
    }

    private func startRepeat(initialDelay: TimeInterval,
                             repeatInterval: TimeInterval = 0.03,
                             ownerKeyCode: UInt16,
                             nextInterval: (() -> TimeInterval)? = nil,
                             _ initial: @escaping () -> Void) {
        repeatOwnerKeyCode = ownerKeyCode
        initial()
        // The initial action may end the repeat before its timer is installed.
        guard repeatOwnerKeyCode == ownerKeyCode else { return }
        repeatTimer?.invalidate()
        let action = initial
        repeatAction = action
        repeatNextInterval = nextInterval
        repeatTimer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.repeatNextInterval != nil else {
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
                    self?.repeatAction?()
                }
                return
            }
            self.runSelfSchedulingRepeat(ownerKeyCode: ownerKeyCode)
        }
    }

    private func runSelfSchedulingRepeat(ownerKeyCode: UInt16) {
        repeatAction?()
        guard repeatAction != nil, let nextInterval = repeatNextInterval,
              repeatOwnerKeyCode == ownerKeyCode else { return }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: max(0, nextInterval()),
                                           repeats: false) { [weak self] _ in
            self?.runSelfSchedulingRepeat(ownerKeyCode: ownerKeyCode)
        }
    }

    static let compareKeyCode: UInt16 = 8

    private func handleKeyUp(_ event: NSEvent) {

        if event.keyCode == Self.turboSpaceKeyCode {
            applyTurbo(turbo.keyUp(), reason: "keyUp")
        }
        if event.keyCode == Self.compareKeyCode, compareActive {
            setMotionCompare(false)
            return
        }
        // Play the boost invitation when the confirming key is released.
        if event.keyCode == 126, volumeBoostPrompted, !volumeBoostUnlocked {
            chrome?.playVolumeBoostInvitation()
        }

        if let owner = repeatOwnerKeyCode, event.keyCode != owner { return }
        stopRepeat()
    }

    private func setMotionCompare(_ on: Bool) {
        guard on != compareActive else { return }
        compareActive = on
        core?.setMotionCompareEnabled(on)
        if on { showCompareOverlay() } else { compareOverlay?.isHidden = true }
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private func showCompareOverlay() {
        if compareOverlay == nil {
            let overlay = PassthroughView()
            overlay.wantsLayer = true
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            overlay.addSubview(divider)
            func chip(_ text: String) -> NSTextField {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .white
                label.alignment = .center
                label.wantsLayer = true
                label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
                label.layer?.cornerRadius = 6
                overlay.addSubview(label)
                return label
            }
            compareLeftLabel = chip(L("compare.original"))
            compareRightLabel = chip(L("compare.interp2x"))
            compareDivider = divider
            compareOverlay = overlay
        }
        guard let overlay = compareOverlay else { return }
        if overlay.superview == nil { view.addSubview(overlay) }
        overlay.isHidden = false
        layoutCompareOverlay()
    }

    private func layoutCompareOverlay() {
        guard let overlay = compareOverlay else { return }
        overlay.frame = view.bounds
        let b = overlay.bounds
        compareDivider?.frame = NSRect(x: b.midX - 1.5, y: 0, width: 3, height: b.height)

        var topInset: CGFloat = 0
        if let win = view.window, let content = win.contentView {
            topInset = content.bounds.maxY - win.contentLayoutRect.maxY
        }
        func place(_ label: NSTextField?, centerXFraction: CGFloat) {
            guard let label else { return }
            let s = label.fittingSize
            let w = s.width + 20, h = s.height + 8
            label.frame = NSRect(x: b.width * centerXFraction - w / 2,
                                 y: b.height - h - 24 - topInset, width: w, height: h)
        }
        place(compareLeftLabel, centerXFraction: 0.25)
        place(compareRightLabel, centerXFraction: 0.75)
    }

    static let turboSpaceKeyCode: UInt16 = 49

    private static func turboAllowedKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53, 125, 126: return true
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "f", "F", "m", "M", "s", "S": return true
        default: return false
        }
    }

    private func togglePlaybackNow() {
        cancelPlaybackScroll()
        // Core.play() turns Ended into an implicit precise seek-to-zero.
        if core?.state == .ended { yieldDirectoryScanToForegroundIO() }
        core?.togglePlayPause()
    }

    private func turboSpaceDown() {
        // Restore the pre-gesture state before Turbo decides whether Space is
        // a pause request or a request to start an already paused item.
        cancelPlaybackScroll()
        guard let core else { return }

        if repeatOwnerKeyCode != nil { stopRepeat() }
        let effects = turbo.keyDown(enabled: SPTurboSettings.isEnabled,
                                    playing: core.state == .playing,
                                    currentRate: core.playbackRate,
                                    configuredRate: SPTurboSettings.rate)
        applyTurbo(effects, reason: "keyDown")
    }

    private func endTurbo(reason: String) {
        applyTurbo(turbo.forceEnd(), reason: reason)
    }

    func endTurboForSettingsChange() {
        endTurbo(reason: "settings")
    }

    func simulateTurboSpaceForTest(down: Bool) {
        if down { turboSpaceDown() } else { applyTurbo(turbo.keyUp(), reason: "keyUp(test)") }
    }

    var corePositionForTest: Double { core?.position ?? -1 }

    func simulateArrowKeyForTest(left: Bool, down: Bool) {
        guard let event = NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: left ? 123 : 124) else { return }
        if down { handleKey(event) } else { handleKeyUp(event) }
    }

    private func applyTurbo(_ effects: [SPTurboGesture.Effect], reason: String) {
        for effect in effects {
            switch effect {
            case .togglePlayback:
                togglePlaybackNow()
            case .scheduleThreshold:
                turboTimer?.invalidate()
                turboTimer = Timer.scheduledTimer(withTimeInterval: SPTurboSpeed.holdThreshold,
                                                  repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.turboTimer = nil
                    self.applyTurbo(self.turbo.thresholdFired(), reason: "threshold")
                }
                chrome?.setTurboPhase(.charging)
                turboHUDView().beginCharge(targetRate: turbo.turboRate)
                if Self.dbg {
                    NSLog("[Turbo] 蓄力 base=%.2f target=%.2f", turbo.baseRate, turbo.turboRate)
                }
            case .cancelThreshold:
                turboTimer?.invalidate()
                turboTimer = nil
                chrome?.setTurboPhase(.idle)
                turboHUD?.cancelCharge()
                if Self.dbg { NSLog("[Turbo] 蓄力取消（%@）", reason) }
            case .engage(let rate):
                guard let core else { break }

                openPanelQuietPrewarmWork?.cancel()
                openPanelQuietPrewarmWork = nil

                core.setPlaybackRate(rate)
                transitionPresentation(.playbackRateChanged(core.playbackRate))
                core.play()
                chrome?.setTurboPhase(.active)
                turboHUDView().engage(baseRate: turbo.baseRate, rate: core.playbackRate)
                if Self.dbg { NSLog("[Turbo] 加速 %.2f→%.2f", turbo.baseRate, core.playbackRate) }
            case .restore(let rate):
                turboTimer?.invalidate()
                turboTimer = nil
                turboHUD?.dismiss()

                if let core {
                    core.setPlaybackRate(rate)
                    transitionPresentation(.playbackRateChanged(core.playbackRate))
                    refreshMotionSmoothingControl()
                }
                chrome?.setTurboPhase(.idle)
                if Self.dbg { NSLog("[Turbo] 恢复 %.2f（%@）", rate, reason) }
            }
        }
    }

    private func turboHUDView() -> SPTurboHUDView {
        if let hud = turboHUD { return hud }
        let hud = SPTurboHUDView(frame: .zero)
        view.addSubview(hud)
        turboHUD = hud
        return hud
    }

    private func playbackNoticeView() -> SPPlaybackNoticeView {
        if let notice = playbackNotice { return notice }
        let notice = SPPlaybackNoticeView(frame: .zero)
        view.addSubview(notice)
        playbackNotice = notice
        layoutPlaybackNotice()
        return notice
    }

    private func layoutPlaybackNotice() {
        guard let notice = playbackNotice else { return }
        var topInset: CGFloat = 0
        if let win = view.window, let content = win.contentView {
            topInset = content.bounds.maxY - win.contentLayoutRect.maxY
        }
        notice.place(in: view.bounds, topInset: topInset)
    }

    private func layoutTurboHUD() {
        guard let hud = turboHUD else { return }

        var topInset: CGFloat = 0
        if let win = view.window, let content = win.contentView {
            topInset = content.bounds.maxY - win.contentLayoutRect.maxY
        }
        hud.place(in: view.bounds, topInset: topInset)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatAction = nil
        repeatNextInterval = nil
        repeatOwnerKeyCode = nil
        seekStepInFlight = false
        // Key release does not refine the final keyframe because remote media
        // can stall for 0.5-1 second while decoding to an exact target. Restore
        // playback and keep the sticky base at the accumulated target.
        if burstStepCount > 1, let core {
            lastRelSeekTarget = burstTarget
            lastRelSeekAt = ProcessInfo.processInfo.systemUptime
            if burstWasPlaying {
                core.play()
            }
        }
        burstWasPlaying = false
        burstStepCount = 0
    }

    @discardableResult
    private func cancelTransientInteractions() -> Bool {
        // Waiting and skipped-content notices belong to the outgoing session.
        // Closing to the welcome view need not produce another growth callback.
        playbackNotice?.clearAll()
        skipNoticeCount = 0
        skipNoticeLastAt = 0

        let shouldResumePlaybackOnRollback = burstWasPlaying || scrollSeekWasPlaying
        // Session boundaries drop delayed input without seeking or resuming the
        // outgoing item. A failed open can restore the captured playback state.
        scrollGestureTimeout?.invalidate()
        scrollGestureTimeout = nil
        gestureSeekTimer?.invalidate()
        gestureSeekTimer = nil
        gestureSeek.reset()
        _ = scrollGesture.reset()
        pinchGesture.reset()
        scrollSeekTarget = nil
        scrollSeekWasPlaying = false
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatAction = nil
        repeatNextInterval = nil

        scrubTimer?.invalidate()
        scrubTimer = nil
        pendingScrubTarget = nil

        thumbTrailingRequest?.cancel()
        chromePresenter?.cancelTransientInteraction()

        setMotionCompare(false)

        endTurbo(reason: "sessionBoundary")

        isScrubbing = false
        lastCoarseSeekAt = 0
        lastCoarseTarget = -1

        if scrubMuteEngaged {
            scrubMuteEngaged = false
            core?.setMuted(false)
            publishVolumePresentation()
        }

        seekStepInFlight = false
        seekStepIssuedAt = 0
        burstTarget = 0
        burstStepCount = 0
        burstWasPlaying = false
        return shouldResumePlaybackOnRollback
    }

    private func captureScreenshot() {
        guard let core, let fp = core.currentFilePath else { return }
        let name = ((fp as NSString).lastPathComponent as NSString).deletingPathExtension
        let baseName = "\(name)_screenshot_\(Int(core.position))"
        let mediaDirectory = (fp as NSString).deletingLastPathComponent

        core.captureScreenshotPNG { [weak self] png in
            guard let self else { return }
            guard let png else {
                self.noteScreenshotResult(ok: false, path: "")
                return
            }
            self.saveScreenshot(png, baseName: baseName, mediaDirectory: mediaDirectory)
        }
    }

    private func saveScreenshot(_ png: Data, baseName: String, mediaDirectory: String) {
#if SP_APP_STORE

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let saved = SPFolderGrants.ensureAccess(path: mediaDirectory)
                ? Self.writeScreenshot(png, directory: mediaDirectory, baseName: baseName)
                : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let saved {
                    self.noteScreenshotResult(ok: true, path: saved)
                } else {
                    self.presentScreenshotSavePanel(png, filename: baseName + ".png")
                }
            }
        }
#else

        var directories = [mediaDirectory]
        if let pictures = FileManager.default.urls(for: .picturesDirectory,
                                                   in: .userDomainMask).first?.path,
           pictures != mediaDirectory {
            directories.append(pictures)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in

            var saved: String?
            for directory in directories {
                saved = Self.writeScreenshot(png, directory: directory, baseName: baseName)
                if saved != nil { break }
            }
            DispatchQueue.main.async {
                self?.noteScreenshotResult(ok: saved != nil, path: saved ?? "")
            }
        }
#endif
    }

    nonisolated private static func writeScreenshot(_ png: Data, directory: String,
                                                    baseName: String) -> String? {
        for serial in 1..<1000 {
            let name = serial == 1 ? baseName + ".png" : "\(baseName)_\(serial).png"
            let path = (directory as NSString).appendingPathComponent(name)
            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: png)
                try handle.close()
                return path
            } catch {
                try? handle.close()
                unlink(path)
                return nil
            }
        }
        return nil
    }

#if SP_APP_STORE
    private func presentScreenshotSavePanel(_ png: Data, filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = filename
        let save: (URL) -> Void = { [weak self] url in
            DispatchQueue.global(qos: .utility).async {
                let ok = (try? png.write(to: url, options: .atomic)) != nil
                url.stopAccessingSecurityScopedResource()
                DispatchQueue.main.async {
                    self?.noteScreenshotResult(ok: ok, path: url.path)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                save(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            save(url)
        }
    }
#endif

    private func noteScreenshotResult(ok: Bool, path: String) {
        guard ok else {
            playbackNoticeView().showTransient(L("alert.screenshotFailed"))
            return
        }
        showControlsTemporarily()

        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        playbackNoticeView().showTransient(String(format: L("screenshot.notice.savedToFmt"), folder))
    }

    private func toggleFullscreen() {
        view.window?.toggleFullScreen(nil)
    }

    func fullscreenTransitionFailed() {
        gestureFullscreenTransition = false
        pinchGesture.reset()
    }

    private static func playbackGesturePhase(_ phase: NSEvent.Phase) -> SPPlaybackScrollGesture.Phase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        return phase.isEmpty ? .none : .changed
    }

    /// Only PlayerView forwards these events. Scroll views and playback controls
    /// keep their own input, rather than being intercepted by an app-wide monitor.
    private func handlePlaybackScroll(_ event: NSEvent) -> Bool {
        guard hasMediaSession, let core,
              core.state == .playing || core.state == .paused || core.state == .ended,
              !turbo.blocksPlaybackControls,
              !isScrubbing || scrollSeekTarget != nil else {
            cancelPlaybackScroll()
            return false
        }
        let phase = Self.playbackGesturePhase(event.phase)
        let effects = scrollGesture.update(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            inverted: event.isDirectionInvertedFromDevice, phase: phase,
            momentum: !event.momentumPhase.isEmpty,
            horizontalEnabled: SPPlaybackGestureSettings.horizontalSeekEnabled,
            verticalEnabled: SPPlaybackGestureSettings.verticalVolumeEnabled,
            sensitivity: SPPlaybackGestureSettings.sensitivity.multiplier)
        for effect in effects {
            switch effect {
            case .beginSeek:
                guard core.duration.isFinite, core.duration > 0 else { continue }
                stopRepeat()
                gestureSeekTimer?.invalidate()
                gestureSeekTimer = nil
                gestureSeek.reset()
                scrollSeekTarget = core.position
                scrollSeekWasPlaying = core.isPlaying
                thumbTrailingRequest?.cancel()
                isScrubbing = true
                scrubMuteAllowed = false
                lastCoarseTarget = -1
                lastRelSeekTarget = -1
                if scrollSeekWasPlaying { core.pause() }
            case .seek(let delta):
                if scrollSeekTarget != nil {
                    gestureSeek.submit(delta)
                    pumpPlaybackGestureSeek()
                    transitionPresentation(.timelineChanged(
                        position: core.position, duration: core.duration, rate: core.playbackRate))
                    showControlsTemporarily()
                } else {
                    perform(.seekRelative(delta))
                }
            case .endSeek:
                endPlaybackScrollSeek()
            case .volume(let delta):
                // PlayerCommandPolicy preserves the separate confirmation for
                // volume boost; a gesture cannot silently cross above 100%.
                perform(.adjustVolumePercent(delta))
            }
        }

        scrollGestureTimeout?.invalidate()
        scrollGestureTimeout = nil
        if phase != .ended, phase != .cancelled, phase != .none,
           event.momentumPhase.isEmpty {
            // End delivery can be lost when focus or the pointer moves to an
            // overlay. Never leave an otherwise playing item paused forever.
            scrollGestureTimeout = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPlaybackScroll() }
            }
        }
        return SPPlaybackGestureSettings.horizontalSeekEnabled ||
            SPPlaybackGestureSettings.verticalVolumeEnabled
    }

    private func endPlaybackScrollSeek() {
        guard scrollSeekTarget != nil else { return }
        gestureSeekTimer?.invalidate()
        gestureSeekTimer = nil
        if let delta = gestureSeek.finish() {
            issuePlaybackGestureSeek(delta)
        }
        gestureSeek.reset()
        scrollSeekTarget = nil
        isScrubbing = false
        let resume = scrollSeekWasPlaying
        scrollSeekWasPlaying = false
        if resume { core?.play() }
        if let core {
            transitionPresentation(.timelineChanged(
                position: core.position, duration: core.duration, rate: core.playbackRate))
        }
        showControlsTemporarily()
    }

    private func pumpPlaybackGestureSeek() {
        gestureSeekTimer?.invalidate()
        gestureSeekTimer = nil
        guard scrollSeekTarget != nil, let core else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let delta = gestureSeek.next(now: now, settled: core.seekSettled) {
            issuePlaybackGestureSeek(delta)
        }
        guard let delay = gestureSeek.retryDelay(now: now, settled: core.seekSettled) else { return }
        gestureSeekTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpPlaybackGestureSeek() }
        }
    }

    private func issuePlaybackGestureSeek(_ delta: Double) {
        guard scrollSeekTarget != nil, let core,
              core.position.isFinite, core.duration.isFinite else { return }
        // Apply the combined relative movement to the latest playback landing.
        // Directional keyframe selection keeps small forward movements from
        // repeatedly redisplaying the preceding keyframe. Release uses the
        // same quick seek policy, without an extra exact decode.
        let target = max(0, min(core.duration, core.position + delta))
        guard abs(target - core.position) >= 0.0005 else { return }
        scrollSeekTarget = target
        issueForegroundSeek(to: target, precise: false, forward: delta > 0)
    }

    private func cancelPlaybackScroll() {
        scrollGestureTimeout?.invalidate()
        scrollGestureTimeout = nil
        _ = scrollGesture.reset()
        endPlaybackScrollSeek()
    }

    private func handlePlaybackMagnify(_ event: NSEvent) -> Bool {
        let mode: SPPlaybackPinchGesture.Mode
        switch SPPlaybackGestureSettings.pinchAction {
        case .resizeWindow: mode = .resizeWindow
        case .fullscreen: mode = .fullscreen
        case .disabled: mode = .disabled
        }
        guard hasVideoSession, let window = view.window,
              core?.state == .playing || core?.state == .paused || core?.state == .ended,
              !turbo.blocksPlaybackControls, mode != .disabled else {
            pinchGesture.reset()
            return false
        }
        cancelPlaybackScroll()
        let phase = Self.playbackGesturePhase(event.phase)
        if gestureFullscreenTransition {
            if phase == .ended || phase == .cancelled { pinchGesture.reset() }
            return true
        }
        let frame = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let minimum = window.contentRect(forFrameRect: NSRect(origin: .zero, size: window.minSize)).size
        let effect = pinchGesture.update(
            magnification: Double(event.magnification), phase: phase, mode: mode,
            contentSize: window.contentRect(forFrameRect: frame).size,
            minimum: minimum, maximum: window.contentRect(forFrameRect: visible).size,
            isFullscreen: window.styleMask.contains(.fullScreen))
        switch effect {
        case .resize(let size):
            window.spSetContentSizeKeepingCenter(size)
        case .setFullscreen(let fullscreen):
            if window.styleMask.contains(.fullScreen) != fullscreen {
                perform(.toggleFullscreen)
            }
        case nil:
            break
        }
        return true
    }

    private func handleKey(_ event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {

            return
        }

        guard !event.isARepeat else { return }

        if let welcome, !welcome.isHidden, !hasMediaSession,
           event.keyCode == 36 || event.keyCode == 76 {
            welcome.playFirst()
            return
        }

        if turbo.blocksPlaybackControls, !Self.turboAllowedKey(event) { return }

        if SPFeatures.enhancements, event.keyCode == Self.compareKeyCode, let core,
           core.frameInterpolationMode == .doubleRate {
            setMotionCompare(true)
            return
        }

        switch event.keyCode {
        case 53: // PlayerView consumes key events, so handle fullscreen Escape here.
            if view.window?.styleMask.contains(.fullScreen) == true {
                toggleFullscreen()
            }
            return
        case 124: // →
            seekWithRepeat(+5, ownerKeyCode: event.keyCode)
            return
        case 123: // ←
            seekWithRepeat(-5, ownerKeyCode: event.keyCode)
            return
        case 126: // ↑
            volumeWithRepeat(+5, ownerKeyCode: event.keyCode)
            return
        case 125: // ↓
            volumeWithRepeat(-5, ownerKeyCode: event.keyCode)
            return
        default:
            break
        }
        switch event.charactersIgnoringModifiers {
        case " ":
            turboSpaceDown()
        case "f", "F":
            perform(.toggleFullscreen)
        case "[":
            perform(.setPlaybackRate((core?.playbackRate ?? 1.0) / 1.25))
        case "]":
            perform(.setPlaybackRate((core?.playbackRate ?? 1.0) * 1.25))
        case "m", "M":
            perform(.toggleMute)
        case "a", "A":
            perform(.setLoopPointA)
        case "b", "B":
            perform(.setLoopPointB)
        case "c", "C":
            perform(.clearLoop)
        case "\u{F729}":  // Home
            perform(.seekAbsolute(0))
        case "\u{F72B}":  // End
            perform(.seekAbsolute(core?.duration ?? 0))
        case ".":
            perform(.stepFrame(1))
        case ",":
            perform(.stepFrame(-1))
        case "s", "S":
            perform(.captureScreenshot)
        case "\u{F72C}":
            perform(.previousMedia)
        case "\u{F72D}":
            perform(.nextMedia)
        default:
            break
        }
    }
}

// NSSlider's mouseDown tracking loop remains inside super until mouse-up, so
// wrapping that call provides exact begin/end callbacks. The action-time event
// type is not a reliable way to distinguish the phases.
final class ScrubSlider: NSSlider {
    var onTrackBegan: (() -> Void)?
    var onTrackEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTrackBegan?()
        super.mouseDown(with: event)
        onTrackEnded?()
    }
}

extension PlayerViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier?.rawValue {
        case "sp.audioTracks":
            menu.removeAllItems()
            let tracks = core?.audioTrackList ?? []
            guard !tracks.isEmpty else {
                menu.addItem(NSMenuItem(title: L("track.noAudio"), action: nil, keyEquivalent: ""))
                return
            }
            let cur = core?.currentAudioTrackIndex ?? -1
            for t in tracks {
                guard let idx = t["index"] as? NSNumber, let title = t["title"] as? String else { continue }
                let item = NSMenuItem(title: title, action: #selector(audioTrackAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = idx.intValue
                item.state = idx.intValue == cur ? .on : .off
                menu.addItem(item)
            }
        case "sp.subtitleTracks":
            menu.removeAllItems()
            let tracks = core?.subtitleTrackList ?? []
            let cur = core?.currentSubtitleTrackIndex ?? -1
            let externalActive = activeExternalSubtitleURL
            let off = NSMenuItem(title: L("track.subtitleOff"), action: #selector(subtitleTrackAction(_:)),
                                 keyEquivalent: "")
            off.target = self
            off.tag = -1

            off.state = (cur == -1 && externalActive == nil && !captionsDisplayActive) ? .on : .off
            menu.addItem(off)
            if !tracks.isEmpty {
                menu.addItem(.separator())
                for t in tracks {
                    guard let idx = t["index"] as? NSNumber, let title = t["title"] as? String else { continue }
                    let item = NSMenuItem(title: title, action: #selector(subtitleTrackAction(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.tag = idx.intValue
                    item.state = (externalActive == nil && idx.intValue == cur) ? .on : .off
                    menu.addItem(item)
                }
            }

            if !externalSubtitleCandidates.isEmpty {
                menu.addItem(.separator())
                for url in externalSubtitleCandidates {
                    let item = NSMenuItem(title: url.lastPathComponent,
                                          action: #selector(externalSubtitleTrackAction(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    item.state = url == externalActive ? .on : .off
                    menu.addItem(item)
                }
            }
            if let item = captionsTrackMenuItem() {
                menu.addItem(.separator())
                menu.addItem(item)
            }
        case "sp.subtitleScale":
            let cur = core?.subtitleScale ?? 1.0
            for item in menu.items {
                item.state = abs(Double(item.tag) / 100.0 - cur) < 0.01 ? .on : .off
            }
        case "sp.recentPlays":

            menu.removeAllItems()
            let recents = RecentPlays.load()
            guard !recents.isEmpty else {
                menu.addItem(NSMenuItem(title: L("menu.recent.empty"), action: nil, keyEquivalent: ""))
                return
            }
            for entry in recents {
                let item = NSMenuItem(title: entry.title,
                                      action: #selector(recentPlayAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = entry.path
                item.toolTip = entry.path
                if #available(macOS 14.0, *) {
                    item.badge = NSMenuItemBadge(string: entry.isFinished
                        ? L("welcome.finished")
                        : String(format: L("welcome.remainFmt"), entry.remainingText))
                }
                menu.addItem(item)
            }
            // Clearing this list preserves resume positions. Full privacy cleanup
            // remains a separate, confirmed action in the app menu.
            menu.addItem(.separator())
            let clearItem = NSMenuItem(title: L("menu.recent.clear"),
                                       action: #selector(clearRecentPlaysAction(_:)),
                                       keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        case "sp.aspectMenu":
            for item in menu.items where !item.isSeparatorItem {
                item.state = item.tag == currentForcedAspectTag ? .on : .off
            }
        case "sp.cropMenu":
            for item in menu.items where !item.isSeparatorItem {
                item.state = item.tag == currentCropTag ? .on : .off
            }
        case "sp.frameInterpolation":
            let presentation = currentMotionPresentation()
            for item in menu.items {

                item.target = self
                item.state = item.tag == presentation.selectedModeTag ? .on : .off

                item.isEnabled = presentation.isMenuItemEnabled(tag: item.tag)
                item.toolTip = item.tag == 0 ? nil
                    : presentation.menuToolTip
            }
        default:
            break
        }
    }
}

extension PlayerViewController {
    @objc func generateCaptionsAction(_ sender: Any?) {
        guard #available(macOS 26.0, *) else { return }
        if let ctx = captionsMediaContext() {
            captionsController().menuAction(context: ctx)
        } else if let task = CaptionTaskCenter.shared.backgroundTask {
            if task.isFinished && !task.isRetryingSave { CaptionTaskCenter.shared.presentSaveRecovery(for: task, in: view.window) }
            else { CaptionTaskCenter.shared.presentStatusDialog(for: task, in: view.window) }
        }
    }

    var captionsMenuAvailable: Bool {
        if #available(macOS 26.0, *) { return SPPlayerCore.fullFeatureTier() && (hasMediaSession || CaptionTaskCenter.shared.backgroundTask != nil) }
        return false
    }

    private func captionsRefreshMenuTitle(_ item: NSMenuItem) {
        guard #available(macOS 26.0, *) else { return }
        let url = hasMediaSession && currentMediaIndex >= 0 && currentMediaIndex < mediaList.count ? mediaList[currentMediaIndex] : nil
        item.title = CaptionTaskCenter.shared.menuTitle(forMedia: url)
    }

    @available(macOS 26.0, *)
    private func captionsMediaContext() -> CaptionsController.MediaContext? {
        guard let core, hasMediaSession, let window = view.window,
              currentMediaIndex >= 0, currentMediaIndex < mediaList.count else { return nil }
        return CaptionsController.MediaContext(
            core: core, window: window, mediaURL: mediaList[currentMediaIndex],
            audioStreamIndex: core.currentAudioTrackIndex,
            durationSeconds: core.duration, timelineOriginUs: core.timelineOriginUs, playhead: core.position,
            externalSubtitleFiles: externalSubtitleCandidates,
            embeddedTextTracks: core.subtitleTrackList.compactMap { t in
                guard let idx = (t["index"] as? NSNumber)?.intValue, let title = t["title"] as? String else { return nil }
                return (index: idx, title: title)
            },
            displayedExternalSubtitle: activeExternalSubtitleURL,
            displayedEmbeddedSubtitle: activeExternalSubtitleURL == nil ? core.currentSubtitleTrackIndex : -1,
            uiLanguage: AppLanguage.current ?? Locale.preferredLanguages.first ?? "en")
    }

    private var captionsDisplayActive: Bool {
        if #available(macOS 26.0, *) { return captions?.displayActive ?? false }
        return false
    }

    private func captionsTrackMenuItem() -> NSMenuItem? {
        if #available(macOS 26.0, *) { return captions?.trackMenuItem() }
        return nil
    }

    private func captionsMediaWillClose(unregisterCore: Bool = true) {
        captionsAttachChecked = false
        if #available(macOS 26.0, *) {
            if unregisterCore, let core { CaptionProbeRegistry.unregister(core) }
            captions?.mediaWillClose()
        }
    }

    private func captionsRegisterCore(_ core: SPPlayerCore) {
        if #available(macOS 26.0, *) { CaptionProbeRegistry.register(core) }
    }

    private func captionsAttachIfNeeded() {
        guard #available(macOS 26.0, *), !captionsAttachChecked, hasMediaSession, view.window != nil else { return }
        captionsAttachChecked = true
        guard currentMediaIndex >= 0, currentMediaIndex < mediaList.count,
              (CaptionTaskCenter.shared.task(forMedia: mediaList[currentMediaIndex])
                ?? CaptionTaskCenter.shared.recoverableTask(forMedia: mediaList[currentMediaIndex])) != nil,
              let ctx = captionsMediaContext() else { return }
        captionsController().mediaDidOpen(context: ctx)
    }

    private func captionsUserSelectedOtherSubtitle() {
        core?.cancelPendingSubtitleLoad()
        if #available(macOS 26.0, *) { captions?.userSelectedOtherSubtitle() }
    }

    private func captionsAutomationHookIfNeeded() {
        guard #available(macOS 26.0, *), !captionsAutomationFired else { return }
        guard let spec = Self.captionsAutomationSpec else { captionsAutomationFired = true; return }
        guard let ctx = captionsMediaContext() else { return }
        captionsAutomationFired = true
        for part in spec.split(separator: ";").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            var item = part
            var delay = 0.0
            if item.hasPrefix("+"), let colon = item.firstIndex(of: ":"),
               let secs = Double(item[item.index(after: item.startIndex)..<colon]) {
                delay = secs
                item = String(item[item.index(after: colon)...])
            }
            if delay <= 0 {
                captionsController().startAutomation(context: ctx, spec: item)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let ctx = self.captionsMediaContext() else { return }
                    self.captionsController().startAutomation(context: ctx, spec: item)
                }
            }
        }
    }
}

extension PlayerViewController: SPTransientNoticePresenting {

    func showTransientNotice(_ text: String) {
        if let welcome, !welcome.isHidden {
            welcome.showTransientNotice(text)
        } else {
            playbackNoticeView().showTransient(text)
        }
    }
}
