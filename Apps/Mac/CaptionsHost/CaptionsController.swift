import AppKit
import NaturalLanguage

/// Bound a system-framework metadata query that is allowed to never answer.
///
/// `SpeechTranscriber.supportedLocales` and `LanguageAvailability`'s
/// `supportedLanguages` are async properties backed by system services. When
/// that service is unavailable the await can suspend indefinitely, which would
/// otherwise leave the options notice on screen with no way forward. The query
/// is abandoned once the deadline passes and its late result is discarded.
private enum CaptionOptionQuery {
    /// Long enough to absorb a cold system service, short enough that a wedged
    /// one degrades to a partial options sheet instead of a stuck notice.
    static let timeout: TimeInterval = 5

    static func bounded<Value: Sendable>(
        _ seconds: TimeInterval,
        _ query: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard !_Concurrency.Task.isCancelled else { return nil }
        let slot = OptionQuerySlot<Value>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            // Arm before starting either racer so the slot owns the continuation
            // before anything can settle it.
            slot.arm(continuation)
            // Deliberately unstructured: a service that never answers must not
            // keep the caller suspended, and it cannot be cancelled from here.
            _Concurrency.Task {
                let value = await query()
                slot.settle(value)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                slot.settle(nil)
            }
        }
    }
}

/// Single-use handoff for `CaptionOptionQuery.bounded`. Whichever of the query
/// or its deadline arrives first wins; later arrivals are dropped.
private final class OptionQuerySlot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Value?, Never>?
    private var settled = false

    func arm(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        waiting = continuation
        lock.unlock()
    }

    func settle(_ value: Value?) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

// Window-level integration for menus, task submission and generated subtitle
// display. Construct lazily outside the first-frame path. The app task center
// owns execution; this controller attaches one window to its media's task.
@available(macOS 26.0, *)
@MainActor
final class CaptionsController: NSObject {
    /// Capture session context at the action boundary without retaining the view controller.
    struct MediaContext {
        var core: SPPlayerCore
        var window: NSWindow
        var mediaURL: URL
        var audioStreamIndex: Int
        var durationSeconds: Double
        /// Playback timeline origin in microseconds.
        var timelineOriginUs: Int64
        /// Current playback position; caption generation and detection start from the beginning.
        var playhead: Double
        var externalSubtitleFiles: [URL]
        /// Embedded text subtitle tracks, identified by container stream index and title.
        var embeddedTextTracks: [(index: Int, title: String)]
        /// Current external file or embedded track, used to preselect the options sheet.
        var displayedExternalSubtitle: URL?
        var displayedEmbeddedSubtitle: Int
        var uiLanguage: String
    }

    enum SubtitleSource: Equatable, Sendable {
        case file(URL)
        case embedded(index: Int, title: String)
    }

    private(set) var displayActive = false
    private var statusView: CaptionStatusView?
    private var core: SPPlayerCore?
    private var hideTimer: Timer?
    /// The active, queued or recently completed task attached to this window.
    private(set) var task: CaptionTaskCenter.Task?
    /// An existing subtitle file displayed directly without creating a task.
    private var displayedExistingName: String?
    private var displayedEvents: [CaptionRenderEvent] = []
    /// Notify the view controller after display attachment so it can clear obsolete
    /// external-subtitle UI state after the core has switched tracks.
    var onDisplayAttached: (() -> Void)?
    /// Selecting a generated/existing result supersedes a pending external load
    /// even when the current render track does not need replacing.
    var onDisplaySelection: (() -> Void)?
    /// Increment on media replacement or window close; verify across suspension points.
    private var sessionGeneration = 0
    private var interfaceTask: _Concurrency.Task<Void, Never>?
    private var interfaceRequestID: UUID?
    private var interfaceSelection: Int?
    private var displayGeneration = 0
    /// A requested external file has not replaced the current render track yet.
    /// Its completion may change display intent only while this token is current.
    private var externalSelection: Int?
    private var wantsTaskDisplay = true
    private var taskDisplayActive = false

    private var center: CaptionTaskCenter { .shared }

    // MARK: - Window lifecycle

    /// Reattach subtitle display and status when reopening media with an existing task.
    func mediaDidOpen(context: MediaContext) {
        guard let t = center.task(forMedia: context.mediaURL) ?? center.recoverableTask(forMedia: context.mediaURL) else { return }
        attach(to: t, context: context)
    }

    /// Detach display and subscriptions on close or replacement; app-owned work continues.
    func mediaWillClose() {
        sessionGeneration &+= 1
        displayGeneration &+= 1
        externalSelection = nil
        interfaceTask?.cancel()
        interfaceTask = nil
        interfaceRequestID = nil
        interfaceSelection = nil
        if let t = task { center.removeListener(owner: self, from: t) }
        task = nil
        taskDisplayActive = false
        wantsTaskDisplay = true
        displayActive = false
        displayedExistingName = nil
        displayedEvents = []
        fedEvents.removeAll()
        core = nil
        hideStatus()
    }

    /// Explicit track selection detaches only the display; caption generation continues.
    func userSelectedOtherSubtitle() {
        cancelInterfaceWork()
        displayGeneration &+= 1
        externalSelection = nil
        interfaceTask?.cancel()
        interfaceTask = nil
        wantsTaskDisplay = false
        displayActive = false
    }

    /// Keep the current subtitles until the core validates and installs the file.
    /// A new generated track must not invalidate that explicit pending request.
    func beginExternalSubtitleSelection() -> Int {
        cancelInterfaceWork()
        displayGeneration &+= 1
        externalSelection = displayGeneration
        return displayGeneration
    }

