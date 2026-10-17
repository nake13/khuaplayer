import AppKit

enum MainMenuBuilder {

    static func build(trackMenuDelegate: NSMenuDelegate? = nil) -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("menu.about"),
                        action: #selector(AppDelegate.showAboutPanelAction(_:)),
                        keyEquivalent: "")
        // Show Check for Updates only in configured direct-distribution builds.
#if !SP_APP_STORE
        if SPSoftwareUpdater.isConfigured {
            appMenu.addItem(withTitle: L("menu.checkForUpdates"),
                            action: #selector(AppDelegate.checkForUpdatesAction(_:)),
                            keyEquivalent: "")
            // Refresh the automatic-update checkmark when the menu opens.
            let autoItem = NSMenuItem(title: L("menu.autoUpdate"),
                                      action: #selector(AppDelegate.toggleAutoUpdateAction(_:)),
                                      keyEquivalent: "")
            autoItem.identifier = NSUserInterfaceItemIdentifier("sp.autoUpdate")
            appMenu.addItem(autoItem)
            appMenu.identifier = NSUserInterfaceItemIdentifier("sp.appMenu")
            appMenu.delegate = trackMenuDelegate
        }
#endif
        appMenu.addItem(.separator())

        let langItem = NSMenuItem(title: L("settings.language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu(title: L("settings.language"))
        langMenu.identifier = NSUserInterfaceItemIdentifier("sp.language")
        langMenu.delegate = trackMenuDelegate
        langMenu.autoenablesItems = false
        let systemLangItem = NSMenuItem(title: L("settings.language.system"),
                                        action: #selector(AppDelegate.languageAction(_:)),
                                        keyEquivalent: "")
        langMenu.addItem(systemLangItem)
        langMenu.addItem(.separator())
        for code in AppLanguage.supported {
            let item = NSMenuItem(title: AppLanguage.displayName(for: code),
                                  action: #selector(AppDelegate.languageAction(_:)),
                                  keyEquivalent: "")
            item.representedObject = code
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        appMenu.addItem(langItem)
#if !SP_APP_STORE
        // Format-selection panel for direct distribution.
        appMenu.addItem(withTitle: L("menu.defaultPlayer"),
                        action: #selector(AppDelegate.defaultPlayerAction(_:)),
                        keyEquivalent: "")
#endif
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: L("menu.clearHistory"),
                        action: #selector(AppDelegate.clearAllHistoryAction(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: L("menu.privacyPolicy"),
                        action: #selector(AppDelegate.privacyPolicyAction(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L("menu.file"))

        fileMenu.identifier = NSUserInterfaceItemIdentifier("sp.fileMenu")
        fileMenu.delegate = trackMenuDelegate
        fileItem.submenu = fileMenu
        let openItem = NSMenuItem(title: L("menu.open"), action: #selector(PlayerViewController.openDocumentAction(_:)), keyEquivalent: "o")
        fileMenu.addItem(openItem)

        let recentItem = NSMenuItem(title: L("menu.recentPlays"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: L("menu.recentPlays"))
        recentMenu.identifier = NSUserInterfaceItemIdentifier("sp.recentPlays")
        recentMenu.delegate = trackMenuDelegate
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let playItem = NSMenuItem()
        mainMenu.addItem(playItem)
        let playMenu = NSMenu(title: L("menu.play"))
        playItem.submenu = playMenu

        playMenu.addItem(withTitle: L("menu.play.pause"), action: #selector(PlayerViewController.togglePlayPauseAction(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("menu.play.forward5"), action: #selector(PlayerViewController.seekForwardAction(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("menu.play.backward5"), action: #selector(PlayerViewController.seekBackwardAction(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("menu.play.forward30"), action: #selector(PlayerViewController.seekForwardBigAction(_:)), keyEquivalent: "")
        playMenu.addItem(withTitle: L("menu.play.backward30"), action: #selector(PlayerViewController.seekBackwardBigAction(_:)), keyEquivalent: "")
        playMenu.addItem(.separator())

        let turboItem = NSMenuItem(title: L("menu.turbo"), action: nil, keyEquivalent: "")
        let turboMenu = NSMenu(title: L("menu.turbo"))
        turboMenu.identifier = NSUserInterfaceItemIdentifier("sp.turbo")
        turboMenu.delegate = trackMenuDelegate
        turboMenu.autoenablesItems = false
        let turboEnable = NSMenuItem(title: L("menu.turbo.enable"),
                                     action: #selector(AppDelegate.toggleTurboAction(_:)),
                                     keyEquivalent: "")
        turboEnable.identifier = NSUserInterfaceItemIdentifier("sp.turbo.enable")
        turboMenu.addItem(turboEnable)
        turboMenu.addItem(.separator())
        for rate in SPTurboSpeed.rateOptions {
            let item = NSMenuItem(title: SPChromeView.fmtRate(rate),
                                  action: #selector(AppDelegate.turboRateAction(_:)),
                                  keyEquivalent: "")
            item.tag = Int((rate * 100).rounded())
            turboMenu.addItem(item)
        }
        turboItem.submenu = turboMenu
        playMenu.addItem(turboItem)

        let styleItem = NSMenuItem(title: L("menu.timelineStyle"), action: nil, keyEquivalent: "")
        let styleMenu = NSMenu(title: L("menu.timelineStyle"))
        styleMenu.identifier = NSUserInterfaceItemIdentifier("sp.timelineStyle")
        styleMenu.delegate = trackMenuDelegate
        styleMenu.autoenablesItems = false
        for (title, tag) in [(L("menu.timelineStyle.starTrail"), 0),
                             (L("menu.timelineStyle.tide"), 1),
                             (L("menu.timelineStyle.classic"), 2)] {
            let item = NSMenuItem(title: title,
                                  action: #selector(AppDelegate.timelineStyleAction(_:)),
                                  keyEquivalent: "")
            item.tag = tag
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        playMenu.addItem(styleItem)

        let gesturesItem = NSMenuItem(title: L("menu.gestures"), action: nil, keyEquivalent: "")
        let gesturesMenu = NSMenu(title: L("menu.gestures"))
        gesturesMenu.identifier = NSUserInterfaceItemIdentifier("sp.playbackGestures")
        gesturesMenu.delegate = trackMenuDelegate
        gesturesMenu.autoenablesItems = false
        let horizontalSeekItem = NSMenuItem(title: L("menu.gestures.horizontalSeek"),
                                            action: #selector(AppDelegate.toggleHorizontalSeekGestureAction(_:)),
                                            keyEquivalent: "")
        horizontalSeekItem.identifier = NSUserInterfaceItemIdentifier("sp.playbackGestures.horizontalSeek")
        gesturesMenu.addItem(horizontalSeekItem)
        let verticalVolumeItem = NSMenuItem(title: L("menu.gestures.verticalVolume"),
                                            action: #selector(AppDelegate.toggleVerticalVolumeGestureAction(_:)),
                                            keyEquivalent: "")
        verticalVolumeItem.identifier = NSUserInterfaceItemIdentifier("sp.playbackGestures.verticalVolume")
        gesturesMenu.addItem(verticalVolumeItem)
        gesturesMenu.addItem(.separator())

        let pinchItem = NSMenuItem(title: L("menu.gestures.pinch"), action: nil, keyEquivalent: "")
        let pinchMenu = NSMenu(title: L("menu.gestures.pinch"))
        pinchMenu.identifier = NSUserInterfaceItemIdentifier("sp.playbackGestures.pinch")
        pinchMenu.delegate = trackMenuDelegate
        pinchMenu.autoenablesItems = false
        for (title, action) in [(L("menu.gestures.pinch.resizeWindow"), SPPlaybackGestureSettings.PinchAction.resizeWindow),
                                (L("menu.gestures.pinch.fullscreen"), .fullscreen),
                                (L("menu.gestures.pinch.disabled"), .disabled)] {
            let item = NSMenuItem(title: title,
                                  action: #selector(AppDelegate.pinchGestureAction(_:)),
                                  keyEquivalent: "")
            item.tag = action.rawValue
            pinchMenu.addItem(item)
        }
        pinchItem.submenu = pinchMenu
        gesturesMenu.addItem(pinchItem)

        let sensitivityItem = NSMenuItem(title: L("menu.gestures.sensitivity"), action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu(title: L("menu.gestures.sensitivity"))
        sensitivityMenu.identifier = NSUserInterfaceItemIdentifier("sp.playbackGestures.sensitivity")
        sensitivityMenu.delegate = trackMenuDelegate
        sensitivityMenu.autoenablesItems = false
        for (title, sensitivity) in [(L("menu.gestures.sensitivity.low"), SPPlaybackGestureSettings.Sensitivity.low),
                                     (L("menu.gestures.sensitivity.normal"), .normal),
                                     (L("menu.gestures.sensitivity.high"), .high)] {
            let item = NSMenuItem(title: title,
                                  action: #selector(AppDelegate.gestureSensitivityAction(_:)),
                                  keyEquivalent: "")
            item.tag = sensitivity.rawValue
            sensitivityMenu.addItem(item)
        }
        sensitivityItem.submenu = sensitivityMenu
        gesturesMenu.addItem(sensitivityItem)
        gesturesItem.submenu = gesturesMenu
        playMenu.addItem(gesturesItem)
        playMenu.addItem(.separator())
        // Enhanced playback controls exist only in builds that enable them.
        if SPFeatures.enhancements {
            // Motion processing initializes on demand; publishing the menu
            // does not load video or graphics resources during startup.
            let motionItem = NSMenuItem(title: L("menu.motion"), action: nil, keyEquivalent: "")
            let motionMenu = NSMenu(title: L("menu.motion"))
            motionMenu.identifier = NSUserInterfaceItemIdentifier("sp.frameInterpolation")
            motionMenu.delegate = trackMenuDelegate
            // The menu delegate controls availability from media and API state.
            // Disable automatic validation so an empty window stays disabled.
            motionMenu.autoenablesItems = false
            for (title, tag) in [(L("menu.motion.off"), 0), (L("menu.motion.double"), 1)] {
                let item = NSMenuItem(title: title,
                                      action: #selector(PlayerViewController.frameInterpolationAction(_:)),
                                      keyEquivalent: "")
                item.tag = tag
                motionMenu.addItem(item)
            }
            motionItem.submenu = motionMenu
            playMenu.addItem(motionItem)
            playMenu.addItem(.separator())
        }

        let audioTrackItem = NSMenuItem(title: L("menu.audioTracks"), action: nil, keyEquivalent: "")
        let audioTrackMenu = NSMenu(title: L("menu.audioTracks"))
        audioTrackMenu.identifier = NSUserInterfaceItemIdentifier("sp.audioTracks")
        audioTrackMenu.delegate = trackMenuDelegate
        audioTrackItem.submenu = audioTrackMenu
        playMenu.addItem(audioTrackItem)
        playMenu.addItem(.separator())
        playMenu.addItem(withTitle: L("menu.mediaInfo"), action: #selector(PlayerViewController.mediaInfoAction(_:)), keyEquivalent: "i")

        let subItem = NSMenuItem()
        mainMenu.addItem(subItem)
        let subMenu = NSMenu(title: L("menu.subtitles"))
        subItem.submenu = subMenu
        subMenu.addItem(withTitle: L("menu.loadSubtitle"),
                        action: #selector(PlayerViewController.loadSubtitleAction(_:)),
                        keyEquivalent: "l")
        subMenu.addItem(.separator())
        let subTrackItem = NSMenuItem(title: L("menu.subtitleTracks"), action: nil, keyEquivalent: "")
        let subTrackMenu = NSMenu(title: L("menu.subtitleTracks"))
        subTrackMenu.identifier = NSUserInterfaceItemIdentifier("sp.subtitleTracks")
        subTrackMenu.delegate = trackMenuDelegate
        subTrackItem.submenu = subTrackMenu
        subMenu.addItem(subTrackItem)
        let sizeItem = NSMenuItem(title: L("menu.subtitleScale"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: L("menu.subtitleScale"))
        sizeMenu.identifier = NSUserInterfaceItemIdentifier("sp.subtitleScale")
        sizeMenu.delegate = trackMenuDelegate
        for (name, pct) in [("25%", 25), ("50%", 50), ("75%", 75), (L("menu.subtitleScale.default"), 100),
                            ("125%", 125), ("150%", 150), ("200%", 200)] {
            let item = NSMenuItem(title: name,
                                  action: #selector(PlayerViewController.subtitleScaleAction(_:)),
                                  keyEquivalent: "")
            item.tag = pct
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        subMenu.addItem(sizeItem)

        if #available(macOS 26.0, *), SPPlayerCore.fullFeatureTier() {
            subMenu.addItem(.separator())
            subMenu.addItem(withTitle: L("menu.captions.generateOrTranslate"),
                            action: #selector(PlayerViewController.generateCaptionsAction(_:)),
                            keyEquivalent: "")
        }

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L("menu.view"))
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: L("menu.toggleFullscreen"), action: #selector(PlayerViewController.toggleFullscreenAction(_:)), keyEquivalent: "f")

        let aspectItem = NSMenuItem(title: L("menu.aspect"), action: nil, keyEquivalent: "")
        let aspectMenu = NSMenu(title: L("menu.aspect"))
        // Aspect correction and cropping are independent operations: the
        // former preserves the full frame with letterboxing, while the latter
        // fills the target ratio by removing centered overflow. Stretching is
        // intentionally omitted because it distorts the image.
        let ratioList: [(String, Int)] = [
            ("1:1", 1000), ("5:4", 1250), ("4:3", 1333), ("3:2", 1500),
            ("16:10", 1600), ("16:9", 1778), ("1.85:1", 1850), ("2.21:1", 2210),
            ("2.35:1", 2350), ("2.39:1", 2390), ("2.76:1", 2760),
        ]
        let forcedRatios = [(L("menu.aspect.default"), 0)] + ratioList
        for (name, tag) in forcedRatios {
            let item = NSMenuItem(title: name, action: #selector(PlayerViewController.forcedAspectAction(_:)), keyEquivalent: "")
            item.tag = tag
            aspectMenu.addItem(item)
        }
        aspectItem.submenu = aspectMenu
        aspectMenu.identifier = NSUserInterfaceItemIdentifier("sp.aspectMenu")
        aspectMenu.delegate = trackMenuDelegate
        viewMenu.addItem(aspectItem)

        let cropItem = NSMenuItem(title: L("menu.crop"), action: nil, keyEquivalent: "")
        let cropMenu = NSMenu(title: L("menu.crop"))
        for (name, tag) in [(L("menu.crop.none"), 0)] + ratioList {
            let item = NSMenuItem(title: name, action: #selector(PlayerViewController.cropAspectAction(_:)), keyEquivalent: "")
            item.tag = tag
            cropMenu.addItem(item)
        }
        cropItem.submenu = cropMenu
        cropMenu.identifier = NSUserInterfaceItemIdentifier("sp.cropMenu")
        cropMenu.delegate = trackMenuDelegate
        viewMenu.addItem(cropItem)

        let rotItem = NSMenuItem(title: L("menu.rotation"), action: nil, keyEquivalent: "")
        let rotMenu = NSMenu(title: L("menu.rotation"))
        for (i, name) in ["0°", "90°", "180°", "270°"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(PlayerViewController.rotationAction(_:)), keyEquivalent: "")
            item.tag = i * 90
            rotMenu.addItem(item)
        }
        rotItem.submenu = rotMenu
        viewMenu.addItem(rotItem)

        let mirrorItem = NSMenuItem(title: L("menu.mirror"), action: nil, keyEquivalent: "")
        let mirrorMenu = NSMenu(title: L("menu.mirror"))
        for (i, name) in [L("menu.mirror.none"), L("menu.mirror.horizontal"), L("menu.mirror.vertical")].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(PlayerViewController.mirrorAction(_:)), keyEquivalent: "")
            item.tag = i
            mirrorMenu.addItem(item)
        }
        mirrorItem.submenu = mirrorMenu
        viewMenu.addItem(mirrorItem)

        return mainMenu
    }
}
