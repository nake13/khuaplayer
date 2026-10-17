import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    // One window owns each media session. Closing a non-final window destroys
    // it; closing the final window keeps a hidden welcome window for Dock reopen.
    // After launch the registry therefore remains nonempty.
    private var windowControllers: [PlayerWindowController] = []

    private let menuRouter = MenuRouter()

    private var pendingOpenURLs: [URL] = []
    private var cliOpenIssued = false
    private var didFinishLaunchingCompleted = false
    private var launchOpensMedia = false
#if SP_INTERNAL_BUILD && !SP_APP_STORE
    private var reopenTestClickDelay: Double?
    private var reopenTestUseMouse = false
#endif

    @MainActor private func makeWindowController(deferCore: Bool = false,
                                                 mediaSize: Bool = false) -> PlayerWindowController {
        let wc = PlayerWindowController(deferCore: deferCore, mediaSize: mediaSize)
        wc.onWillClose = { [weak self] wc in self?.windowControllerWillClose(wc) }
        windowControllers.append(wc)
        return wc
    }

    @MainActor private func windowControllerWillClose(_ wc: PlayerWindowController) {
        let isLast = windowControllers.count <= 1
        wc.playerViewController.handleWindowClose(destroyingWindow: !isLast)
        if isLast, #available(macOS 26.0, *), let notice = CaptionTaskCenter.shared.backgroundNotice {

            wc.playerViewController.showWelcomeNotice(notice)
        }
        guard !isLast else { return }

        wc.window?.delegate = nil
        wc.window?.contentViewController = nil

        windowControllers.removeAll { $0 === wc }

        DispatchQueue.main.async { _ = wc }
    }

    @MainActor @objc func generateCaptionsAction(_ sender: Any?) {
        guard #available(macOS 26.0, *), let t = CaptionTaskCenter.shared.backgroundTask else { return }
        if t.isFinished && !t.isRetryingSave { CaptionTaskCenter.shared.presentSaveRecovery(for: t, in: nil) }
        else { CaptionTaskCenter.shared.presentStatusDialog(for: t, in: nil) }
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(generateCaptionsAction(_:)) {
            guard #available(macOS 26.0, *) else { return false }
            menuItem.title = CaptionTaskCenter.shared.menuTitle(forMedia: nil)
            return CaptionTaskCenter.shared.backgroundTask != nil
        }
        return true
    }

    @MainActor @objc func showAboutPanelAction(_ sender: Any?) {
        // The full product name can differ from the short Dock and Finder name.
        let productName = Bundle.main.object(forInfoDictionaryKey: "SPProductName") as? String
            ?? L("app.displayName")
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: productName])
    }

    @MainActor @objc func openDocumentAction(_ sender: Any?) {
        let wc = windowControllers.first { $0.window?.isKeyWindow ?? false }
            ?? windowControllers.first { $0.window?.isMainWindow ?? false }
            ?? windowControllers.first
        guard let wc else { return }

        if !(wc.window?.isVisible ?? false) {
            wc.showWindowForReopen()
        }
        wc.playerViewController.openDocumentAction(sender)
    }

    /// Duplicate-open lookup: standardized media path to its existing window.
    /// The small window registry is scanned directly, avoiding duplicate state.
    @MainActor func windowController(forOpenPath path: String) -> PlayerWindowController? {
        windowControllers.first { $0.playerViewController.openMediaPath == path }
    }

    @discardableResult
    @MainActor private func openInWindow(url: URL) -> PlayerWindowController {
        let std = url.standardizedFileURL.path
        if let existing = windowController(forOpenPath: std) {

            if existing.playerViewController.handleDuplicateMediaOpen(url: url) {
                return existing
            }
        }
        if let idle = windowControllers.first(where: { !$0.playerViewController.hasOpenMedia }) {
            idle.open(url: url)
            return idle
        }
        let wc = makeWindowController(mediaSize: true)
        if let ref = NSApp.mainWindow ?? windowControllers.first(where: { $0 !== wc })?.window,
           let win = wc.window {

            win.cascadeTopLeft(from: NSPoint(x: ref.frame.minX + 24, y: ref.frame.maxY - 24))
        }
        wc.open(url: url)
        return wc
    }

    // Finder opens from associations, Open With, or a Dock drop. A batch of N
    // media URLs creates or reuses N windows, with each grant owned by its window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }

        if !didFinishLaunchingCompleted {
            spLaunchMark("odoc 送达（文件路径此刻才可知）")
            recordLaunchKind(bare: false)

            if urls.contains(where: { !SPSubtitleAutoload.isSubtitleFile($0) }) { launchOpensMedia = true }
        }
        if windowControllers.isEmpty {
            guard didFinishLaunchingCompleted else {
                pendingOpenURLs.append(contentsOf: urls)
                return
            }

            _ = makeWindowController()
        }
        openURLBatch(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route a URL batch by type. Subtitle files augment an active media session
    /// instead of creating media windows. Prefer the last media window from the
    /// same batch, then the key/main/any media window; only a process with no
    /// media session falls back to the idle hub and its existing prompt.
    @MainActor private func openURLBatch(_ urls: [URL]) {
        let subs = urls.filter { SPSubtitleAutoload.isSubtitleFile($0) }
        let media = urls.filter { !SPSubtitleAutoload.isSubtitleFile($0) }
        var lastMediaWC: PlayerWindowController?
        for url in media { lastMediaWC = openInWindow(url: url) }
        guard !subs.isEmpty else { return }
        let target = lastMediaWC
            ?? windowControllers.first {
                ($0.window?.isKeyWindow ?? false) && $0.playerViewController.hasOpenMedia
            }
            ?? windowControllers.first {
                ($0.window?.isMainWindow ?? false) && $0.playerViewController.hasOpenMedia
            }
            ?? windowControllers.first { $0.playerViewController.hasOpenMedia }
        for url in subs {
            if let target {
                target.playerViewController.open(url: url)
            } else {
                openInWindow(url: url)
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        spLaunchMark("willFinishLaunching 入口")

        let speculativeBare = spCLIFilePath == nil &&
            (UserDefaults.standard.object(forKey: Self.bareLaunchHintKey) as? Bool ?? true)

        let wc = makeWindowController(deferCore: speculativeBare, mediaSize: !speculativeBare)
        spLaunchMark("窗口已创建（含 loadView/渲染器，未亮相）")

        if let path = spCLIFilePath {
            cliOpenIssued = true
            wc.open(url: URL(fileURLWithPath: path, isDirectory: false))
            spLaunchMark("窗口已 show（CLI 打开路径）")
        } else if speculativeBare {

            spLaunchMark("投机欢迎窗开始（上次为裸启动）")
            wc.playerViewController.showEmptyState()
            wc.showWindow(nil)
            spLaunchMark("欢迎窗已 show（投机提前）")

            DispatchQueue.main.async { [weak wc] in
                wc?.playerViewController.ensureCore()
            }
        } else {

            WelcomeView.prewarmTexture(scale: wc.window?.backingScaleFactor
                                       ?? NSScreen.main?.backingScaleFactor ?? 2.0,
                                       qos: .utility)
        }
    }

    private static let bareLaunchHintKey = WelcomeView.bareLaunchHintKey
    private func recordLaunchKind(bare: Bool) {
        UserDefaults.standard.set(bare, forKey: Self.bareLaunchHintKey)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        spLaunchMark("openUntitledFile 信号")
        guard let wc = windowControllers.first, !cliOpenIssued else { return true }

        guard !windowControllers.contains(where: { $0.window?.isVisible ?? false }) else { return true }
        recordLaunchKind(bare: true)
        wc.playerViewController.showEmptyState()
        wc.showWindow(nil)
        spLaunchMark("欢迎窗已 show（untitled 提前）")
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        spLaunchMark("didFinishLaunching 入口")
        guard let wc = windowControllers.first else { return }
        if cliOpenIssued { launchOpensMedia = true }

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            openURLBatch(urls)
        }

        if !windowControllers.contains(where: { $0.window?.isVisible ?? false }) {
            recordLaunchKind(bare: true)
            wc.playerViewController.showEmptyState()
            wc.showWindow(nil)
            spLaunchMark("欢迎窗已 show（一次成型）")
        }
        didFinishLaunchingCompleted = true

        NSApp.activate(ignoringOtherApps: true)

        // Direct-distribution updates only. An unconfigured build does not load
        // Sparkle or make a network request.
#if !SP_APP_STORE
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            SPSoftwareUpdater.startIfConfigured()
        }
#endif
#if SP_INTERNAL_BUILD && !SP_APP_STORE
        // Start internal responsiveness diagnostics after launch. The optional
        // self-test injects one delay three seconds later, measured in milliseconds.
        DispatchQueue.main.async {
            SPMainThreadSentinel.start(visibleWindowProvider: {
                PlayerViewController.anyPlayerWindowVisible
            })
            if let raw = ProcessInfo.processInfo.environment["SP_HANGTEST"],
               let ms = Int(raw), ms > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    SPMainThreadSentinel.phase("hangtest") {
                        Thread.sleep(forTimeInterval: Double(ms) / 1000)
                    }
                }
            }
        }