    func completeExternalSubtitleSelection(_ token: Int, succeeded: Bool) {
        guard externalSelection == token, displayGeneration == token else { return }
        externalSelection = nil
        if succeeded {
            userSelectedOtherSubtitle()
        } else {
            // The core reports its read error after this completion returns.
            // Attaching a first generated batch inline would advance the core's
            // load generation and accidentally suppress that error notification.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == token, self.externalSelection == nil,
                      let task = self.task else { return }
                self.updateTaskDisplay(task)
            }
        }
    }

    // MARK: - Menus

    /// Show task status for existing work, otherwise present generation options.
    func menuAction(context: MediaContext) {
        if let t = center.task(forMedia: context.mediaURL) {
            if task == nil { attach(to: t, context: context) }
            center.presentStatusDialog(for: t, in: context.window)
            return
        }
        if let task = center.recoverableTask(forMedia: context.mediaURL) {
            attach(to: task, context: context)
            let generation = sessionGeneration
            center.presentSaveRecovery(for: task, in: context.window) { [weak self, weak task] in
                guard let self, let task, self.sessionGeneration == generation,
                      self.center.recoverableTask(forMedia: context.mediaURL) === task else { return }
                self.presentSheet(context: context)
            }
            return
        }
        presentSheet(context: context)
    }

    func menuTitle(forMedia url: URL?) -> String { center.menuTitle(forMedia: url) }

    /// A virtual generated-subtitle entry in the track menu.
    func trackMenuItem() -> NSMenuItem? {
        var title: String
        if let t = task, !t.committedEvents.isEmpty {
            title = t.targetTag == nil ? L("captions.track.generated", t.languageLabel)
                                       : L("captions.track.generatedBilingual", t.languageLabel)
            if !t.progressText.isEmpty { title += " · " + t.progressText }
        } else if let name = displayedExistingName {
            title = name
        } else {
            return nil
        }
        let item = NSMenuItem(title: title, action: #selector(reattachAction(_:)), keyEquivalent: "")
        item.target = self
        item.state = displayActive && (task?.committedEvents.isEmpty != false || taskDisplayActive) ? .on : .off
        return item
    }

    @objc private func reattachAction(_ sender: Any?) {
        guard let core else { return }
        let supersedesExternalSelection = externalSelection != nil
        externalSelection = nil
        cancelInterfaceWork()
        onDisplaySelection?()
        // Reselecting the current track is a new display intent; a late file read must not override it.
        displayGeneration &+= 1
        interfaceTask?.cancel()
        interfaceTask = nil
        if let task, !task.committedEvents.isEmpty {
            wantsTaskDisplay = true
            if displayActive, taskDisplayActive {
                if supersedesExternalSelection { updateTaskDisplay(task) }
                return
            }
            taskDisplayActive = true
            attachDisplay(core: core, events: task.committedEvents)
        } else if !displayedEvents.isEmpty, !displayActive {
            attachDisplay(core: core, events: displayedEvents)
        }
    }

    // MARK: - Options and submission

    private func presentSheet(context: MediaContext) {
        guard interfaceTask == nil, context.window.attachedSheet == nil else { return }
        let gen = sessionGeneration
        let requestID = UUID()
        interfaceRequestID = requestID
        // Acknowledge the click before waiting for model lists or playback-safe
        // directory I/O. This nonmodal notice leaves playback/Seek available.
        showStatus(L("captions.status.loadingOptions"), in: context, onCancel: { [weak self] in
            guard self?.interfaceRequestID == requestID else { return }
            self?.cancelInterfaceWork()
        })
        interfaceTask = _Concurrency.Task { @MainActor [weak self] in
            // Both queries are bounded and start together, so a wedged system
            // service costs one deadline instead of one per query.
            async let transcriberLocales = CaptionOptionQuery.bounded(CaptionOptionQuery.timeout) {
                await CaptionTranscriber.supportedLocales()
            }
            async let translatorTargets = CaptionOptionQuery.bounded(CaptionOptionQuery.timeout) {
                await CaptionTranslator.supportedLanguages()
            }
            let loadedLocales: [Locale]? = await transcriberLocales
            let loadedTargets: [Locale.Language]? = await translatorTargets
            let locales = loadedLocales ?? []
            let targets = loadedTargets ?? []
            let sidecars = await CaptionSubtitleFiles.sidecars(for: context.mediaURL, shouldPause: { !CaptionProbeRegistry.idle() })
            guard let self, gen == self.sessionGeneration, self.interfaceRequestID == requestID,
                  !_Concurrency.Task.isCancelled else { return }
            self.interfaceTask = nil
            self.interfaceRequestID = nil
            self.hideStatus()
            var sources: [SubtitleSource] = context.embeddedTextTracks.map { .embedded(index: $0.index, title: $0.title) }
            sources += context.externalSubtitleFiles.map { .file($0) }
            sources += sidecars.filter { !context.externalSubtitleFiles.contains($0) }.map { .file($0) }
            // Speech needs a language list and subtitle translation needs a target
            // list, so require one mode that can actually run. Otherwise a partial
            // answer after a timeout would open a sheet whose Generate cannot finish.
            guard !locales.isEmpty || (!sources.isEmpty && !targets.isEmpty) else {
                self.presentError(L("captions.error.unavailable"), in: context.window)
                return
            }
            let sheet = CaptionSheet(context: context, transcriberLocales: locales, targetLanguages: targets,
                                     subtitleSources: sources, existingSidecars: sidecars)
            sheet.present { [weak self] choice in
                guard let self, gen == self.sessionGeneration, let choice else { return }
                if let existing = choice.useExisting {
                    self.showExisting(existing, bilingual: CaptionSubtitleFiles.isBilingualOutput(url: existing, mediaURL: context.mediaURL), context: context)
                    return
                }
                switch choice.mode {
                case .subtitle(let src):
                    guard let target = choice.target else { return }
                    self.startSubtitle(source: src, target: target, context: context)
                case .speech(let locale):
                    self.startSpeech(locale: locale, target: choice.target, context: context)
                }
            }
        }
    }

    private func cancelInterfaceWork() {
        guard interfaceRequestID != nil else { return }
        interfaceRequestID = nil
        interfaceTask?.cancel()
        interfaceTask = nil
        hideStatus()
        if let selection = interfaceSelection {
            interfaceSelection = nil
            completeExternalSubtitleSelection(selection, succeeded: false)
        }
    }

    /// Automation-only submission without the options sheet. Accept speech, embedded
    /// subtitle and external-file sources; retain the trailing marker for compatibility.
    func startAutomation(context: MediaContext, spec: String) {
        var spec = spec
        if spec.hasSuffix("!") { spec.removeLast() }
        let parts = spec.split(separator: ">", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return }
        let target = parts.count > 1 ? Locale.Language(identifier: parts[1]) : nil
        if parts[0].hasPrefix("file:"), let target {
            startSubtitle(source: .file(URL(fileURLWithPath: String(parts[0].dropFirst(5)))), target: target, context: context)
        } else if parts[0].hasPrefix("sub:"), let idx = Int(parts[0].dropFirst(4)), let target {
            let title = context.embeddedTextTracks.first { $0.index == idx }?.title ?? "#\(idx)"
            startSubtitle(source: .embedded(index: idx, title: title), target: target, context: context)
        } else {
            startSpeech(locale: parts[0] == "auto" ? nil : Locale(identifier: parts[0]), target: target, context: context)
        }
    }

    private struct PreparationError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Capture values on enqueue; reading, detection and installation all use the sole execution slot.
    private func startSubtitle(source: SubtitleSource, target: Locale.Language, context: MediaContext) {
        let initial = Self.configuration(for: context, sourceLocale: Locale(identifier: "und"), target: target)
        let request = CaptionTaskCenter.Task(mediaURL: context.mediaURL, languageLabel: Self.languageName(target)) { task in
            CaptionTaskCenter.shared.preparationChanged(task, message: L("captions.status.preparing"))
            var config = initial
            let sample: String?
            switch source {
            case .file(let url):
                guard let parsed = await CaptionSubtitleFiles.cues(from: url, shouldPause: { !CaptionProbeRegistry.idle() }) else {
                    throw PreparationError(message: L("captions.error.readFailed", url.lastPathComponent))
                }
                config.existingCues = parsed
                config.sourceFileURL = url
                sample = parsed.prefix(200).map(\.text).joined(separator: " ")
            case .embedded(let index, _):
                config.embeddedSubtitleStream = index
                sample = try await Self.embeddedSample(mediaURL: initial.mediaURL, stream: index,
                                                       timelineOriginUs: initial.timelineOriginUs)
            }
            try _Concurrency.Task.checkCancellation()
            let lang = await _Concurrency.Task.detached(priority: .utility) {
                sample.flatMap { CaptionTextLanguage.dominantLanguage(of: $0) }
            }.value
            try _Concurrency.Task.checkCancellation()
            guard let lang else { throw PreparationError(message: L("captions.error.noSubtitleText")) }
            let srcLocale = Locale(identifier: lang)
            let sourceTag = CaptionLanguageTags.fileTag(forTranscriberLocale: srcLocale)
            if sourceTag == CaptionLanguageTags.fileTag(forTargetLanguage: target.minimalIdentifier) {
                return .notNeeded(L("captions.status.subtitleSameLanguage", Self.languageName(target)))
            }
            config.sourceLocale = srcLocale
            try await Self.ensureTranslationInstalled(source: Locale.Language(identifier: sourceTag), target: target,
                                                       window: task.presentationWindow)
            return .ready(config)
        }
        submit(request, context: context)
    }

    private func startSpeech(locale: Locale?, target: Locale.Language?, context: MediaContext) {
        let initial = Self.configuration(for: context, sourceLocale: locale ?? Locale(identifier: "und"), target: target)
        let label = locale.map { Self.languageLabel(sourceLocale: $0, target: target) } ?? L("captions.language.auto")
        let request = CaptionTaskCenter.Task(mediaURL: context.mediaURL, languageLabel: label) { task in
            var config = initial
            var source = locale
            if source == nil {
                CaptionTaskCenter.shared.preparationChanged(task, message: L("captions.status.detecting"))
                let candidates = await CaptionTranscriber.installedLocales()
                try _Concurrency.Task.checkCancellation()
                if !candidates.isEmpty {
                    source = try await CaptionEngine.detectLanguage(mediaURL: initial.mediaURL,
                        audioStreamIndex: initial.audioStreamIndex, timelineOriginUs: initial.timelineOriginUs,
                        at: 0, candidates: candidates, progress: { [weak task] value in
                            let percent = value.isFinite ? Int((min(1, max(0, value)) * 100).rounded()) : 0
                            _Concurrency.Task { @MainActor in
                                guard let task else { return }
                                CaptionTaskCenter.shared.preparationChanged(task,
                                    message: L("captions.status.detectingSample", percent))
                            }
                        })
                }
                try _Concurrency.Task.checkCancellation()
                guard source != nil else { throw PreparationError(message: L("captions.error.detectFailed")) }
            }
            guard let source else { throw PreparationError(message: L("captions.error.detectFailed")) }
            config.sourceLocale = source
            let sourceTag = CaptionLanguageTags.fileTag(forTranscriberLocale: source)
            var note: String?
            if let target, sourceTag == CaptionLanguageTags.fileTag(forTargetLanguage: target.minimalIdentifier) {
                config.targetLanguage = nil
                note = L("captions.status.speechSameLanguage", Self.languageName(target))
            }
            if let target = config.targetLanguage {
                CaptionTaskCenter.shared.preparationChanged(task, message: L("captions.status.preparing"))
                try await Self.ensureTranslationInstalled(source: Locale.Language(identifier: sourceTag), target: target,
                                                           window: task.presentationWindow)
            }
            return .ready(config, note: note)
        }
        submit(request, context: context)
    }

    private static func configuration(for context: MediaContext, sourceLocale: Locale,
                                      target: Locale.Language?) -> CaptionEngine.Configuration {
        var c = CaptionEngine.Configuration(mediaURL: context.mediaURL, audioStreamIndex: context.audioStreamIndex,
                                            sourceLocale: sourceLocale, targetLanguage: target,
                                            durationSeconds: context.durationSeconds)
        c.timelineOriginUs = context.timelineOriginUs
        return c
    }

    private func submit(_ request: CaptionTaskCenter.Task, context: MediaContext) {
        let submitted = center.submit(request)
        attach(to: submitted, context: context)
        if submitted !== request { center.presentStatusDialog(for: submitted, in: context.window) }
    }

    // MARK: - Task attachment

    private func attach(to t: CaptionTaskCenter.Task, context: MediaContext) {
        if task !== t {
            if let old = task {
                if taskDisplayActive {
                    displayedEvents = old.committedEvents
                    displayedExistingName = old.sidecarURL?.lastPathComponent ?? old.languageLabel
                }
                center.removeListener(owner: self, from: old)
            }
            taskDisplayActive = false
            wantsTaskDisplay = true
        }
        task = t
        core = context.core
        t.presentationWindow = context.window
        let listener = CaptionTaskCenter.Listener(
            owner: self,
            onEvents: { [weak self, weak t] events in
                guard let self, let t else { return }
                self.updateTaskDisplay(t, fresh: events)
            },
            onProgress: { [weak self] t in self?.handleProgress(t, context: context) },
            onFinished: { [weak self] t, error in self?.handleFinished(t, error: error, context: context) })
        center.addListener(listener, to: t, owner: self)
        if t.isFinished {
            handleFinished(t, error: t.error, context: context)
        } else {
            updateTaskDisplay(t)
            handleProgress(t, context: context)
        }
    }

    /// Switch tracks only when displayable cues exist. Queuing, preparation and
    /// empty results must preserve the user's current subtitles.
    private func updateTaskDisplay(_ t: CaptionTaskCenter.Task, fresh: [CaptionRenderEvent]? = nil) {
        guard task === t, wantsTaskDisplay, let core, !t.committedEvents.isEmpty else { return }
        if !taskDisplayActive {
            // A new track invalidates a pending external load; appending to the
            // already displayed generated track does not, so keep it flowing.
            guard externalSelection == nil else { return }
            taskDisplayActive = true
            attachDisplay(core: core, events: t.committedEvents)
        } else if displayActive {
            feed(fresh ?? t.committedEvents, to: core)
        }
    }

    private func handleProgress(_ t: CaptionTaskCenter.Task, context: MediaContext) {
        if t.isSaving {
            showStatus(L("captions.status.saving"), in: context)
            return
        }
        if t.isStopping {
            showStatus(L("captions.status.stopping"), in: context)
            return
        }
        if t.isWaitingForPlayback {
            showStatus(L("captions.status.waitingForPlayback"), in: context)
            return
        }
        guard !t.isRunning else {
            let pct = Int((t.progress * 100).rounded())
            switch t.phase {
            case .preparing: showStatus(t.preparationMessage ?? t.note ?? L("captions.status.preparing"), in: context)
            case .downloadingModel: showStatus(L("captions.status.downloading", pct), in: context)
            case .transcribing(let doneSeconds, let eta):
                if let eta, eta >= 60 {
                    showStatus(L("captions.status.transcribingETA", pct, SPTimeText.clock(doneSeconds),
                                 CaptionTaskCenter.formatETA(eta)), in: context)
                } else {
                    showStatus(L("captions.status.transcribingAt", pct, SPTimeText.clock(doneSeconds)), in: context)
                }
            case .translating: showStatus(L("captions.status.translating", pct), in: context)
            case .saving: showStatus(L("captions.status.saving"), in: context)
            case .finished, .failed: break
            }
            return
        }
        if !t.isFinished { showStatus(L("captions.status.queued", center.running?.mediaName ?? ""), in: context) }
    }

    private func handleFinished(_ t: CaptionTaskCenter.Task, error: Error?, context: MediaContext) {
        guard task === t else { return }
        if error is CancellationError {
            hideStatus()
            if taskDisplayActive {
                if displayActive, let core { core.endGeneratedSubtitleTrack() }
                displayActive = false
                displayedEvents = []
                displayedExistingName = nil
            }
            taskDisplayActive = false
            task = nil
        } else if let save = error as? CaptionSaveError {
            updateTaskDisplay(t)
            let recoverable = center.recoverableTask(forMedia: t.mediaURL) === t
            showStatus(CaptionTaskCenter.saveFailureMessage(save), in: context, autoHide: recoverable ? nil : 8,
                       actionTitle: recoverable ? L("captions.button.retrySave") : nil,
                       onCancel: recoverable ? { [weak self, weak t] in
                guard let self, let t else { return }
                self.attach(to: t, context: context)
                self.center.presentSaveRecovery(for: t, in: context.window)
            } : nil)
        } else if let error {
            showStatus(L("captions.status.failed", error.localizedDescription), in: context, autoHide: 6)
        } else if let message = t.completionMessage {
            task = nil
            showStatus(message, in: context, autoHide: 5)
        } else {
            updateTaskDisplay(t)
            if let url = t.sidecarURL {
                showStatus(L("captions.status.done", url.lastPathComponent), in: context, autoHide: 4)
            }
        }
    }

    /// Read and parse existing subtitles off the main thread, then validate both
    /// media-session and track-selection generations after suspension.
    private func showExisting(_ url: URL, bilingual: Bool, context: MediaContext) {
        let selection = beginExternalSubtitleSelection()
        onDisplaySelection?()
        let gen = sessionGeneration
        let requestID = UUID()
        interfaceRequestID = requestID
        interfaceSelection = selection
        showStatus(L("captions.status.loadingExisting", url.lastPathComponent), in: context, onCancel: { [weak self] in
            guard self?.interfaceRequestID == requestID else { return }
            self?.cancelInterfaceWork()
        })
        interfaceTask = _Concurrency.Task { @MainActor [weak self] in
            let events = await CaptionSubtitleFiles.generatedEvents(from: url, bilingual: bilingual, shouldPause: { !CaptionProbeRegistry.idle() })
            guard let self, gen == self.sessionGeneration, self.interfaceRequestID == requestID,
                  !_Concurrency.Task.isCancelled else { return }
            self.interfaceTask = nil
            self.interfaceRequestID = nil
            self.interfaceSelection = nil
            self.hideStatus()
            guard selection == self.displayGeneration else { return }
            guard let events, !events.isEmpty else {
                self.completeExternalSubtitleSelection(selection, succeeded: false)
                self.presentError(L("captions.error.readFailed", url.lastPathComponent), in: context.window)
                return
            }
            self.completeExternalSubtitleSelection(selection, succeeded: true)
            if let t = self.task { self.center.removeListener(owner: self, from: t); self.task = nil }
            self.core = context.core
            self.taskDisplayActive = false
            self.displayedExistingName = url.lastPathComponent
            self.displayedEvents = events
            self.attachDisplay(core: context.core, events: events)
        }
    }

    private func attachDisplay(core: SPPlayerCore, events: [CaptionRenderEvent]) {
        core.beginGeneratedSubtitleTrack(withHeader: CaptionASS.header)
        displayActive = true
        onDisplayAttached?()
        readOrder = 0
        fedEvents.removeAll(keepingCapacity: true)
        if !events.isEmpty { feed(events, to: core) }
    }

    private var readOrder = 0
    // Overlapping cues may arrive with earlier start times. Deduplicate by identity, not snapshot index.
    private var fedEvents: Set<CaptionRenderEvent> = []
    private func feed(_ events: [CaptionRenderEvent], to core: SPPlayerCore) {
        for e in events {
            guard let timing = CaptionSRT.timing(e), fedEvents.insert(e).inserted else { continue }
            let line = CaptionASS.event(readOrder: readOrder, e)
            readOrder += 1
            core.appendGeneratedSubtitleEvent(line, startUs: timing.start,
                                              durationUs: timing.duration)
        }
    }

    // MARK: - Translation assets

    private static func ensureTranslationInstalled(source: Locale.Language, target: Locale.Language,
                                                    window: NSWindow?) async throws {
        let status = await CaptionTranslator.status(source: source, target: target)
        try _Concurrency.Task.checkCancellation()
        switch status {
        case .installed: return
        case .supported:
            try await CaptionDownloadHostLoader.download(source: source, target: target, window: window)
            try _Concurrency.Task.checkCancellation()
            // Dismissing the system dialog can succeed without downloading; recheck asset availability.
            guard await CaptionTranslator.status(source: source, target: target) == .installed else {
                throw CancellationError()
            }
            try _Concurrency.Task.checkCancellation()
        default:
            throw PreparationError(message: L("captions.error.translationUnsupported", source.minimalIdentifier, target.minimalIdentifier))
        }
    }

    // MARK: - Task status capsule

    private func showStatus(_ text: String, in context: MediaContext, autoHide: TimeInterval? = nil,
                            actionTitle: String? = nil,
                            onCancel: (() -> Void)? = nil) {
        guard let content = context.window.contentView else { return }
        let view: CaptionStatusView
        if let v = statusView, v.superview != nil {
            view = v
        } else {
            view = CaptionStatusView(frame: .zero)
            content.addSubview(view)
            statusView = view
        }
        if spDebugEnabled, view.currentText != text { NSLog("[Captions] 状态：%@", text) }
        view.setText(text)
        view.setCancellation(onCancel, title: actionTitle)
        view.place(in: content.bounds)
        view.isHidden = false
        hideTimer?.invalidate()
        if let autoHide {
            hideTimer = Timer.scheduledTimer(withTimeInterval: autoHide, repeats: false) { [weak self] _ in
                _Concurrency.Task { @MainActor in self?.hideStatus() }
            }
        }
    }

    private func hideStatus() {
        hideTimer?.invalidate()
        hideTimer = nil
        statusView?.setCancellation(nil)
        statusView?.removeFromSuperview()
    }

    private func presentError(_ message: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = L("captions.sheet.title")
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Utilities

    /// Sample embedded text from the beginning in two-minute windows until 300
    /// characters or 20 minutes. Run on the reader queue with playback admission.
    private static func embeddedSample(mediaURL: URL, stream: Int, timelineOriginUs: Int64) async throws -> String? {
        nonisolated(unsafe) let r = SPCaptionSubtitleReader(path: mediaURL.path, subtitleStreamIndex: Int32(stream))
        r.timelineOriginUs = timelineOriginUs
        let q = DispatchQueue(label: "dev.khuaplayer.captions.sample", qos: .utility)
        let text: String? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                q.async {
                    var out = ""
                    var start = 0.0
                    while start < 1200, out.count < 300 {
                        guard let cues = r.readCues(fromSeconds: start, durationSeconds: 120,
                                                    shouldPause: { !CaptionProbeRegistry.idle() }) else {
                            cont.resume(throwing: r.lastError ?? CancellationError())
                            return
                        }
                        for c in cues {
                            let t = CaptionSRT.cleanSubtitleText(c.text)
                            if !t.isEmpty { out += t + " " }
                        }
                        start += 120
                    }
                    cont.resume(returning: out.isEmpty ? nil : out)
                }
            }
        } onCancel: {
            r.abort()
        }
        try _Concurrency.Task.checkCancellation()
        return text
    }

    static func languageName(_ l: Locale.Language) -> String {
        CaptionLanguageNames.target(l)
    }

    static func languageLabel(sourceLocale: Locale, target: Locale.Language?) -> String {
        let src = CaptionLanguageNames.speech(sourceLocale)
        guard let target else { return src }
        return "\(src) → \(languageName(target))"
    }
}

