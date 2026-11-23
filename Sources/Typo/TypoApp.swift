import SwiftUI
import UniformTypeIdentifiers
import TypoCore

@main
struct TypoApp {
    static func main() {
        let app = NSApplication.shared
        let launcher = Launcher()
        app.delegate = launcher
        app.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu(title: "Typo AI")
        let preferences = applicationMenu.addItem(withTitle: "Настройки",
                                                   action: #selector(Launcher.openGeneralPreferences),
                                                   keyEquivalent: ",")
        preferences.target = launcher
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Выйти из Typo AI", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        app.mainMenu = mainMenu
        withExtendedLifetime(launcher) { app.run() }
    }
}

final class Launcher: NSObject, NSApplicationDelegate {
    let engine = InputEngine()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private let preferencesRoute = PreferencesRoute()
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
        installStatusItem()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Typo AI"
        item.button?.setAccessibilityLabel("Typo AI")
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TypoMenuPanel(
            engine: engine,
            runAction: { [weak self] action in self?.runFromPopover(action) },
            openSettings: { [weak self] in self?.openGeneralPreferences() },
            openHistory: { [weak self] in self?.showPreferences(page: .history) }
        ))
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        withObservationTracking {
            let icon = engine.ai.phase == .recording ? "mic.fill" : "waveform"
            statusItem?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "Typo AI")
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateStatusIcon() }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.close(); return }
        engine.noteApplicationActivation(NSWorkspace.shared.frontmostApplication)
        engine.start()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = NSAppearance(named: engine.ai.panelAppearance.palette.usesLightSurface ? .aqua : .darkAqua)
        if let size = popover.contentViewController?.view.fittingSize, size.width > 0, size.height > 0 {
            popover.contentSize = size
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func runFromPopover(_ action: Action) {
        popover.close()
        DispatchQueue.main.async { [weak self] in self?.engine.launchAI(action, fromMenu: true) }
    }

    @objc func openGeneralPreferences() { showPreferences(page: .general) }

    private func showPreferences(page: PreferencesPage? = nil) {
        popover.close()
        if let page { preferencesRoute.page = page }
        if preferencesWindow == nil {
            preferencesWindow = makeWindow("Настройки Typo AI",
                                           view: Preferences(engine: engine, route: preferencesRoute),
                                           size: CGSize(width: 800, height: 642))
        }
        if let preferencesWindow { present(preferencesWindow) }
    }

    private func makeWindow<Content: View>(_ title: String, view: Content, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openGeneralPreferences()
        return false
    }
}

private enum PreferencesPage: String, CaseIterable {
    case general = "Общие"
    case dictation = "Диктовка"
    case history = "История диктовок"
    case editing = "Редактура"
    case appearance = "Внешний вид"
    case shortcuts = "Клавиши"

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .dictation: FloatingControlPanel.dictationIcon
        case .history: "clock.arrow.circlepath"
        case .editing: FloatingControlPanel.editIcon
        case .appearance: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        }
    }
}

@Observable private final class PreferencesRoute {
    var page = PreferencesPage.general
}

private struct Preferences: View {
    @Bindable var engine: InputEngine
    let route: PreferencesRoute
    private var page: PreferencesPage { route.page }
    private var selectedPage: PreferencesPage { page == .history ? .dictation : page }
    @State private var recording: Action?
    @State private var monitor: Any?
    @State private var message: String?
    @State private var exceptionWord = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Typo AI", systemImage: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 13)
                ForEach(PreferencesPage.allCases.filter { $0 != .history }, id: \.self) { item in
                    Button { route.page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 13, weight: selectedPage == item ? .semibold : .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(TypoHoverStyle(ink: .primary, tint: Color.accentColor, selected: selectedPage == item))
                    .accessibilityAddTraits(selectedPage == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 23)
            .frame(width: 166)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Разделы настроек")
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if page == .history {
                        Button("Назад к диктовке", systemImage: "chevron.left") { route.page = .dictation }
                            .labelStyle(.iconOnly)
                            .help("Назад к диктовке")
                    }
                    Text(page.rawValue)
                        .font(.system(size: 25, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                Group {
                    switch page {
                    case .general: general
                    case .dictation: dictation
                    case .history: DictationHistoryView(ai: engine.ai)
                    case .editing: editing
                    case .appearance: appearance
                    case .shortcuts: shortcuts
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: route.page) {
            if route.page != .appearance { engine.ai.panelAppearance.isPlacingControls = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private var general: some View {
        Form {
            let permissions = PermissionCards(engine: engine)
            if permissions.isNeeded {
                Section("Разрешения") { permissions }
            }

            Section("Автоисправление") {
                Toggle("Исправлять раскладку во время набора", isOn: $engine.automatic)
            }

            Section("Слова-исключения") {
                Text("После трёх отмен автоисправления Typo запомнит исходное слово.")
                    .foregroundStyle(.secondary)
                ForEach(engine.wordExceptions.words.sorted(), id: \.self) { word in
                    LabeledContent(word) {
                        Button("Удалить") { engine.wordExceptions.remove(word) }
                    }
                }
                TextField("Слово", text: $exceptionWord)
                    .onSubmit(addException)
                Button("Добавить слово", action: addException)
                    .disabled(exceptionWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

            Section("О приложении") {
                LabeledContent("Разработчик", value: "Артур Абдуллин")
                HStack(spacing: 16) {
                    Link("Telegram", destination: URL(string: "https://t.me/artur_prodesign")!)
                    Link("GitHub", destination: URL(string: "https://github.com/Lahuri09")!)
                    Link("Instagram", destination: URL(string: "https://www.instagram.com/artur.prodesign/")!)
                }
                Link("Написать о поддержке Typo", destination: URL(string: "https://t.me/artur_prodesign")!)
            }
        }
        .formStyle(.grouped)
    }

    private var dictation: some View {
        Form {
            Section("Результат диктовки") {
                @Bindable var ai = engine.ai
                Picker("Если текстовое поле недоступно", selection: $ai.dictationFallback) {
                    ForEach(DictationFallback.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                Toggle("Звук после диктовки", isOn: $ai.playDictationSound)
                Button {
                    route.page = .history
                } label: {
                    Label("История диктовок", systemImage: "clock.arrow.circlepath")
                }
            }
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
        }
        .formStyle(.grouped)
    }

    private var editing: some View {
        @Bindable var ai = engine.ai
        return Form {
            EditActionSettings(catalog: ai.editActions)
            Section {
                Picker("Степень сокращения", selection: $ai.shortening) {
                    ForEach(ShorteningStrength.allCases, id: \.self) { strength in
                        Text(strength.title).tag(strength)
                    }
                }
            }
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
                        Button(recording == action ? "Нажмите клавишу…" : shortcut.displayLabel) { record(action) }
                            .accessibilityLabel("Назначить: " + action.title)
                            .accessibilityValue(shortcut.displayLabel)
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
}

extension Shortcut {
    var displayLabel: String {
        let flags = CGEventFlags(rawValue: self.modifiers)
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
        let name: String
        if let number = InputEngine.functionKeys[key] {
            name = "F\(number)"
        } else if let control = InputEngine.plainControlKeys[key] {
            name = control
        } else if ansi.indices.contains(Int(key)), !ansi[Int(key)].isEmpty {
            name = ansi[Int(key)]
        } else {
            name = "код \(key)"
        }
        return prefix + name + (double ? " ×2" : "")
    }
}