#endif
        installLaunchTestHooks()

        if launchOpensMedia {
            DispatchQueue.main.asyncAfter(deadline: .now() + PlayerViewController.chromeInstallFallback) { [weak self] in
                self?.ensureMainMenu()
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.ensureMainMenu() }
        }
        installMenuTestHooks()
    }

    private var mainMenuInstalled = false
    func ensureMainMenu() {
        guard !mainMenuInstalled else { return }
        mainMenuInstalled = true
        NSApp.mainMenu = MainMenuBuilder.build(trackMenuDelegate: menuRouter)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        RecentPlaysWarmer.noteAppTerminating()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {

        if #available(macOS 26.0, *), !CaptionTaskCenter.shared.confirmQuitIfNeeded() { return .terminateCancel }

        for wc in windowControllers {
            wc.playerViewController.flushResumePositionNow(forceDiskSync: true)
        }
        return .terminateNow
    }

    // A Dock reopen with no visible windows shows a clean empty window. Closing
    // a window ends that active session, while reopening the same file later can
    // still use its saved resume position.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {

        if !flag, let wc = windowControllers.first {
            wc.showWindowForReopen()
            fireReopenTestClickIfArmed(wc)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let recents = RecentPlays.load()
        guard !recents.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in recents {
            let item = NSMenuItem(title: entry.title,
                                  action: #selector(dockRecentPlayAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            item.toolTip = entry.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("menu.clearHistory"),
                               action: #selector(clearAllHistoryAction(_:)),
                               keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        return menu
    }

    @MainActor @objc private func dockRecentPlayAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }

        let wc = windowControllers.first { $0.window?.isKeyWindow ?? false }
            ?? windowControllers.first { $0.window?.isMainWindow ?? false }
            ?? windowControllers.first
        wc?.playerViewController.openRecentEntry(path: path)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var sheetHostWindow: NSWindow? {
        if let w = NSApp.keyWindow, w.isVisible { return w }
        if let w = NSApp.mainWindow, w.isVisible { return w }
        if let w = windowControllers.first(where: { $0.window?.isVisible ?? false })?.window { return w }
        return nil
    }

    @MainActor func discardAllReusableOpenPanels() {
        for wc in windowControllers {
            wc.playerViewController.discardReusableOpenPanel()
        }
    }

    @objc func clearAllHistoryAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("clearHistory.confirm.title")
        alert.informativeText = L("clearHistory.confirm.message")
        alert.addButton(withTitle: L("clearHistory.confirm.ok"))
        alert.addButton(withTitle: L("clearHistory.confirm.cancel"))

        if let window = sheetHostWindow {
            let vc = MenuRouter.activePlayerVC()
            Task { @MainActor in
                let response = await alert.beginSheetModal(for: window)
                guard response == .alertFirstButtonReturn else { return }
                vc?.clearAllHistory()
            }
        } else {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            MenuRouter.activePlayerVC()?.clearAllHistory()
        }
    }

    // Local, self-contained privacy summary. Deliberately has no external URL.
    @MainActor @objc func privacyPolicyAction(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("privacy.summary.title")
        alert.informativeText = L("privacy.summary.message")
#if !SP_APP_STORE
        if SPSoftwareUpdater.usageReportingConfigured {
            alert.informativeText = L("privacy.updateUsage.message")
        }
#endif
        alert.addButton(withTitle: L("privacy.summary.ok"))
        if let window = sheetHostWindow {
            alert.beginSheetModal(for: window)
        } else {
            _ = alert.runModal()
        }
    }

    // ── Software updates (configured non-App-Store builds only) ─────────
#if !SP_APP_STORE
    @objc func checkForUpdatesAction(_ sender: Any?) {
        // Menu actions run on the main thread; enter the actor explicitly.
        MainActor.assumeIsolated { SPSoftwareUpdater.checkForUpdates() }
    }

    // Automatic-update toggle; menuNeedsUpdate refreshes its checkmark.
    @objc func toggleAutoUpdateAction(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            SPSoftwareUpdater.setAutomaticChecks(
                !SPSoftwareUpdater.automaticChecksEnabled)
        }
    }
