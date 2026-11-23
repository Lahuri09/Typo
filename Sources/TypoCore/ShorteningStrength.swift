import Foundation

public enum ShorteningStrength: String, CaseIterable, Sendable {
    case gentle, strong

    public var title: String { self == .gentle ? "Бережное" : "Сильное" }

    public func instruction(russian: Bool) -> String {
        switch (self, russian) {
        case (.gentle, true):
            "Слегка сократи текст. Убери слова-паразиты, повторы и лишние обороты. Сохрани каждый отдельный факт, просьбу, отрицание, имя, число, срок и последовательность абзацев. Возможно небольшое сокращение. Это не пересказ."
        case (.strong, true):
            "Заметно сократи текст. Объедини близкие предложения, убери повторы и второстепенные формулировки. Сохрани важные факты из каждой части, условия, отрицания, числа, имена, сроки и просьбы."
        case (.gentle, false):
            "Trim lightly. Remove filler and repetition. Keep each distinct fact, request, negation, name, number, deadline and the order of paragraphs. A small reduction is sufficient. Do not summarize."
        case (.strong, false):
            "Shorten substantially by merging related sentences and removing filler and repetition. Retain important facts from each section, conditions, negations, names, numbers, deadlines and requests."
        }
    }

    public func accepts(_ output: String, replacing source: String) -> Bool {
        guard !output.isEmpty, EditPreset.concise.accepts(output, replacing: source) else { return false }
        let baseline = EditPreset.concise.removingFiller(from: removingRepeatedParagraphs(in: source))
        let before = Self.lines(baseline)
        let after = Self.lines(output)
        let beforeTerms = before.map(Self.terms)
        let afterTerms = after.map(Self.terms)
        let allOutputTerms = afterTerms.reduce(into: Set<Substring>()) { $0.formUnion($1) }
        // Repeated boilerplate can dominate an edit. Check terms that distinguish the remaining paragraphs.
        if before.count < Self.lines(source).count, beforeTerms.count > 1, let first = beforeTerms.first {
            let common = beforeTerms.dropFirst().reduce(first) { $0.intersection($1) }
            if common.count * 2 >= first.count,
               !beforeTerms.allSatisfy({ $0.subtracting(common).isSubset(of: allOutputTerms) }) { return false }
        }
        if self == .gentle {
            guard before.count == after.count, output.count * 100 >= before.joined().count * 65 else { return false }
            return zip(beforeTerms, afterTerms).allSatisfy { initial, final in
                initial.intersection(final).count * 4 >= initial.count * 3
            }
        }

        return beforeTerms.allSatisfy { $0.intersection(allOutputTerms).count * 2 >= $0.count }
    }

    public func removingRepeatedParagraphs(in text: String) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            let key = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !key.contains(where: \.isNumber) {
                if self == .strong, !seen.insert(key).inserted { continue }
                if self == .gentle, kept.last?.trimmingCharacters(in: .whitespacesAndNewlines) == key { continue }
            }
            kept.append(paragraph)
        }
        return kept.joined(separator: "\n\n")
    }

    public static func paragraphGroups(in text: String, limit: Int = 1_800) -> [String] {
        var groups: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            if let previous = groups.last, previous.utf16.count + 2 + paragraph.utf16.count <= limit {
                groups[groups.count - 1] += "\n\n" + paragraph
            } else {
                groups.append(paragraph)
            }
        }
        return groups
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func terms(_ text: Substring) -> Set<Substring> {
        // A short prefix tolerates common changes in Russian word endings.
        Set(text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter }.filter { $0.count >= 4 }.map { $0.prefix(4) })
    }
}
