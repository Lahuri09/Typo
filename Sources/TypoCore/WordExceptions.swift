import Foundation

public struct WordExceptions: Codable {
    public private(set) var words: Set<String> = []
    private var reversals: [String: Int] = [:]

    public init() {}

    public func contains(_ word: String) -> Bool {
        words.contains(Self.normalize(word))
    }

    public mutating func add(_ word: String) {
        let key = Self.normalize(word)
        guard (1...40).contains(key.count), key.allSatisfy(\.isLetter), Layout.of(key) != nil else { return }
        words.insert(key)
        reversals.removeValue(forKey: key)
    }

    public mutating func remove(_ word: String) {
        let key = Self.normalize(word)
        words.remove(key)
        reversals.removeValue(forKey: key)
    }

    public mutating func recordReversal(of word: String) {
        let key = Self.normalize(word)
        guard (1...40).contains(key.count), key.allSatisfy(\.isLetter), !words.contains(key) else { return }
        if reversals[key, default: 0] >= 2 {
            add(key)
        } else {
            reversals[key, default: 0] += 1
        }
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }
}
