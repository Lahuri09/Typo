import AppKit
import SwiftUI
import TypoCore

enum ActivityStatus: Equatable {
    case preparing, recording, transcribing, choosingEdit, rewriting, ready, inserted, dictated, unchanged, error(String)

    var label: String {
        switch self {
        case .preparing: "Открываем микрофон"
        case .recording: "Идёт запись"
        case .transcribing: "Распознаём речь"
        case .choosingEdit: "Выберите стиль"
        case .rewriting: "Редактируем текст"
        case .ready: "Результат готов"
        case .inserted: "Текст обновлён"
        case .dictated: "Диктовка вставлена"
        case .unchanged: "Текст без изменений"
        case .error(let message): message
        }
    }

    var icon: String {
        switch self {
        case .preparing, .recording: "mic.fill"
        case .transcribing: "waveform"
        case .choosingEdit, .rewriting: FloatingControlPanel.editIcon
        case .ready, .inserted, .dictated, .unchanged: "checkmark"
        case .error: "exclamationmark"
        }
    }

    var dismissal: Duration? {
        switch self {
        case .ready: .seconds(6)
        case .inserted, .dictated, .unchanged: .milliseconds(1500)
        case .error: .seconds(4)
        default: nil
        }
    }
}

@Observable
final class ActivityHUD {
    fileprivate let appearance: PanelAppearance
    private(set) var status: ActivityStatus?
    private(set) var actions: [EditAction] = []
    fileprivate private(set) var scale: CGFloat = 1
    fileprivate private(set) var chooserHeight: CGFloat = 0
    @ObservationIgnored private var panel: OverlayPanel?
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private var visibilityRevision = 0
    fileprivate static let chromeInset: CGFloat = 18
    private static let minimumChooserHeight: CGFloat = 110
    private let level: () -> Double
    private let cancel: () -> Void
    private let complete: () -> Void
    private let chooseEdit: (EditAction) -> Void
    private let copyEditResult: () -> Void

    init(appearance: PanelAppearance, level: @escaping () -> Double, cancel: @escaping () -> Void,
         complete: @escaping () -> Void, chooseEdit: @escaping (EditAction) -> Void = { _ in },
         copyEditResult: @escaping () -> Void = {}) {
        self.appearance = appearance
        self.level = level
        self.cancel = cancel
        self.complete = complete
        self.chooseEdit = chooseEdit
        self.copyEditResult = copyEditResult
    }