#endif

#if !SP_APP_STORE
    // ── Set as Default Player (direct distribution only) ─────────────────
    @objc func defaultPlayerAction(_ sender: NSMenuItem) {
        // Capture only the window before entering the isolated closure.
        let window = sheetHostWindow
        MainActor.assumeIsolated {
            SPDefaultPlayer.presentDialog(over: window)
        }
    }
#endif

    @objc func toggleTurboAction(_ sender: Any?) {
        let enabled = !SPTurboSettings.isEnabled
        SPTurboSettings.isEnabled = enabled
        guard !enabled else { return }

        let controllers = windowControllers
        MainActor.assumeIsolated {
            for wc in controllers { wc.playerViewController.endTurboForSettingsChange() }
        }
    }

    @objc func turboRateAction(_ sender: NSMenuItem) {
        SPTurboSettings.rate = Double(sender.tag) / 100.0
    }

    @objc func timelineStyleAction(_ sender: NSMenuItem) {
        let style: SPTimelineStyleSettings.Style
        switch sender.tag { case 1: style = .tide; case 2: style = .classic; default: style = .starTrail }
        guard style != SPTimelineStyleSettings.style else { return }
        SPTimelineStyleSettings.style = style
    }

    @objc func toggleHorizontalSeekGestureAction(_ sender: Any?) {
        SPPlaybackGestureSettings.horizontalSeekEnabled.toggle()
    }

    @objc func toggleVerticalVolumeGestureAction(_ sender: Any?) {
        SPPlaybackGestureSettings.verticalVolumeEnabled.toggle()
    }

    @objc func pinchGestureAction(_ sender: NSMenuItem) {
        guard let action = SPPlaybackGestureSettings.PinchAction(rawValue: sender.tag) else { return }
        SPPlaybackGestureSettings.pinchAction = action
    }

    @objc func gestureSensitivityAction(_ sender: NSMenuItem) {
        guard let sensitivity = SPPlaybackGestureSettings.Sensitivity(rawValue: sender.tag) else { return }
        SPPlaybackGestureSettings.sensitivity = sensitivity
    }

    @objc func languageAction(_ sender: NSMenuItem) {
        let target = sender.representedObject as? String
        guard target != AppLanguage.current else { return }
        AppLanguage.apply(target)

        let running = Bundle.main.preferredLocalizations.first
        guard AppLanguage.effectiveLanguage(for: target) != running else {
            return
        }
        let alert = NSAlert()
        alert.messageText = L("settings.language.restart.title")
        alert.informativeText = L("settings.language.restart.message")
        alert.addButton(withTitle: L("settings.language.restart.now"))
        alert.addButton(withTitle: L("settings.language.restart.later"))
        let respond: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .alertFirstButtonReturn else { return }

            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        if let window = sheetHostWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}

