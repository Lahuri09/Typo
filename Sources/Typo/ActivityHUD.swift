import AppKit
import SwiftUI
import TypoCore

enum ActivityStatus: Equatable {
    case preparing, recording, transcribing, choosingEdit, refiningEdit, rewriting, ready, inserted, dictated, copied, unchanged
    case fieldUnavailable, selectionRequired, layoutException(String), error(String)

    var label: String {
        switch self {
        case .preparing: "Открываем микрофон"
        case .recording: "Идёт запись"
        case .transcribing: "Распознаём речь"
        case .choosingEdit: "Выберите стиль"
        case .refiningEdit: "Уточнить редактуру"
        case .rewriting: "Редактируем текст"
        case .ready: "Результат готов"
        case .inserted: "Текст обновлён"
        case .dictated: "Диктовка вставлена"
        case .copied: "Скопировано в буфер"
        case .unchanged: "Текст без изменений"
        case .fieldUnavailable: "Выберите текстовое поле"
        case .selectionRequired: "Выделите текст для обработки"
        case .layoutException(let text): "«\(text)» добавлено в исключения"
        case .error(let message): message
        }
    }

    var icon: String {
        switch self {
        case .preparing, .recording: "mic.fill"
        case .transcribing: "waveform"
        case .choosingEdit, .rewriting: FloatingControlPanel.editIcon
        case .refiningEdit: "arrow.clockwise"
        case .ready, .inserted, .dictated, .copied, .unchanged, .layoutException: "checkmark"
        case .fieldUnavailable, .selectionRequired: "text.cursor"
        case .error: "exclamationmark"
        }
    }

    var dismissal: Duration? {
        switch self {
        case .ready: .seconds(6)
        case .inserted, .dictated, .copied, .unchanged: .milliseconds(1800)
        case .fieldUnavailable, .selectionRequired: .milliseconds(2800)
        case .layoutException: .seconds(3)
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
    private(set) var allowsRefinement = false
    fileprivate private(set) var recordingCountdown: RecordingCountdown?
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
    private let refineEdit: () -> Void
    private let submitRevision: (String?) -> Void
    private let didHide: () -> Void

    init(appearance: PanelAppearance, level: @escaping () -> Double, cancel: @escaping () -> Void,
         complete: @escaping () -> Void, chooseEdit: @escaping (EditAction) -> Void = { _ in },
         copyEditResult: @escaping () -> Void = {}, refineEdit: @escaping () -> Void = {},
         submitRevision: @escaping (String?) -> Void = { _ in }, didHide: @escaping () -> Void = {}) {
        self.appearance = appearance
        self.level = level
        self.cancel = cancel
        self.complete = complete
        self.chooseEdit = chooseEdit
        self.copyEditResult = copyEditResult
        self.refineEdit = refineEdit
        self.submitRevision = submitRevision
        self.didHide = didHide
    }

    func show(_ next: ActivityStatus, actions: [EditAction] = [], allowsRefinement: Bool = false,
              countdown: RecordingCountdown? = nil) {
        dismissal?.cancel()
        visibilityRevision += 1
        let window = panel ?? makePanel()
        let showing = status == nil || !window.isVisible
        let takesKeyboard = next == .refiningEdit
        let revision = visibilityRevision
        if next == .choosingEdit { self.actions = actions }
        if next == .recording { recordingCountdown = countdown }
        self.allowsRefinement = allowsRefinement
        if window.acceptsKeyboardInput && !takesKeyboard { window.orderOut(nil) }
        window.acceptsKeyboardInput = takesKeyboard
        updateLayout(for: next, on: showing ? NSScreen.underPointer : window.screen, preserveSize: !showing)
        window.ignoresMouseEvents = next != .recording && next != .choosingEdit && next != .ready
            && !takesKeyboard && !allowsRefinement
        if !window.isVisible { window.orderFrontRegardless() }
        let animation: Animation = if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            .easeOut(duration: 0.12)
        } else if next == .fieldUnavailable {
            .easeOut(duration: 0.28)
        } else {
            .spring(duration: showing ? 0.42 : 0.32, bounce: showing ? 0.08 : 0.03)
        }
        withAnimation(animation, completionCriteria: .removed) {
            status = next
        } completion: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visibilityRevision == revision else { return }
                self.refreshLayout()
            }
        }
        if takesKeyboard { window.makeKey() }
        if let duration = allowsRefinement ? .seconds(8) : next.dismissal {
            dismissal = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                self?.hide()
            }
        }
    }

    func hide() {
        guard status != nil, let window = panel else { return }
        dismissal?.cancel()
        didHide()
        visibilityRevision += 1
        let revision = visibilityRevision
        window.ignoresMouseEvents = true
        if window.acceptsKeyboardInput { window.resignKey() }
        window.acceptsKeyboardInput = false
        let animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Animation.easeOut(duration: 0.12) : .easeInOut(duration: 0.24)
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
                                                        chooseEdit: chooseEdit, copyEditResult: copyEditResult,
                                                        refineEdit: refineEdit, submitRevision: submitRevision))
        panel = window
        return window
    }

    static func contentSize(for status: ActivityStatus, chooserHeight: CGFloat = 0) -> CGSize {
        let width: CGFloat = switch status {
        case .choosingEdit: 446
        case .refiningEdit: 402
        case .recording: 282
        default: 285
        }
        let height: CGFloat = switch status {
        case .choosingEdit: chooserHeight
        case .refiningEdit: 106
        default: 48
        }
        return CGSize(width: width, height: height)
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
    let refineEdit: () -> Void
    let submitRevision: (String?) -> Void
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
                let feedback = status == .fieldUnavailable
                shell(status)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: (feedback ? 4 : 8) * direction))
                            .combined(with: .scale(scale: feedback ? 0.96 : 0.88, anchor: anchor)),
                        removal: .opacity
                            .combined(with: .offset(y: (feedback ? 2 : 5) * direction))
                            .combined(with: .scale(scale: feedback ? 0.98 : 0.93, anchor: anchor))
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
            } else if status == .refiningEdit {
                EditRefinementView(theme: theme, cancel: cancel, submit: submitRevision)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            } else {
                content(status)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .modifier(PanelChrome(theme: theme, cornerRadius: choosing ? 23 : 24, emphasis: choosing ? 0.24 : 0.19,
                              usesGradient: model.appearance.usesGradient, edgeTint: status == .fieldUnavailable ? warningTint : nil))
        .scaleEffect(scale)
        .frame(width: size.width * scale, height: size.height * scale)
    }

    private var warningTint: Color {
        theme.usesLightSurface ? Color(red: 0.66, green: 0.20, blue: 0.24) : Color(red: 1, green: 0.45, blue: 0.47)
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

                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityLabel("Идёт запись")

                DotWave(level: level, color: accent, reduceMotion: reduceMotion)
                    .frame(width: 91, height: 23)
                    .accessibilityHidden(true)

                if let countdown = model.recordingCountdown {
                    RecordingTimer(countdown: countdown, onLightSurface: theme.usesLightSurface)
                }

                Button(action: complete) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.backdrop)
                        .frame(width: 32, height: 32)
                        .background(accent, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закончить и распознать")
            }
        } else {
            HStack(spacing: 9) {
                Image(systemName: status.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status == .fieldUnavailable ? warningTint : accent)
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
                } else if model.allowsRefinement && (status == .inserted || status == .unchanged) {
                    Button(action: refineEdit) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 32, height: 32)
                            .background(accent.opacity(0.15), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Уточнить или повторить редактуру")
                } else if status.dismissal == nil {
                    ProgressView().controlSize(.small).tint(theme.ink.opacity(0.85))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: 260)
            .accessibilityElement(children: status == .ready || model.allowsRefinement ? .contain : .combine)
        }
    }
}

