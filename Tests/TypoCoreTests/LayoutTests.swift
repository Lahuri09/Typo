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
    static func main() throws {
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
        let header = Data([82, 73, 70, 70, 0, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32,
                           16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0,
                           100, 97, 116, 97, 0, 0, 0, 0])
        let snapshot = WaveSnapshot.make(header + Data(repeating: 0, count: 64_000), maxAudioBytes: 32_000)
        expect(snapshot?.count == 32_044)
        expect(snapshot.map { Array($0[40..<44]) } == [0, 125, 0, 0])
        expect(WaveSnapshot.make(header) == nil)
        let caret = NSRange(location: 7, length: 0)
        let draftRange = NSRange(location: 2, length: 5)
        expect(DictationDraft.ownedRange(in: "A Так.  B\n", selection: caret,
                                        original: "A  B", cursor: 2, draft: "Так. ") == draftRange)
        expect(DictationDraft.ownedRange(in: "A Так.  B", selection: draftRange,
                                        original: "A  B", cursor: 2, draft: "Так. ") == draftRange)
        expect(DictationDraft.ownedRange(in: "A Так.  X", selection: caret,
                                        original: "A  B", cursor: 2, draft: "Так. ") == nil)
        expect(DictationDraft.ownedRange(in: "A Так.  B", selection: NSRange(location: 0, length: 0),
                                        original: "A  B", cursor: 2, draft: "Так. ") == nil)
        let composerCaret = NSRange(location: 5, length: 0)
        expect(DictationDraft.ownedRange(in: "Привет", selection: composerCaret,
                                        original: "\n", cursor: 0, draft: "Привет",
                                        allowsMissingTerminalLineFeed: true) == nil)
        expect(DictationDraft.ownedRange(in: "Привет", selection: NSRange(location: 6, length: 0),
                                        original: "\n", cursor: 0, draft: "Привет",
                                        allowsMissingTerminalLineFeed: true) == NSRange(location: 0, length: 6))
        expect(!DictationDraft.matches("Привет", expected: "Привет\n\n", allowsMissingTerminalLineFeed: true))
        expect(DictationDraft.ownedRange(in: "До привет после", selection: NSRange(location: 9, length: 0),
                                        original: "До пример после", cursor: 3, draft: "привет",
                                        replacing: 6) == NSRange(location: 3, length: 6))
        let update = DictationDraft.change(from: "Привет 👋!", to: "Привет 👋 всем", at: 2)
        expect(update.range == NSRange(location: 11, length: 1) && update.text == " всем")
        try buildsAIRequestsAndDecodesResponses()
        try runCloudEditorChecks { expect($0) }
        try runSpeechModelChecks { expect($0) }
        runEditActionChecks { expect($0) }
        let panelBounds = CGRect(x: -900, y: 28, width: 800, height: 620)
        let panelSize = CGSize(width: 300, height: 84)
        let position = PanelPosition(horizontal: 0.25, vertical: 0.75)
        let panelFrame = position.windowFrame(size: panelSize, in: panelBounds)
        expect(panelFrame == CGRect(x: -775, y: 162, width: 300, height: 84))
        expect(PanelPosition(center: CGPoint(x: panelFrame.midX, y: panelFrame.midY),
                             size: panelSize, in: panelBounds) == position)
        let clamped = PanelPosition(center: CGPoint(x: -1_000, y: 1_000), size: panelSize, in: panelBounds)
        expect(clamped == PanelPosition(horizontal: 0, vertical: 0))
        let obstacle = CGRect(x: -525, y: 172, width: 75, height: 50)
        let clear = position.windowFrame(size: panelSize, in: panelBounds, avoiding: obstacle)
        expect(clear == CGRect(x: -829, y: 162, width: 300, height: 84))
        let wide = position.windowFrame(size: CGSize(width: 900, height: 900), in: panelBounds,
                                        avoiding: CGRect(x: -225, y: 28, width: 125, height: 100))
        expect(wide == CGRect(x: -900, y: 132, width: 800, height: 516))
        expect(EditPreset.chooserActions.prefix(2).elementsEqual([.proofread, .concise]))
        expect(!EditPreset.chooserActions.contains(.punctuation) && !EditPreset.chooserActions.contains(.spelling))
        expect(EditPreset.punctuation.accepts("Привет, как дела?", replacing: "Привет как дела"))
        expect(!EditPreset.punctuation.accepts("Привет, как дела?", replacing: "Привет как поживаешь"))
        expect(!EditPreset.punctuation.accepts("Привет, как дела?", replacing: "Привет\nкак дела"))
        expect(EditPreset.spelling.accepts("Я сегодня дома.", replacing: "Я севодня дома."))
        expect(!EditPreset.spelling.accepts("Я сегодня дома!", replacing: "Я севодня дома."))
        expect(!EditPreset.spelling.accepts("Я дома.", replacing: "Я севодня дома."))
        expect(!EditPreset.spelling.accepts("Я сижу дома.", replacing: "Я севодня дома."))
        expect(!EditPreset.business.accepts("Send the report.", replacing: "Пришли отчёт."))
        expect(!EditPreset.business.accepts("Отчёт, блядь, нужен к 16:00.", replacing: "Скинь отчёт к 16:00."))
        expect(!EditPreset.business.accepts("Я заебался переделывать отчёт.", replacing: "Я устал переделывать отчёт."))
        expect(!EditPreset.business.accepts("Fix the fucking form.", replacing: "Fix the form."))
        expect(EditPreset.business.accepts("Подстрахуй меня и отправь отчёт.", replacing: "Помоги отправить отчёт."))
        expect(!EditPreset.concise.accepts("Отчёт до 17:00.", replacing: "Отправь отчёт до 14:00."))
        expect(EditPreset.concise.removingFiller(from: "Короче, я просто хотел сказать, что отчёт нужен завтра.")
               == "Отчёт нужен завтра.")
        expect(EditPreset.concise.removingFiller(from: "Я хотел предупредить, что отчёт нужен завтра.")
               == "Я хотел предупредить, что отчёт нужен завтра.")
        expect(EditPreset.proofread.fixingBasicPunctuation(in: "мы получили письмо но не ответили")
               == "мы получили письмо, но не ответили")
        expect(EditPreset.custom.accepts("Send the report.", replacing: "Пришли отчёт."))
        expect(EditPreset.custom.instruction(custom: "Моя инструкция") == "Моя инструкция")
        expect(AIRequest.cleanTranscript("  [BLANK_AUDIO]\n") == "")
        expect(AIRequest.cleanTranscript("[blank_audio] ...") == "")
        expect(AIRequest.cleanTranscript("Привет [BLANK_AUDIO] мир!") == "Привет мир!")
        expect(AIRequest.cleanTranscript("Hello, world!") == "Hello, world!")
        expect(AIRequest.cleanTranscript("Первая часть.\nВторая строка\nи конец.") == "Первая часть. Вторая строка и конец.")
        print("Passed \(checked) assertions in 12 scenarios")
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

@MainActor private func buildsAIRequestsAndDecodesResponses() throws {
    let text = "Привет! 🙂"
    let endpoint = URL(string: "http://127.0.0.1:11439")!
    let rewrite = try AIRequest.rewrite(text, instruction: "Перепиши короче", endpoint: endpoint)
    let body = try JSONSerialization.jsonObject(with: rewrite.httpBody!) as? [String: Any]
    let messages = body?["messages"] as? [[String: String]]
    expect(rewrite.url?.absoluteString == "http://127.0.0.1:11439/api/chat")
    expect(rewrite.httpMethod == "POST")
    expect(rewrite.value(forHTTPHeaderField: "Authorization") == nil)
    expect(body?["model"] as? String == AIRequest.model)
    expect(body?["stream"] as? Bool == false)
    expect(messages?.first?["content"]?.contains("Перепиши короче") == true)
    expect((body?["format"] as? [String: Any])?["required"] as? [String] == ["edited"])
    expect(body?["think"] as? Bool == false)
    let input = try JSONDecoder().decode([String: String].self, from: Data((messages?.last?["content"] ?? "").utf8))
    expect(input["source"] == text)
    expect(AIRequest.isConversationalRefusal("Я не могу продолжить разговор.", source: "Сократи меня."))
    expect(!AIRequest.isConversationalRefusal("Я не могу прийти.", source: "Я не могу прийти сегодня."))
    expect(!EditPreset.concise.accepts("Привет, как у тебя дела?", replacing: "Привет, как дела?"))

    let rewritten = try AIRequest.result(from: Data(#"{"message":{"content":"{\"edited\":\"  Исправлено  \"}"}}"#.utf8))
    let empty = try AIRequest.result(from: Data(#"{"message":{"content":"{\"edited\":\"   \"}"}}"#.utf8))
    expect(rewritten == "Исправлено")
    expect(empty.isEmpty)
}
