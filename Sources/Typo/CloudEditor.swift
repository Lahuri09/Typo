import Foundation
import Security
import SwiftUI
import TypoCore

@Observable
final class CloudEditor {
    struct Profile: Codable, Equatable {
        var provider: CloudEditorProvider = .local
        var baseURL = ""
        var model = ""

        func endpoint() throws -> URL { try provider.endpoint(baseURL: baseURL) }
    }

    struct Configuration {
        fileprivate let profile: Profile
        fileprivate let key: String
    }

    private static let settingsKey = "cloudEditorProfile"
    private static let keychainService = "local.typo.Switcher.editor"
    private(set) var profile: Profile

    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }(), delegate: RejectCloudRedirects(), delegateQueue: nil)

    init() {
        profile = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(Profile.self, from: $0) } ?? Profile()
    }

    func configuration() throws -> Configuration? {
        try configuration(for: profile, enteredKey: "")
    }

    func save(_ draft: Profile, enteredKey: String) throws {
        if let configuration = try configuration(for: draft, enteredKey: enteredKey) {
            if !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Self.saveKey(configuration.key, for: configuration.profile)
            }
            profile = configuration.profile
        } else {
            profile = Profile()
        }
        UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: Self.settingsKey)
    }

    func test(_ draft: Profile, enteredKey: String) async throws {
        guard let configuration = try configuration(for: draft, enteredKey: enteredKey) else { return }
        _ = try await Self.rewrite("сегодня встреча в десять", instruction: "Fix capitalization and punctuation.",
                                   configuration: configuration)
    }

    static func rewrite(_ text: String, instruction: String, configuration: Configuration, revision: EditRevision? = nil,
                        session: URLSession = CloudEditor.session) async throws -> String {
        let profile = configuration.profile
        let request = try CloudEditorRequest.rewrite(text, instruction: instruction, provider: profile.provider,
                                                      baseURL: profile.baseURL, model: profile.model,
                                                      key: configuration.key, revision: revision)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw CloudEditorError.connection
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CloudEditorError.connection }
        return try CloudEditorRequest.result(from: data, status: http.statusCode, provider: profile.provider)
    }

    private func configuration(for draft: Profile, enteredKey: String) throws -> Configuration? {
        guard draft.provider != .local else { return nil }
        var resolved = draft
        resolved.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.model.isEmpty, !resolved.model.contains(where: \.isWhitespace) else {
            throw CloudEditorError.model
        }
        resolved.baseURL = draft.provider.acceptsCustomURL ? try draft.endpoint().absoluteString : ""
        let cleanKey = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try cleanKey.isEmpty ? Self.loadKey(for: resolved) : cleanKey
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CloudEditorError.key }
        return Configuration(profile: resolved, key: key)
    }

    private static func keychainQuery(for profile: Profile) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: try profile.provider.rawValue + "|" + profile.endpoint().absoluteString
        ]
    }

    private static func loadKey(for profile: Profile) throws -> String {
        var query = try keychainQuery(for: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { throw CloudEditorError.key }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8)
        else { throw CloudEditorError.keychain }
        return key
    }

    private static func saveKey(_ key: String, for profile: Profile) throws {
        var query = try keychainQuery(for: profile)
        let bytes = Data(key.utf8)
        let attributes = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = bytes
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CloudEditorError.keychain }
        } else if status != errSecSuccess {
            throw CloudEditorError.keychain
        }
    }
}

private final class RejectCloudRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct CloudEditorSettings: View {
    let editor: CloudEditor
    @State private var draft: CloudEditor.Profile
    @State private var enteredKey = ""
    @State private var feedback: String?
    @State private var checking = false

    init(editor: CloudEditor) {
        self.editor = editor
        _draft = State(initialValue: editor.profile)
    }

    var body: some View {
        let active = editor.profile
        let activeModel = active.provider == .local ? active.provider.title : "\(active.provider.title) · \(active.model)"
        Section("Модель для редактуры") {
            LabeledContent("Сейчас используется", value: activeModel)
            Picker("Провайдер", selection: $draft.provider) {
                ForEach(CloudEditorProvider.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            if draft.provider != .local {
                TextField("Модель", text: $draft.model, prompt: Text("Имя модели в API"))
                if draft.provider.acceptsCustomURL {
                    TextField("Адрес API", text: $draft.baseURL,
                              prompt: Text(draft.provider == .qwen ? draft.provider.defaultBaseURL
                                                                  : "https://api.example.com/v1"))
                }
                SecureField("API-ключ", text: $enteredKey, prompt: Text("Введите ключ провайдера"))
                if draft.provider == .openAI {
                    Link("Получить ключ OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    Text("Подписка ChatGPT и использование API оплачиваются отдельно.")
                        .foregroundStyle(.secondary)
                }
                Text("Онлайн-модель получает выделенный текст. Ключ хранится в «Связке ключей» macOS.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(draft.provider == .local ? "Использовать локальную" : "Сохранить и использовать", action: save)
                    .disabled(checking || (draft == editor.profile && enteredKey.isEmpty))
                if draft.provider != .local {
                    Button(checking ? "Проверяем…" : "Проверить подключение", action: test)
                        .disabled(checking)
                }
            }
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
        }
        .onChange(of: draft.provider) { _, provider in
            draft = provider == editor.profile.provider ? editor.profile
                : CloudEditor.Profile(provider: provider, model: provider.defaultModel)
            enteredKey = ""
            feedback = nil
        }
        .onChange(of: draft.baseURL) { _, _ in enteredKey = "" }
    }

    private func save() {
        do {
            try editor.save(draft, enteredKey: enteredKey)
            draft = editor.profile
            enteredKey = ""
            feedback = "Настройки сохранены."
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func test() {
        let profile = draft
        let key = enteredKey
        feedback = nil
        checking = true
        Task {
            defer { checking = false }
            do {
                try await editor.test(profile, enteredKey: key)
                if draft == profile, enteredKey == key { feedback = "Подключение работает. Провайдер ответил на пробный текст." }
            } catch {
                if draft == profile, enteredKey == key { feedback = error.localizedDescription }
            }
        }
    }
}
