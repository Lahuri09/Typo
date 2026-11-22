import AppKit
import SwiftUI
import TypoCore

final class FloatingControlPanel: NSObject {
    private let appearance: PanelAppearance
    private let record: () -> Void
    private let edit: () -> Void
    private let isRecording: () -> Bool
    private let canEdit: () -> Bool
    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var started = false
    static let contentSize = CGSize(width: 78, height: 42)
    static let dictationIcon = "waveform"
    static let editIcon = "pencil.line"

    static func windowSize(scale: CGFloat) -> CGSize {
        let rim = PanelChrome.shadowInset * 2
        return CGSize(width: (contentSize.width + rim) * scale, height: (contentSize.height + rim) * scale)
    }

    init(appearance: PanelAppearance, record: @escaping () -> Void, edit: @escaping () -> Void,
         isRecording: @escaping () -> Bool = { false }, canEdit: @escaping () -> Bool = { true }) {
        self.appearance = appearance
        self.record = record
        self.edit = edit
        self.isRecording = isRecording
        self.canEdit = canEdit
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        observeAppearance()
    }

    @objc private func displayChanged(_ note: Notification) {
        refresh(reorder: true)
    }

    private func observeAppearance() {
        withObservationTracking {
            _ = appearance.floatingVisibility
            _ = appearance.hasTextContext
            _ = appearance.isPlacingControls
            _ = isRecording()
            _ = appearance.controlsPosition
            _ = appearance.size
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppearance() }
        }
        refresh()
    }

    private func refresh(reorder: Bool = false) {
        let size = Self.windowSize(scale: appearance.size.scale)
        let visible = appearance.isPlacingControls || appearance.floatingVisibility == .always
            || (appearance.floatingVisibility == .inText && (appearance.hasTextContext || isRecording()))
        let screens = visible ? NSScreen.screens : []
        var visiblePanels: [CGDirectDisplayID: OverlayPanel] = [:]
        var visibleFrames: [CGDirectDisplayID: CGRect] = [:]
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let bounds = screen.panelBounds
            guard !bounds.isEmpty else { continue }
            let window = panels[id] ?? OverlayPanel(size: size, content: FloatingControlsView(
                appearance: appearance, record: record, edit: edit, isRecording: isRecording, canEdit: canEdit,
                move: { [weak self] window, origin, finished in self?.move(window, to: origin, finished: finished) }
            ))
            let frame = appearance.controlsPosition.windowFrame(size: size, in: bounds)
            if window.frame != frame { window.setFrame(frame, display: true) }
            if !window.isVisible || reorder { window.orderFrontRegardless() }
            visiblePanels[id] = window
            visibleFrames[id] = window.frame
        }
        for (id, panel) in panels where visiblePanels[id] == nil { panel.orderOut(nil) }
        panels = visiblePanels
        if appearance.floatingFrames != visibleFrames { appearance.floatingFrames = visibleFrames }
    }

    private func move(_ window: NSWindow, to origin: CGPoint, finished: Bool) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen
        guard let bounds = screen?.panelBounds, !bounds.isEmpty else { return }
        let size = window.frame.size
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let position = PanelPosition(center: center, size: size, in: bounds)
        window.setFrameOrigin(position.windowFrame(size: size, in: bounds).origin)
        if finished {
            appearance.controlsPosition = position
            appearance.isPlacingControls = false
        }
    }
}

