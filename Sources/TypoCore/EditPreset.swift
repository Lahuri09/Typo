import Foundation

public enum EditPreset: String, CaseIterable, Sendable {
    case proofread, punctuation, spelling, concise, business, conversational, custom

    public static let chooserActions: [Self] = [.proofread, .concise, .business, .conversational, .custom]

    public var title: String {
        switch self {
        case .proofread: "Вычитка"
        case .punctuation: "Пунктуация"
        case .spelling: "Орфография"
        case .concise: "Сократить"
        case .business: "Деловой тон"
        case .conversational: "Разговорный тон"
        case .custom: "Мой стиль"
        }
    }

    public var subtitle: String {
        switch self {
        case .proofread: "Ошибки, грамматика и пунктуация"
        case .punctuation: "Только знаки препинания"
        case .spelling: "Только написание слов"
        case .concise: "Без повторов и лишних слов"
        case .business: "Ясно и профессионально"
        case .conversational: "Проще и естественнее"
        case .custom: "Инструкция из настроек"
        }
    }

    public var icon: String {
        switch self {
        case .proofread: "text.badge.checkmark"
        case .punctuation: "text.quote"
        case .spelling: "textformat.abc"
        case .concise: "arrow.down.right.and.arrow.up.left"
        case .business: "briefcase"
        case .conversational: "bubble.left.and.text.bubble.right"
        case .custom: "slider.horizontal.3"
        }
    }

    public func instruction(custom: String, source: String = "", shortening: ShorteningStrength = .gentle) -> String {
        if self == .custom { return custom }
        if Self.isMostlyCyrillic(source) {
            let action = switch self {
            case .proofread:
                "Вычитай текст целиком. Исправь грамматику, написание слов, заглавные буквы и знаки препинания. Сохрани формулировки и факты. Пример: «мы вчера получили письмо но не ответили» → «Мы вчера получили письмо, но не ответили.»"
            case .punctuation:
                "Расставь только знаки препинания. Сохрани каждое слово, регистр букв и абзацы без изменений. Пример: «Привет как дела» → «Привет, как дела?»."
            case .spelling:
                "Исправь опечатки внутри слов. Не подбирай синонимы. Сохрани знаки препинания, пробелы, регистр и порядок слов. Пример: «Я севодня дома.» → «Я сегодня дома.»."
            case .concise:
                shortening.instruction(russian: true)
            case .business:
                """
                Перепиши исходник вежливо для рабочего чата. Убери мат, резкость и жаргон, в том числе в цитатах и словах со звёздочками. Сохрани каждый факт, число, срок, просьбу и отрицание. Не меняй, кто что сделал и что нужно сделать. Исправь ошибки и верни только отредактированный текст.
                """
            case .conversational:
                "Перепиши просто и разговорно. Сохрани смысл, факты, сроки и просьбы."
            case .custom:
                custom
            }
            return "Пиши по-русски. " + action
        }
        return switch self {
        case .proofread:
            "Correct spelling, grammar and punctuation. Keep the original wording whenever possible, and preserve meaning and tone."
        case .punctuation:
            "Correct punctuation only. Keep every word, its spelling, and its capitalization exactly unchanged. Preserve paragraph breaks."
        case .spelling:
            "Fix obvious misspellings inside words only. Preserve punctuation, whitespace, word count, word order and capitalization. Leave words that are already correctly spelled untouched."
        case .concise:
            shortening.instruction(russian: false)
        case .business:
            """
            Rewrite this as a polite professional message. Rephrase every instance of swearing, insults and coarse slang, including quotations and words masked with symbols. Remove expletive interjections. Preserve facts, names, dates, times, requests and negation.
            """
        case .conversational:
            "Rewrite in a clear, natural conversational tone. Keep facts, names and intent intact."
        case .custom:
            custom
        }
    }

    public func accepts(_ output: String, replacing source: String) -> Bool {
        guard self == .custom || (Self.isMostlyCyrillic(source) == Self.isMostlyCyrillic(output)
            && source.split { !$0.isNumber } == output.split { !$0.isNumber }) else { return false }
        return switch self {
        case .proofread:
            Self.preservesProofreadingStructure(source: source, output: output)
        case .punctuation:
            source.split { $0.isWhitespace || $0.isPunctuation }
                == output.split { $0.isWhitespace || $0.isPunctuation }
                && source.filter(\.isNewline) == output.filter(\.isNewline)
        case .spelling:
            source.filter { !$0.isLetter } == output.filter { !$0.isLetter }
                && source.split { !$0.isLetter }.count == output.split { !$0.isLetter }.count
                && zip(source.split { !$0.isLetter }, output.split { !$0.isLetter })
                    .allSatisfy { Self.isPlausibleSpellingChange($0, $1) }
        case .concise:
            output.count < source.count
        case .business:
            !Self.containsProfanity(output)
        default:
            true
        }
    }

