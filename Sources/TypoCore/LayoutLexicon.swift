import Foundation

public struct LayoutLexicon: Sendable {
    private let english: [String: Int]
    private let russian: [String: Int]
    private let englishCommon: [String]
    private let russianCommon: [String]
    private let englishTrigrams: Set<String>
    private let russianTrigrams: Set<String>

    private init(english: [String: Int], russian: [String: Int]) {
        self.english = english
        self.russian = russian
        englishCommon = english.keys.filter { english[$0, default: 0] >= 100 }.sorted()
        russianCommon = russian.keys.filter { russian[$0, default: 0] >= 100 }.sorted()
        englishTrigrams = Set(englishCommon.filter { $0.allSatisfy(\.isLetter) }.flatMap(Self.trigrams))
        russianTrigrams = Set(russianCommon.filter { $0.allSatisfy(\.isLetter) }.flatMap(Self.trigrams))
    }

    public static let bundled: Self = {
        let bundle = Bundle.main.url(forResource: "Typo_TypoCore", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        let lexicons = bundle.resourceURL?.appendingPathComponent("Lexicons", isDirectory: true)
        return Self(english: load("en", from: lexicons), russian: load("ru", from: lexicons))
    }()

    public func contains(_ word: String, in layout: Layout) -> Bool {
        count(word, in: layout) != nil
    }

    func hasCommonContinuation(of prefix: String, in layout: Layout) -> Bool {
        let words = layout == .english ? englishCommon : russianCommon
        var low = 0
        var high = words.count
        while low < high {
            let middle = low + (high - low) / 2
            if words[middle] <= prefix { low = middle + 1 }
            else { high = middle }
        }
        return low < words.count && words[low].hasPrefix(prefix)
    }

    func supportsCorrection(to word: String, in layout: Layout) -> Bool {
        let frequency = count(word, in: layout) ?? 0
        // Short forms collide with ordinary text more often.
        return word.count >= 5 && frequency >= (word.count >= 8 ? 25 : 60)
    }

    func supportsShortLiveCorrection(to word: String, in layout: Layout) -> Bool {
        count(word, in: layout) ?? 0 >= 1_000
    }

    func supportsUnknownCorrection(from original: String, to candidate: String, in source: Layout) -> Bool {
        guard original.count >= 8, original.allSatisfy(\.isLetter) else { return false }
        let from = source == .english ? englishTrigrams : russianTrigrams
        let to = source == .english ? russianTrigrams : englishTrigrams
        return Set(Self.trigrams(original)).subtracting(from).count >= 3
            && Self.trigrams(candidate).allSatisfy(to.contains)
    }

    private static func trigrams(_ word: String) -> [String] {
        let letters = Array(word)
        guard letters.count >= 3 else { return [] }
        return (0...(letters.count - 3)).map { String(letters[$0..<$0 + 3]) }
    }

    private func count(_ word: String, in layout: Layout) -> Int? {
        layout == .english ? english[word] : russian[word]
    }

    private static func load(_ language: String, from directory: URL?) -> [String: Int] {
        guard let url = directory?.appendingPathComponent(language + ".txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var words: [String: Int] = [:]
        words.reserveCapacity(80_000)
        for line in contents.split(separator: "\n") {
            guard let separator = line.firstIndex(of: " "),
                  let count = Int(line[line.index(after: separator)...]) else { continue }
            words[String(line[..<separator])] = count
        }
        return words
    }
}
