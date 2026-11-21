import Foundation

public enum Editing {
    public static func isCredentialLabel(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        let compact = words.joined()
        return words.contains { ["login", "username", "password", "passcode", "логин", "пароль"].contains($0) }
            || ["username", "password", "onetimecode", "имяпользователя"].contains(where: compact.contains)
    }


    public static func span(_ range: NSRange, in text: String) -> Range<String.Index>? {
        let utf16 = text.utf16
        let count = utf16.count
        guard range.location >= 0, range.location <= count,
              range.length >= 0, range.length <= count - range.location else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        guard let lower = start.samePosition(in: text), let upper = end.samePosition(in: text)
        else { return nil }
        return lower..<upper
    }

    public static func wordWhileTyping(before offset: Int, in text: String) -> NSRange? {
        guard let caret = span(NSRange(location: offset, length: 0), in: text)?.lowerBound,
              caret == text.endIndex || text[caret].isWhitespace || ".,!?;:".contains(text[caret]),
              let token = word(before: offset, in: text, skipSpaces: false),
              let tokenSpan = span(token, in: text) else { return nil }

        let fragment = text[tokenSpan]
        guard !fragment.contains(where: { "/@".contains($0) }),
              let separator = fragment.lastIndex(where: { ".,!?;:".contains($0) }),
              separator > fragment.startIndex else { return token }
        let previous = fragment[fragment.index(before: separator)]
        // A period after ASCII text can be part of a domain or filename.
        guard previous.isLetter, fragment[separator] != "." || !previous.isASCII else { return token }
        let start = fragment.index(after: separator)
        guard start != caret else { return nil }
        return NSRange(start..<caret, in: text)
    }

    public static func word(before offset: Int, in text: String, skipSpaces: Bool = true) -> NSRange? {
        guard let caret = span(NSRange(location: offset, length: 0), in: text)?.lowerBound
        else { return nil }
        var end = caret
        if skipSpaces {
            while end > text.startIndex && text[text.index(before: end)] == " " {
                end = text.index(before: end)
            }
        }
        var start = end
        while start > text.startIndex && !text[text.index(before: start)].isWhitespace {
            start = text.index(before: start)
        }
        return start == end ? nil : NSRange(start..<end, in: text)
    }
}

public struct TextEdit {
    public let range: NSRange
    public let original: String
    public let replacement: String
    public let trailing: String

    public init(range: NSRange, original: String, replacement: String, trailing: String) {
        self.range = range
        self.original = original
        self.replacement = replacement
        self.trailing = trailing
    }

    public func reverseRange(in text: String, selection: NSRange) -> NSRange? {
        let expected = replacement + trailing
        let count = text.utf16.count
        guard range.location >= 0, range.location <= count,
              expected.utf16.count <= count - range.location else { return nil }
        let check = NSRange(location: range.location, length: expected.utf16.count)
        guard selection == NSRange(location: NSMaxRange(check), length: 0),
              let span = Editing.span(check, in: text), text[span] == expected else { return nil }
        return NSRange(location: range.location, length: replacement.utf16.count)
    }
}
