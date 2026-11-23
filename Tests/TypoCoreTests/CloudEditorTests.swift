import Foundation
import TypoCore

@MainActor func runCloudEditorChecks(_ expect: (Bool) -> Void) throws {
    let endpoints: [(CloudEditorProvider, String)] = [
        (.openAI, "https://api.openai.com/v1/chat/completions"),
        (.deepSeek, "https://api.deepseek.com/chat/completions"),
        (.claude, "https://api.anthropic.com/v1/messages"),
        (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
        (.kimi, "https://api.moonshot.ai/v1/chat/completions"),
        (.qwen, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
    ]
    let source = "«Привет»\nЮникод 🙂"
    for (provider, expected) in endpoints {
        let request = try CloudEditorRequest.rewrite(source, instruction: "Вычитай", provider: provider,
                                                      baseURL: "", model: provider.defaultModel, key: "test-key")
        expect(request.url?.absoluteString == expected && request.httpMethod == "POST")
        guard let bytes = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let messages = body["messages"] as? [[String: String]],
              let payload = messages.last?["content"]
        else { expect(false); continue }
        let quoted = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))
        expect(quoted["source"] == source && body["model"] as? String == provider.defaultModel)
        if provider == .claude {
            expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            expect(body["max_tokens"] as? Int == 4096 && body["system"] != nil)
        } else {
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            expect(body["stream"] as? Bool == false && messages.first?["role"] == "system")
            expect(provider == .openAI ? (body["store"] as? Bool == false) : (body["store"] == nil))
            expect(provider == .openAI ? (body["reasoning_effort"] as? String == "none") : (body["reasoning_effort"] == nil))
        }
    }

    let custom = CloudEditorProvider.compatible
    let base = try custom.endpoint(baseURL: "https://EXAMPLE.org:443/v1/")
    let complete = try custom.endpoint(baseURL: "https://example.org/v1/chat/completions")
    expect(base == complete)
    for invalid in ["http://example.org", "https://user@example.org", "https://example.org/v1?key=x",
                    "https://example.org/v1#fragment", "https://example.org/a/../v1", "https://example.org:0"] {
        expect((try? custom.endpoint(baseURL: invalid)) == nil)
    }
    let direct = try CloudEditorProvider.openAI.endpoint(baseURL: "https://other.example")
    expect(direct.host == "api.openai.com")
    expect((try? CloudEditorRequest.rewrite(source, instruction: "Edit", provider: .openAI, baseURL: "",
                                            model: "test", key: "fake\nextra")) == nil)

    let refinement = EditRevision(previous: "Первый вариант", clarification: "Сохрани сроки 🙂")
    let revised = try CloudEditorRequest.rewrite(source, instruction: "Вычитай", provider: .openAI,
        baseURL: "", model: CloudEditorProvider.openAI.defaultModel, key: "test-key", revision: refinement)
    if let body = revised.httpBody,
       let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
       let messages = object["messages"] as? [[String: String]],
       let user = messages.last?["content"] {
        let payload = try JSONDecoder().decode([String: String].self, from: Data(user.utf8))
        expect(payload == ["source": source, "previous": "Первый вариант", "clarification": "Сохрани сроки 🙂"])
        expect(messages.first?["content"]?.contains("Сохрани сроки") == false)
        expect(messages.first?["content"]?.contains("JSON field clarification") == true)
    } else {
        expect(false)
    }

    let chat = Data(#"{"choices":[{"message":{"content":" Исправлено "},"finish_reason":"stop"}]}"#.utf8)
    let claude = Data(#"{"content":[{"type":"thinking"},{"type":"text","text":"Исправлено"}],"stop_reason":"end_turn"}"#.utf8)
    let truncated = Data(#"{"choices":[{"message":{"content":"Часть"},"finish_reason":"length"}]}"#.utf8)
    expect((try CloudEditorRequest.result(from: chat, status: 200, provider: .openAI)) == "Исправлено")
    expect((try CloudEditorRequest.result(from: claude, status: 200, provider: .claude)) == "Исправлено")
    expect((try? CloudEditorRequest.result(from: truncated, status: 200, provider: .kimi)) == nil)
    let statuses: [(Int, CloudEditorError)] = [(401, .authentication), (402, .billing), (429, .quota), (503, .connection)]
    for (status, error) in statuses {
        do {
            _ = try CloudEditorRequest.result(from: Data(), status: status, provider: .openAI)
            expect(false)
        } catch let result as CloudEditorError {
            expect(result == error)
        }
    }
}
