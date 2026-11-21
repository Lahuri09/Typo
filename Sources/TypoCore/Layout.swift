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
