import AppKit
import SwiftUI
import TypoCore

struct PanelAppearanceSettings: View {
    @Bindable var appearance: PanelAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var display = PreviewDisplay.current
    @State private var replay: Replay?
    @State private var status: ActivityStatus?
    @State private var draft = ""
    @State private var draftSelected = false
    @State private var coordinatesExpanded = false
    @GestureState private var panelDrag: PreviewDrag?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Предпросмотр").font(.headline)
                Spacer()
                Button { replay = Replay(mode: .dictation) } label: {
                    Label("Диктовка", systemImage: FloatingControlPanel.dictationIcon)
                }
                .help("Проиграть пример диктовки")
                Button { replay = Replay(mode: .editing) } label: {
                    Label("Редактура", systemImage: FloatingControlPanel.editIcon)
                }
                .help("Проиграть пример редактуры")
            }
            VStack(alignment: .leading, spacing: 8) {
                desktopPreview
                    .frame(height: min(310, 640 * display.frame.height / display.frame.width))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Предпросмотр рабочего стола")
                    .accessibilityValue(status?.label ?? "Положение панелей")
                Text("Наведите на плавающую панель и потяните за три точки сверху.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            styleControls
            Divider()
            HStack(spacing: 10) {
                Picker("Плавающая панель", selection: $appearance.floatingVisibility) {
                    ForEach(FloatingVisibility.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Spacer()
                Button(appearance.isPlacingControls ? "Готово" : "Переместить на экране") {
                    appearance.isPlacingControls.toggle()
                }
            }
            HStack(spacing: 10) {
                placementMenu("Панель активности", position: $appearance.hudPosition)
                placementMenu("Плавающая панель", position: $appearance.controlsPosition)
                Spacer()
                Toggle("Градиент панелей", isOn: $appearance.usesGradient)
                    .toggleStyle(.checkbox)
            }
            DisclosureGroup("Точная настройка положения", isExpanded: $coordinatesExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    coordinateControls("Панель активности", position: $appearance.hudPosition)
                    coordinateControls("Плавающая панель", position: $appearance.controlsPosition)
                }
                .padding(.top, 12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            display = .current
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            display = .current
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            display = .current
        }
        .task(id: replay) {
            if let replay { await play(replay.mode) }
        }
        .onDisappear {
            replay = nil
            status = nil
            draft = ""
            draftSelected = false
        }
    }

    private var showsFloatingPreview: Bool { appearance.floatingVisibility != .hidden || appearance.isPlacingControls }

    private var styleControls: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Цвет").font(.subheadline.weight(.medium))
                HStack(spacing: 3) {
                    ForEach(PanelTheme.allCases.filter { $0 != .custom }, id: \.self) { theme in
                        swatch(theme)
                    }
                    ColorPicker("Свой цвет", selection: $appearance.colorSelection, supportsOpacity: false)
                        .labelsHidden()
                        .help("Выбрать свой цвет")
                        .fixedSize()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Цвет панелей")
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Размер панелей").font(.subheadline.weight(.medium))
                Picker("Размер панелей", selection: $appearance.size) {
                    ForEach(PanelSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func swatch(_ theme: PanelTheme) -> some View {
        let selected = appearance.theme == theme
        let palette = theme.palette()
        return Button { appearance.theme = theme } label: {
            Circle()
                .fill(palette.swatch)
                .overlay { Circle().strokeBorder(.primary.opacity(0.24), lineWidth: 1) }
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.isSolid ? palette.ink : palette.backdrop)
                    }
                }
                .padding(3)
                .background {
                    if selected { Circle().strokeBorder(.primary.opacity(0.7), lineWidth: 1.5) }
                }
                .frame(width: 25, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(theme.title)
    }

    private func placementMenu(_ title: String, position: Binding<PanelPosition>) -> some View {
        let preset = PanelPlacement.allCases.first { $0.position == position.wrappedValue }
        return Menu {
            ForEach(PanelPlacement.allCases, id: \.self) { placement in
                Button { position.wrappedValue = placement.position } label: {
                    if placement == preset {
                        Label(placement.title, systemImage: "checkmark")
                    } else {
                        Text(placement.title)
                    }
                }
            }
            Divider()
            Button("Свободное…") { coordinatesExpanded = true }
        } label: {
            Text(title)
        }
        .fixedSize()
        .accessibilityValue(preset?.title ?? "Свободное положение")
        .help(preset?.title ?? "Свободное положение")
    }

    private func coordinateControls(_ title: String, position: Binding<PanelPosition>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(spacing: 20) {
                coordinateSlider("Слева", title: title, position: position, horizontal: true)
                coordinateSlider("Сверху", title: title, position: position, horizontal: false)
            }
        }
    }

    private func coordinateSlider(_ label: String, title: String, position: Binding<PanelPosition>,
                                  horizontal: Bool) -> some View {
        let value = Binding<Double>(get: {
            horizontal ? position.wrappedValue.horizontal : position.wrappedValue.vertical
        }, set: { value in
            let current = position.wrappedValue
            position.wrappedValue = PanelPosition(horizontal: horizontal ? value : current.horizontal,
                                                  vertical: horizontal ? current.vertical : value)
        })
        return HStack {
            Slider(value: value, in: 0...1, step: 0.01) { Text(label) }
                .accessibilityLabel(title + ", " + label.lowercased())
                .accessibilityValue(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var desktopPreview: some View {
        GeometryReader { geometry in
            let projection = DesktopProjection(display: display, container: geometry.size)
            desktopScene(projection)
                .environment(\.colorScheme, .dark)
                .clipShape(.rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.13)).allowsHitTesting(false) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func desktopScene(_ projection: DesktopProjection) -> some View {
        let sampleStatus = status ?? .transcribing
        let scale = appearance.size.scale
        let controlsSize = FloatingControlPanel.windowSize(scale: scale)
        let controlsFrame = appearance.controlsPosition.windowFrame(size: controlsSize, in: display.bounds)
        let hudBase = ActivityHUD.windowSize(for: sampleStatus, scale: 1, chooserHeight: PreviewActivity.chooserHeight)
        let hudScale = min(scale, display.bounds.width / hudBase.width)
        let hudSize = ActivityHUD.windowSize(for: sampleStatus, scale: hudScale, chooserHeight: PreviewActivity.chooserHeight)
        let hudFrame = appearance.hudPosition.windowFrame(size: hudSize, in: display.bounds,
                                                          avoiding: showsFloatingPreview ? controlsFrame : nil)
        let hud = projection.frame(for: hudFrame)
        let controls = projection.frame(for: controlsFrame)
        let hudOffset = panelDrag?.controls == false ? panelDrag?.translation ?? .zero : .zero
        let controlsOffset = panelDrag?.controls == true ? panelDrag?.translation ?? .zero : .zero
        return ZStack {
            DemoDesktop(draft: draft, draftSelected: draftSelected, display: display)
            PreviewActivity(status: sampleStatus, isSample: status == nil, theme: appearance.palette,
                            usesGradient: appearance.usesGradient)
                .scaleEffect(hudScale * projection.scale)
                .opacity(status == nil ? 0.72 : 1)
                .id(status == nil)
                .transition(hudTransition(scale: hudScale * projection.scale))
                .position(projection.center(of: hud, movedBy: hudOffset))
                .allowsHitTesting(false)
            if showsFloatingPreview {
                PreviewFloatingControls(theme: appearance.palette, recording: status == .recording,
                                        usesGradient: appearance.usesGradient)
                    .scaleEffect(scale * projection.scale)
                    .position(projection.center(of: controls, movedBy: controlsOffset))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: projection.size.width, height: projection.size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .updating($panelDrag) { value, drag, transaction in
                drag = previewDrag(value, hud: hud, controls: controls)
                transaction.animation = nil
            }
            .onEnded { value in
                guard let drag = previewDrag(value, hud: hud, controls: controls) else { return }
                let frame = drag.controls ? controls : hud
                let window = drag.controls ? controlsFrame : hudFrame
                let center = projection.center(of: frame, movedBy: drag.translation)
                let position = projection.position(for: center, window: window)
                if drag.controls { appearance.controlsPosition = position }
                else { appearance.hudPosition = position }
            })
        .accessibilityHidden(true)
    }

    private func previewDrag(_ value: DragGesture.Value, hud: CGRect, controls: CGRect) -> PreviewDrag? {
        let point = value.startLocation
        if showsFloatingPreview, controls.insetBy(dx: -5, dy: -5).contains(point) {
            return PreviewDrag(controls: true, translation: value.translation)
        }
        if hud.insetBy(dx: -5, dy: -5).contains(point) {
            return PreviewDrag(controls: false, translation: value.translation)
        }
        return nil
    }

    private struct PreviewDrag {
        let controls: Bool
        let translation: CGSize
    }

    private func hudTransition(scale: CGFloat) -> AnyTransition {
        guard status != nil, !reduceMotion else { return .opacity }
        let position = appearance.hudPosition
        let direction: CGFloat = position.vertical <= 0.5 ? -1 : 1
        let anchor = UnitPoint(x: position.horizontal, y: position.vertical)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8 * direction * scale))
                .combined(with: .scale(scale: 0.88, anchor: anchor)),
            removal: .opacity.combined(with: .offset(y: 5 * direction * scale))
                .combined(with: .scale(scale: 0.93, anchor: anchor))
        )
    }

    private func play(_ mode: Replay.Mode) async {
        draft = mode == .editing ? "давай перенесем встречу на завтра я утром свободен" : ""
        draftSelected = mode == .editing
        updateStatus(mode == .dictation ? .recording : .choosingEdit)
        do {
            try await Task.sleep(for: .milliseconds(1300))
            updateStatus(mode == .dictation ? .transcribing : .rewriting)
            try await Task.sleep(for: .milliseconds(800))
            draftSelected = false
            draft = mode == .dictation ? "Привет! Давай встретимся завтра в 11?" :
                "Давай перенесём встречу на завтра. Я свободен утром."
            updateStatus(mode == .dictation ? .dictated : .inserted)
            try await Task.sleep(for: .milliseconds(1100))
            updateStatus(nil)
        } catch { return }
    }

    private func updateStatus(_ next: ActivityStatus?) {
        let animation: Animation = if reduceMotion {
            .easeOut(duration: 0.12)
        } else if next == nil {
            .easeInOut(duration: 0.25)
        } else if status == nil {
            .spring(duration: 0.36, bounce: 0.17)
        } else {
            .spring(duration: 0.29, bounce: 0.07)
        }
        withAnimation(animation) { status = next }
    }

    private struct Replay: Equatable {
        enum Mode { case dictation, editing }
        let id = UUID()
        let mode: Mode
    }
}

private struct PreviewDisplay: Equatable {
    let frame: CGRect
    let bounds: CGRect
    let visible: CGRect

    static var current: Self {
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.underPointer, !screen.panelBounds.isEmpty {
            return Self(frame: screen.frame, bounds: screen.panelBounds, visible: screen.visibleFrame)
        }
        let fallback = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 58, width: 1440, height: 818)
        return Self(frame: fallback, bounds: visible.insetBy(dx: 6, dy: 6), visible: visible)
    }
}

private struct DesktopProjection {
    let display: PreviewDisplay
    let scale: CGFloat
    let size: CGSize

    init(display: PreviewDisplay, container: CGSize) {
        self.display = display
        scale = max(0.001, min(container.width / display.frame.width, container.height / display.frame.height))
        size = CGSize(width: display.frame.width * scale, height: display.frame.height * scale)
    }

    func frame(for window: CGRect) -> CGRect {
        CGRect(x: (window.minX - display.frame.minX) * scale, y: (display.frame.maxY - window.maxY) * scale,
               width: window.width * scale, height: window.height * scale)
    }

    func center(of frame: CGRect, movedBy translation: CGSize) -> CGPoint {
        let area = self.frame(for: display.bounds)
        let insetX = min(area.width, frame.width) / 2
        let insetY = min(area.height, frame.height) / 2
        return CGPoint(x: min(max(frame.midX + translation.width, area.minX + insetX), area.maxX - insetX),
                       y: min(max(frame.midY + translation.height, area.minY + insetY), area.maxY - insetY))
    }

    func position(for center: CGPoint, window: CGRect) -> PanelPosition {
        let point = CGPoint(x: display.frame.minX + center.x / scale, y: display.frame.maxY - center.y / scale)
        return PanelPosition(center: point, size: window.size, in: display.bounds)
    }
}

private struct DemoDesktop: View {
    let draft: String
    let draftSelected: Bool
    let display: PreviewDisplay

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = min(1.25, max(0.55, min(size.width / 470, size.height / 260)))
            ZStack {
                Color(red: 0.115, green: 0.14, blue: 0.24)
                RadialGradient(colors: [Color(red: 0.29, green: 0.40, blue: 0.67), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: size.width * 0.77)
                RadialGradient(colors: [Color(red: 0.21, green: 0.34, blue: 0.41), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: size.width * 0.67)
                menuBar(unit)
                    .frame(maxHeight: .infinity, alignment: .top)
                messenger(unit: unit, showsSidebar: size.width > 350)
                    .frame(width: size.width * 0.72, height: size.height * 0.65)
                dock(unit)
            }
        }
    }

    private func menuBar(_ unit: CGFloat) -> some View {
        HStack(spacing: 7 * unit) {
            Image(systemName: "apple.logo")
            Text("Чат").fontWeight(.semibold)
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
            Text("10:24").monospacedDigit()
        }
        .font(.system(size: 8 * unit))
        .foregroundStyle(.white.opacity(0.91))
        .padding(.horizontal, 9 * unit)
        .frame(height: 16 * unit)
        .background(.black.opacity(0.26))
    }

    private func messenger(unit: CGFloat, showsSidebar: Bool) -> some View {
        let corner = 10 * unit
        return VStack(spacing: 0) {
            HStack(spacing: 4 * unit) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.82)).frame(width: 5 * unit)
                }
                Text("Чат")
                    .font(.system(size: 9 * unit, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 23 * unit)
            }
            .padding(.horizontal, 9 * unit)
            .frame(height: 23 * unit)
            .background(.white.opacity(0.055))
            Divider()
            HStack(spacing: 0) {
                if showsSidebar {
                    VStack(alignment: .leading, spacing: 3 * unit) {
                        contact("Маша", unit: unit, selected: true)
                        contact("Антон", unit: unit, selected: false)
                        Spacer(minLength: 0)
                    }
                    .padding(6 * unit)
                    .frame(width: 75 * unit)
                    .background(.white.opacity(0.04))
                    Divider()
                }
                conversation(unit)
            }
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.092, green: 0.115, blue: 0.16), in: RoundedRectangle(cornerRadius: corner))
        .clipShape(.rect(cornerRadius: corner))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.17)) }
        .shadow(color: .black.opacity(0.24), radius: 13 * unit, y: 6 * unit)
    }

    private func contact(_ name: String, unit: CGFloat, selected: Bool) -> some View {
        Label(name, systemImage: "person.crop.circle.fill")
            .font(.system(size: 8 * unit, weight: selected ? .semibold : .regular))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.71))
            .lineLimit(1)
            .padding(5 * unit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 5 * unit))
    }

    private func conversation(_ unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7 * unit) {
            Text("Маша")
                .font(.system(size: 10 * unit, weight: .semibold))
            Divider()
            Spacer(minLength: 0)
            bubble("Привет! Есть минутка?", outgoing: false, unit: unit)
            bubble("Да, конечно", outgoing: true, unit: unit)
            bubble("Когда тебе удобно встретиться?", outgoing: false, unit: unit)
            HStack(spacing: 6 * unit) {
                Text(draft.isEmpty ? "Сообщение" : draft)
                    .font(.system(size: 8.5 * unit))
                    .foregroundStyle(.white.opacity(draft.isEmpty ? 0.65 : 0.98))
                    .lineLimit(2)
                    .background(draftSelected ? .blue.opacity(0.65) : .clear, in: .rect(cornerRadius: 2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 13 * unit))
                    .foregroundStyle(.white.opacity(draft.isEmpty ? 0.34 : 0.9))
            }
            .padding(5 * unit)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 6 * unit))
        }
        .padding(9 * unit)
    }

    private func bubble(_ message: String, outgoing: Bool, unit: CGFloat) -> some View {
        Text(message)
            .font(.system(size: 8.5 * unit))
            .lineLimit(1)
            .padding(.horizontal, 7 * unit)
            .padding(.vertical, 4 * unit)
            .background(outgoing ? Color(red: 0.22, green: 0.33, blue: 0.57) : .white.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 6 * unit))
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    private func dock(_ unit: CGFloat) -> some View {
        let bottomInset = display.visible.minY - display.frame.minY
        let leftInset = display.visible.minX - display.frame.minX
        let rightInset = display.frame.maxX - display.visible.maxX
        let atSide = max(leftInset, rightInset) > max(4, bottomInset)
        let layout = atSide ? AnyLayout(VStackLayout(spacing: 5 * unit)) : AnyLayout(HStackLayout(spacing: 5 * unit))
        let alignment: Alignment = atSide ? (leftInset > rightInset ? .leading : .trailing) : .bottom
        return layout {
            dockIcon("face.smiling.fill", color: .blue, unit: unit)
            dockIcon("safari.fill", color: .cyan, unit: unit)
            dockIcon("message.fill", color: .green, unit: unit)
            dockIcon("sparkles", color: .purple, unit: unit)
            dockIcon("trash.fill", color: .gray, unit: unit)
        }
        .padding(4 * unit)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 8 * unit))
        .padding(3 * unit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func dockIcon(_ icon: String, color: Color, unit: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9 * unit, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 14 * unit, height: 14 * unit)
            .background(color.opacity(0.55), in: RoundedRectangle(cornerRadius: 4 * unit))
    }
}