#if SP_INTERNAL_BUILD && !SP_APP_STORE
@MainActor private final class ReopenTestHeartbeat {
    private var last = CFAbsoluteTimeGetCurrent()
    private var ticks = 0
    private let clickAt: CFAbsoluteTime
    init(clickAt: CFAbsoluteTime) { self.clickAt = clickAt }
    func beat() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - last > 0.3 {
            NSLog("[ReopenTest] 主线程停顿 %.0fms（点击后 +%.0fms）",
                  (now - last) * 1000, (now - clickAt) * 1000)
        }
        last = now
        ticks += 1
        if ticks < 150 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in beat() }
        } else {
            NSLog("[ReopenTest] 心跳结束（15s）")
        }
    }
}
#endif

// Internal-build launch test hooks are isolated from production launch
// orchestration. Public and App Store builds compile both installers as empty.
@MainActor private extension AppDelegate {
    func installLaunchTestHooks() {
#if SP_INTERNAL_BUILD && !SP_APP_STORE
    // Headless file-association test hook: SP_SETDEFAULT_TEST=ext,...
    MainActor.assumeIsolated { SPDefaultPlayer.handleTestHook() }

    if let raw = ProcessInfo.processInfo.environment["SP_REOPENTEST"] {
        var closeSec = 8.0, clickSec = 1.0
        var panelDir: URL?
        var wantPanel = false
        var panelAtSec: Double?
        for part in raw.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "close": closeSec = Double(kv[1]) ?? closeSec
            case "click": clickSec = Double(kv[1]) ?? clickSec
            case "panelAt": panelAtSec = Double(kv[1])
            case "mouse": reopenTestUseMouse = kv[1] == "1"
            case "panel":
                wantPanel = true
                if kv[1] != "1" { panelDir = URL(fileURLWithPath: kv[1], isDirectory: true) }
            default: break
            }
        }
        reopenTestClickDelay = clickSec
        let preparePanel: () -> Void = { [weak self] in
            guard wantPanel, let wc = self?.windowControllers.first else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            wc.playerViewController.prepareOpenPanelForReopenTest(directory: panelDir)
            NSLog("[ReopenTest] 面板预建 %.0fms dir=%@",
                  (CFAbsoluteTimeGetCurrent() - t0) * 1000, panelDir?.path ?? "(默认)")
        }
        if let panelAtSec {
            DispatchQueue.main.asyncAfter(deadline: .now() + panelAtSec, execute: preparePanel)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + closeSec) { [weak self] in
            guard let wc = self?.windowControllers.first else { return }
            if panelAtSec == nil { preparePanel() }
            NSLog("[ReopenTest] performClose")
            wc.window?.performClose(nil)
            NSLog("[ReopenTest] 关窗完成，等待外部真实重开（open -a）")
        }
    }
    if ProcessInfo.processInfo.environment["SP_CLOSETEST"] != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            NSLog("[CloseTest] performClose")
            self?.windowControllers.first?.window?.performClose(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            NSLog("[CloseTest] 模拟 Dock 重开")
            _ = self?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            NSLog("[CloseTest] 重开返回（主线程存活）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            NSLog("[CloseTest] +3s 主线程心跳正常")
        }
    }