    func show(_ next: ActivityStatus, actions: [EditAction] = []) {
        dismissal?.cancel()
        visibilityRevision += 1
        let window = panel ?? makePanel()
        let showing = status == nil || !window.isVisible
        let revision = visibilityRevision
        if next == .choosingEdit { self.actions = actions }
        updateLayout(for: next, on: showing ? NSScreen.underPointer : window.screen, preserveSize: !showing)
        window.ignoresMouseEvents = next != .recording && next != .choosingEdit && next != .ready
        if showing && !window.isVisible { window.orderFrontRegardless() }
        let animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Animation.easeOut(duration: 0.12) : .spring(duration: showing ? 0.36 : 0.29, bounce: showing ? 0.17 : 0.07)
        withAnimation(animation, completionCriteria: .removed) {
            status = next
        } completion: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visibilityRevision == revision else { return }
                self.refreshLayout()
            }
        }
        if let duration = next.dismissal {
            dismissal = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                self?.hide()
            }
        }
    }

    func hide() {
        guard status != nil, let window = panel else { return }
        dismissal?.cancel()
        visibilityRevision += 1
        let revision = visibilityRevision
        window.ignoresMouseEvents = true
        let animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Animation.easeOut(duration: 0.12) : .easeInOut(duration: 0.25)
        withAnimation(animation, completionCriteria: .removed) {
            status = nil
        } completion: { [weak self] in
            guard self?.visibilityRevision == revision else { return }
            window.orderOut(nil)
        }
    }

    private func makePanel() -> OverlayPanel {
        let window = OverlayPanel(size: Self.windowSize(for: .transcribing, scale: appearance.size.scale),
                                  content: ActivityView(model: self, level: level,
                                                        cancel: cancel, complete: complete,
                                                        chooseEdit: chooseEdit, copyEditResult: copyEditResult))
        panel = window
        return window
    }

    static func contentSize(for status: ActivityStatus, chooserHeight: CGFloat = 0) -> CGSize {
        let width: CGFloat = switch status {
        case .choosingEdit: 446
        case .recording: 233
        default: 285
        }
        return CGSize(width: width, height: status == .choosingEdit ? chooserHeight : 48)
    }

    static func windowSize(for status: ActivityStatus, scale: CGFloat, chooserHeight: CGFloat = 0) -> CGSize {
        let content = contentSize(for: status, chooserHeight: chooserHeight)
        return CGSize(width: (content.width + chromeInset * 2) * scale,
                      height: (content.height + chromeInset * 2) * scale)
    }

    fileprivate var fullChooserHeight: CGFloat {
        max(Self.minimumChooserHeight, CGFloat((actions.count + 1) / 2) * 62 + 70)
    }

    fileprivate func refreshLayout() {
        guard let status else { return }
        updateLayout(for: status, on: panel?.screen)
    }

    private func updateLayout(for status: ActivityStatus, on screen: NSScreen?, preserveSize: Bool = false) {
        guard let panel, let screen = screen ?? NSScreen.underPointer else { return }
        let area = screen.panelBounds
        guard area.width > 0, area.height > 0 else { return }
        let chooser = status == .choosingEdit
        let fullSize = Self.windowSize(for: status, scale: 1, chooserHeight: fullChooserHeight)
        let minimumHeight = Self.windowSize(for: status, scale: 1, chooserHeight: Self.minimumChooserHeight).height
        let preferredScale = min(appearance.size.scale, area.width / fullSize.width, area.height / minimumHeight)
        let preferredSize = CGSize(width: fullSize.width * preferredScale, height: fullSize.height * preferredScale)
        let size = preserveSize
            ? CGSize(width: max(panel.frame.width, preferredSize.width), height: max(panel.frame.height, preferredSize.height))
            : preferredSize
        let floatingFrame = screen.displayID.flatMap { appearance.floatingFrames[$0] }
        let frame = appearance.hudPosition.windowFrame(size: size, in: area, avoiding: floatingFrame)
        scale = min(preferredScale, frame.width / fullSize.width, frame.height / minimumHeight)
        if chooser { chooserHeight = min(fullChooserHeight, frame.height / scale - Self.chromeInset * 2) }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

private struct ActivityPositionLayout: SwiftUI.Layout {
    let position: PanelPosition

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let point = CGPoint(x: bounds.minX + (bounds.width - size.width) * position.horizontal,
                                y: bounds.minY + (bounds.height - size.height) * position.vertical)
            subview.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

private struct ActivityView: View {
    let model: ActivityHUD
    let level: () -> Double
    let cancel: () -> Void
    let complete: () -> Void
    let chooseEdit: (EditAction) -> Void
    let copyEditResult: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: PanelPalette { model.appearance.palette }
    private var accent: Color { theme.accent }

    var body: some View {
        let appearance = model.appearance
        let position = appearance.hudPosition
        let direction: CGFloat = position.vertical <= 0.5 ? -1 : 1
        let anchor = UnitPoint(x: position.horizontal, y: position.vertical)
        ActivityPositionLayout(position: position) {
            if let status = model.status {
                shell(status)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: 8 * direction))
                            .combined(with: .scale(scale: 0.88, anchor: anchor)),
                        removal: .opacity
                            .combined(with: .offset(y: 5 * direction))
                            .combined(with: .scale(scale: 0.93, anchor: anchor))
                    ))
            }
        }
        .padding(ActivityHUD.chromeInset * model.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: appearance.size) { scheduleLayout() }
        .onChange(of: appearance.hudPosition) { scheduleLayout() }
        .onChange(of: appearance.floatingFrames) { scheduleLayout() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            scheduleLayout()
        }
    }

    private func scheduleLayout() {
        Task { @MainActor in model.refreshLayout() }
    }

    private func shell(_ status: ActivityStatus) -> some View {
        let choosing = status == .choosingEdit
        let size = ActivityHUD.contentSize(for: status, chooserHeight: model.chooserHeight)
        let scale = model.scale

        return ZStack(alignment: .top) {
            if choosing {
                editChooser.frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.opacity)
            } else {
                content(status)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .modifier(PanelChrome(theme: theme, cornerRadius: choosing ? 23 : 24, emphasis: choosing ? 0.24 : 0.19,
                              usesGradient: model.appearance.usesGradient))
        .scaleEffect(scale)
        .frame(width: size.width * scale, height: size.height * scale)
    }

    private var editChooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: FloatingControlPanel.editIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(theme.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                Text(ActivityStatus.choosingEdit.label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.78))
                        .frame(width: 28, height: 28)
                        .background(theme.ink.opacity(0.09), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть выбор")
                .help("Закрыть выбор (Esc)")
            }

            if model.actions.isEmpty {
                Text("Включите стиль редактуры в настройках Typo.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink.opacity(0.75))
                    .frame(minHeight: 32, alignment: .leading)
            } else if model.chooserHeight < model.fullChooserHeight {
                ScrollView { actionButtons }
            } else {
                actionButtons
            }
        }
        .padding(16)
    }

    private var actionButtons: some View {
        let actions = model.actions
        let pairedCount = actions.count - actions.count % 2
        return VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(actions.prefix(pairedCount), content: actionButton)
            }
            if let last = actions.dropFirst(pairedCount).first {
                actionButton(last)
            }
        }
    }

    private func actionButton(_ action: EditAction) -> some View {
        Button { chooseEdit(action) } label: {
            EditActionLabel(action: action, accent: accent, ink: theme.ink)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func content(_ status: ActivityStatus) -> some View {
        if status == .recording {
            HStack(spacing: 13) {
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.82))
                        .frame(width: 32, height: 32)
                        .background(theme.ink.opacity(0.09), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Отменить запись")
                .help("Отменить запись")

                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityLabel("Идёт запись")

                DotWave(level: level, color: accent, reduceMotion: reduceMotion)
                    .frame(width: 91, height: 23)
                    .accessibilityHidden(true)

                Button(action: complete) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.backdrop)
                        .frame(width: 32, height: 32)
                        .background(accent, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закончить и распознать")
                .help("Закончить и распознать")
            }
        } else {
            HStack(spacing: 9) {
                Image(systemName: status.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(status.label)
                    .contentTransition(.opacity)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if status == .ready {
                    Button(action: copyEditResult) {
                        Text("Скопировать")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.ink.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if status.dismissal == nil {
                    ProgressView().controlSize(.small).tint(theme.ink.opacity(0.85))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: 260)
            .accessibilityElement(children: status == .ready ? .contain : .combine)
        }
    }
}

private struct EditActionLabel: View {
    let action: EditAction
    let accent: Color
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: action.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 27, height: 27)
                .background(ink.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text(action.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ink.opacity(0.65))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 54)
        .background(ink.opacity(hovered ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(ink.opacity(hovered ? 0.18 : 0.065), lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .onHover { next in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovered = next }
        }
    }
}

private struct DotWave: View {
    let level: () -> Double
    let color: Color
    let reduceMotion: Bool
    @State private var history = Array(repeating: 0.0, count: 13)

    var body: some View {
        Canvas { context, size in
            let spacing = size.width / Double(history.count)
            for (column, amplitude) in history.enumerated() {
                for row in -2...2 {
                    let glow = max(0.09, min(1, 0.33 + amplitude * 1.38 - Double(abs(row)) * 0.28))
                    let radius = 1.05 + glow * 0.72
                    let x = (Double(column) + 0.5) * spacing
                    let y = size.height / 2 + Double(row) * 4.5
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                       width: radius * 2, height: radius * 2)),
                                 with: .color(color.opacity(glow)))
                }
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            var envelope = 0.0
            while !Task.isCancelled {
                envelope = max(level(), envelope * 0.68)
                history.removeFirst()
                history.append(envelope)
                do { try await Task.sleep(for: .milliseconds(36)) } catch { return }
            }
        }
    }
}
