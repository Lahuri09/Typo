import AppKit
import AVFoundation
import TypoCore

@Observable
final class AIInput {
    enum Phase { case idle, choosingEdit, preparing, recording, processing }
    typealias Delivery = (String, @escaping (Bool) -> Void) -> Void

    private(set) var phase = Phase.idle
    private(set) var message = ""
    private(set) var result: String?
    let local = LocalAI()
    let cloudEditor = CloudEditor()
    let speechModels = SpeechModels()
    let editActions = EditActionCatalog()
    let panelAppearance = PanelAppearance()
    @ObservationIgnored private lazy var previewEngine = LocalAI()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    var speechLanguage = UserDefaults.standard.string(forKey: "speechLanguage")
        ?? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "auto") {
        didSet { UserDefaults.standard.set(speechLanguage, forKey: "speechLanguage") }
    }
    var playEditSound = UserDefaults.standard.bool(forKey: "playEditSound") {
        didSet { UserDefaults.standard.set(playEditSound, forKey: "playEditSound") }
    }
    var playDictationSound = UserDefaults.standard.bool(forKey: "playDictationSound") {
        didSet { UserDefaults.standard.set(playDictationSound, forKey: "playDictationSound") }
    }
    var usesGigaAM = UserDefaults.standard.object(forKey: "usesGigaAM") as? Bool ?? true {
        didSet { UserDefaults.standard.set(usesGigaAM, forKey: "usesGigaAM") }
    }
    @ObservationIgnored private lazy var hud = ActivityHUD(
        appearance: panelAppearance,
        level: { [weak self] in self?.microphoneLevel() ?? 0 },
        cancel: { [weak self] in self?.cancelDictation() },
        complete: { [weak self] in self?.stopDictation() },
        chooseEdit: { [weak self] in self?.chooseEdit($0) },
        copyEditResult: { [weak self] in self?.copyResult() }
    )
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recordingSpeech: (language: String, usesGigaAM: Bool, cloud: SpeechModels.Configuration?)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var deliveryID: UUID?
    @ObservationIgnored private var recordingTimeout: Task<Void, Never>?
    @ObservationIgnored private var liveDictation: LiveDictation?
    @ObservationIgnored private var pendingEdit: (text: String, isCurrent: () -> Bool, deliver: Delivery)?

    private func microphoneLevel() -> Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 53) / 40))
    }

    func startDictation(_ live: LiveDictation) {
        guard phase == .idle else { return }
        let cloud: SpeechModels.Configuration?
        do { cloud = try speechModels.configuration() }
        catch { finish(error.localizedDescription); return }
        guard cloud != nil || local.speechReady else {
            finish(LocalAI.Failure.missingSpeech.localizedDescription)
            return
        }
        let language = speechLanguage
        let usesGigaAM = usesGigaAM
        phase = .preparing
        message = "Подготовка микрофона…"
        hud.show(.preparing)
        result = nil
        work = Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled else { return }
            work = nil
            guard allowed else {
                finish("Разрешите Typo доступ к микрофону в настройках macOS.")
                return
            }
            do {
                let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
                do {
                    let audio = try AVAudioRecorder(url: directory.appendingPathComponent("dictation.wav"), settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
                    ])
                    audio.isMeteringEnabled = true
                    guard audio.record() else { throw CocoaError(.fileWriteUnknown) }
                    recorder = audio
                    recordingSpeech = (language, usesGigaAM, cloud)
                    liveDictation = live
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
                phase = .recording
                message = "Идёт запись…"
                inputLog.notice("Dictation recording started")
                hud.show(.recording)
                if local.speechReady { beginPreview(language: language, usesGigaAM: usesGigaAM) }
                recordingTimeout = Task {
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    stopDictation()
                }
            } catch {
                inputLog.error("Recorder startup error: \(String(describing: error), privacy: .public)")
                finish("Не удалось начать запись с микрофона.")
            }
        }
    }

    func cancelDictation(message: String = "Запись отменена.") {
        guard phase != .idle else { hud.hide(); return }
        let wasProcessing = phase == .processing
        let wasChoosingEdit = phase == .choosingEdit
        pendingEdit = nil
        deliveryID = nil
        work?.cancel()
        work = nil
        if wasProcessing { local.cancelTranscription() }
        let preview = previewTask
        let live = liveDictation
        liveDictation = nil
        if let audio = takeRecording() {
            try? FileManager.default.removeItem(at: audio.url.deletingLastPathComponent())
        }
        if let live {
            Task {
                await preview?.value
                live.cancel()
            }
        }
        phase = .idle
        if wasChoosingEdit { self.message = "" }
        else { self.message = wasProcessing ? "Обработка отменена." : message }
        hud.hide()
    }

    func stopDictation() {
        let preview = previewTask
        guard let speech = recordingSpeech, let live = liveDictation, let audio = takeRecording() else { return }
        let recordedBytes = (try? audio.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        inputLog.notice("Dictation recording stopped; WAV bytes=\(recordedBytes)")
        submit(.transcribing, destination: { output, completion in
            self.liveDictation = nil
            live.complete(output, completion: completion)
        }) {
            defer { try? FileManager.default.removeItem(at: audio.url.deletingLastPathComponent()) }
            let output: String
            if let cloud = speech.cloud {
                output = if try await LocalAI.hasAudibleSignal(audio.url) {
                    try await SpeechModels.transcribe(audio.url, language: speech.language, configuration: cloud)
                } else { "" }
            } else {
                output = try await self.local.transcribe(audio.url, language: speech.language, usesGigaAM: speech.usesGigaAM)
            }
            inputLog.notice("Final speech recognized, length=\(output.utf16.count)")
            await preview?.value
            return output
        }
    }

    private func beginPreview(language: String, usesGigaAM: Bool) {
        previewTask = Task { [weak self] in
            var interval = Duration.milliseconds(1100)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, let recorder = self.recorder else { return }
                if recorder.currentTime > 40 { interval = .milliseconds(2200) }
                let previewURL = recorder.url.deletingLastPathComponent().appending(path: "preview.wav")
                guard let raw = try? Data(contentsOf: recorder.url),
                      let snapshot = WaveSnapshot.make(raw, maxAudioBytes: raw.count),
                      (try? snapshot.write(to: previewURL, options: .atomic)) != nil else { continue }
                let text: String
                do {
                    text = try await self.previewEngine.transcribe(previewURL, language: language,
                                                                   preview: true, usesGigaAM: usesGigaAM)
                } catch {
                    if !Task.isCancelled { inputLog.error("Live speech recognition failed: \(String(describing: error), privacy: .public)") }
                    continue
                }
                guard !Task.isCancelled else { return }
                if !text.isEmpty, self.phase == .recording {
                    inputLog.debug("Speech preview recognized, length=\(text.utf16.count)")
                    await self.liveDictation?.preview(text)
                }
            }
        }
    }

    private func takeRecording() -> AVAudioRecorder? {
        guard let audio = recorder else { return nil }
        previewTask?.cancel()
        previewTask = nil
        previewEngine.cancelTranscription()
        recordingTimeout?.cancel()
        recordingTimeout = nil
        audio.stop()
        recorder = nil
        recordingSpeech = nil
        return audio
    }

    func offerEdit(_ text: String, isCurrent: @escaping () -> Bool, destination: @escaping Delivery) {
        guard phase == .idle else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish("Выделите текст для обработки.")
            return
        }
        let actions = editActions.enabledActions
        guard !actions.isEmpty else {
            finish("Включите хотя бы одно действие в настройках редактуры.")
            return
        }
        pendingEdit = (text, isCurrent, destination)
        phase = .choosingEdit
        message = ActivityStatus.choosingEdit.label
        hud.show(.choosingEdit, actions: actions)
    }

    private func chooseEdit(_ action: EditAction) {
        guard phase == .choosingEdit, let edit = pendingEdit else { return }
        pendingEdit = nil
        guard edit.isCurrent() else {
            inputLog.notice("Edit cancelled because the selected text changed")
            finish("Выделите текст снова.")
            return
        }
        let original = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = edit.text.prefix(while: \.isWhitespace)
        let trailing = String(edit.text.reversed().prefix(while: \.isWhitespace).reversed())
        let instruction = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action.preset != .custom || !instruction.isEmpty else {
            finish("Добавьте инструкцию для «\(action.name)» в настройках.")
            return
        }
        submit(.rewriting, destination: edit.deliver) {
            let output = try await self.local.edit(original, preset: action.preset, custom: instruction,
                                                   cloud: self.cloudEditor.configuration())
            return leading + output + trailing
        }
    }

    private func submit(_ status: ActivityStatus, destination: @escaping Delivery,
                        operation: @escaping () async throws -> String) {
        phase = .processing
        message = status.label
        hud.show(status)
        result = nil
        let id = UUID()
        deliveryID = id
        work = Task {
            do {
                let output = try await operation()
                guard !Task.isCancelled else { return }
                work = nil
                guard !output.isEmpty else {
                    liveDictation = nil
                    finish(status == .transcribing ? "Речь не распознана." : "Модель вернула пустой результат.")
                    return
                }
                let showOutcome: (Bool) -> Void = { inserted in
                    guard self.deliveryID == id else { return }
                    if status == .rewriting, self.playEditSound { NSSound(named: "Tink")?.play() }
                    if inserted {
                        let outcome: ActivityStatus = status == .transcribing ? .dictated : .inserted
                        if outcome == .dictated, self.playDictationSound { NSSound(named: "Pop")?.play() }
                        self.finish(outcome.label, status: outcome)
                    } else if status == .transcribing {
                        self.finish("Не удалось вставить диктовку в исходное поле.")
                    } else {
                        self.result = output
                        self.finish("Можно скопировать результат редактуры.", status: .ready)
                    }
                }
                destination(output, showOutcome)
            } catch LocalAI.Failure.noChanges {
                guard !Task.isCancelled else { return }
                work = nil
                finish(ActivityStatus.unchanged.label, status: .unchanged)
            } catch {
                guard !Task.isCancelled else { return }
                work = nil
                liveDictation = nil
                inputLog.error("AI operation failed: \(String(describing: error), privacy: .public)")
                finish(error.localizedDescription)
            }
        }
    }

    private func finish(_ message: String, status: ActivityStatus? = nil) {
        deliveryID = nil
        phase = .idle
        self.message = message
        hud.show(status ?? .error(message))
    }

    var canDismiss: Bool { phase != .idle || hud.status != nil }

    func showUnavailableField() {
        guard phase == .idle else { return }
        finish("Выберите доступное текстовое поле.")
    }

    func copyResult() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        message = "Результат скопирован."
        if hud.status == .ready { hud.hide() }
    }
}