#endif
    }

    func fireReopenTestClickIfArmed(_ wc: PlayerWindowController) {
#if SP_INTERNAL_BUILD && !SP_APP_STORE
        guard let delay = reopenTestClickDelay else { return }
        reopenTestClickDelay = nil
        let reopenAt = CFAbsoluteTimeGetCurrent()
        NSLog("[ReopenTest] 真实重开回调，%.1fs 后点击最近条目", delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let path = RecentPlays.load().first?.path else {
                NSLog("[ReopenTest] 最近播放为空，无法点击")
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            NSLog("[ReopenTest] 点击最近条目 +%.0fms%@: %@",
                  (t0 - reopenAt) * 1000, self.reopenTestUseMouse ? "（真实鼠标事件）" : "",
                  (path as NSString).lastPathComponent)
            if self.reopenTestUseMouse {
                if !wc.playerViewController.reopenTestClickFirstRowWithEvents() {
                    NSLog("[ReopenTest] 找不到最近播放行，退回直接调用")
                    wc.playerViewController.openRecentEntry(path: path)
                }
            } else {
                wc.playerViewController.openRecentEntry(path: path)
            }
            NSLog("[ReopenTest] 点击派发同步返回 %.0fms",
                  (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            ReopenTestHeartbeat(clickAt: t0).beat()
        }
#endif
    }

    func installMenuTestHooks() {
#if SP_INTERNAL_BUILD && !SP_APP_STORE

    if ProcessInfo.processInfo.environment["SP_MWCLOSE"] != nil {

        weak var probedWC: PlayerWindowController?
        weak var probedWindow: NSWindow?
        weak var probedVC: PlayerViewController?
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            NSLog("[MWTest] 关首窗（关前窗口数=%d）", self?.windowControllers.count ?? -1)
            probedWC = self?.windowControllers.first
            probedWindow = probedWC?.window
            probedVC = probedWC?.playerViewController
            probedWC?.window?.performClose(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { [weak self] in
            let vis = self?.windowControllers.filter { $0.window?.isVisible ?? false }.count ?? -1
            NSLog("[MWTest] 关后窗口数=%d 可见=%d 存活{wc=%d win=%d vc=%d}",
                  self?.windowControllers.count ?? -1, vis,
                  probedWC != nil ? 1 : 0, probedWindow != nil ? 1 : 0,
                  probedVC != nil ? 1 : 0)
            if let w = probedWindow {
                let wPtr = String(format: "%p", UInt(bitPattern: ObjectIdentifier(w).hashValue))
                _ = wPtr
                NSLog("[MWTest] 幸存窗指针=%@ vc指针=%@",
                      String(describing: Unmanaged.passUnretained(w).toOpaque()),
                      probedVC != nil
                          ? String(describing: Unmanaged.passUnretained(probedVC!).toOpaque())
                          : "nil")
                NSLog("[MWTest] 幸存窗诊断: inNSAppWindows=%d visible=%d hasContentVC=%d parent=%d sheets=%lu childWins=%lu",
                      NSApp.windows.contains(where: { $0 === w }) ? 1 : 0,
                      w.isVisible ? 1 : 0,
                      w.contentViewController != nil ? 1 : 0,
                      w.parent != nil ? 1 : 0,
                      UInt(w.sheets.count),
                      UInt(w.childWindows?.count ?? 0))
            }
        }
    }

    if let raw = ProcessInfo.processInfo.environment["SP_TURBOTEST"] {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        if parts.count == 2, parts[0] > 0, parts[1] > parts[0] {
            for (i, at) in parts.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self,
                          let wc = (NSApp.keyWindow?.windowController as? PlayerWindowController)
                              ?? self.windowControllers.first else { return }
                    wc.playerViewController.simulateTurboSpaceForTest(down: i == 0)
                }
            }
        }
    }

    if let raw = ProcessInfo.processInfo.environment["SP_BACKSTEPTEST"] {
        let parts = raw.split(separator: ",").map(String.init)
        let nums = parts.compactMap { Double($0) }
        if nums.count >= 3, nums[0] > 0, nums[1] >= 1, nums[2] > 0 {
            let left = parts.last != "R"
            for i in 0..<Int(nums[1]) {
                let at = nums[0] + Double(i) * nums[2]
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self,
                          let wc = (NSApp.keyWindow?.windowController as? PlayerWindowController)
                              ?? self.windowControllers.first else { return }
                    NSLog("[BackstepTest] press %d pos=%.3f", i + 1,
                          wc.playerViewController.corePositionForTest)
                    wc.playerViewController.simulateArrowKeyForTest(left: left, down: true)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak wc] in
                        guard let wc else { return }
                        NSLog("[BackstepTest] release %d", i + 1)
                        wc.playerViewController.simulateArrowKeyForTest(left: left, down: false)
                    }
                }
            }
        }
    }

    if let raw = ProcessInfo.processInfo.environment["SP_OPENPANELTEST"] {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        if let openSec = parts.first, openSec > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + openSec) { [weak self] in
                self?.openDocumentAction(nil)
            }
            if parts.count > 1, parts[1] > openSec {
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { [weak self] in
                    guard let self,
                          let wc = (NSApp.keyWindow?.windowController as? PlayerWindowController)
                              ?? self.windowControllers.first else { return }
                    wc.playerViewController.cancelOpenDocumentPanelForTest()
                }
            }
        }
    }

    if ProcessInfo.processInfo.environment["SP_MENUTEST"] != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [menuRouter] in
            for id in ["sp.audioTracks", "sp.subtitleTracks", "sp.subtitleScale",
                       "sp.recentPlays", "sp.language", "sp.appMenu",
                       "sp.frameInterpolation", "sp.aspectMenu", "sp.cropMenu",
                       "sp.turbo", "sp.timelineStyle"] {
                guard let menu = MenuRouter.findMenu(identifier: id,
                                                     in: NSApp.mainMenu) else {
                    NSLog("[MenuTest] %@ 未找到", id)
                    continue
                }
                menuRouter.menuNeedsUpdate(menu)
                let desc = menu.items.map { item -> String in
                    if item.isSeparatorItem { return "|" }
                    return item.title + (item.state == .on ? "✓" : "")
                        + (item.isEnabled ? "" : "(灰)")
                }.joined(separator: ", ")
                NSLog("[MenuTest] %@ → %@", id, desc)
            }

            if let dock = (NSApp.delegate as? AppDelegate)?
                .applicationDockMenu(NSApp) {
                let desc = dock.items.map {
                    $0.isSeparatorItem ? "|" : $0.title
                }.joined(separator: ", ")
                NSLog("[MenuTest] dockMenu → %@", desc)
            } else {
                NSLog("[MenuTest] dockMenu → (空账本，nil)")
            }
        }
    }
#endif
    }
}
