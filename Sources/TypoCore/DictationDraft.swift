import Foundation

public enum DictationDraft {
    public static func matches(_ actual: String, expected: String, allowsMissingTerminalLineFeed: Bool = false) -> Bool {
        actual == expected || actual == expected + "\n"
            || (allowsMissingTerminalLineFeed && expected.last == "\n" && actual == expected.dropLast())
    }

    public static func ownedRange(in actual: String, selection: NSRange,
                                  original: String, cursor: Int, draft: String,
                                  replacing length: Int = 0,
                                  allowsMissingTerminalLineFeed: Bool = false) -> NSRange? {
        let insertion = NSRange(location: cursor, length: length)
        guard !draft.isEmpty, let span = Editing.span(insertion, in: original) else { return nil }
        var expected = original
        expected.replaceSubrange(span, with: draft)
        let range = NSRange(location: cursor, length: draft.utf16.count)
        let caret = NSRange(location: NSMaxRange(range), length: 0)
        guard matches(actual, expected: expected,
                      allowsMissingTerminalLineFeed: allowsMissingTerminalLineFeed && NSMaxRange(range) < expected.utf16.count),
              selection == caret || selection == range else { return nil }
        return range
    }

    public static func change(from draft: String, to text: String, at start: Int) -> (range: NSRange, text: String) {
        var prefixLength = 0
        var prefixCharacters = 0
        for (previous, next) in zip(draft, text) {
            guard previous == next, previous.utf16.elementsEqual(next.utf16) else { break }
            prefixLength += previous.utf16.count
            prefixCharacters += 1
        }
        return (NSRange(location: start + prefixLength, length: draft.utf16.count - prefixLength),
                String(text.dropFirst(prefixCharacters)))
    }
}
