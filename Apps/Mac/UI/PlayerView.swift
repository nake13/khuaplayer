import AppKit
import QuartzCore

final class PlayerView: NSView {
    let metalLayer = CAMetalLayer()

    var onDoubleClick: (() -> Void)?

    var onMouseDown: ((NSEvent) -> Void)?

    var onMouseUp: ((NSEvent) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
    var onMagnify: ((NSEvent) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        layer = metalLayer
        wantsLayer = true

        metalLayer.backgroundColor = NSColor.black.cgColor

        metalLayer.isOpaque = true
        metalLayer.contentsScale = 2.0
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)

        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    override func draw(_ dirtyRect: NSRect) {}

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) != true { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if onMagnify?(event) != true { super.magnify(with: event) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true])?.first as? URL
        else { return false }
        onFileDropped?(url)
        return true
    }

    var onFileDropped: ((URL) -> Void)?
}
