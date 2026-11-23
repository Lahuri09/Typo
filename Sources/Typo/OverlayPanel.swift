import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { acceptsKeyboardInput }
    override var canBecomeMain: Bool { false }
    var acceptsKeyboardInput = false
    private var wantsVisible = false
    private var visibilityRevision = 0
    var canDragAt: ((CGPoint) -> Bool)?
    var onDrag: ((NSWindow, CGPoint, Bool) -> Void)?
    var onClickAfterGrab: ((CGPoint, CGPoint) -> Void)?
    var acceptsGrabClicks = true
    private var dragAnchor: (windowPoint: CGPoint, screenPoint: CGPoint)?
    private var didDrag = false

    init<Content: View>(size: CGSize, content: Content) {
        let rect = NSRect(origin: .zero, size: size)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true

        let host = OverlayHostingView(rootView: AnyView(content.preferredColorScheme(.dark)))
        host.sizingOptions = []
        // A separate container keeps hosting view layout from resizing the AppKit window.
        let container = NSView(frame: rect)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    override func sendEvent(_ event: NSEvent) {
        let point = event.locationInWindow
        if event.type == .leftMouseDown, canDragAt?(point) == true {
            // Hold the click until we know whether the pointer moved the panel.
            dragAnchor = (point, convertPoint(toScreen: point))
            didDrag = false
            return
        }
        if let anchor = dragAnchor, event.type == .leftMouseDragged || event.type == .leftMouseUp {
            let finished = event.type == .leftMouseUp
            let pointer = convertPoint(toScreen: point)
            if !didDrag, hypot(pointer.x - anchor.screenPoint.x, pointer.y - anchor.screenPoint.y) >= 5 {
                didDrag = true
                NSCursor.closedHand.set()
            }
            if didDrag {
                let grabbedPoint = anchor.windowPoint
                onDrag?(self, CGPoint(x: pointer.x - grabbedPoint.x, y: pointer.y - grabbedPoint.y), finished)
            }
            if finished {
                dragAnchor = nil
                if didDrag { NSCursor.arrow.set() }
                else if acceptsGrabClicks { onClickAfterGrab?(anchor.windowPoint, point) }
            }
            return
        }
        super.sendEvent(event)
    }

    func setFloatingVisible(_ visible: Bool, reorder: Bool = false) {
        guard wantsVisible != visible else {
            if reorder && visible { orderFrontRegardless() }
            return
        }
        wantsVisible = visible
        visibilityRevision += 1
        let revision = visibilityRevision
        ignoresMouseEvents = !visible
        if !visible, dragAnchor != nil {
            dragAnchor = nil
            NSCursor.arrow.set()
        }
        if visible && !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (visible ? 0.22 : 0.16)
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                if let self, self.visibilityRevision == revision, !self.wantsVisible { self.orderOut(nil) }
            }
        }
    }
}

private final class OverlayHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(pointer) } ?? main
    }

    var panelBounds: CGRect {
        let safe = safeAreaInsets
        let safeFrame = CGRect(x: frame.minX + safe.left, y: frame.minY + safe.bottom,
                               width: frame.width - safe.left - safe.right,
                               height: frame.height - safe.top - safe.bottom)
        return visibleFrame.intersection(safeFrame).insetBy(dx: 6, dy: 6)
    }
}

struct PanelChrome: ViewModifier {
    static let shadowInset: CGFloat = 14
    let theme: PanelPalette
    let cornerRadius: CGFloat
    var emphasis = 0.19
    var usesGradient = true
    var edgeTint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                let translucent = usesGradient && !reduceTransparency && !theme.isSolid
                if translucent { shape.fill(.ultraThinMaterial) }
                shape.fill(theme.backdrop.opacity(translucent ? 0.88 : 1))
                if usesGradient {
                    shape.fill(LinearGradient(stops: [
                        .init(color: theme.accent.opacity(theme.isSolid ? 0.08 : emphasis + 0.10), location: 0),
                        .init(color: .clear, location: 0.58),
                        .init(color: .black.opacity(theme.isSolid ? 0.07 : 0.20), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                if let edgeTint {
                    shape.fill(LinearGradient(stops: [.init(color: .clear, location: 0.58),
                                                     .init(color: edgeTint.opacity(0.21), location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.ink.opacity(contrast == .increased ? 0.38 : 0.16), lineWidth: 1)
                .allowsHitTesting(false) }
            .background {
                Canvas { context, size in
                    var shadow = context
                    shadow.addFilter(.shadow(color: .black.opacity(0.24), radius: 5, y: 2, options: .shadowOnly))
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
                    shadow.fill(shape.path(in: rect), with: .color(.black))
                }
                .padding(-Self.shadowInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}
