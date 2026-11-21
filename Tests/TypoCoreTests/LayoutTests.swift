import AppKit
import Foundation
import TypoCore

@MainActor private var checked = 0

@MainActor private func expect(_ condition: @autoclosure () -> Bool, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("Failed assertion at LayoutTests.swift:\(line)\n".utf8))
        exit(1)
    }
    checked += 1
}

@main
struct TestRunner {
    static func main() {
        convertsCaseAndPunctuation()
        automaticChecksBothLanguages()
        findsWordAtUTF16Caret()
        doublePressRequiresConsecutiveReleasedKeys()
        undoChecksCaretAndExactReplacement()
        recognizesWithMacOSDictionaries()
        expect(Editing.isCredentialLabel("current-password"))
        expect(Editing.isCredentialLabel("Имя пользователя"))
        expect(Editing.isCredentialLabel("accountUsernameField"))
        expect(!Editing.isCredentialLabel("Введите сообщение"))
        recognizesCorpusForms()
        recognizesWhileTyping()
        recognizesAfterPunctuation()
        learnsWordExceptions()
        print("Passed \(checked) assertions in 11 scenarios")
    }
}

@MainActor private func convertsCaseAndPunctuation() {
    expect(Layout.convert("Ghbdtn, vbh!") == "Приветб мир!")
    expect(Layout.convert("Руддщ Цщкдв") == "Hello World")
    expect(Layout.convert("Ёж 🙂 123") == "|; 🙂 123")
    expect(Layout.convert("ghbdtn Руддщ") == "привет Hello")
    expect(Layout.convert("\\;br\nРуддщ") == "ёжик\nHello")
    expect(Layout.convert("рштп?") == "hing?")
}

@MainActor private func automaticChecksBothLanguages() {
    let known: [Layout: Set<String>] = [.english: ["hello", "test"], .russian: ["привет", "еуые"]]
    let recognizer = LayoutRecognizer { known[$1, default: []].contains($0) }
    expect(recognizer.correction(for: "Ghbdtn") == "Привет")
    expect(recognizer.correction(for: "руддщ") == "hello")
    expect(recognizer.correction(for: "test") == nil)
    expect(recognizer.correction(for: "asdf") == nil)
    expect(recognizer.correction(for: "foo.bar") == nil)
    expect(recognizer.correction(for: "one1") == nil)
}

@MainActor private func findsWordAtUTF16Caret() {
    expect(Editing.word(before: 10, in: "🙂 ghbdtn ") == NSRange(location: 3, length: 6))
    expect(Editing.word(before: 7, in: "abc.def", skipSpaces: false) == NSRange(location: 0, length: 7))
    expect(Editing.word(before: 1, in: "🙂") == nil)
    expect(Editing.word(before: Int.max, in: "hi") == nil)
    expect(Editing.span(NSRange(location: 0, length: 1), in: "🙂") == nil)
    expect(Editing.span(NSRange(location: 1, length: 0), in: "e\u{301}") == nil)
}

@MainActor private func doublePressRequiresConsecutiveReleasedKeys() {
    var matcher = HotkeyMatcher()
    let key = Shortcut(key: 96, modifiers: 0, double: true)
    expect(!matcher.press(key, at: 1))
    expect(!matcher.press(key, at: 1.1))
    matcher.release(96)
    expect(matcher.press(key, at: 1.2))
    matcher.release(96)
    expect(!matcher.press(key, at: 2))
    matcher.release(96)
    expect(!matcher.press(key, at: 3))
    matcher.release(96)
    matcher.reset()
    expect(!matcher.press(key, at: 3.1))
}

@MainActor private func undoChecksCaretAndExactReplacement() {
    let edit = TextEdit(range: NSRange(location: 3, length: 6), original: "ghbdtn",
                        replacement: "привет", trailing: " ")
    expect(edit.reverseRange(in: "🙂 привет ", selection: NSRange(location: 10, length: 0))
            == NSRange(location: 3, length: 6))
    expect(edit.reverseRange(in: "🙂 прилет ", selection: NSRange(location: 10, length: 0)) == nil)
    expect(edit.reverseRange(in: "🙂 привет ", selection: NSRange(location: 9, length: 0)) == nil)
}

