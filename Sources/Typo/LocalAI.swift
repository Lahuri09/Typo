import AppKit
import AVFoundation
import Foundation
import TypoCore

final class LocalAI {
    enum Failure: LocalizedError {
        case missingSpeech, missingEditor, transcription, transcriptionTimeout, editor, invalidEdit, noChanges

        var errorDescription: String? {
            switch self {
            case .missingSpeech: "Whisper не найден. Установите полную сборку Typo."
            case .missingEditor: "Qwen не найден. Установите полную сборку Typo."
            case .transcription: "Не удалось распознать запись."
            case .transcriptionTimeout: "Распознавание заняло слишком много времени."
            case .editor: "Локальная модель недоступна. Проверьте установку Ollama и Qwen."
            case .invalidEdit: "Модель не вернула подходящую правку."
            case .noChanges: "Текст уже в порядке."
            }
        }
    }

    private let support = URL.applicationSupportDirectory.appending(path: "Typo/LocalAI")
    private let bundled: URL?
    nonisolated private static let editorManifest = "manifests/registry.ollama.ai/library/qwen2.5/1.5b"
    init(bundled: URL? = Bundle.main.resourceURL?.appending(path: "LocalAI")) {
        self.bundled = bundled
    }

    private var speechRuntime: URL {
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.appending(path: "whisper-cli").path) {
            return bundled
        }
        return support
    }

    let smallModel = SmallModel()
    private var speechModel: URL { speechRuntime.appending(path: "ggml-base.bin") }
    private var russianRuntime: URL? {
        [bundled, support].compactMap { $0?.appending(path: "GigaAM") }.first { directory in
            FileManager.default.isExecutableFile(atPath: directory.appending(path: "sherpa-onnx-offline").path)
                && FileManager.default.fileExists(atPath: directory.appending(path: "model.int8.onnx").path)
                && FileManager.default.fileExists(atPath: directory.appending(path: "tokens.txt").path)
                && FileManager.default.fileExists(atPath: directory.appending(path: "libonnxruntime.dylib").path)
        }
    }
    var russianSpeechReady: Bool { russianRuntime != nil }

    private var editorRuntime: URL {
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.appending(path: "ollama").path) {
            return bundled
        }
        return support
    }
    private let endpoint = URL(string: "http://127.0.0.1:\(Int.random(in: 49152...65535))")!
    private let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return configuration
    }(), delegate: LoopbackOnly(), delegateQueue: nil)
    private var server: Process?
    private var speechProcess: Process?
    var speechReady: Bool {
        FileManager.default.isExecutableFile(atPath: speechRuntime.appending(path: "whisper-cli").path)
            && FileManager.default.fileExists(atPath: speechModel.path)
    }
    var editorReady: Bool {
        FileManager.default.isExecutableFile(atPath: editorRuntime.appending(path: "ollama").path)
            && FileManager.default.fileExists(atPath: editorRuntime.appending(path: "ollama-models")
                .appending(path: Self.editorManifest).path)
    }

    func cancelTranscription() {
        if let speechProcess, speechProcess.isRunning { speechProcess.terminate() }
    }

    func stop() {
        cancelTranscription()
        if let server, server.isRunning { server.terminate() }
    }

    func transcribe(_ audio: URL, language: String, preview: Bool = false, usesGigaAM: Bool = true) async throws -> String {
        try Task.checkCancellation()
        guard speechReady else { throw Failure.missingSpeech }
        guard try await Self.hasAudibleSignal(audio) else { return "" }
        if usesGigaAM, language == "ru", let runtime = russianRuntime {
            do {
                let text = try await decodeRussian(audio, runtime: runtime)
                if preview || !text.isEmpty { return text }
            } catch {
                try Task.checkCancellation()
            }
            inputLog.notice("GigaAM returned no usable transcription; trying Whisper")
        }
        let useSmall = !preview && smallModel.installed && smallModel.variant == .small
        let preferred = useSmall ? smallModel.file : speechModel
        let text = try await decodeSpeech(audio, language: language, model: preferred, preview: preview)
        if !preview, text.isEmpty, smallModel.installed {
            let fallback = useSmall ? speechModel : smallModel.file
            inputLog.notice("Speech model returned no words; trying the other installed model")
            return try await decodeSpeech(audio, language: language, model: fallback, preview: false)
        }
        return text
    }

    private func decodeRussian(_ audio: URL, runtime: URL) async throws -> String {
        let result = audio.appendingPathExtension("giga.json")
        guard FileManager.default.createFile(atPath: result.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw Failure.transcription }
        defer { try? FileManager.default.removeItem(at: result) }
        let stream = try FileHandle(forWritingTo: result)
        defer { try? stream.close() }
        let process = Process()
        process.executableURL = runtime.appending(path: "sherpa-onnx-offline")
        process.arguments = ["--print-args=false", "--num-threads=4", "--feat-dim=64",
                             "--nemo-ctc-model=\(runtime.appending(path: "model.int8.onnx").path)",
                             "--tokens=\(runtime.appending(path: "tokens.txt").path)", audio.path]
        process.standardOutput = stream
        process.standardError = FileHandle.nullDevice
        try await runSpeech(process)
        struct Result: Decodable { let text: String }
        return AIRequest.cleanTranscript(try JSONDecoder().decode(Result.self, from: Data(contentsOf: result)).text)
    }

    private func decodeSpeech(_ audio: URL, language: String, model: URL, preview: Bool) async throws -> String {
        try Task.checkCancellation()
        let output = audio.deletingPathExtension()
        let process = Process()
        process.executableURL = speechRuntime.appending(path: "whisper-cli")
        process.arguments = ["-m", model.path, "-f", audio.path,
                             "-l", language, "-otxt", "-of", output.path, "-np", "-ng",
                             "-t", String(min(6, ProcessInfo.processInfo.activeProcessorCount)),
                             "-bo", "1", "-bs", preview ? "1" : "2"]
        if preview { process.arguments?.append("-nf") }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await runSpeech(process)
        let rawText = try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8)
        return AIRequest.cleanTranscript(rawText)
    }

    private func runSpeech(_ process: Process) async throws {
        try Task.checkCancellation()
        speechProcess = process
        var timedOut = false
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        defer {
            timeout.cancel()
            if speechProcess === process { speechProcess = nil }
        }
        let status = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try Task.checkCancellation()
        if timedOut { throw Failure.transcriptionTimeout }
        guard status == 0 else { throw Failure.transcription }
    }

    @concurrent static func hasAudibleSignal(_ url: URL) async throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(file.processingFormat.sampleRate * 0.02)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else { throw Failure.transcription }
        var audibleFrames = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            let count = Int(buffer.frameLength)
            let energy = (0..<count).reduce(Float.zero) { $0 + samples[$1] * samples[$1] }
            if energy / Float(count) >= 0.00001 {
                audibleFrames += 1
                if audibleFrames == 4 { return true }
            }
        }
        return false
    }

    func edit(_ original: String, preset: EditPreset, custom: String, shortening: ShorteningStrength = .gentle,
              cloud: CloudEditor.Configuration? = nil, revision: EditRevision? = nil) async throws -> String {
        if preset == .concise, cloud == nil, revision == nil, original.utf16.count > 2_600 {
            let text = shortening.removingRepeatedParagraphs(in: original)
            if text.utf16.count > 2_600 {
                let groups = ShorteningStrength.paragraphGroups(in: text)
                if groups.count > 1 {
                    var edited: [String] = []
                    for group in groups {
                        try Task.checkCancellation()
                        let replacement: String
                        do {
                            replacement = try await editSelection(group, preset: preset, custom: custom,
                                                                  shortening: shortening, cloud: nil, revision: nil)
                        } catch Failure.noChanges, Failure.invalidEdit {
                            replacement = group
                        }
                        edited.append(replacement)
                    }
                    let output = edited.joined(separator: "\n\n")
                    if shortening.accepts(output, replacing: original) { return output }
                    if shortening.accepts(text, replacing: original) { return text }
                    throw Failure.invalidEdit
                }
            }
        }
        return try await editSelection(original, preset: preset, custom: custom, shortening: shortening,
                                       cloud: cloud, revision: revision)
    }

    private func editSelection(_ original: String, preset: EditPreset, custom: String, shortening: ShorteningStrength,
                               cloud: CloudEditor.Configuration?, revision: EditRevision?) async throws -> String {
        try Task.checkCancellation()
        let appliesStyle = [.concise, .business, .conversational, .custom].contains(preset)
        let business = preset == .business
        let input = business ? EditPreset.neutralizingBusinessExpressions(in: original) : original
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidEdit }
        let prepared = preset == .punctuation ? input : Self.correctSpelling(input, preservingProfanity: business)
        let punctuation = appliesStyle ? EditPreset.proofread : preset
        let corrected = punctuation.fixingBasicPunctuation(in: prepared)
        let source = switch preset {
        case .business: EditPreset.concise.removingFiller(from: corrected)
        case .concise: preset.removingFiller(from: shortening.removingRepeatedParagraphs(in: corrected))
        default: corrected
        }
        if preset == .spelling, revision == nil {
            guard source != original else { throw Failure.noChanges }
            return source
        }
        if cloud == nil, preset == .concise, shortening == .gentle, revision == nil,
           shortening.accepts(source, replacing: original) {
            return source
        }

        var unchanged = false
        var backendError: Error?
        let styleInstruction = preset.instruction(custom: custom, source: source, shortening: shortening)
        let writingInstruction = "Correct spelling, grammar, capitalization and punctuation in the result. Preserve the meaning, facts and point of view, and adjust the tone only as requested by the editing rule."
        let instruction = switch preset {
        case .custom:
            "\(writingInstruction) Keep the original word order where possible and punctuate complete sentences.\nEditing style: \(styleInstruction)"
        case .concise, .conversational:
            "\(styleInstruction)\n\(writingInstruction)"
        default:
            styleInstruction
        }
        let retry = preset == .proofread
            ? instruction + "\nCheck punctuation and sentence capitalization even if spelling is already correct."
            : instruction + "\nReturn only the edited source. Follow the editing rule, keep the original facts and point of view."
        let hasLongProofreadFallback = preset == .proofread && source.utf16.count > 4_000 && source != original
        func accepts(_ text: String) -> Bool {
            preset == .concise ? shortening.accepts(text, replacing: original) : preset.accepts(text, replacing: original)
        }
        for rule in cloud == nil && !hasLongProofreadFallback ? [instruction, retry] : [instruction] {
            do {
                let output = if let cloud {
                    try await CloudEditor.rewrite(source, instruction: rule, configuration: cloud, revision: revision)
                } else {
                    try await rewrite(source, instruction: rule, revision: revision)
                }
                let neutral = business ? EditPreset.neutralizingBusinessExpressions(in: output) : output
                let polished = appliesStyle
                    ? punctuation.fixingBasicPunctuation(in: Self.correctSpelling(neutral, preservingProfanity: business))
                    : output
                let edited = preset.removingFiller(from: polished)
                if !edited.isEmpty, !AIRequest.isConversationalRefusal(edited, source: original),
                   accepts(edited) {
                    if let revision {
                        if edited != revision.previous { return edited }
                    } else if edited != source, edited != original { return edited }
                    unchanged = true
                }
            } catch is DecodingError {
                continue
            } catch {
                try Task.checkCancellation()
                if cloud != nil { throw error }
                backendError = error
                break
            }
        }
        let fallback = preset.removingFiller(from: source)
        if revision == nil, let resolved = EditFallback.resolve(original: original, prepared: fallback,
                                                                 preset: preset) { return resolved }
        if unchanged { throw Failure.noChanges }
        if let backendError { throw backendError }
        // A local model can return an unsafe rewrite even after the guarded retry. Do not surface
        // that as a broken request: keep the selected text intact and report that there were no safe changes.
        throw Failure.noChanges
    }

    private static func correctSpelling(_ text: String, preservingProfanity: Bool) -> String {
        let checker = NSSpellChecker.shared
        let words = text.ranges(of: /\b[A-Za-zА-Яа-яЁё]{3,}\b/)
        var output = text
        for range in words.reversed() {
            let word = String(text[range])
            // Redirect profanity to the business rewrite, before the spellchecker can reinterpret it.
            if preservingProfanity, EditPreset.containsProfanity(word) { continue }
            guard let layout = Layout.of(word) else { continue }
            let language = layout == .russian ? "ru" : "en"
            let fullWord = NSRange(location: 0, length: word.utf16.count)
            guard let correction = checker.correction(forWordRange: fullWord, in: word, language: language,
                                                       inSpellDocumentWithTag: 0) else { continue }
            let suggestions = ([correction] + (checker.guesses(forWordRange: fullWord, in: word, language: language,
                                                                inSpellDocumentWithTag: 0) ?? [])).filter {
                EditPreset.spelling.accepts($0, replacing: word)
                    && LayoutLexicon.bundled.supportsSpellingChange(from: word, to: $0, in: layout)
            }
            guard let best = suggestions.first(where: { $0.first == word.first }) ?? suggestions.first,
                  let target = Range(NSRange(range, in: text), in: output) else { continue }
            output.replaceSubrange(target, with: best)
        }
        return output
    }

    private func rewrite(_ text: String, instruction: String, revision: EditRevision? = nil) async throws -> String {
        try Task.checkCancellation()
        guard editorReady else { throw Failure.missingEditor }
        if server?.isRunning != true {
            let runtime = editorRuntime
            let source = runtime.appending(path: "ollama-models")
            let models = if runtime == support { source }
                else { try await Self.stageEditorModels(source, in: support) }
            try Task.checkCancellation()
            if server?.isRunning != true { try startEditor(runtime: runtime, models: models) }
        }
        var health = URLRequest(url: endpoint.appending(path: "api/version"), timeoutInterval: 1)
        health.cachePolicy = .reloadIgnoringLocalCacheData
        for _ in 0..<40 {
            guard server?.isRunning == true else { break }
            if let (_, response) = try? await session.data(for: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                let request = try AIRequest.rewrite(text, instruction: instruction, endpoint: endpoint, revision: revision)
                let (data, result) = try await session.data(for: request)
                guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.editor }
                return try AIRequest.result(from: data)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.editor
    }

    private func startEditor(runtime: URL, models: URL) throws {
        let process = Process()
        process.executableURL = runtime.appending(path: "ollama")
        process.arguments = ["serve"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "OLLAMA_HOST": endpoint.absoluteString,
            "OLLAMA_MODELS": models.path,
            "OLLAMA_NO_CLOUD": "1",
            "OLLAMA_NOPRUNE": "1",
            "OLLAMA_KEEP_ALIVE": "2m"
        ]) { _, local in local }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
    }

    @concurrent private static func stageEditorModels(_ source: URL, in support: URL) async throws -> URL {
        let files = FileManager.default
        let destination = support.appending(path: "bundled-qwen2.5-1.5b")
        let manifest = destination.appending(path: editorManifest)
        if files.fileExists(atPath: manifest.path) { return destination }
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        let staging = support.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        // Ollama writes model metadata. Keep its writable copy outside the signed app.
        try files.copyItem(at: source, to: staging)
        do { try files.moveItem(at: staging, to: destination) }
        catch { guard files.fileExists(atPath: manifest.path) else { throw error } }
        return destination
    }
}

private final class LoopbackOnly: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
