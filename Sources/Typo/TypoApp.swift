import SwiftUI
import UniformTypeIdentifiers
import TypoCore

@main
struct TypoApp: App {
    @NSApplicationDelegateAdaptor(Launcher.self) private var launcher
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Typo AI", systemImage: launcher.engine.ai.phase == .recording ? "mic.fill" : "waveform") {
            let ai = launcher.engine.ai
            @Bindable var appearance = ai.panelAppearance
            Button {
                launcher.engine.launchAI(.dictation, fromMenu: true)
            } label: {
                Label(ai.phase == .recording ? "Закончить запись" : "Начать запись",
                      systemImage: ai.phase == .recording ? "stop.circle" : FloatingControlPanel.dictationIcon)
            }
            .disabled(ai.phase != .idle && ai.phase != .recording)
            Button {
                launcher.engine.launchAI(.rewrite, fromMenu: true)
            } label: {
                Label("Открыть редактуру", systemImage: FloatingControlPanel.editIcon)
            }
            .disabled(ai.phase != .idle)
            if ai.phase == .recording {
                Button("Отменить запись") { ai.cancelDictation() }
            }
            Divider()
            Menu("Плавающая панель") {
                Picker("Показывать", selection: $appearance.floatingVisibility) {
                    ForEach(FloatingVisibility.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Button(appearance.isPlacingControls ? "Закончить перемещение" : "Переместить на экране") {
                    appearance.isPlacingControls.toggle()
                }
            }
            Toggle("Автоисправление", isOn: Binding(
                get: { launcher.engine.automatic }, set: { launcher.engine.automatic = $0 }
            ))
            if !launcher.engine.running {
                Button("Проверить разрешения") { launcher.engine.start(prompt: true) }
            }
            Divider()
            if !ai.message.isEmpty { Text(ai.message) }
            if ai.result != nil {
                Button("Скопировать результат") { ai.copyResult() }
            }
            Divider()
            Button("Настройки…") {
                launcher.engine.start()
                openWindow(id: "preferences")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Выйти из Typo AI") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }

        Window("Настройки Typo AI", id: "preferences") {
            Preferences(engine: launcher.engine)
        }
        .defaultSize(width: 720, height: 635)
        .windowResizability(.contentSize)
    }
}

final class Launcher: NSObject, NSApplicationDelegate {
    let engine = InputEngine()
    private lazy var floating = FloatingControlPanel(
        appearance: engine.ai.panelAppearance,
        record: { [weak self] in self?.engine.launchAI(.dictation, fromMenu: true) },
        edit: { [weak self] in self?.engine.launchAI(.rewrite, fromMenu: true) },
        isRecording: { [weak self] in self?.engine.ai.phase == .recording },
        canEdit: { [weak self] in self?.engine.ai.phase == .idle }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared
        engine.noteApplicationActivation(workspace.frontmostApplication)
        workspace.notificationCenter.addObserver(self, selector: #selector(noteActivation(_:)),
                                                 name: NSWorkspace.didActivateApplicationNotification, object: nil)
        engine.start()
        floating.start()
    }

    @objc private func noteActivation(_ notification: Notification) {
        engine.noteApplicationActivation(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        engine.ai.cancelDictation()
        engine.ai.local.stop()
    }
    func applicationDidBecomeActive(_ notification: Notification) { engine.start() }
}

private struct Preferences: View {
    private enum Page: String, CaseIterable {
        case general = "Общие"
        case dictation = "Диктовка"
        case editing = "Редактура"
        case appearance = "Внешний вид"
        case shortcuts = "Клавиши"

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .dictation: FloatingControlPanel.dictationIcon
            case .editing: FloatingControlPanel.editIcon
            case .appearance: "slider.horizontal.3"
            case .shortcuts: "keyboard"
            }
        }
    }

    @Bindable var engine: InputEngine
    @State private var page: Page = .general
    @State private var recording: Action?
    @State private var monitor: Any?
    @State private var message: String?
    @State private var exceptionWord = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button {
                        page = item
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            .foregroundStyle(page == item ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if page == item {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.13))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Вкладки настроек")
            Divider()
            switch page {
            case .general: general
            case .dictation: dictation
            case .editing: editing
            case .appearance: appearance
            case .shortcuts: shortcuts
            }
        }
        .frame(width: 720, height: 635)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private var general: some View {
        Form {
            Section("Автоисправление") {
                Toggle("Исправлять раскладку во время набора", isOn: $engine.automatic)
                if !engine.running {
                    Text(engine.trusted
                         ? "Quartz недоступен. Проверьте разрешение «Мониторинг ввода» и перезапустите Typo."
                         : "Разрешите Typo управлять компьютером в разделе «Универсальный доступ».")
                        .foregroundStyle(.secondary)
                    Button("Запросить или проверить доступ") { engine.start(prompt: true) }
                    if engine.trusted {
                        Button("Запросить мониторинг ввода") { _ = CGRequestListenEventAccess() }
                    }
                }
            }

            Section("Слова-исключения") {
                HStack {
                    TextField("Слово", text: $exceptionWord)
                        .onSubmit(addException)
                    Button("Добавить", action: addException)
                        .disabled(exceptionWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("После трёх отмен автоисправления Typo запомнит исходное слово.")
                    .foregroundStyle(.secondary)
                ForEach(engine.wordExceptions.words.sorted(), id: \.self) { word in
                    LabeledContent(word) {
                        Button("Удалить") { engine.wordExceptions.remove(word) }
                    }
                }
            }

            Section("Исключения") {
                Text("Защищённые поля и распознаваемые поля входа, распространённые терминалы и редакторы кода исключены автоматически.")
                    .foregroundStyle(.secondary)
                ForEach(engine.exclusions, id: \.self) { id in
                    LabeledContent(id) {
                        Button("Удалить") { engine.exclusions.removeAll { $0 == id } }
                    }
                }
                Button("Добавить приложение…") { chooseApplication() }
            }
        }
        .formStyle(.grouped)
    }

    private var dictation: some View {
        Form {
            Section("Локальное распознавание") {
                @Bindable var ai = engine.ai
                @Bindable var small = ai.local.smallModel
                Picker("Язык диктовки", selection: $ai.speechLanguage) {
                    Text("Русский").tag("ru")
                    Text("Английский").tag("en")
                    Text("Автоматически").tag("auto")
                }
                if ai.speechLanguage == "ru", ai.local.russianSpeechReady {
                    Picker("Движок для русского", selection: $ai.usesGigaAM) {
                        Text("GigaAM").tag(true)
                        Text("Whisper").tag(false)
                    }
                }
                Picker(ai.speechLanguage == "ru" && ai.local.russianSpeechReady && ai.usesGigaAM
                           ? "Резервный Whisper" : "Модель Whisper",
                       selection: $small.variant) {
                    Text("Whisper Base").tag(SmallModel.Variant.base)
                    if small.installed { Text("Whisper Small").tag(SmallModel.Variant.small) }
                }
                if let progress = small.progress {
                    ProgressView("Whisper Small", value: progress)
                    Button("Отменить загрузку") { small.cancelDownload() }
                } else if !small.installed {
                    Button("Скачать Whisper Small · 190 МБ") { small.startDownload() }
                }
                if !small.message.isEmpty { Text(small.message).foregroundStyle(.secondary) }
            }

            SpeechModelSettings(models: engine.ai.speechModels)
            Section {
                @Bindable var ai = engine.ai
                Toggle("Звук после диктовки", isOn: $ai.playDictationSound)
            }
        }
        .formStyle(.grouped)
    }

    private var editing: some View {
        @Bindable var ai = engine.ai
        return Form {
            EditActionSettings(catalog: ai.editActions)
            CloudEditorSettings(editor: ai.cloudEditor)
            Section {
                Toggle("Звук после редактуры", isOn: $ai.playEditSound)
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        ScrollView {
            PanelAppearanceSettings(appearance: engine.ai.panelAppearance)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
    }

    private var shortcuts: some View {
        Form {
            Section("Горячие клавиши") {
                ForEach(Action.allCases) { action in
                    let shortcut = engine.shortcuts[action] ?? action.initial
                    LabeledContent(action.title) {
                        Button(recording == action ? "Нажмите клавишу…" : Self.label(shortcut)) { record(action) }
                            .accessibilityLabel("Назначить: " + action.title)
                            .accessibilityValue(Self.label(shortcut))
                    }
                    Toggle("Двойное нажатие · " + action.title.lowercased(), isOn: Binding(
                        get: { shortcut.double },
                        set: { _ = engine.bind(Shortcut(key: shortcut.key, modifiers: shortcut.modifiers, double: $0), to: action) }
                    ))
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }

        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func addException() {
        engine.wordExceptions.add(exceptionWord)
        if engine.wordExceptions.contains(exceptionWord) { exceptionWord = "" }
    }

    private func record(_ action: Action) {
        stopRecording()
        message = nil
        recording = action
        engine.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .intersection(InputEngine.modifiers)
            let shortcut = Shortcut(key: event.keyCode, modifiers: flags.rawValue,
                                    double: engine.shortcuts[action]?.double ?? false)
            if !engine.bind(shortcut, to: action) {
                message = "Эта клавиша или комбинация уже назначена другому действию."
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        engine.recording = false
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier, !engine.exclusions.contains(id) else { return }
        engine.exclusions.append(id)
        engine.exclusions.sort()
    }

    private static func label(_ shortcut: Shortcut) -> String {
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        let modifiers: [(CGEventFlags, String)] = [
            (.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")
        ]
        let prefix = modifiers.filter { flags.contains($0.0) }.map(\.1).joined()
        let ansi: [String] = [
            "A", "S", "D", "F", "H", "G", "Z", "X", "C", "V", "", "B", "Q", "W", "E", "R",
            "Y", "T", "1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8", "0", "]", "O",
            "U", "[", "I", "P", "↩", "L", "J", "'", "K", ";", "\\", ",", "/", "N", "M", ".",
            "Tab", "Space", "`", "⌫"
        ]
        let key: String
        if let number = InputEngine.functionKeys[shortcut.key] {
            key = "F\(number)"
        } else if let name = InputEngine.plainControlKeys[shortcut.key] {
            key = name
        } else if ansi.indices.contains(Int(shortcut.key)), !ansi[Int(shortcut.key)].isEmpty {
            key = ansi[Int(shortcut.key)]
        } else {
            key = "код \(shortcut.key)"
        }
        return prefix + key + (shortcut.double ? " ×2" : "")
    }
}
