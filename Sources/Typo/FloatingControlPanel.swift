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
    static let contentSize = CGSize(width: 72, height: 38)
    static let buttonDiameter: CGFloat = 30
    static let buttonSpacing: CGFloat = 4
    static let dictationIcon = "waveform"
    static let editIcon = "pencil.line"

    static func windowSize(scale: CGFloat) -> CGSize {
        CGSize(width: (contentSize.width + PanelChrome.shadowInset * 2) * scale,
               height: (contentSize.height + PanelChrome.shadowInset * 2) * scale)
    }

    static func dragRegion(in bounds: CGRect, scale: CGFloat) -> CGRect {
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
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
        let screens = NSScreen.screens
        var visiblePanels: [CGDirectDisplayID: OverlayPanel] = [:]
        var visibleFrames: [CGDirectDisplayID: CGRect] = [:]
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let bounds = bounds(on: screen)
            guard !bounds.isEmpty else { continue }
            guard visible || panels[id] != nil else { continue }
            let window = panels[id] ?? makePanel(size: size)
            let frame = appearance.controlsPosition.windowFrame(size: size, in: bounds)
            if window.frame != frame { window.setFrame(frame, display: true) }
            window.acceptsGrabClicks = !appearance.isPlacingControls
            window.setFloatingVisible(visible, reorder: reorder || appearance.isPlacingControls)
            visiblePanels[id] = window
            if visible { visibleFrames[id] = window.frame }
        }
        for (id, panel) in panels where visiblePanels[id] == nil { panel.orderOut(nil) }
        panels = visiblePanels
        if appearance.floatingFrames != visibleFrames { appearance.floatingFrames = visibleFrames }
    }

    private func makePanel(size: CGSize) -> OverlayPanel {
        let window = OverlayPanel(size: size, content: FloatingControlsView(
            appearance: appearance, record: record, edit: edit, isRecording: isRecording, canEdit: canEdit
        ))
        window.canDragAt = { [weak window, weak self] point in
            guard let window, let self else { return false }
            let region = Self.dragRegion(in: CGRect(origin: .zero, size: window.frame.size),
                                         scale: self.appearance.size.scale)
            return region.contains(point)
        }
        window.onClickAfterGrab = { [weak window, weak self] start, end in
            guard let window, let self else { return }
            let bounds = CGRect(origin: .zero, size: window.frame.size)
            let scale = self.appearance.size.scale
            guard let action = Self.action(at: start, in: bounds, scale: scale),
                  action == Self.action(at: end, in: bounds, scale: scale) else { return }
            if action == .dictation {
                if self.isRecording() || self.canEdit() { self.record() }
            } else if self.canEdit() {
                self.edit()
            }
        }
        window.onDrag = { [weak self] window, origin, finished in
            self?.move(window, to: origin, finished: finished)
        }
        return window
    }

    private static func action(at point: CGPoint, in bounds: CGRect, scale: CGFloat) -> Action? {
        let x = (point.x - bounds.midX) / scale
        let y = (point.y - bounds.midY) / scale
        let offset = (buttonDiameter + buttonSpacing) / 2
        let radius = buttonDiameter / 2
        if hypot(x + offset, y) <= radius { return .dictation }
        if hypot(x - offset, y) <= radius { return .rewrite }
        return nil
    }

    private func bounds(on screen: NSScreen) -> CGRect {
        PanelPosition.floatingBounds(in: screen.panelBounds, screenBottom: screen.frame.minY + screen.safeAreaInsets.bottom,
                                     shadow: PanelChrome.shadowInset * appearance.size.scale)
    }

    private func move(_ window: NSWindow, to origin: CGPoint, finished: Bool) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen
        guard let screen else { return }
        let bounds = bounds(on: screen)
        guard !bounds.isEmpty else { return }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    private var engaged: Bool { hovered || appearance.isPlacingControls || isRecording() || !canEdit() }

    var body: some View {
        let recording = isRecording()
        let editingAvailable = canEdit()
        let theme = appearance.palette
        HStack(spacing: FloatingControlPanel.buttonSpacing) {
            control(recording ? "stop.fill" : FloatingControlPanel.dictationIcon,
                    label: recording ? "Закончить и распознать" : "Начать диктовку",
                    active: recording, action: record)
                .disabled(!recording && !editingAvailable)
            control(FloatingControlPanel.editIcon, label: "Редактировать текст", action: edit)
                .disabled(!editingAvailable)
        }
        .frame(width: FloatingControlPanel.contentSize.width, height: FloatingControlPanel.contentSize.height)
        .modifier(PanelChrome(theme: theme, cornerRadius: 21, usesGradient: appearance.usesGradient))
        .opacity(reduceTransparency || engaged ? 1 : appearance.restingOpacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.19), value: engaged)
        .scaleEffect(appearance.size.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            FloatingHoverTracking(scale: appearance.size.scale, onHover: { hovered = $0 })
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
                .frame(width: FloatingControlPanel.buttonDiameter, height: FloatingControlPanel.buttonDiameter)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? theme.backdrop : theme.accent)
            .background(active ? theme.accent : theme.ink.opacity(configuration.isPressed ? 0.20 : hovered ? 0.15 : 0.08),
                        in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            .onHover { hovered = isEnabled && $0 }
    }
}

private struct FloatingHoverTracking: NSViewRepresentable {
    let scale: CGFloat
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHover = onHover
        if view.scale != scale {
            view.scale = scale
            view.updateTrackingAreas()
        }
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        var scale: CGFloat = 1
        private var hoverArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let region = FloatingControlPanel.dragRegion(in: bounds, scale: scale)
            let area = NSTrackingArea(rect: region, options: [.activeAlways, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