    private static func preservesProofreadingStructure(source: String, output: String) -> Bool {
        let originalLines = source.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let editedLines = output.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        return originalLines.count == editedLines.count && zip(originalLines, editedLines).allSatisfy { original, edited in
            let originalWords = original.split(whereSeparator: \.isWhitespace).count
            let editedWords = edited.split(whereSeparator: \.isWhitespace).count
            return originalWords - editedWords <= max(1, originalWords / 10)
        }
    }

    private static let profanityPattern = #"""
    (?ix)
    (?:^|[.!?]\s+)\s*блин\s*[,!]
    |\b(?:
        (?:какого|какой|каким|ни|до)\s+хрен\p{L}*
        |(?:на|по|ни|до|за|про|о|от)?ху[йяеёию]\p{L}*
        |(?:за|про|на|вы|от|по|об|под|раз|у|с)?[ъь]?[её]б[ауыёелн]\p{L}*
        |(?:за|про|на|вы|от|по|об|под|раз|у|с)?[ъь]?[её]б[\p{P}\p{S}]{1,2}[а-яё]+
        |пизд\p{L}*|бля(?:дь|ть|дск\p{L}*)?|бл[\p{S}*](?:ть|дь)|сука|суки
        |хреново|хрень|дерьм\p{L}*|облажа\p{L}*|сран\p{L}*
        |(?:motherfuck|fuck|bullshit|shit|asshole|goddamn)\p{L}*
    )\b
    """#

    public static func containsProfanity(_ text: String) -> Bool {
        text.range(of: profanityPattern, options: .regularExpression) != nil
    }

    public static func neutralizingBusinessExpressions(in text: String) -> String {
        let substitutions: [(String, String)] = [
            (#"(?im)^([ \t]*)блин[ \t]*[,!][ \t]*"#, "$1"),
            (#"(?i),[ \t]*(?:блять|блядь|сука)[ \t]*(?=[.!?])"#, ""),
            (#"(?i)\b(это)([ \t]+будет)?[ \t]+пиздец\b"#, "$1$2 серьёзная проблема"),
            (#"(?i)\b[её]бан(?:ый|ая|ое|ые|ого|ой|ому|ую|ым|ыми|ых|ом)\b[ \t]+"#, ""),
            (#"(?i)\b(вс[её])[ \t]+про[её]бали\b"#, "$1 сделали неправильно"),
            (#"(?im)^([ \t]*)нахуй[ \t]+(эти|такие)\b"#, "$1Не нужны $2")
        ]
        let neutral = substitutions.reduce(text) { text, substitution in
            text.replacingOccurrences(of: substitution.0, with: substitution.1, options: .regularExpression)
        }
        guard neutral != text, let first = neutral.first, first.isLowercase,
              text.first?.isUppercase == true else { return neutral }
        return first.uppercased() + neutral.dropFirst()
    }

    public func removingFiller(from source: String) -> String {
        guard self == .concise else { return source }
        return source.components(separatedBy: "\n").map { line in
            let shortened = line.replacingOccurrences(
                of: #"^(?:(?:ну,?\s+)?короче,\s+)?(?:(?:на данный момент\s+)?(?:я\s+)?(?:просто\s+)?хотел[аи]?(?:\s+бы)?\s+(?:сказать|уточнить),\s+что\s+)?"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            guard shortened != line, let first = shortened.first, first.isLetter else { return line }
            return first.uppercased() + shortened.dropFirst()
        }.joined(separator: "\n")
    }

    public func fixingBasicPunctuation(in source: String) -> String {
        guard self == .proofread || self == .punctuation else { return source }
        return source.replacingOccurrences(of: #"(?<=[А-Яа-яЁё])[ \t]+(но)(?=[ \t]+[А-Яа-яЁё])"#,
                                           with: ", $1", options: [.regularExpression, .caseInsensitive])
    }

    private static func isMostlyCyrillic(_ text: String) -> Bool {
        var cyrillic = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x052F).contains(scalar.value) { cyrillic += 1 }
            else if scalar.properties.isAlphabetic { other += 1 }
        }
        return cyrillic > other
    }

    private static func isPlausibleSpellingChange(_ original: Substring, _ edited: Substring) -> Bool {
        if original == edited { return true }
        let before = Array(original)
        let after = Array(edited)
        guard abs(before.count - after.count) <= 2,
              before.first?.isUppercase == after.first?.isUppercase else { return false }
        let limit = before.count < 5 ? 1 : 2
        var previous = Array(0...after.count)
        for (index, letter) in before.enumerated() {
            var row = [index + 1]
            for (column, editedLetter) in after.enumerated() {
                row.append(min(previous[column + 1] + 1, row[column] + 1,
                               previous[column] + (letter == editedLetter ? 0 : 1)))
            }
            if row.allSatisfy({ $0 > limit }) { return false }
            previous = row
        }
        return previous[after.count] <= limit
    }
}
