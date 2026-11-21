import AppKit
import ApplicationServices
import Carbon
import OSLog
import TypoCore

let inputLog = Logger(subsystem: "local.typo.Switcher", category: "Input")

struct FocusedText {
    private static var pasteInProgress = false
    let element: AXUIElement
    let value: String
    let selection: NSRange
    private let pid: pid_t
    private let bundleIdentifier: String?

    init?(application: NSRunningApplication) {
        guard !IsSecureEventInputEnabled() else { inputLog.notice("Secure input is active"); return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let focused = Self.read(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            inputLog.notice("No focused accessibility element"); return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.08)
        guard let role = Self.read(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            inputLog.notice("Focused element is not an editable text role"); return nil
        }
        guard
              Self.read(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              Self.read(element, "AXProtectedContent") as? Bool != true,
              !["AXAutocompleteValue", kAXIdentifierAttribute, kAXTitleAttribute,
                kAXDescriptionAttribute, kAXPlaceholderValueAttribute].contains(where: { attribute in
                    guard let label = Self.read(element, attribute) as? String else { return false }
                    return Editing.isCredentialLabel(label)
                }) else { return nil }
        guard Self.writable(element, kAXSelectedTextRangeAttribute) else {
            inputLog.notice("Editor does not expose a writable selection range"); return nil
        }
        guard
              let selection = Self.range(element),
              let value = Self.read(element, kAXValueAttribute) as? String,
              Editing.span(selection, in: value) != nil else {
            inputLog.notice("Editor did not provide a valid text snapshot"); return nil
        }
        if let selections = Self.read(element, kAXSelectedTextRangesAttribute) as? [Any],
           selections.count > 1 { return nil }
        self.element = element
        self.selection = selection
        self.pid = application.processIdentifier
        self.bundleIdentifier = application.bundleIdentifier
        self.value = value
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
        bundleIdentifier != "com.openai.codex" && Self.writable(element, kAXSelectedTextAttribute)
    }

    func replace(_ range: NSRange, with replacement: String, through proxy: CGEventTapProxy?,
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
        let initialCount = pasteboard.changeCount
        var savedItems: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    if range != selection && Self.range(element) == range { _ = setSelection(selection) }
                    return false
                }
            }
            savedItems.append(copy)
        }
        guard pasteboard.changeCount == initialCount,
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
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            if range != selection && Self.range(element) == range { _ = setSelection(selection) }
            return false
        }
        let replacementCount = pasteboard.changeCount
        Self.pasteInProgress = true

        down.flags = .maskCommand
        up.flags = .maskCommand
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
        let deadline = DispatchTime.now() + .milliseconds(80)
        @MainActor func confirmPaste() {
            let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && !IsSecureEventInputEnabled()
                && Self.read(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
                    .map { CFEqual($0, element) } == true
            let actual = focused ? Self.read(element, kAXValueAttribute) as? String : nil
            if focused, actual != editedValue, DispatchTime.now() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: confirmPaste)
                return
            }

            Self.pasteInProgress = false
            if pasteboard.changeCount == replacementCount {
                pasteboard.clearContents()
                if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            }
            if actual == value, range != selection, Self.range(element) == range {
                _ = setSelection(selection)
            }
            if focused, actual != editedValue { inputLog.notice("Editor did not confirm paste insertion") }
            completion(actual == editedValue)
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

    func confirmsSelection(_ range: NSRange) -> Bool {
        // Some editors publish the selected string later than the range.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.read(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFEqual(focused, element), Self.range(element) == range else { return false }
        return Self.read(element, kAXValueAttribute) as? String == value
    }

    private func setSelection(_ range: NSRange) -> Bool {
        var raw = CFRange(location: range.location, length: range.length)
        guard let boxed = AXValueCreate(.cfRange, &raw) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, boxed) == .success
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
