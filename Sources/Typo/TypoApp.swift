import SwiftUI
import UniformTypeIdentifiers
import TypoCore

@main
struct TypoApp: App {
    @NSApplicationDelegateAdaptor(Launcher.self) private var launcher
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Typo", systemImage: "keyboard") {
            Toggle("Автоисправление", isOn: Binding(
                get: { launcher.engine.automatic }, set: { launcher.engine.automatic = $0 }
            ))
            if !launcher.engine.running {
                Button("Проверить разрешения") { launcher.engine.start(prompt: true) }
            }
            Divider()
            Button("Настройки…") {
                launcher.engine.start()
                openWindow(id: "preferences")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Выйти из Typo") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }

        Window("Настройки Typo", id: "preferences") {
            Preferences(engine: launcher.engine)
        }
        .defaultSize(width: 480, height: 460)
        .windowResizability(.contentSize)
    }
}

final class Launcher: NSObject, NSApplicationDelegate {
    let engine = InputEngine()
    func applicationDidFinishLaunching(_ notification: Notification) { engine.start() }
    func applicationDidBecomeActive(_ notification: Notification) { engine.start() }
}

private struct Preferences: View {
    @Bindable var engine: InputEngine
    @State private var recording: Action?
    @State private var monitor: Any?
    @State private var message: String?
    @State private var exceptionWord = ""

    var body: some View {
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
        .frame(width: 500, height: 480)
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
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