@MainActor private func recognizesWithMacOSDictionaries() {
    let spelling = NSSpellChecker.shared
    expect(spelling.availableLanguages.contains("ru"))
    expect(spelling.availableLanguages.contains("en"))
    let recognizer = LayoutRecognizer { word, layout in
        spelling.checkSpelling(of: word, startingAt: 0, language: layout == .english ? "en" : "ru",
                               wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
    expect(recognizer.correction(for: "ghbdtn") == "привет")
    expect(recognizer.correction(for: "руддщ") == "hello")
    expect(recognizer.correction(for: "hello") == nil)
    expect(recognizer.correction(for: "привет") == nil)
}

@MainActor private func recognizesCorpusForms() {
    let lexicon = LayoutLexicon.bundled
    let recognizer = LayoutRecognizer(lexicon: lexicon) { _, _ in false }
    for (word, layout) in [("девчонками", Layout.russian), ("orbiting", .english)] {
        expect(lexicon.contains(word, in: layout))
        expect(recognizer.correction(for: layout.converted(word)) == word)
        expect(recognizer.correction(for: word) == nil)
    }
    let rarerWord = Layout.english.converted("abjure")
    expect(recognizer.correctionWhileTyping(rarerWord, lastTyped: rarerWord.last!) == "abjure")
    expect(recognizer.correction(for: "asdfghjkl") == nil)
    expect(recognizer.correction(for: "ghbdtn123") == nil)
    expect(recognizer.correction(for: Layout.russian.converted("мир")) == nil)
    let original = Layout.russian.converted("девчонками")
    let guarded = LayoutRecognizer(lexicon: lexicon) { $0 == original && $1 == .english }
    expect(guarded.correction(for: original) == nil)
}

@MainActor private func recognizesWhileTyping() {
    let recognizer = LayoutRecognizer(lexicon: .bundled) { word, layout in
        layout == .russian && ["мир", Layout.english.converted("micro")].contains(word)
    }
    for text in ["ghbdtn", "руддщ"] {
        let firstCorrection = text.indices.lazy.compactMap { index in
            recognizer.correctionWhileTyping(String(text[...index]), lastTyped: text[index]).map {
                $0 + Layout.of(text)!.converted(String(text[text.index(after: index)...]))
            }
        }.first
        expect(firstCorrection == (text == "ghbdtn" ? "привет" : "hello"))
    }
    expect(recognizer.correctionWhileTyping("ghbdtn", lastTyped: "n") == "привет")
    expect(recognizer.correctionWhileTyping("руддщ", lastTyped: "щ") == "hello")
    expect(recognizer.correctionWhileTyping("ghbdtn", lastTyped: "t") == nil)
    expect(recognizer.correctionWhileTyping("vbh", lastTyped: "h") == "мир")
    expect(recognizer.correctionWhileTyping("нуы", lastTyped: "ы") == "yes")
    expect(recognizer.correctionWhileTyping("rfr", lastTyped: "r") == "как")
    expect(recognizer.correctionWhileTyping("ab", lastTyped: "b") == nil)
    expect(recognizer.correctionWhileTyping("micro", lastTyped: "o") == nil)
    expect(recognizer.correctionWhileTyping("привет", lastTyped: "т") == nil)
}

@MainActor private func recognizesAfterPunctuation() {
    let recognizer = LayoutRecognizer(lexicon: .bundled) { _, _ in false }
    for text in ["🙂 Привет,ghbdtn", "🙂 Привет.ghbdtn"] {
        let range = Editing.wordWhileTyping(before: text.utf16.count, in: text)
        expect(range == NSRange(location: text.utf16.count - 6, length: 6))
        if let range, let span = Editing.span(range, in: text) {
            expect(recognizer.correctionWhileTyping(String(text[span]), lastTyped: "n") == "привет")
        }
    }
    expect(Editing.wordWhileTyping(before: 6, in: "ghbdtn!") == NSRange(location: 0, length: 6))
    expect(Editing.wordWhileTyping(before: 6, in: "ghbdtnx") == nil)
    expect(Editing.wordWhileTyping(before: 8, in: "a/ghbdtn") == NSRange(location: 0, length: 8))
}

@MainActor private func learnsWordExceptions() {
    let recognizer = LayoutRecognizer(lexicon: .bundled) { _, _ in false }
    let unknown = "sinkerproofing"
    let typed = Layout.english.converted(unknown)
    expect(!LayoutLexicon.bundled.contains(unknown, in: .english))
    expect(recognizer.correctionWhileTyping(typed, lastTyped: typed.last!) == unknown)
    expect(recognizer.correctionWhileTyping("шинкерпрккукл", lastTyped: "л") == nil)
    expect(recognizer.correctionWhileTyping(unknown, lastTyped: "g") == nil)

    var exceptions = WordExceptions()
    exceptions.add("  NeoRendering ")
    expect(exceptions.contains("neorendering"))
    exceptions.add("two words")
    expect(!exceptions.contains("two words"))
    exceptions.recordReversal(of: typed)
    exceptions.recordReversal(of: typed.uppercased())
    expect(!exceptions.contains(typed))
    exceptions = try! JSONDecoder().decode(WordExceptions.self, from: JSONEncoder().encode(exceptions))
    exceptions.recordReversal(of: typed)
    expect(exceptions.contains(typed))
    exceptions.remove(typed)
    exceptions.recordReversal(of: typed)
    expect(!exceptions.contains(typed))
}