// MARK: - Content-based subtitle language detection
enum CaptionTextLanguage {
    /// Return a BCP 47 language identifier, or nil when text is insufficient.
    static func dominantLanguage(of text: String) -> String? {
        guard text.count >= 20 else { return nil }
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        return rec.dominantLanguage?.rawValue
    }
}

// MARK: - AppKit task status capsule
final class CaptionStatusView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 10
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)
        cancelButton.title = L("captions.button.cancel")
        cancelButton.bezelStyle = .inline
        cancelButton.contentTintColor = .white
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        cancelButton.isHidden = true
        addSubview(cancelButton)
        autoresizingMask = [.minXMargin, .minYMargin]
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return onCancel != nil && (hit === cancelButton || hit?.isDescendant(of: cancelButton) == true) ? hit : nil
    }

    @objc private func cancelAction(_ sender: Any?) { onCancel?() }

    func setCancellation(_ action: (() -> Void)?, title: String? = nil) {
        onCancel = action
        cancelButton.title = title ?? L("captions.button.cancel")
        cancelButton.isHidden = action == nil
        setText(currentText)
    }

    var currentText: String { label.stringValue }

    func setText(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        cancelButton.sizeToFit()
        let cancelWidth = onCancel == nil ? 0 : cancelButton.frame.width + 12
        let w = min(label.frame.width + 24 + cancelWidth, 460)
        let h = max(label.frame.height, onCancel == nil ? 0 : cancelButton.frame.height) + 10
        var f = frame
        f.size = NSSize(width: w, height: h)
        frame = f
        label.frame = NSRect(x: 12, y: (h - label.frame.height) / 2, width: w - 24 - cancelWidth, height: label.frame.height)
        cancelButton.setFrameOrigin(NSPoint(x: w - 12 - cancelButton.frame.width,
                                            y: (h - cancelButton.frame.height) / 2))
    }

    func place(in bounds: CGRect) {
        var f = frame
        f.origin = CGPoint(x: bounds.maxX - f.width - 16, y: bounds.maxY - f.height - 16)
        frame = f
    }
}

