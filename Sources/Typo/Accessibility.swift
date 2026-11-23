import AppKit
import ApplicationServices
import Carbon
import OSLog
import TypoCore

let inputLog = Logger(subsystem: "local.typo.Switcher", category: "Input")
let dictationEventMarker: Int64 = 0x5479706F

struct PasteboardSnapshot {
    let changeCount: Int
    private let items: [NSPasteboardItem]

    init?(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        var copies: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { return nil }
            }
            copies.append(copy)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        items = copies
    }

    func restore(to pasteboard: NSPasteboard, ifUnchangedSince replacementCount: Int) {
        guard pasteboard.changeCount == replacementCount else { return }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

struct FocusedText {
    private static var pasteInProgress = false
    let element: AXUIElement
    let value: String
    let selection: NSRange
    private let pid: pid_t
    private let bundleIdentifier: String?

    init?(application: NSRunningApplication) {
        guard let element = Self.editorElement(in: application, diagnostics: true),
              let selection = Self.range(element),
              let value = Self.editorText(element, preferRange: Self.isChatGPT(application.bundleIdentifier)),
              Editing.span(selection, in: value) != nil else { return nil }
        if let selections = Self.read(element, kAXSelectedTextRangesAttribute) as? [Any],
           selections.count > 1 { return nil }
        self.element = element
        self.selection = selection
        self.pid = application.processIdentifier
        self.bundleIdentifier = application.bundleIdentifier
        self.value = value
    }

    static func hasEditorContext(in application: NSRunningApplication, click: CGPoint?) -> Bool {
        guard let element = editorElement(in: application, diagnostics: false), range(element) != nil else { return false }
        guard let click, let bounds = editorBounds(element) else { return true }
        // Some editors keep AX focus on a composer after a click elsewhere in the window.
        return bounds.insetBy(dx: -3, dy: -3).contains(click)
    }

    private static func editorBounds(_ element: AXUIElement) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let dimensions = read(element, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func editorElement(in application: NSRunningApplication, diagnostics: Bool) -> AXUIElement? {
        guard !IsSecureEventInputEnabled() else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let focused = Self.read(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            if diagnostics { inputLog.notice("No focused accessibility element") }
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.08)
        guard let role = Self.read(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            if diagnostics { inputLog.notice("Focused element is not an editable text role") }
            return nil
        }
        guard
              Self.read(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              Self.read(element, "AXProtectedContent") as? Bool != true,
              !["AXAutocompleteValue", kAXIdentifierAttribute, kAXTitleAttribute,
                kAXDescriptionAttribute, kAXPlaceholderValueAttribute].contains(where: { attribute in
                    guard let label = Self.read(element, attribute) as? String else { return false }
                    return Editing.isCredentialLabel(label)
                }) else { return nil }
        return element
    }

    func matches(_ other: FocusedText) -> Bool {
        pid == other.pid && CFEqual(element, other.element)
            && selection == other.selection && value == other.value
    }

    func beginSelection(_ range: NSRange) -> Bool {
        !IsSecureEventInputEnabled() && confirmsSelection(selection) && setSelection(range)
    }

    func restoreSelection(after range: NSRange) {
        if !IsSecureEventInputEnabled(), confirmsSelection(range) || confirmsSelection(selection) {
            _ = setSelection(selection)
        }
    }

    var supportsNativeReplacement: Bool {
        // The ChatGPT composer acknowledges AXSelectedText writes without changing its text.
        !usesComposerLineFeed && Self.writable(element, kAXSelectedTextRangeAttribute)
            && Self.writable(element, kAXSelectedTextAttribute)
    }

    var usesComposerLineFeed: Bool { Self.isChatGPT(bundleIdentifier) }

    private static func isChatGPT(_ identifier: String?) -> Bool {
        identifier == "com.openai.codex" || identifier == "com.openai.chat"
    }

    func sameElement(as other: FocusedText) -> Bool {
        pid == other.pid && CFEqual(element, other.element)
    }

    func replaceDictation(_ range: NSRange, with text: String, isCurrent: @escaping () -> Bool,
                          completion: @escaping (Bool) -> Void) {
        guard isCurrent(), !Self.pasteInProgress else { completion(false); return }
        if supportsNativeReplacement,
           let applied = replaceNatively(range, with: text, caret: range.location + text.utf16.count) {
            completion(applied)
            return
        }
        guard let span = Editing.span(range, in: value),
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !text.contains(where: \.isNewline), range.length > 0 || !text.isEmpty else {
            completion(false)
            return
        }
        // Chromium expects one grapheme per Unicode key event. Never synthesize Return or Tab.
        let pieces = text.isEmpty ? [[]] : text.map { Array($0.utf16) }
        let key = CGKeyCode(text.isEmpty ? kVK_Delete : kVK_Space)
        var events = [CGEvent]()
        for units in pieces {
            guard units.count <= 20, let pair = Self.dictationKeyEvents(key, text: units) else {
                completion(false)
                return
            }
            events.append(contentsOf: pair)
        }

        var expected = value
        expected.replaceSubrange(span, with: text)
        let inserted = NSRange(location: range.location, length: text.utf16.count)
        let caret = NSRange(location: NSMaxRange(inserted), length: 0)

        prepareReplacementRange(range, graphemes: value[span].count, isCurrent: isCurrent) { prepared in
            guard prepared, isCurrent(), confirmsSelection(range), !IsSecureEventInputEnabled() else {
                inputLog.notice("Could not confirm the dictation insertion range")
                completion(false)
                return
            }
            let deadline = DispatchTime.now() + .milliseconds(850)
            for event in events { event.postToPid(pid) }

            @MainActor func confirmInsertion() {
                guard isFocused else { completion(false); return }
                if let actual = Self.editorText(element, preferRange: usesComposerLineFeed),
                   let after = Self.range(element), after == caret || after == inserted,
                   DictationDraft.matches(actual, expected: expected,
                       allowsMissingTerminalLineFeed: usesComposerLineFeed && caret.location < expected.utf16.count) {
                    if after == inserted && inserted.length > 0 && isCurrent() { _ = setSelection(caret) }
                    completion(true)
                } else if DispatchTime.now() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: confirmInsertion)
                } else {
                    if isCurrent() { restoreSelection(after: range) }
                    inputLog.notice("Editor did not confirm direct dictation insertion")
                    completion(false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: confirmInsertion)
        }
    }

    func replaceLayout(_ range: NSRange, with text: String, isCurrent: @escaping () -> Bool,
                       completion: @escaping (Bool) -> Void) {
        guard !Self.pasteInProgress, let span = Editing.span(range, in: value) else {
            completion(false)
            return
        }
        // Web editors may interpret a synthetic Unicode key event as its physical Space key.
        prepareReplacementRange(range, graphemes: value[span].count, isCurrent: isCurrent) { prepared in
            guard prepared, isCurrent() else { completion(false); return }
            if !replace(range, with: text, through: nil, completion: completion) {
                restoreSelection(after: range)
                completion(false)
            }
        }
    }

    private func prepareReplacementRange(_ target: NSRange, graphemes: Int, isCurrent: @escaping () -> Bool,
                                       completion: @escaping (Bool) -> Void) {
        guard isCurrent(), let observed = unchangedDictationSelection else { completion(false); return }
        if observed == target { completion(true); return }
        guard observed == selection else { completion(false); return }

        // Some Chromium composers acknowledge the AX write but keep their caret in place.
        let accepted = setSelection(target)
        let axDeadline = DispatchTime.now() + .milliseconds(90)
        @MainActor func confirmAX() {
            guard isCurrent(), let observed = unchangedDictationSelection else { completion(false); return }
            if observed == target { completion(true); return }
            guard observed == selection else { completion(false); return }
            if accepted, DispatchTime.now() < axDeadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: confirmAX)
            } else {
                selectDictationSuffix(target, graphemes: graphemes, isCurrent: isCurrent, completion: completion)
            }
        }
        confirmAX()
    }

    private func selectDictationSuffix(_ target: NSRange, graphemes: Int, isCurrent: @escaping () -> Bool,
                                       completion: @escaping (Bool) -> Void) {
        let caret = NSRange(location: NSMaxRange(target), length: 0)
        guard selection.location <= target.location || selection == caret,
              NSMaxRange(selection) == caret.location, (1...160).contains(graphemes),
              let extend = Self.dictationKeyEvents(CGKeyCode(kVK_LeftArrow), flags: .maskShift) else {
            completion(false)
            return
        }

        @MainActor func extendSelection() {
            guard isCurrent(), unchangedDictationSelection == caret else { completion(false); return }
            inputLog.debug("Selecting verified dictation suffix with \(graphemes) arrow presses")
            for _ in 0..<graphemes {
                for event in extend { event.postToPid(pid) }
            }
            awaitDictationSelection(target, isCurrent: isCurrent) { selected in
                if !selected && isCurrent(), let observed = unchangedDictationSelection,
                   observed != selection {
                    if selection == caret, observed.location >= target.location,
                       NSMaxRange(observed) == caret.location,
                       let collapse = Self.dictationKeyEvents(CGKeyCode(kVK_RightArrow)) {
                        for event in collapse { event.postToPid(pid) }
                    } else {
                        _ = setSelection(selection)
                    }
                }
                completion(selected)
            }
        }

        if selection == caret { extendSelection(); return }
        guard isCurrent(), unchangedDictationSelection == selection,
              let collapse = Self.dictationKeyEvents(CGKeyCode(kVK_RightArrow)) else {
            completion(false)
            return
        }
        for event in collapse { event.postToPid(pid) }
        awaitDictationSelection(caret, isCurrent: isCurrent) { collapsed in
            if collapsed { extendSelection() }
            else { completion(false) }
        }
    }

    private func awaitDictationSelection(_ target: NSRange, isCurrent: @escaping () -> Bool,
                                         completion: @escaping (Bool) -> Void) {
        let deadline = DispatchTime.now() + .milliseconds(350)
        @MainActor func poll() {
            guard isCurrent(), let observed = unchangedDictationSelection else { completion(false); return }
            if observed == target { completion(true) }
            else if DispatchTime.now() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25), execute: poll)
            } else { completion(false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25), execute: poll)
    }

    private var unchangedDictationSelection: NSRange? {
        guard isFocused, Self.editorText(element, preferRange: usesComposerLineFeed) == value else { return nil }
        return Self.range(element)
    }

    private static func dictationKeyEvents(_ key: CGKeyCode, flags: CGEventFlags = [],
                                           text: [UInt16] = []) -> [CGEvent]? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: dictationEventMarker)
            if !text.isEmpty { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        }
        return [down, up]
    }

    func replaceAISelection(_ range: NSRange, with replacement: String, completion: @escaping (Bool) -> Void) {
        guard !Self.pasteInProgress, !replacement.isEmpty else { completion(false); return }
        if supportsNativeReplacement,
           let applied = replaceNatively(range, with: replacement,
                                         caret: range.location + replacement.utf16.count) {
            completion(applied)
            return
        }
        if !replace(range, with: replacement, through: nil,
                    aiPaste: true, completion: completion) {
            completion(false)
        }
    }

    func replace(_ range: NSRange, with replacement: String, through proxy: CGEventTapProxy?,
                 aiPaste: Bool = false,
                 completion: @escaping (Bool) -> Void) -> Bool {
        guard !Self.pasteInProgress, !replacement.isEmpty,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              !IsSecureEventInputEnabled(), let span = Editing.span(range, in: value),
              confirmsSelection(range) || (confirmsSelection(selection) && setSelection(range)) else {
            inputLog.notice("Could not prepare the replacement selection"); return false
        }

        guard confirmsSelection(range),
              !IsSecureEventInputEnabled() else {
            inputLog.notice("Editor did not confirm the intended selection")
            if range != selection && Self.range(element) == range { _ = setSelection(selection) }
            return false
        }

        let pasteboard = NSPasteboard.general
        guard let saved = PasteboardSnapshot(pasteboard), pasteboard.changeCount == saved.changeCount,
              confirmsSelection(range),
              !IsSecureEventInputEnabled() else {
            if range != selection && Self.range(element) == range { _ = setSelection(selection) }
            return false
        }

        let item = NSPasteboardItem()
        item.setString(replacement, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            saved.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
            if range != selection && Self.range(element) == range { _ = setSelection(selection) }
            return false
        }
        let replacementCount = pasteboard.changeCount
        Self.pasteInProgress = true

        down.flags = .maskCommand
        up.flags = .maskCommand
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: dictationEventMarker)
        }
        if let proxy {
            down.tapPostEvent(proxy)
            up.tapPostEvent(proxy)
        } else {
            down.postToPid(pid)
            up.postToPid(pid)
        }
        var expected = value
        expected.replaceSubrange(span, with: replacement)
        let editedValue = expected
        let deadline = DispatchTime.now() + .milliseconds(aiPaste ? 1500 : (usesComposerLineFeed ? 350 : 80))
        @MainActor func confirmPaste() {
            let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && !IsSecureEventInputEnabled()
                && Self.read(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
                    .map { CFEqual($0, element) } == true
            let actual = focused ? Self.editorText(element,
                preferRange: usesComposerLineFeed) : nil
            let inserted = NSRange(location: range.location, length: replacement.utf16.count)
            let end = NSRange(location: NSMaxRange(inserted), length: 0)
            let confirmed = actual.map { observed in
                if observed == editedValue { return true }
                guard usesComposerLineFeed, DictationDraft.matches(observed, expected: editedValue,
                    allowsMissingTerminalLineFeed: usesComposerLineFeed && end.location < editedValue.utf16.count)
                else { return false }
                let selectionAfterPaste = Self.range(element)
                return selectionAfterPaste == end || selectionAfterPaste == inserted
            } ?? false
            if !confirmed, (focused || aiPaste), pasteboard.changeCount == replacementCount, DispatchTime.now() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: confirmPaste)
                return
            }

            Self.pasteInProgress = false
            saved.restore(to: pasteboard, ifUnchangedSince: replacementCount)
            if (aiPaste || usesComposerLineFeed), confirmed {
                if Self.range(element) == inserted {
                    _ = setSelection(NSRange(location: NSMaxRange(inserted), length: 0))
                }
            } else if actual == value, range != selection, Self.range(element) == range {
                _ = setSelection(selection)
            }
            if focused, !confirmed {
                inputLog.notice("Paste unconfirmed; before length=\(value.utf16.count), expected=\(editedValue.utf16.count), observed=\(actual?.utf16.count ?? -1)")
            }
            completion(confirmed)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: confirmPaste)
        return true
    }

    func replaceNatively(_ range: NSRange, with replacement: String, caret: Int) -> Bool? {
        guard !IsSecureEventInputEnabled(), let span = Editing.span(range, in: value),
              confirmsSelection(range) || (confirmsSelection(selection) && setSelection(range)) else {
            inputLog.notice("Could not prepare native replacement")
            return false
        }

        guard confirmsSelection(range), !IsSecureEventInputEnabled() else {
            inputLog.notice("Editor did not confirm the native replacement selection")
            if range != selection && Self.range(element) == range { _ = setSelection(selection) }
            return false
        }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                                  replacement as CFString)
        if status == .attributeUnsupported || status == .notImplemented || status == .illegalArgument {
            // Fall back only if the editor explicitly rejected the write and the field is intact.
            guard confirmsSelection(range), range == selection || setSelection(selection),
                  confirmsSelection(selection) else { return false }
            inputLog.notice("Editor rejected native replacement; trying paste")
            return nil
        }

        var expected = value
        expected.replaceSubrange(span, with: replacement)
        guard Self.read(element, kAXValueAttribute) as? String == expected else {
            if confirmsSelection(range), range != selection { _ = setSelection(selection) }
            inputLog.notice("Editor did not confirm native replacement (AX status \(status.rawValue))")
            return false
        }
        let target = NSRange(location: caret, length: 0)
        if Self.range(element) != target { _ = setSelection(target) }
        return true
    }

    private var isFocused: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !IsSecureEventInputEnabled(),
              let focused = Self.read(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFEqual(focused, element) else { return false }
        return true
    }

    func confirmsSelection(_ range: NSRange) -> Bool {
        // Some editors publish the selected string later than the range.
        isFocused && Self.range(element) == range
            && Self.editorText(element, preferRange: usesComposerLineFeed) == value
    }

    private func setSelection(_ range: NSRange) -> Bool {
        var raw = CFRange(location: range.location, length: range.length)
        guard let boxed = AXValueCreate(.cfRange, &raw) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, boxed) == .success
    }

    private static func editorText(_ element: AXUIElement, preferRange: Bool) -> String? {
        if preferRange,
           let length = read(element, kAXNumberOfCharactersAttribute) as? Int, (1...100_000).contains(length) {
            var range = CFRange(location: 0, length: length)
            if let boxed = AXValueCreate(.cfRange, &range) {
                var result: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, boxed, &result
                ) == .success, let text = result as? String, text.utf16.count == length {
                    return text
                }
            }
        }
        return read(element, kAXValueAttribute) as? String
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func writable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var writable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &writable) == .success && writable.boolValue
    }

    private static func range(_ element: AXUIElement) -> NSRange? {
        guard let result = read(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var raw = CFRange()
        guard AXValueGetValue(result as! AXValue, .cfRange, &raw),
              raw.location >= 0, raw.length >= 0, raw.length <= Int.max - raw.location else { return nil }
        return NSRange(location: raw.location, length: raw.length)
    }
}