private struct PreviewFloatingControls: View {
    let theme: PanelPalette
    let recording: Bool
    let usesGradient: Bool

    var body: some View {
        HStack(spacing: 4) {
            icon(recording ? "stop.fill" : FloatingControlPanel.dictationIcon, active: recording)
            icon(FloatingControlPanel.editIcon, active: false)
        }
        .frame(width: FloatingControlPanel.contentSize.width, height: FloatingControlPanel.contentSize.height)
        .modifier(PanelChrome(theme: theme, cornerRadius: 21, usesGradient: usesGradient))
    }

    private func icon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? theme.backdrop : theme.accent)
            .frame(width: 32, height: 32)
            .background(active ? theme.accent : theme.ink.opacity(0.07), in: Circle())
    }
}

private struct PreviewActivity: View {
    static let chooserHeight: CGFloat = 132
    let status: ActivityStatus
    let isSample: Bool
    let theme: PanelPalette
    let usesGradient: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = ActivityHUD.contentSize(for: status, chooserHeight: Self.chooserHeight)
        Group {
            switch status {
            case .recording: recording
            case .choosingEdit: chooser
            default:
                HStack(spacing: 9) {
                    Image(systemName: status.icon).foregroundStyle(theme.accent)
                    Text(isSample ? "Панель активности" : status.label)
                        .foregroundStyle(theme.ink)
                        .contentTransition(.opacity)
                    if !isSample && status.dismissal == nil && !reduceMotion {
                        ProgressView().controlSize(.small).tint(theme.ink.opacity(0.85))
                    }
                }
                .font(.system(size: 13, weight: .medium))
            }
        }
        .frame(width: size.width, height: size.height)
        .modifier(PanelChrome(theme: theme, cornerRadius: status == .choosingEdit ? 23 : 24,
                              emphasis: status == .choosingEdit ? 0.24 : 0.19, usesGradient: usesGradient))
    }

    private var recording: some View {
        HStack(spacing: 13) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.82))
                .frame(width: 32, height: 32)
                .background(theme.ink.opacity(0.09), in: Circle())
            Image(systemName: "mic.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
            PreviewWave(accent: theme.accent).frame(width: 91, height: 23)
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.backdrop)
                .frame(width: 32, height: 32)
                .background(theme.accent, in: Circle())
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .background(theme.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                Text(status.label).font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(theme.ink.opacity(0.09), in: Circle())
            }
            HStack(spacing: 8) {
                editOption(.proofread, selected: true)
                editOption(.concise, selected: false)
            }
        }
        .padding(16)
        .foregroundStyle(theme.ink)
    }

    private func editOption(_ preset: EditPreset, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: preset.icon).foregroundStyle(theme.accent)
            Text(preset.title).fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 54)
        .background(theme.ink.opacity(selected ? 0.15 : 0.065), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct PreviewWave: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 9
            Canvas { context, size in
                for column in 0..<13 {
                    let amplitude = (sin(Double(column) * 0.85 - phase) + 1) / 2
                    for row in -2...2 {
                        let glow = max(0.09, min(1, 0.41 + amplitude * 0.75 - Double(abs(row)) * 0.30))
                        let radius = 1.05 + glow * 0.72
                        let x = (Double(column) + 0.5) * size.width / 13
                        let y = size.height / 2 + Double(row) * 4.5
                        context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                           width: radius * 2, height: radius * 2)),
                                     with: .color(accent.opacity(glow)))
                    }
                }
            }
        }
    }
}
