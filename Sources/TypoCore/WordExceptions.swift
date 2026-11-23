import Foundation

public struct WordExceptions: Codable {
    public private(set) var words: Set<String> = []
    private var reversals: [String: Int] = [:]

    public init() {}

    public func contains(_ word: String) -> Bool {
        words.contains(Self.normalize(word))
    }

    public func matchesEnding(at end: Int, in text: String) -> Bool {
        var start = end
        for _ in 0..<4 {
            guard let token = Editing.word(before: start, in: text),
                  let span = Editing.span(NSRange(location: token.location, length: end - token.location),
                                          in: text),
                  !text[span].contains(where: \.isNewline) else { return false }
            if contains(String(text[span])) { return true }
            start = token.location
        }
        return false
    }

    public mutating func add(_ word: String) {
        let key = Self.normalize(word)
        guard Self.isValidWord(key) else { return }
        insert(key)
    }

    public mutating func remove(_ word: String) {
        let key = Self.normalize(word)
        words.remove(key)
        reversals.removeValue(forKey: key)
    }

    @discardableResult
    public mutating func recordReversal(of word: String) -> String? {
        let key = Self.normalize(word)
        let tokens = key.split(separator: " ")
        guard (1...4).contains(tokens.count), tokens.allSatisfy({ Self.isValidWord(String($0)) }),
              !words.contains(key) else { return nil }
        reversals[key, default: 0] += 1
        guard reversals[key, default: 0] >= 3 else { return nil }
        insert(key)
        return key
    }

    private mutating func insert(_ key: String) {
        words.insert(key)
        reversals.removeValue(forKey: key)
    }

    private static func isValidWord(_ key: String) -> Bool {
        (1...40).contains(key.count) && key.allSatisfy(\.isLetter) && Layout.of(key) != nil
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").joined(separator: " ")
            .precomposedStringWithCanonicalMapping.lowercased()
    }
}