struct RecordingTimer: View {
    let countdown: RecordingCountdown
    let onLightSurface: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let reading = countdown.reading()
            let seconds = reading.seconds
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(reading.isWarning ? Color(red: 1, green: 0.46, blue: 0.46) : .white)
                .frame(width: 36, height: 22)
                .background(onLightSurface ? Color.black.opacity(0.78) : .clear, in: Capsule())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: reading.isWarning)
                .accessibilityLabel(reading.isWarning ? "Запись скоро завершится" : "До конца записи")
                .accessibilityValue(Text(Duration.seconds(seconds).formatted(.units(
                    allowed: [.minutes, .seconds], width: .wide))))
        }
    }
}

private struct EditRefinementView: View {
    let theme: PanelPalette
    let cancel: () -> Void
    let submit: (String?) -> Void
    @State private var details = ""
    @FocusState private var focused: Bool

    private var instruction: String { details.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(ActivityStatus.refiningEdit.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                Button("Новый вариант", systemImage: "arrow.clockwise") { submit(nil) }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 24, height: 24)
                        .background(theme.ink.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть уточнение")
            }
            HStack(spacing: 8) {
                TextField("Что изменить?", text: $details, prompt: Text("Что изменить?")
                    .foregroundStyle(theme.ink.opacity(0.55)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink)
                    .padding(9)
                    .background(theme.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .focused($focused)
                    .onSubmit(apply)
                Button(action: apply) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.backdrop)
                        .frame(width: 32, height: 32)
                        .background(theme.accent.opacity(instruction.isEmpty ? 0.45 : 1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(instruction.isEmpty)
                .accessibilityLabel("Применить уточнение")
            }
        }
        .padding(15)
        .onAppear { focused = true }
        .onExitCommand(perform: cancel)
    }

    private func apply() {
        guard !instruction.isEmpty else { return }
        submit(String(instruction.prefix(1_000)))
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
                .background(accent.opacity(hovered ? 0.19 : 0.09), in: RoundedRectangle(cornerRadius: 7))
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
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(accent)
                .opacity(hovered ? 0.9 : 0)
                .offset(x: hovered || reduceMotion ? 0 : -3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 9)
        .frame(height: 54)
        .background(accent.opacity(hovered ? 0.14 : 0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(hovered ? 0.30 : 0.08), lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .onHover { next in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.17)) { hovered = next }
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
