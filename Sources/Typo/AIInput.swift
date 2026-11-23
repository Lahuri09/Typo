import AppKit
import AVFoundation
import TypoCore

@Observable
final class AIInput {
    enum Phase { case idle, choosingEdit, refiningEdit, preparing, recording, processing }
    typealias Delivery = (String, @escaping (Bool) -> Void) -> Void
    struct EditTarget {
        let isCurrent: () -> Bool
        let deliver: Delivery
        let afterReplacing: (String) -> EditTarget?
    }

    private struct EditOperation {
        let text: String
        let action: EditAction
        let shortening: ShorteningStrength
        let cloud: CloudEditor.Configuration?
    }

    private struct CompletedEdit {
        let operation: EditOperation
        let target: EditTarget
        let text: String
    }

    private(set) var phase = Phase.idle
    private(set) var hasMicrophoneAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private(set) var result: String?
    let local = LocalAI()
    let cloudEditor = CloudEditor()
    let speechModels = SpeechModels()
    let editActions = EditActionCatalog()
    let panelAppearance = PanelAppearance()
    let dictationHistory = DictationHistory()
    var shortening = UserDefaults.standard.string(forKey: "shorteningStrength")
        .flatMap(ShorteningStrength.init(rawValue:)) ?? .gentle {
        didSet { UserDefaults.standard.set(shortening.rawValue, forKey: "shorteningStrength") }
    }
    var dictationFallback = UserDefaults.standard.string(forKey: "dictationFallback")
        .flatMap(DictationFallback.init(rawValue:)) ?? .history {
        didSet { UserDefaults.standard.set(dictationFallback.rawValue, forKey: "dictationFallback") }
    }
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
        copyEditResult: { [weak self] in self?.copyResult() },
        refineEdit: { [weak self] in self?.offerRefinement() },
        submitRevision: { [weak self] in self?.reviseEdit(clarification: $0) },
        didHide: { [weak self] in self?.completedEdit = nil }
    )
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recordingSpeech: (language: String, usesGigaAM: Bool, cloud: SpeechModels.Configuration?)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var deliveryID: UUID?
    @ObservationIgnored private var recordingTimeout: Task<Void, Never>?
    @ObservationIgnored private var liveDictation: LiveDictation?
    @ObservationIgnored private var pendingEdit: (text: String, target: EditTarget)?
    @ObservationIgnored private var completedEdit: CompletedEdit?
    @ObservationIgnored private lazy var fieldSound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)

    private func microphoneLevel() -> Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 53) / 40))
    }

    func refreshMicrophoneAccess() {
        let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if hasMicrophoneAccess != granted { hasMicrophoneAccess = granted }
    }

    func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshMicrophoneAccess()
        case .notDetermined:
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refreshMicrophoneAccess()
            }
        default:
            if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(settings)
            }
        }
    }

    func startDictation(_ live: LiveDictation? = nil) {
        guard phase == .idle else { return }
        completedEdit = nil
        if live == nil && dictationFallback == .disabled { showUnavailableField(); return }
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
        hud.show(.preparing)
        result = nil
        work = Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            refreshMicrophoneAccess()
            guard !Task.isCancelled else { return }
            work = nil
            guard allowed else {
                finish("Разрешите Typo доступ к микрофону в настройках macOS.")
                return
            }
            do {
                let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
                let countdown: RecordingCountdown
                do {
                    let audio = try AVAudioRecorder(url: directory.appendingPathComponent("dictation.wav"), settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
                    ])
                    audio.isMeteringEnabled = true
                    guard audio.record() else { throw CocoaError(.fileWriteUnknown) }
                    countdown = RecordingCountdown()
                    recorder = audio
                    recordingSpeech = (language, usesGigaAM, cloud)
                    liveDictation = live
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
                phase = .recording
                inputLog.notice("Dictation recording started")
                hud.show(.recording, countdown: countdown)
                if live != nil && local.speechReady { beginPreview(language: language, usesGigaAM: usesGigaAM) }
                recordingTimeout = Task {
                    do {
                        try await Task.sleep(until: countdown.deadline, tolerance: .zero, clock: .continuous)
                    } catch { return }
                    stopDictation()
                }
            } catch {
                inputLog.error("Recorder startup error: \(String(describing: error), privacy: .public)")
                finish("Не удалось начать запись с микрофона.")
            }
        }
    }

    func cancelDictation() {
        guard phase != .idle else { hud.hide(); return }
        let wasProcessing = phase == .processing
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
        hud.hide()
    }

    func stopDictation() {
        let preview = previewTask
        guard let speech = recordingSpeech, let audio = takeRecording() else { return }
        let live = liveDictation
        let recordedBytes = (try? audio.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        inputLog.notice("Dictation recording stopped; WAV bytes=\(recordedBytes)")
        submit(.transcribing, destination: { output, completion in
            self.liveDictation = nil
            if let live { live.complete(output, completion: completion) }
            else { completion(false) }
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

    func offerEdit(_ text: String, target: EditTarget) {
        guard phase == .idle else { return }
        completedEdit = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            promptForEditSelection()
            return
        }
        let actions = editActions.enabledActions
        guard !actions.isEmpty else {
            finish("Включите хотя бы одно действие в настройках редактуры.")
            return
        }
        pendingEdit = (text, target)
        phase = .choosingEdit
        hud.show(.choosingEdit, actions: actions)
    }

    private func chooseEdit(_ action: EditAction) {
        guard phase == .choosingEdit, let edit = pendingEdit else { return }
        pendingEdit = nil
        guard edit.target.isCurrent() else {
            inputLog.notice("Edit cancelled because the selected text changed")
            finish("Выделите текст снова.")
            return
        }
        guard action.preset != .custom || !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish("Добавьте инструкцию для «\(action.name)» в настройках.")
            return
        }
        do {
            let operation = EditOperation(text: edit.text, action: action, shortening: shortening,
                                          cloud: try cloudEditor.configuration())
            runEdit(operation, in: edit.target)
        } catch {
            finish(error.localizedDescription)
        }
    }

    private func offerRefinement() {
        guard phase == .idle, let completedEdit else { return }
        guard completedEdit.target.isCurrent() else {
            self.completedEdit = nil
            finish("Текст или курсор изменились. Выделите текст снова.")
            return
        }
        phase = .refiningEdit
        hud.show(.refiningEdit)
    }

    private func reviseEdit(clarification: String?) {
        guard phase == .refiningEdit, let completedEdit else { return }
        let revision = EditRevision(previous: completedEdit.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    clarification: clarification)
        runEdit(completedEdit.operation, in: completedEdit.target, revision: revision)
    }

    private func runEdit(_ plan: EditOperation, in target: EditTarget, revision: EditRevision? = nil) {
        let previous = completedEdit
        completedEdit = nil
        let original = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = plan.text.prefix(while: \.isWhitespace)
        let trailing = String(plan.text.reversed().prefix(while: \.isWhitespace).reversed())
        submit(.rewriting, destination: target.deliver, didInsert: { output in
            self.completedEdit = target.afterReplacing(output).map {
                CompletedEdit(operation: plan, target: $0, text: output)
            }
        }, unchanged: previous) {
            if revision != nil {
                // The nonactivating panel returns keyboard focus to the original editor on closure.
                for _ in 0..<8 {
                    if target.isCurrent() { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard target.isCurrent() else { throw EditTargetChanged() }
            }
            let output = try await self.local.edit(original, preset: plan.action.preset, custom: plan.action.prompt,
                                                   shortening: plan.shortening, cloud: plan.cloud, revision: revision)
            return leading + output + trailing
        }
    }

    private struct EditTargetChanged: LocalizedError {
        var errorDescription: String? { "Текст или курсор изменились. Выделите текст снова." }
    }

    private func submit(_ status: ActivityStatus, destination: @escaping Delivery,
                        didInsert: ((String) -> Void)? = nil, unchanged: CompletedEdit? = nil,
                        operation: @escaping () async throws -> String) {
        phase = .processing
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
                        didInsert?(output)
                        let outcome: ActivityStatus = status == .transcribing ? .dictated : .inserted
                        if outcome == .dictated, self.playDictationSound { NSSound(named: "Pop")?.play() }
                        self.finish(outcome.label, status: outcome)
                    } else if status == .transcribing {
                        self.completeStandaloneDictation(output)
                    } else {
                        self.result = output
                        self.finish("Можно скопировать результат редактуры.", status: .ready)
                    }
                }
                destination(output, showOutcome)
            } catch LocalAI.Failure.noChanges {
                guard !Task.isCancelled else { return }
                work = nil
                completedEdit = unchanged
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

    private func finish(_ message: String, status: ActivityStatus? = nil, showPanel: Bool = true) {
        deliveryID = nil
        phase = .idle
        if showPanel { hud.show(status ?? .error(message), allowsRefinement: completedEdit != nil) }
        else { hud.hide() }
    }

    var canDismiss: Bool { phase != .idle || hud.status != nil }

    func promptForEditSelection() {
        guard phase == .idle else { return }
        completedEdit = nil
        finish("", status: .selectionRequired)
    }

    func showUnavailableField() {
        guard phase == .idle else { return }
        if hud.status != .fieldUnavailable {
            fieldSound?.volume = 0.27
            fieldSound?.play()
        }
        finish("", status: .fieldUnavailable)
    }

    func copyResult() {
        guard let result else { return }
        copyToClipboard(result)
        if hud.status == .ready { hud.hide() }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func completeStandaloneDictation(_ text: String) {
        switch dictationFallback {
        case .history:
            dictationHistory.add(text)
            if playDictationSound { NSSound(named: "Pop")?.play() }
            finish("", showPanel: false)
        case .clipboard:
            copyToClipboard(text)
            if playDictationSound { NSSound(named: "Pop")?.play() }
            finish(ActivityStatus.copied.label, status: .copied)
        case .disabled:
            result = text
            finish("Поле стало недоступно. Результат можно скопировать.", status: .ready)
        }
    }
}
