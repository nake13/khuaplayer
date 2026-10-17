import AppKit

// Process-wide router for dynamic menus.
//
// The main menu is process-global, while track, subtitle, interpolation, and
// display submenus describe one playback session. Their contents and actions
// must therefore follow the key window. AppDelegate retains this router because
// NSMenu.delegate is weak; process-level menus are handled here and session-level
// menus are forwarded to the active PlayerViewController, which also becomes the
// target for the generated items.
final class MenuRouter: NSObject, NSMenuDelegate {

    static func activePlayerVC() -> PlayerViewController? {
        if let vc = NSApp.keyWindow?.contentViewController as? PlayerViewController {
            return vc
        }
        if let vc = NSApp.mainWindow?.contentViewController as? PlayerViewController {
            return vc
        }
        return NSApp.windows.lazy
            .compactMap { $0.contentViewController as? PlayerViewController }
            .first
    }

    static func findMenu(identifier: String, in menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        if menu.identifier?.rawValue == identifier { return menu }
        for item in menu.items {
            if let found = findMenu(identifier: identifier, in: item.submenu) {
                return found
            }
        }
        return nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier?.rawValue {
        case "sp.fileMenu":

            OpenPanelWarmer.warm(trigger: .menuIntent)
        case "sp.turbo":
            let enabled = SPTurboSettings.isEnabled
            let rate = SPTurboSettings.rate
            for item in menu.items where !item.isSeparatorItem {
                if item.identifier?.rawValue == "sp.turbo.enable" {
                    item.state = enabled ? .on : .off
                } else {
                    item.state = abs(Double(item.tag) / 100.0 - rate) < 0.001 ? .on : .off
                }
            }
        case "sp.timelineStyle":
            let cur: Int
            switch SPTimelineStyleSettings.style { case .starTrail: cur = 0; case .tide: cur = 1; case .classic: cur = 2 }
            for item in menu.items where !item.isSeparatorItem {
                item.state = item.tag == cur ? .on : .off
            }
        case "sp.playbackGestures":
            for item in menu.items {
                switch item.identifier?.rawValue {
                case "sp.playbackGestures.horizontalSeek":
                    item.state = SPPlaybackGestureSettings.horizontalSeekEnabled ? .on : .off
                case "sp.playbackGestures.verticalVolume":
                    item.state = SPPlaybackGestureSettings.verticalVolumeEnabled ? .on : .off
                default:
                    break
                }
            }
        case "sp.playbackGestures.pinch":
            for item in menu.items where !item.isSeparatorItem {
                item.state = item.tag == SPPlaybackGestureSettings.pinchAction.rawValue ? .on : .off
            }
        case "sp.playbackGestures.sensitivity":
            for item in menu.items where !item.isSeparatorItem {
                item.state = item.tag == SPPlaybackGestureSettings.sensitivity.rawValue ? .on : .off
            }
        case "sp.language":
            let current = AppLanguage.current
            for item in menu.items where !item.isSeparatorItem {
                item.state =
                    (item.representedObject as? String) == current ? .on : .off
            }
#if !SP_APP_STORE
        case "sp.appMenu":
            // Sparkle's user default is the source of truth for this checkmark.
            for item in menu.items
            where item.identifier?.rawValue == "sp.autoUpdate" {
                item.state =
                    SPSoftwareUpdater.automaticChecksEnabled ? .on : .off
            }
#endif
        default:

            Self.activePlayerVC()?.menuNeedsUpdate(menu)
        }
    }
}