private struct FloatingControlsView: View {
    let appearance: PanelAppearance
    let record: () -> Void
    let edit: () -> Void
    let isRecording: () -> Bool
    let canEdit: () -> Bool
    let move: (NSWindow, CGPoint, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false
    @State private var dragging = false
    private static let handleSize = CGSize(width: 34, height: 20)

    private var revealsHandle: Bool { hovered || dragging }
    private var engaged: Bool { revealsHandle || appearance.isPlacingControls || isRecording() || !canEdit() }

    var body: some View {
        let recording = isRecording()
        let editingAvailable = canEdit()
        let theme = appearance.palette
        HStack(spacing: 4) {
            control(recording ? "stop.fill" : FloatingControlPanel.dictationIcon,
                    label: recording ? "Закончить и распознать" : "Начать диктовку",
                    active: recording, action: record)
                .disabled(!recording && !editingAvailable)
            control(FloatingControlPanel.editIcon, label: "Редактировать текст", action: edit)
                .disabled(!editingAvailable)
        }
        .frame(width: FloatingControlPanel.contentSize.width, height: FloatingControlPanel.contentSize.height)
        .modifier(PanelChrome(theme: theme, cornerRadius: 21, usesGradient: appearance.usesGradient))
        .opacity(reduceTransparency || engaged ? 1 : 0.70)
        .overlay(alignment: .top) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 28, height: 13)
                .background(theme.backdrop, in: Capsule())
                .overlay { Capsule().strokeBorder(theme.ink.opacity(0.22), lineWidth: 1) }
                .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                .opacity(revealsHandle ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!revealsHandle)
                .accessibilityLabel("Перетащить панель")
                .help("Перетащить панель")
                .offset(y: -11)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: engaged)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: revealsHandle)
        .scaleEffect(appearance.size.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            FloatingDragHandle(size: Self.handleSize, scale: appearance.size.scale, isVisible: revealsHandle, move: move,
                               onHover: { hovered = $0 }, onDragState: { dragging = $0 })
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Плавающие кнопки Typo")
    }

    private func control(_ icon: String, label: String, active: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(ControlButtonStyle(theme: appearance.palette, active: active))
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct ControlButtonStyle: ButtonStyle {
    let theme: PanelPalette
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? theme.backdrop : theme.accent)
            .background(active ? theme.accent : theme.ink.opacity(configuration.isPressed ? 0.18 : 0.08),
                        in: Circle())
            .opacity(isEnabled ? 1 : 0.38)
    }
}

private struct FloatingDragHandle: NSViewRepresentable {
    let size: CGSize
    let scale: CGFloat
    let isVisible: Bool
    let move: (NSWindow, CGPoint, Bool) -> Void
    let onHover: (Bool) -> Void
    let onDragState: (Bool) -> Void

    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.gripSize = CGSize(width: size.width * scale, height: size.height * scale)
        view.gripCenterOffset = (FloatingControlPanel.contentSize.height / 2 + 1) * scale
        view.gripIsVisible = isVisible
        view.move = move
        view.onHover = onHover
        view.onDragState = onDragState
        view.window?.invalidateCursorRects(for: view)
    }

    final class Handle: NSView {
        var move: ((NSWindow, CGPoint, Bool) -> Void)?
        var onHover: ((Bool) -> Void)?
        var onDragState: ((Bool) -> Void)?
        var gripSize: CGSize = .zero
        var gripCenterOffset: CGFloat = 0
        var gripIsVisible = false
        private var hoverArea: NSTrackingArea?
        private var anchor: CGPoint?
        private var didMove = false

        private var grip: CGRect {
            CGRect(x: bounds.midX - gripSize.width / 2, y: bounds.midY + gripCenterOffset - gripSize.height / 2,
                   width: gripSize.width, height: gripSize.height)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            // The panel never becomes key, so its tracking area must stay active over other apps.
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func hitTest(_ point: NSPoint) -> NSView? {
            gripIsVisible && grip.contains(convert(point, from: superview)) ? self : nil
        }

        override func resetCursorRects() {
            if gripIsVisible { addCursorRect(grip, cursor: .openHand) }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let pointer = NSEvent.mouseLocation
            anchor = CGPoint(x: pointer.x - window.frame.minX, y: pointer.y - window.frame.minY)
            didMove = false
            onDragState?(true)
            NSCursor.closedHand.set()
        }

        override func mouseDragged(with event: NSEvent) {
            didMove = true
            update(finished: false)
        }

        override func mouseUp(with event: NSEvent) {
            guard anchor != nil else { return }
            if didMove { update(finished: true) }
            anchor = nil
            onDragState?(false)
            NSCursor.openHand.set()
        }

        private func update(finished: Bool) {
            guard let anchor, let window else { return }
            let pointer = NSEvent.mouseLocation
            move?(window, CGPoint(x: pointer.x - anchor.x, y: pointer.y - anchor.y), finished)
        }
    }
}