// MARK: - Source and target options sheet
@available(macOS 26.0, *)
@MainActor
final class CaptionSheet: NSObject {
    enum Mode {
        case subtitle(CaptionsController.SubtitleSource)
        case speech(Locale?)               // Nil selects automatic language detection.
    }

    struct Choice {
        var mode: Mode
        var target: Locale.Language?       // Nil selects transcription without translation.
        /// Non-nil selects an existing subtitle file.
        var useExisting: URL?
    }

    private let context: CaptionsController.MediaContext
    private let locales: [Locale]
    private let targets: [Locale.Language]
    private let sources: [CaptionsController.SubtitleSource]
    private let existingSidecars: [URL]
    private let subtitleRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let speechRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let subtitlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtitleTargetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speechTargetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetSupportHint = NSTextField(wrappingLabelWithString: "")
    private let existingHint = NSTextField(wrappingLabelWithString: "")
    private let regenerateCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var confirmButton: NSButton?
    private weak var currentAlert: NSAlert?
    private var targetSupportRow: NSGridRow?
    private var existingURL: URL?
    private var targetSupportTask: _Concurrency.Task<Void, Never>?
    private var targetSupportGeneration = 0
    private var supportedTargetsBySource: [String: Set<String>] = [:]
    private var checkingTargetSupport = false
    private var targetWasReset = false

