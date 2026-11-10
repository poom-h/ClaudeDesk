import AppKit
import SwiftUI

/// Native mouse tracking avoids gesture competition with the terminal and scroll view.
struct PaneDragSurface: NSViewRepresentable {
    var cursor: NSCursor = .openHand
    var click: (Int) -> Void = { _ in }
    var changed: (CGPoint, CGSize) -> Void
    var ended: () -> Void

    func makeNSView(context: Context) -> DragTrackingView { DragTrackingView() }
    func updateNSView(_ view: DragTrackingView, context: Context) {
        view.dragCursor = cursor
        view.click = click
        view.changed = changed
        view.ended = ended
    }
}

final class DragTrackingView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var dragCursor: NSCursor = .openHand
    var click: (Int) -> Void = { _ in }
    var changed: (CGPoint, CGSize) -> Void = { _, _ in }
    var ended: () -> Void = {}
    private var origin: NSPoint?
    private var moved = false
    private var trackingChanged: ((CGPoint, CGSize) -> Void)?
    private var trackingEnded: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: dragCursor) }
    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow
        moved = false
        trackingChanged = changed
        trackingEnded = ended
        click(event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
        guard moved || hypot(delta.width, delta.height) >= 3 else { return }
        moved = true
        NSCursor.closedHand.set()
        trackingChanged?(convert(event.locationInWindow, from: nil), delta)
    }
    override func mouseUp(with event: NSEvent) {
        if moved {
            mouseDragged(with: event)
            trackingEnded?()
        }
        origin = nil
        trackingChanged = nil
        trackingEnded = nil
        moved = false
        dragCursor.set()
    }
}
