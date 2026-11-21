import AppKit
import ApplicationServices
import Carbon
import OSLog
import TypoCore

enum Action: String, CaseIterable, Identifiable {
    case correct, undo
    var id: Self { self }
    var title: String { self == .correct ? "Исправить выделение или слово" : "Отменить исправление" }
    var initial: Shortcut { Shortcut(key: self == .correct ? 97 : 98, modifiers: 0) }
}

@Observable
final class InputEngine {
    static let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]
    static let plainControlKeys: [UInt16: String] = [53: "Esc", 114: "Help", 115: "Home",
        116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down"]
    private static let excluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4",
        "com.github.wez.wezterm", "com.apple.ScriptEditor2", "com.panic.Nova"
    ]

    var automatic = UserDefaults.standard.object(forKey: "automatic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automatic") }
    }
    var exclusions = UserDefaults.standard.stringArray(forKey: "exclusions") ?? [] {
        didSet { UserDefaults.standard.set(exclusions, forKey: "exclusions") }
    }
    var wordExceptions = UserDefaults.standard.data(forKey: "wordExceptions")
        .flatMap { try? JSONDecoder().decode(WordExceptions.self, from: $0) } ?? WordExceptions() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(wordExceptions), forKey: "wordExceptions") }
    }
    private(set) var running = false
    private(set) var trusted = false
    private(set) var shortcuts: [Action: Shortcut] = Dictionary(uniqueKeysWithValues: Action.allCases.map { action in
        let saved = UserDefaults.standard.data(forKey: action.rawValue)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        return (action, saved ?? action.initial)
    })
    var recording = false {
        didSet { reset() }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var matcher = HotkeyMatcher()
    private var typedLetters = 0
    private var inputRevision: UInt64 = 0
    private var cancelSelection: (() -> Void)?
    private var consumedKeys: Set<UInt16> = []
    private var undo: (element: AXUIElement, pid: pid_t, edit: TextEdit,
                       from: TISInputSource?, toID: String?, automatic: Bool)?
    private let recognizer = LayoutRecognizer(lexicon: .bundled) { word, layout in
        let language = layout == .english ? "en" : "ru"
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(language) else { return false }
        return checker.checkSpelling(of: word, startingAt: 0, language: language,
                                     wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    func bind(_ shortcut: Shortcut, to action: Action) -> Bool {
        guard !shortcuts.contains(where: {
                  $0.key != action && $0.value.key == shortcut.key && $0.value.modifiers == shortcut.modifiers
              }) else { return false }
        shortcuts[action] = shortcut
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: action.rawValue)
        reset()
        return true
    }

    func start(prompt: Bool = false) {
        if prompt {
            trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }
        if !trusted {
            if let tap { CFMachPortInvalidate(tap) }
            tap = nil
            source = nil
            running = false
            reset()
            return
        }
        if let tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            running = CGEvent.tapIsEnabled(tap: tap)
            return
        }

        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { proxy, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<InputEngine>.fromOpaque(pointer).takeUnretainedValue()
                let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.rawValue
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let timestamp = Double(event.timestamp) / 1_000_000_000
                var letter: Character?
                if type == .keyDown, !repeated,
                   flags & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue |
                            CGEventFlags.maskControl.rawValue) == 0 {
                    var count = 0
                    var unit: UniChar = 0
                    event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &count,
                                                   unicodeString: &unit)
                    if count == 1, let scalar = Unicode.Scalar(unit) {
                        let character = Character(scalar)
                        if character.isLetter { letter = character }
                    }
                }
                let typedLetter = letter
                let proxyAddress = UInt(bitPattern: proxy)
                let consumed = MainActor.assumeIsolated {
                    engine.handle(type, key: key, flags: flags, repeated: repeated, letter: typedLetter, at: timestamp,
                                  through: OpaquePointer(bitPattern: proxyAddress)!)
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            running = false
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = CGEvent.tapIsEnabled(tap: tap)
    }

    private func reset() {
        cancelSelection?()
        cancelSelection = nil
        inputRevision &+= 1
        matcher.reset()
        consumedKeys.removeAll()
        typedLetters = 0
        undo = nil
    }

    private func handle(_ type: CGEventType, key: UInt16, flags: UInt64, repeated: Bool, letter: Character?, at time: Double,
                        through proxy: CGEventTapProxy) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard !recording, !IsSecureEventInputEnabled() else {
            reset()
            return false
        }
        guard type == .keyDown || type == .keyUp else {
            reset()
            return false
        }
        let modifiers = flags & Self.modifiers.rawValue
        if type == .keyUp {
            matcher.release(key)
            return consumedKeys.remove(key) != nil
        }

        cancelSelection?()
        cancelSelection = nil
        inputRevision &+= 1
        if repeated && consumedKeys.contains(key) { return true }
        let action = repeated ? nil : Action.allCases.first {
            shortcuts[$0]?.key == key && shortcuts[$0]?.modifiers == modifiers
        }
        if action == nil {
            matcher.reset()
            undo = nil
        }
        guard action == nil, automatic, let letter else {
            typedLetters = 0
            if let action { return handleShortcut(action, key: key, at: time, through: proxy) }
            return false
        }
        let minimum = LayoutRecognizer.minimumLiveLength
        typedLetters = min(typedLetters + 1, minimum)
        guard typedLetters == minimum, let app = eligibleApplication() else { return false }
        let revision = inputRevision
        DispatchQueue.main.async { [weak self] in
            self?.checkTypedLetter(letter, in: app, revision: revision, retries: 4)
        }
        return false
    }

    private func eligibleApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.excluded.contains(id), !id.hasPrefix("com.jetbrains."),
              !exclusions.contains(id),
              app.activationPolicy != .prohibited else {
            return nil
        }
        return app
    }

    private func handleShortcut(_ action: Action, key: UInt16, at time: Double,
                                through proxy: CGEventTapProxy) -> Bool {
        guard let app = eligibleApplication(), let shortcut = shortcuts[action] else { return false }
        if action == .undo && undo == nil { return false }
        if matcher.press(shortcut, at: time) {
            guard let field = FocusedText(application: app) else { return false }
            let native = app.bundleIdentifier == "com.apple.TextEdit" || field.supportsNativeReplacement
            let changed = action == .undo
                ? reverse(in: field, pid: app.processIdentifier, native: native, through: proxy)
                : correct(in: field, pid: app.processIdentifier, lastTyped: nil, native: native, through: proxy)
            guard changed else { return false }
        }
        consumedKeys.insert(key)
        return true
    }

    private func checkTypedLetter(_ letter: Character, in app: NSRunningApplication,
                                  revision: UInt64, retries: Int) {
        let pid = app.processIdentifier
        guard inputRevision == revision, automatic, !recording,
              eligibleApplication()?.processIdentifier == pid,
              let field = FocusedText(application: app) else { return }
        if field.selection.length == 0,
           let caret = Editing.span(field.selection, in: field.value)?.lowerBound,
           caret > field.value.startIndex, field.value[field.value.index(before: caret)] == letter {
            let native = app.bundleIdentifier == "com.apple.TextEdit" || field.supportsNativeReplacement
            _ = correct(in: field, pid: pid, lastTyped: letter, native: native, through: nil)
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
                self?.checkTypedLetter(letter, in: app, revision: revision, retries: retries - 1)
            }
        } else {
            inputLog.notice("Editor did not publish the typed letter at the caret")
        }
    }

    private func correct(in field: FocusedText, pid: pid_t, lastTyped: Character?, native: Bool,
                         through proxy: CGEventTapProxy?) -> Bool {
        undo = nil
        let automatic = lastTyped != nil
        let selection = field.selection
        let range: NSRange
        if selection.length > 0 {
            guard !automatic else { return false }
            range = selection
        } else if automatic {
            guard let word = Editing.wordWhileTyping(before: selection.location, in: field.value) else { return false }
            range = word
        } else {
            guard let caret = Editing.span(selection, in: field.value)?.lowerBound,
                  caret == field.value.endIndex || field.value[caret].isWhitespace,
                  let word = Editing.word(before: selection.location, in: field.value) else { return false }
            range = word
        }

        guard range.length <= (automatic ? 40 : 10_000),
              let span = Editing.span(range, in: field.value) else { return false }
        let original = String(field.value[span])
        let oldSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if automatic, oldSource.flatMap(Self.layout) != Layout.of(original) { return false }
        let replacement: String?
        if let lastTyped {
            guard !wordExceptions.contains(original) else { return false }
            replacement = recognizer.correctionWhileTyping(original, lastTyped: lastTyped)
        } else {
            replacement = Layout.convert(original)
        }
        guard let replacement, replacement != original else {
            inputLog.debug("No eligible layout correction")
            return false
        }

        let target = Layout.of(original).flatMap { layout in
            selection.length == 0 && oldSource.flatMap(Self.layout) == layout
                ? Self.enabledSource(for: layout.opposite) : nil
        }
        if automatic && target == nil { return false }

        let tail = NSRange(location: NSMaxRange(range), length: max(0, selection.location - NSMaxRange(range)))
        guard let tailSpan = Editing.span(tail, in: field.value) else { return false }
        let trailing = String(field.value[tailSpan])
        let newEnd = range.location + replacement.utf16.count
        let caret = newEnd + trailing.utf16.count
        let edit = TextEdit(range: range, original: original, replacement: replacement, trailing: trailing)
        let revision = inputRevision
        let finish: (Bool) -> Void = { [weak self] applied in
            guard applied, let self, self.inputRevision == revision else { return }
            if automatic { self.typedLetters = 0 }
            var newSource: String?
            if let target, let oldSource,
               let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
               Self.sourceID(current) == Self.sourceID(oldSource),
               TISSelectInputSource(target) == noErr {
                newSource = Self.sourceID(target)
            }
            undo = (field.element, pid, edit, oldSource, newSource, automatic)
        }
        let selected = NSRange(location: range.location, length: range.length + tail.length)
        let apply = {
            if native, let applied = field.replaceNatively(range, with: replacement, caret: caret) {
                finish(applied)
                return applied
            }
            return field.replace(selected, with: replacement + trailing, through: proxy, completion: finish)
        }
        if !automatic { return apply() }
        guard field.beginSelection(selected) else { return false }
        if field.confirmsSelection(selected) { return apply() }

        cancelSelection = { field.restoreSelection(after: selected) }
        // Web editors may acknowledge the selection before exposing it to Accessibility.
        @MainActor func awaitSelection(_ tries: Int) {
            guard inputRevision == revision else { return }
            if field.confirmsSelection(selected) {
                cancelSelection = nil
                if !apply() { field.restoreSelection(after: selected) }
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) {
                    awaitSelection(tries - 1)
                }
            } else {
                cancelSelection?()
                cancelSelection = nil
                inputLog.notice("Editor did not publish the requested selection")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { awaitSelection(3) }
        return true
    }

    private func reverse(in field: FocusedText, pid: pid_t, native: Bool, through proxy: CGEventTapProxy) -> Bool {
        guard let undo else { return false }
        self.undo = nil
        guard undo.pid == pid, CFEqual(undo.element, field.element),
              let range = undo.edit.reverseRange(in: field.value, selection: field.selection) else { return false }
        let caret = range.location + undo.edit.original.utf16.count + undo.edit.trailing.utf16.count
        let finish: (Bool) -> Void = { [weak self] applied in
            guard applied else { return }
            if undo.automatic { self?.wordExceptions.recordReversal(of: undo.edit.original) }
            if let from = undo.from, let toID = undo.toID,
               let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
               Self.sourceID(current) == toID {
                TISSelectInputSource(from)
            }
        }
        if native, let applied = field.replaceNatively(range, with: undo.edit.original, caret: caret) {
            finish(applied)
            return applied
        }
        let selected = NSRange(location: range.location, length: range.length + undo.edit.trailing.utf16.count)
        return field.replace(selected, with: undo.edit.original + undo.edit.trailing, through: proxy, completion: finish)
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    private static func layout(_ source: TISInputSource) -> Layout? {
        switch sourceID(source) {
        case "com.apple.keylayout.ABC", "com.apple.keylayout.US": .english
        case "com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin": .russian
        default: nil
        }
    }

    private static func enabledSource(for layout: Layout) -> TISInputSource? {
        let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]
        return sources?.first { Self.layout($0) == layout }
    }
}