    init(context: CaptionsController.MediaContext, transcriberLocales: [Locale],
         targetLanguages: [Locale.Language], subtitleSources: [CaptionsController.SubtitleSource],
         existingSidecars: [URL]) {
        self.context = context
        self.locales = transcriberLocales.sorted { $0.identifier < $1.identifier }
        self.targets = targetLanguages.sorted { $0.minimalIdentifier < $1.minimalIdentifier }
        self.sources = subtitleSources
        self.existingSidecars = existingSidecars
    }

    private var subtitleMode: Bool { subtitleRadio.state == .on }

    func present(completion: @escaping (Choice?) -> Void) {
        let alert = makeAlert()
        alert.beginSheetModal(for: context.window) { [self] resp in
            cancelTargetSupportCheck()
            guard resp == .alertFirstButtonReturn, !checkingTargetSupport else { completion(nil); return }
            let regen = !regenerateCheck.isHidden && regenerateCheck.state == .on
            if subtitleMode {
                let tag = subtitlePopup.selectedItem?.tag ?? 0
                guard sources.indices.contains(tag) else { completion(nil); return }
                let target = (subtitleTargetPopup.selectedItem?.representedObject as? String).map { Locale.Language(identifier: $0) }
                completion(Choice(mode: .subtitle(sources[tag]), target: target, useExisting: regen ? nil : existingURL))
            } else {
                let localeID = languagePopup.selectedItem?.representedObject as? String
                let target = (speechTargetPopup.selectedItem?.representedObject as? String).map { Locale.Language(identifier: $0) }
                completion(Choice(mode: .speech(localeID.map { Locale(identifier: $0) }), target: target,
                                  useExisting: regen ? nil : existingURL))
            }
        }
    }

    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        currentAlert = alert
        alert.messageText = L("captions.sheet.title")
        alert.informativeText = L("captions.sheet.message")
        confirmButton = alert.addButton(withTitle: L("captions.button.generate"))
        alert.addButton(withTitle: L("captions.button.cancel"))

