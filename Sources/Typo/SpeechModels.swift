import Foundation
import Security
import SwiftUI
import TypoCore

@Observable
final class SpeechModels {
    struct Profile: Codable, Equatable {
        var provider: SpeechModelProvider
        var baseURL = ""
        var model = ""
    }

    struct Configuration {
        fileprivate let provider: SpeechModelProvider
        fileprivate let endpoint: URL
        fileprivate let model: String
        fileprivate let key: String
    }

    private struct Preferences: Codable {
        var active: SpeechModelProvider = .local
        var profiles: [SpeechModelProvider: Profile] = [:]
    }

    private static let settingsKey = "speechModelPreferences"
    private static let keychainService = "local.typo.Switcher.speech"
    private var preferences: Preferences
    var profile: Profile { profile(for: preferences.active) }

    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 90
        return configuration
    }(), delegate: RejectSpeechRedirects(), delegateQueue: nil)

    init() {
        preferences = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }

    func profile(for provider: SpeechModelProvider) -> Profile {
        preferences.profiles[provider] ?? Profile(provider: provider, model: provider.defaultModel)
    }

    func configuration() throws -> Configuration? {
        try configuration(for: profile, enteredKey: "")
    }

    func save(_ draft: Profile, enteredKey: String) throws {
        var updated = preferences
        updated.active = draft.provider
        let cleanKey = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = try configuration(for: draft, enteredKey: cleanKey)
        if let configuration {
            let baseURL = draft.provider == .compatible ? configuration.endpoint.absoluteString : ""
            updated.profiles[draft.provider] = Profile(provider: draft.provider, baseURL: baseURL,
                                                       model: configuration.model)
        }
        let encoded = try JSONEncoder().encode(updated)
        if let configuration, !cleanKey.isEmpty {
            try Self.saveKey(cleanKey, for: configuration.provider, endpoint: configuration.endpoint)
        }
        UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
        preferences = updated
    }

    static func transcribe(_ audio: URL, language: String, configuration: Configuration,
                           session: URLSession = SpeechModels.session) async throws -> String {
        try Task.checkCancellation()
        guard let size = try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { throw SpeechModelError.audio }
        guard size <= SpeechModelRequest.maxAudioBytes else { throw SpeechModelError.audioTooLarge }
        guard let bytes = try? Data(contentsOf: audio) else { throw SpeechModelError.audio }
        let request = try SpeechModelRequest.transcription(bytes, language: language,
                                                            provider: configuration.provider,
                                                            endpoint: configuration.endpoint,
                                                            model: configuration.model, key: configuration.key)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw SpeechModelError.connection
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SpeechModelError.badResponse }
        return try SpeechModelRequest.result(from: data, status: http.statusCode)
    }

    private func configuration(for draft: Profile, enteredKey: String) throws -> Configuration? {
        guard draft.provider != .local else { return nil }
        let endpoint = try draft.provider.endpoint(baseURL: draft.baseURL)
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try enteredKey.isEmpty ? Self.loadKey(for: draft.provider, endpoint: endpoint) : enteredKey
        try SpeechModelRequest.validate(model: model, key: key)
        return Configuration(provider: draft.provider, endpoint: endpoint, model: model, key: key)
    }

    private static func keychainQuery(for provider: SpeechModelProvider, endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue + "|" + endpoint.absoluteString
        ]
    }

    private static func loadKey(for provider: SpeechModelProvider, endpoint: URL) throws -> String {
        var query = keychainQuery(for: provider, endpoint: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { throw SpeechModelError.key }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8)
        else { throw SpeechModelError.keychain }
        return key
    }

    private static func saveKey(_ key: String, for provider: SpeechModelProvider, endpoint: URL) throws {
        var query = keychainQuery(for: provider, endpoint: endpoint)
        let bytes = Data(key.utf8)
        let attributes = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = bytes
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SpeechModelError.keychain }
        } else if status != errSecSuccess {
            throw SpeechModelError.keychain
        }
    }
}

private final class RejectSpeechRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SpeechModelSettings: View {
    let models: SpeechModels
    @State private var draft: SpeechModels.Profile
    @State private var enteredKey = ""
    @State private var feedback: String?

    init(models: SpeechModels) {
        self.models = models
        _draft = State(initialValue: models.profile)
    }

    var body: some View {
        let active = models.profile
        let activeTitle = active.provider == .local ? active.provider.title : "\(active.provider.title) · \(active.model)"
        Section("Модель для диктовки") {
            LabeledContent("Сейчас используется", value: activeTitle)
            Picker("Распознавание", selection: $draft.provider) {
                ForEach(SpeechModelProvider.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            if draft.provider != .local {
                TextField("Модель", text: $draft.model, prompt: Text("Имя модели в API"))
                if draft.provider == .compatible {
                    TextField("Адрес HTTPS API", text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
                    Text("Сервис должен поддерживать OpenAI-совместимый метод /audio/transcriptions.")
                        .foregroundStyle(.secondary)
                }
                SecureField("API-ключ", text: $enteredKey, prompt: Text("Введите или замените ключ"))
                Text("Ключ хранится в «Связке ключей» macOS.")
                    .foregroundStyle(.secondary)
                if draft.provider == .openAI {
                    Link("Получить ключ OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                }
            }
            if draft.provider != .local || active.provider != .local {
                Text("Когда выбрана онлайн-модель, после завершения диктовки Typo отправляет запись выбранному сервису. Текст во время записи распознаётся на Mac. Провайдер может взимать плату за запросы.")
                    .foregroundStyle(.secondary)
            }
            Button(draft.provider == .local ? "Использовать локальную модель" : "Сохранить и использовать",
                   action: save)
                .disabled(draft == active && enteredKey.isEmpty)
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
        }
        .onChange(of: draft.provider) { _, provider in
            draft = models.profile(for: provider)
            enteredKey = ""
            feedback = nil
        }
        .onChange(of: draft.baseURL) { _, _ in enteredKey = "" }
    }

    private func save() {
        do {
            try models.save(draft, enteredKey: enteredKey)
            draft = models.profile
            enteredKey = ""
            feedback = "Настройки сохранены."
        } catch {
            feedback = error.localizedDescription
        }
    }
}
