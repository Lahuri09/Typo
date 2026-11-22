import Foundation

public enum SpeechModelProvider: String, CaseIterable, Codable, Sendable {
    case local, openAI, compatible

    public var title: String {
        switch self {
        case .local: "На этом Mac"
        case .openAI: "OpenAI"
        case .compatible: "Свой API"
        }
    }

    public var defaultModel: String { self == .openAI ? "gpt-transcribe" : "" }

    public func endpoint(baseURL: String) throws -> URL {
        guard self != .local else { throw SpeechModelError.address }
        let address = self == .openAI ? "https://api.openai.com/v1"
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw SpeechModelError.address }

        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        let suffix = "/audio/transcriptions"
        if !components.percentEncodedPath.hasSuffix(suffix) { components.percentEncodedPath += suffix }
        guard let url = components.url else { throw SpeechModelError.address }
        return url
    }
}

public enum SpeechModelError: LocalizedError, Equatable, Sendable {
    case address, model, key, keychain, audio, audioTooLarge
    case connection, redirect, authentication, billing, quota, badResponse
    case rejected(status: Int)

    public var errorDescription: String? {
        switch self {
        case .address: "Укажите HTTPS-адрес API без логина, пароля и параметров."
        case .model: "Укажите точное имя модели в API."
        case .key: "Введите API-ключ для этого адреса."
        case .keychain: "Не удалось обратиться к «Связке ключей» macOS."
        case .audio: "Не удалось прочитать файл записи."
        case .audioTooLarge: "Запись больше допустимого размера. Попробуйте продиктовать по частям."
        case .connection: "Сервис распознавания недоступен. Проверьте интернет и адрес API."
        case .redirect: "API перенаправил запрос. Укажите прямой адрес распознавания."
        case .authentication: "API отклонил ключ или у ключа нет доступа к модели."
        case .billing: "API отклонил запрос из-за оплаты. Проверьте баланс провайдера."
        case .quota: "Достигнут лимит распознавания. Проверьте квоту и баланс провайдера."
        case .badResponse: "API вернул ответ в неподдерживаемом формате."
        case let .rejected(status): "API отклонил запись (HTTP \(status)). Проверьте адрес и имя модели."
        }
    }
}

public enum SpeechModelRequest {
    public static let maxAudioBytes = 25_000_000

    public static func validate(model: String, key: String) throws {
        guard !model.isEmpty, model.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw SpeechModelError.model
        }
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw SpeechModelError.key
        }
    }

    public static func transcription(_ audio: Data, language: String, provider: SpeechModelProvider,
                                     endpoint: URL, model: String, key: String) throws -> URLRequest {
        try validate(model: model, key: key)
        guard !audio.isEmpty else { throw SpeechModelError.audio }
        guard audio.count <= maxAudioBytes else { throw SpeechModelError.audioTooLarge }

        let boundary = UUID().uuidString
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        addField("model", model)
        addField("response_format", "json")
        if language.utf8.count == 2, language.utf8.allSatisfy({ (97...122).contains($0) }) {
            addField(provider == .openAI && model == provider.defaultModel ? "languages[]" : "language", language)
        }
        body.append(contentsOf: """
            --\(boundary)\r
            Content-Disposition: form-data; name="file"; filename="dictation.wav"\r
            Content-Type: audio/wav\r
            \r

            """.utf8)
        body.append(audio)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var request = URLRequest(url: try provider.endpoint(baseURL: endpoint.absoluteString),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    public static func result(from data: Data, status: Int) throws -> String {
        switch status {
        case 200...299: break
        case 300...399: throw SpeechModelError.redirect
        case 401, 403: throw SpeechModelError.authentication
        case 402: throw SpeechModelError.billing
        case 413: throw SpeechModelError.audioTooLarge
        case 429:
            if (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.code == "insufficient_quota" {
                throw SpeechModelError.billing
            }
            throw SpeechModelError.quota
        case 500...599: throw SpeechModelError.connection
        default: throw SpeechModelError.rejected(status: status)
        }
        guard let response = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw SpeechModelError.badResponse
        }
        return AIRequest.cleanTranscript(response.text)
    }

    private struct Transcript: Decodable { let text: String }
    private struct ErrorResponse: Decodable {
        let error: ProviderError
        struct ProviderError: Decodable { let code: String? }
    }
}