        subtitleRadio.title = L("captions.mode.subtitle")
        speechRadio.title = L("captions.mode.speech")
        for r in [subtitleRadio, speechRadio] { r.target = self; r.action = #selector(modeChanged(_:)) }

        // Preselect the displayed embedded track, otherwise the first text track.
        subtitlePopup.removeAllItems()
        var preselect = 0
        for (i, s) in sources.enumerated() {
            switch s {
            case .file(let url):
                subtitlePopup.addItem(withTitle: url.lastPathComponent)
                if url == context.displayedExternalSubtitle { preselect = i }
            case .embedded(let idx, let title):
                subtitlePopup.addItem(withTitle: title)
                if idx == context.displayedEmbeddedSubtitle { preselect = i }
            }
            subtitlePopup.lastItem?.tag = i
        }
        if !sources.isEmpty { subtitlePopup.selectItem(at: preselect) }
        // Offer and preselect automatic speech-language detection.
        languagePopup.removeAllItems()
        languagePopup.addItem(withTitle: L("captions.language.auto"))
        languagePopup.lastItem?.representedObject = nil
        for l in locales {
            languagePopup.addItem(withTitle: CaptionLanguageNames.speech(l))
            languagePopup.lastItem?.representedObject = l.identifier
        }
        languagePopup.selectItem(at: 0)
        // Default to the interface language; speech also offers transcription without translation.
        let uiTag = CaptionLanguageTags.fileTag(forTargetLanguage: context.uiLanguage)
        let uiIdentifier = Locale.Language(identifier: context.uiLanguage).minimalIdentifier
        let preferredTarget = targets.firstIndex { $0.minimalIdentifier == uiIdentifier }
            ?? targets.firstIndex { CaptionLanguageTags.fileTag(forTargetLanguage: $0.minimalIdentifier) == uiTag }
        for (popup, allowNone) in [(subtitleTargetPopup, false), (speechTargetPopup, true)] {
            popup.autoenablesItems = false
            popup.removeAllItems()
            if allowNone {
                popup.addItem(withTitle: L("captions.target.none"))
                popup.lastItem?.representedObject = nil
            }
            for t in targets {
                popup.addItem(withTitle: CaptionsController.languageName(t))
                popup.lastItem?.representedObject = t.minimalIdentifier
            }
            popup.selectItem(at: preferredTarget.map { $0 + (allowNone ? 1 : 0) } ?? 0)
        }
        for p in [subtitlePopup, subtitleTargetPopup, languagePopup, speechTargetPopup] {
            p.target = self
            p.action = #selector(selectionChanged(_:))
        }
        let grid = NSGridView(numberOfColumns: 5, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.addRow(with: [subtitleRadio, NSTextField(labelWithString: L("captions.field.subtitle")), subtitlePopup,
                           NSTextField(labelWithString: L("captions.field.target")), subtitleTargetPopup])
        grid.addRow(with: [speechRadio, NSTextField(labelWithString: L("captions.field.audioLanguage")), languagePopup,
                           NSTextField(labelWithString: L("captions.field.target")), speechTargetPopup])
        targetSupportHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        targetSupportHint.textColor = .secondaryLabelColor
        targetSupportHint.preferredMaxLayoutWidth = 520
        let supportRow = grid.addRow(with: [NSGridCell.emptyContentView, targetSupportHint])
        supportRow.mergeCells(in: NSRange(location: 1, length: 4))
        targetSupportRow = supportRow
        existingHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        existingHint.textColor = .secondaryLabelColor
        existingHint.preferredMaxLayoutWidth = 520
        regenerateCheck.title = L("captions.regenerate")
        regenerateCheck.target = self
        regenerateCheck.action = #selector(selectionChanged(_:))
        let hintRow = grid.addRow(with: [NSGridCell.emptyContentView, existingHint])
        hintRow.mergeCells(in: NSRange(location: 1, length: 4))
        let checkRow = grid.addRow(with: [NSGridCell.emptyContentView, regenerateCheck])
        checkRow.mergeCells(in: NSRange(location: 1, length: 4))
        subtitlePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        languagePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        subtitleTargetPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        speechTargetPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 640, height: grid.fittingSize.height)
        alert.accessoryView = grid
        // Prefer translating existing text when available, otherwise use speech.
        // Generating from a track always needs a translation target, so an empty
        // target list disables that mode rather than letting Generate do nothing.
        let hasSubtitles = !sources.isEmpty && !targets.isEmpty
        subtitleRadio.isEnabled = hasSubtitles
        subtitleRadio.state = hasSubtitles ? .on : .off
        speechRadio.state = hasSubtitles ? .off : .on
        speechRadio.isEnabled = !locales.isEmpty
        if locales.isEmpty { speechRadio.state = .off; subtitleRadio.state = .on }
        applyMode()
        return alert
    }

