import Foundation

public enum Layout: Sendable {
    case english, russian

    private static let latin = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./\\~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?|@#$%^&*")
    private static let cyrillic = Array("]йцукенгшщзхъфывапролджэячсмитьбю/ё[ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ?Ё\"№%:,.;")
    private static let toRussian = Dictionary(uniqueKeysWithValues: zip(latin, cyrillic))
    private static let toEnglish = Dictionary(uniqueKeysWithValues: zip(cyrillic, latin))

    public static func of(_ text: String) -> Self? {
        for character in text {
            if character.isLetter && toEnglish[character] != nil { return .russian }
            if character.isASCII && character.isLetter { return .english }
        }
        return nil
    }

    public var opposite: Self { self == .english ? .russian : .english }

    public func converted(_ text: String) -> String {
        let table = self == .english ? Self.toRussian : Self.toEnglish
        return String(text.map { table[$0] ?? $0 })
    }

    public static func convert(_ text: String) -> String {
        var result = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                result += of(token)?.converted(token) ?? token
                result.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        return result + (of(token)?.converted(token) ?? token)
    }
}

public struct LayoutRecognizer {
    private let lexicon: LayoutLexicon?
    private let isKnown: (String, Layout) -> Bool

    public init(lexicon: LayoutLexicon? = nil, isKnown: @escaping (String, Layout) -> Bool) {
        self.lexicon = lexicon
        self.isKnown = isKnown
    }

    public static let minimumLiveLength = 3

    public func correctionWhileTyping(_ word: String, lastTyped: Character) -> String? {
        guard word.count >= Self.minimumLiveLength, word.last == lastTyped,
              let source = Layout.of(word),
              lexicon?.hasCommonContinuation(of: word.lowercased(), in: source) != true else { return nil }
        if word.count < 5 {
            let target = source.converted(word).lowercased()
            guard lexicon?.supportsShortLiveCorrection(to: target, in: source.opposite) == true else { return nil }
            return correction(for: word, attested: true)
        }
        let original = word.lowercased()
        let target = source.converted(word).lowercased()
        let plausible = lexicon?.supportsUnknownCorrection(from: original, to: target, in: source) == true
        return correction(for: word, attested: plausible)
    }

    public func correction(for word: String) -> String? {
        correction(for: word, attested: false)
    }

    public func correctionAtWordBoundary(for word: String) -> String? {
        guard let source = Layout.of(word) else { return nil }
        let target = source.converted(word).lowercased()
        let frequent = lexicon?.supportsShortLiveCorrection(to: target, in: source.opposite) == true
        return correction(for: word, attested: frequent)
    }

    private static let russianShort: Set<String> = [
        "а", "в", "да", "до", "за", "и", "из", "к", "мы", "на", "не", "но", "ну", "о",
        "об", "он", "от", "по", "с", "ты", "у", "то", "уж", "вы", "я", "же", "бы"
    ]
    private static let englishShort: Set<String> = [
        "a", "am", "an", "as", "at", "be", "by", "do", "go", "he", "i", "if", "in",
        "is", "it", "me", "my", "no", "of", "oh", "on", "or", "so", "to", "up", "us", "we"
    ]

    // Use only adjacent words on the same line, with positive evidence for every converted word.
    public func phraseCorrection(endingAt wordRange: NSRange, in text: String,
                                 exceptions: WordExceptions) -> (NSRange, String)? {
        guard let span = Editing.span(wordRange, in: text),
              let source = Layout.of(String(text[span])) else { return nil }
        var start = span.lowerBound
        var best: (NSRange, String)?
        for wordCount in 1...4 {
            let phrase = String(text[start..<span.upperBound])
            let words = phrase.split(separator: " ")
            guard words.count == wordCount, !exceptions.contains(phrase),
                  words.allSatisfy({ !exceptions.contains(String($0)) && supportsPhraseWord($0, from: source) })
            else { break }

            let enoughEvidence = wordCount >= 3
                || (wordCount == 2 && words.reduce(0, { $0 + $1.count }) >= 4)
            if enoughEvidence {
                best = (NSRange(start..<span.upperBound, in: text), source.converted(phrase))
            }
            var previousEnd = start
            while previousEnd > text.startIndex, text[text.index(before: previousEnd)] == " " {
                previousEnd = text.index(before: previousEnd)
            }
            guard previousEnd < start,
                  let previous = Editing.word(before: text[..<previousEnd].utf16.count, in: text, skipSpaces: false),
                  let previousSpan = Editing.span(previous, in: text) else { break }
            start = previousSpan.lowerBound
        }
        return best
    }

    private func supportsPhraseWord(_ word: Substring, from source: Layout) -> Bool {
        guard (1...40).contains(word.count), word.allSatisfy(\.isLetter),
              word.allSatisfy({ Layout.of(String($0)) == source }) else { return false }
        let original = word.lowercased()
        let target = source.converted(original)
        let originalShort = source == .russian ? Self.russianShort : Self.englishShort
        let targetShort = source == .english ? Self.russianShort : Self.englishShort
        guard target.allSatisfy(\.isLetter), !originalShort.contains(original),
              lexicon?.contains(original, in: source) != true,
              word.count < 3 || !isKnown(original, source) else { return false }
        return targetShort.contains(target)
            || lexicon?.supportsShortLiveCorrection(to: target, in: source.opposite) == true
    }

    private func correction(for word: String, attested: Bool) -> String? {
        guard (3...40).contains(word.count), let source = Layout.of(word),
              word.allSatisfy({ !$0.isLetter || Layout.of(String($0)) == source })
        else { return nil }
        let candidate = source.converted(word)
        guard candidate.allSatisfy(\.isLetter) else { return nil }
        let original = word.lowercased()
        let target = candidate.lowercased()
        guard lexicon?.contains(original, in: source) != true else { return nil }
        let dictionaryMatch = lexicon?.supportsCorrection(to: target, in: source.opposite) == true
        guard attested || dictionaryMatch || isKnown(target, source.opposite),
              !isKnown(original, source) else { return nil }
        return candidate
    }
}
