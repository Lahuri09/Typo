import SwiftUI
import TypoCore

struct TypoMenuPanel: View {
    @Bindable var engine: InputEngine
    let runAction: (Action) -> Void
    let openSettings: () -> Void
    let openHistory: () -> Void

    var body: some View {
        let ai = engine.ai
        let appearance = ai.panelAppearance
        let palette = appearance.palette
        let recording = ai.phase == .recording
        let permissions = PermissionCards(engine: engine)
        VStack(alignment: .leading, spacing: 0) {
            if permissions.isNeeded {
                permissions
                separator(palette)
            }
            VStack(spacing: 3) {
                row(recording ? "Закончить запись" : "Начать диктовку", icon: recording ? "stop.fill" : "waveform",
                    palette: palette, shortcut: engine.shortcuts[.dictation]?.displayLabel) { runAction(.dictation) }
                    .disabled(ai.phase != .idle && !recording)
                if recording {
                    row("Отменить запись", icon: "xmark", palette: palette) { ai.cancelDictation() }
                }
                row("История диктовок", icon: "clock.arrow.circlepath", palette: palette, showsChevron: true,
                    count: ai.dictationHistory.entries.count, action: openHistory)
            }
            separator(palette)
            VStack(spacing: 3) {
                row("Редактировать выделение", icon: "pencil.line", palette: palette,
                    shortcut: engine.shortcuts[.rewrite]?.displayLabel) { runAction(.rewrite) }
                    .disabled(ai.phase != .idle)
                if ai.result != nil {
                    row("Скопировать результат", icon: "doc.on.doc", palette: palette) { ai.copyResult() }
                }
            }
            separator(palette)
            Toggle(isOn: $engine.automatic) {
                HStack(spacing: 9) {
                    Image(systemName: "keyboard").foregroundStyle(palette.accent).frame(width: 17)
                        .accessibilityHidden(true)
                    Text("Автосмена раскладки")
                }
            }
            .toggleStyle(MenuSwitchStyle(ink: palette.ink))
            separator(palette)
            row("Настройки", icon: "gearshape", palette: palette, showsChevron: true, action: openSettings)
            row("Выйти из Typo AI", icon: "power", palette: palette) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.ink)
        .padding(13)
        .frame(width: 318)
        .background {
            palette.backdrop
            if appearance.usesGradient {
                LinearGradient(colors: [palette.accent.opacity(palette.isSolid ? 0.06 : 0.15), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .environment(\.colorScheme, palette.usesLightSurface ? .light : .dark)
    }

    private func separator(_ palette: PanelPalette) -> some View {
        Rectangle().fill(palette.ink.opacity(0.13)).frame(height: 1).padding(.vertical, 9)
            .accessibilityHidden(true)
    }

    private func row(_ title: String, icon: String, palette: PanelPalette,
                     shortcut: String? = nil, showsChevron: Bool = false, count: Int? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(palette.accent)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.ink.opacity(0.72))
                        .fixedSize()
                }
                if let count {
                    Text(count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.ink.opacity(0.75))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(palette.ink.opacity(0.09), in: Capsule())
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.48))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(TypoHoverStyle(ink: palette.ink, tint: palette.accent))
    }
}

private struct MenuSwitchStyle: ToggleStyle {
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Color(red: 0.14, green: 0.58, blue: 0.35) : ink.opacity(0.22))
                    .frame(width: 36, height: 21)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 15, height: 15).padding(3)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct TypoHoverStyle: ButtonStyle {
    let ink: Color
    let tint: Color
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 35)
            .background(tint.opacity(selected ? (hovered ? 0.23 : 0.15) : (hovered ? 0.12 : 0)),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.38 : configuration.isPressed ? 0.76 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = isEnabled && $0 }
    }
}

struct DictationHistoryView: View {
    let ai: AIInput
    @State private var copied: DictationEntry.ID?
    @State private var toDelete: DictationEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ai.dictationHistory.entries.isEmpty {
                ContentUnavailableView("Пока пусто", systemImage: "clock.arrow.circlepath",
                                       description: Text("Здесь появятся диктовки, сохранённые без текстового поля."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(ai.dictationHistory.entries) { entry in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(copied == entry.id ? "Скопировано" : "Скопировать",
                                           systemImage: copied == entry.id ? "checkmark" : "doc.on.doc") {
                                        ai.copyToClipboard(entry.text)
                                        copied = entry.id
                                    }
                                    Button("Удалить запись", systemImage: "trash") { toDelete = entry }
                                        .labelStyle(.iconOnly)
                                }
                                Text(entry.text).textSelection(.enabled)
                            }
                            .padding(13)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Удалить эту запись?", isPresented: Binding(get: { toDelete != nil }, set: {
            if !$0 { toDelete = nil }
        }), titleVisibility: .visible, presenting: toDelete) { entry in
            Button("Удалить", role: .destructive) { ai.dictationHistory.remove(entry.id) }
        }
    }
}
