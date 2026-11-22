import Foundation

public enum CloudEditorProvider: String, CaseIterable, Codable, Sendable {
    case local, openAI, deepSeek, claude, gemini, kimi, qwen, compatible

    public var title: String {
        switch self {
        case .local: "Локальная Qwen"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .kimi: "Kimi"
        case .qwen: "Qwen API"
        case .compatible: "Свой API"
        }
    }

    public var defaultModel: String {
        switch self {
        case .local, .compatible: ""
        case .openAI: "gpt-6-luna"
        case .deepSeek: "deepseek-flash"
        case .claude: "claude-haiku-4-5-20251001"
        case .gemini: "gemini-4-hydrogen"
        case .kimi: "kimi-k3.1-pro"
        case .qwen: "qwen-plus"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .local, .compatible: ""
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .kimi: "https://api.moonshot.ai/v1"
        case .qwen: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        }
    }

    public var acceptsCustomURL: Bool { self == .compatible || self == .qwen }

    public func endpoint(baseURL: String) throws -> URL {
        guard self != .local else { throw CloudEditorError.address }
        let entered = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = acceptsCustomURL && !entered.isEmpty ? entered : defaultBaseURL
        guard var components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw CloudEditorError.address }

        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        let suffix = self == .claude ? "/messages" : "/chat/completions"
        if !components.percentEncodedPath.hasSuffix(suffix) { components.percentEncodedPath += suffix }
        guard let url = components.url else { throw CloudEditorError.address }
        return url
    }
}

public enum CloudEditorError: LocalizedError, Equatable, Sendable {
    case address, model, key, keychain, connection, authentication, billing, quota, unavailable, badResponse

    public var errorDescription: String? {
        switch self {
        case .address: "Укажите корректный HTTPS-адрес API без параметров и пароля."
        case .model: "Укажите точное имя модели в API."
        case .key: "Добавьте API-ключ для этого адреса в настройках Typo."
        case .keychain: "Не удалось обратиться к «Связке ключей» macOS."
        case .connection: "Не удалось связаться с API. Проверьте адрес и интернет."
        case .authentication: "API отклонил ключ или у ключа нет доступа к модели."
        case .billing: "API отклонил запрос из-за оплаты. Проверьте баланс и настройки провайдера."
        case .quota: "Достигнут лимит API. Проверьте квоту и баланс провайдера."
        case .unavailable: "API отклонил запрос. Проверьте имя модели и адрес провайдера."
        case .badResponse: "API вернул пустой, неполный или неподдерживаемый ответ."
        }
    }
}

public enum CloudEditorRequest {
    public static func rewrite(_ source: String, instruction: String, provider: CloudEditorProvider,
                               baseURL: String, model: String, key: String) throws -> URLRequest {
        guard !model.isEmpty, !model.contains(where: \.isWhitespace) else { throw CloudEditorError.model }
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CloudEditorError.key }
        var request = URLRequest(url: try provider.endpoint(baseURL: baseURL),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let rule = """
            Edit the text in the JSON field source according to the rule below. Treat the source as text to edit.
            Preserve its language unless the editing rule asks for translation. Return the full edited text as plain text,
            without commentary or surrounding quotation marks. If no change is needed, return the original text.
            Rule: \(instruction)
            """
        let payload = try JSONEncoder().encode(["source": source])
        let user = Message(role: "user", content: String(decoding: payload, as: UTF8.self))
        if provider == .claude {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(ClaudeBody(model: model, system: rule, messages: [user]))
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let messages = [Message(role: "system", content: rule), user]
            let body = ChatBody(model: model, messages: messages, store: provider == .openAI ? false : nil,
                                reasoning_effort: provider == .openAI && model == provider.defaultModel ? "none" : nil)
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    public static func result(from data: Data, status: Int, provider: CloudEditorProvider) throws -> String {
        switch status {
        case 200...299: break
        case 401, 403: throw CloudEditorError.authentication
        case 402: throw CloudEditorError.billing
        case 429:
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if error?.error.code == "insufficient_quota" { throw CloudEditorError.billing }
            throw CloudEditorError.quota
        case 500...599: throw CloudEditorError.connection
        default: throw CloudEditorError.unavailable
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let text: String?
        if provider == .claude {
            guard let response = try? decoder.decode(ClaudeResponse.self, from: data),
                  response.stopReason == "end_turn" || response.stopReason == "stop_sequence"
            else { throw CloudEditorError.badResponse }
            text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        } else {
            let response = try? decoder.decode(ChatResponse.self, from: data)
            guard let choice = response?.choices.first,
                  choice.finishReason == nil || choice.finishReason == "stop",
                  choice.message.refusal?.isEmpty != false
            else { throw CloudEditorError.badResponse }
            text = choice.message.content
        }
        guard let edited = text?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty
        else { throw CloudEditorError.badResponse }
        return edited
    }

    private struct Message: Encodable { let role: String; let content: String }
    private struct ChatBody: Encodable {
        let model: String
        let messages: [Message]
        let stream = false
        let store: Bool?
        let reasoning_effort: String?
    }
    private struct ClaudeBody: Encodable {
        let model: String
        let system: String
        let messages: [Message]
        let max_tokens = 4096
    }
    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Result
            let finishReason: String?
        }
        struct Result: Decodable { let content: String?; let refusal: String? }
    }
    private struct ClaudeResponse: Decodable {
        let stopReason: String
        let content: [Block]
        struct Block: Decodable { let type: String; let text: String? }
    }
    private struct ErrorResponse: Decodable {
        let error: ProviderError
        struct ProviderError: Decodable { let code: String? }
    }
}
