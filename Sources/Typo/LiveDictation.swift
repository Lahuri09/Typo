import AppKit
import TypoCore

/// Replaces only the draft owned by this recording, while the original editor and caret still match.
final class LiveDictation {
    private let original: FocusedText
    private let focused: () -> FocusedText?
    private let revision: () -> UInt64
    private let selectedText: String
    private var draft = ""
    private var unconfirmed: String?

    init(original: FocusedText, revision: @escaping () -> UInt64 = { 0 },
         focused: @escaping () -> FocusedText?) {
        self.original = original
        self.revision = revision
        self.focused = focused
        selectedText = Editing.span(original.selection, in: original.value)
            .map { String(original.value[$0]) } ?? ""
    }

    func preview(_ text: String) async {
        // Escape can only restore a live replacement if it can be typed without control keys.
        guard !selectedText.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !selectedText.contains(where: \.isNewline), draft != text else { return }
        await withCheckedContinuation { continuation in
            apply(text) { applied in
                if applied { self.draft = text; self.unconfirmed = nil }
                continuation.resume()
            }
        }
    }

    func complete(_ text: String, completion: @escaping (Bool) -> Void) {
        apply(text, completion: completion)
    }

    func cancel() {
        if !draft.isEmpty || unconfirmed != nil { apply(selectedText) { _ in } }
    }

    private func apply(_ text: String, completion: @escaping (Bool) -> Void) {
        let baseline = revision()
        guard let current = focused(), current.sameElement(as: original) else {
            inputLog.notice("Original dictation field is no longer focused")
            completion(false)
            return
        }
        let ownedRange: (String) -> NSRange? = { draft in
            DictationDraft.ownedRange(in: current.value, selection: current.selection,
                                      original: self.original.value, cursor: self.original.selection.location,
                                      draft: draft, replacing: self.original.selection.length,
                                      allowsMissingTerminalLineFeed: current.usesComposerLineFeed)
        }
        if let unconfirmed, ownedRange(unconfirmed) != nil {
            draft = unconfirmed
            self.unconfirmed = nil
        }

        let change: (range: NSRange, text: String)
        if draft.isEmpty {
            guard current.matches(original) else {
                inputLog.notice("Dictation selection changed before the first insertion")
                completion(false)
                return
            }
            if text == selectedText { completion(true); return }
            change = (original.selection, text)
        } else {
            guard let existing = ownedRange(draft) else {
                inputLog.notice("Dictation draft no longer matches the editor or caret")
                completion(false)
                return
            }
            if draft == text { completion(true); return }
            change = DictationDraft.change(from: draft, to: text, at: existing.location)
        }
        if !text.isEmpty { unconfirmed = text }
        current.replaceDictation(change.range, with: change.text, isCurrent: { self.revision() == baseline },
                                 completion: completion)
    }
}