    @objc private func modeChanged(_ sender: NSButton) {
        subtitleRadio.state = sender === subtitleRadio ? .on : .off
        speechRadio.state = sender === speechRadio ? .on : .off
        applyMode()
    }

    @objc private func selectionChanged(_ sender: Any?) {
        if let popup = sender as? NSPopUpButton, popup === languagePopup {
            targetWasReset = false
            refreshSpeechTargets()
        } else {
            if let popup = sender as? NSPopUpButton, popup === speechTargetPopup { targetWasReset = false }
            refreshTargetSupportHint()
            refreshExistingHint()
        }
    }

    private func applyMode() {
        let sub = subtitleMode
        subtitlePopup.isEnabled = sub
        subtitleTargetPopup.isEnabled = sub
        languagePopup.isEnabled = !sub
        speechTargetPopup.isEnabled = !sub
        refreshSpeechTargets()
    }

    private func cancelTargetSupportCheck() {
        targetSupportGeneration &+= 1
        targetSupportTask?.cancel()
        targetSupportTask = nil
    }

    /// Metadata queries only, on demand for the selected Speech locale. No
    /// model/session is created, and a late answer cannot change newer choices.
    private func refreshSpeechTargets() {
        cancelTargetSupportCheck()
        checkingTargetSupport = false
        for item in speechTargetPopup.itemArray { item.isEnabled = true }
        speechTargetPopup.isEnabled = !subtitleMode
        guard !subtitleMode, let sourceID = languagePopup.selectedItem?.representedObject as? String else {
            refreshTargetSupportHint()
            refreshExistingHint()
            return
        }
        if let supported = supportedTargetsBySource[sourceID] {
            applySupportedTargets(supported)
            return
        }
        checkingTargetSupport = true
        speechTargetPopup.isEnabled = false
        refreshTargetSupportHint()
        refreshExistingHint()
        let generation = targetSupportGeneration
        let targets = self.targets
        targetSupportTask = _Concurrency.Task { @MainActor [weak self] in
            let source = Locale(identifier: sourceID).language
            var supported: Set<String> = []
            for target in targets {
                guard !_Concurrency.Task.isCancelled else { return }
                let status = await CaptionTranslator.status(source: source, target: target)
                if status == .installed || status == .supported { supported.insert(target.minimalIdentifier) }
            }
            guard let self, generation == targetSupportGeneration, !_Concurrency.Task.isCancelled else { return }
            supportedTargetsBySource[sourceID] = supported
            targetSupportTask = nil
            applySupportedTargets(supported)
        }
    }

    private func applySupportedTargets(_ supported: Set<String>) {
        checkingTargetSupport = false
        speechTargetPopup.isEnabled = !subtitleMode
        for item in speechTargetPopup.itemArray {
            item.isEnabled = (item.representedObject as? String).map { supported.contains($0) } ?? true
        }
        if speechTargetPopup.selectedItem?.isEnabled == false {
            speechTargetPopup.selectItem(at: 0) // Always the explicit transcription-only option.
            targetWasReset = true
        }
        refreshTargetSupportHint()
        refreshExistingHint()
    }

    private func refreshTargetSupportHint() {
        if subtitleMode { targetSupportHint.stringValue = "" }
        else if checkingTargetSupport { targetSupportHint.stringValue = L("captions.target.checking") }
        else if targetWasReset { targetSupportHint.stringValue = L("captions.target.resetToTranscription") }
        else { targetSupportHint.stringValue = "" }
        targetSupportRow?.isHidden = targetSupportHint.stringValue.isEmpty
    }

    /// Use only the sheet's directory snapshot; an explicit source language must match.
    private func refreshExistingHint() {
        defer {
            if let alert = currentAlert, let grid = alert.accessoryView {
                grid.setFrameSize(NSSize(width: grid.frame.width, height: grid.fittingSize.height))
                alert.layout()
            }
        }
        confirmButton?.isEnabled = !checkingTargetSupport
        let targetID = (subtitleMode ? subtitleTargetPopup : speechTargetPopup).selectedItem?.representedObject as? String
        let sourceTag = subtitleMode ? nil : (languagePopup.selectedItem?.representedObject as? String)
            .map { CaptionLanguageTags.fileTag(forTranscriberLocale: Locale(identifier: $0)) }
        let targetTag = CaptionSubtitleFiles.effectiveTargetTag(sourceTag: sourceTag,
            targetTag: targetID.map { CaptionLanguageTags.fileTag(forTargetLanguage: $0) })
        let found = CaptionSubtitleFiles.matchingOutputs(sidecars: existingSidecars, mediaURL: context.mediaURL,
                                                        sourceTag: sourceTag, targetTag: targetTag)
        existingURL = found.first
        guard let ex = existingURL else {
            existingHint.stringValue = ""
            regenerateCheck.isHidden = true
            confirmButton?.title = L("captions.button.generate")
            return
        }
        existingHint.stringValue = L("captions.existing.file", ex.lastPathComponent)
        regenerateCheck.isHidden = false
        confirmButton?.title = regenerateCheck.state == .on ? L("captions.button.regenerate") : L("captions.button.useExisting")
    }
}
