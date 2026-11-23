import Foundation
import TypoCore

@MainActor func runSpeechModelChecks(_ expect: (Bool) -> Void) throws {
    let started = ContinuousClock.now
    let countdown = RecordingCountdown(startedAt: started)
    expect(countdown.deadline == started.advanced(by: .seconds(120)))
    expect(countdown.reading(at: started) == .init(seconds: 120, isWarning: false))
    expect(countdown.reading(at: started.advanced(by: .seconds(108))) == .init(seconds: 12, isWarning: false))
    expect(countdown.reading(at: started.advanced(by: .milliseconds(108_001))) == .init(seconds: 12, isWarning: true))
    expect(countdown.reading(at: started.advanced(by: .seconds(109))) == .init(seconds: 11, isWarning: true))
    expect(countdown.reading(at: countdown.deadline.advanced(by: .seconds(2))) == .init(seconds: 0, isWarning: true))
    let custom = SpeechModelProvider.compatible
    let endpoint = try custom.endpoint(baseURL: "https://EXAMPLE.org:443/v1/")
    let complete = try custom.endpoint(baseURL: "https://example.org/v1/audio/transcriptions")
    expect(endpoint == complete && endpoint.absoluteString == "https://example.org/v1/audio/transcriptions")
    for address in ["http://example.org/v1", "https://user@example.org", "https://example.org/v1?key=x",
                    "https://example.org/v1#fragment", "https://example.org/a/%2E%2E/v1", "https://example.org:0"] {
        expect((try? custom.endpoint(baseURL: address)) == nil)
    }
    let direct = try SpeechModelProvider.openAI.endpoint(baseURL: "https://other.example")
    expect(direct.absoluteString == "https://api.openai.com/v1/audio/transcriptions")

    let audio = Data([0x52, 0x49, 0x46, 0x46, 0xFF, 0x00])
    let standard = try SpeechModelRequest.transcription(audio, language: "ru", provider: .openAI,
                                                        endpoint: direct, model: "gpt-transcribe", key: "test-key")
    let standardBody = String(decoding: standard.httpBody ?? Data(), as: UTF8.self)
    expect(standard.url == direct && standard.httpMethod == "POST")
    expect(standard.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    expect(standard.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    expect(standardBody.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
    expect(standardBody.contains("name=\"languages[]\"\r\n\r\nru\r\n"))
    expect(standardBody.contains("name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
    expect(standard.httpBody?.range(of: audio) != nil)
    let wavTooLarge = Data(repeating: 0, count: SpeechModelRequest.maxAudioBytes + 1)
    do {
        _ = try SpeechModelRequest.transcription(wavTooLarge, language: "ru", provider: .openAI,
                                                 endpoint: direct, model: "gpt-transcribe", key: "test-key")
        expect(false)
    } catch let error as SpeechModelError {
        expect(error == .audioTooLarge)
    }
    let compatible = try SpeechModelRequest.transcription(audio, language: "en", provider: custom,
                                                          endpoint: endpoint, model: "custom-stt", key: "test-key")
    expect(String(decoding: compatible.httpBody ?? Data(), as: UTF8.self)
        .contains("name=\"language\"\r\n\r\nen\r\n"))
    let automatic = try SpeechModelRequest.transcription(audio, language: "auto", provider: custom,
                                                         endpoint: endpoint, model: "custom-stt", key: "test-key")
    expect(!String(decoding: automatic.httpBody ?? Data(), as: UTF8.self).contains("name=\"language"))
    expect((try? SpeechModelRequest.transcription(audio, language: "auto", provider: custom, endpoint: endpoint,
                                                   model: "custom-stt\r\n", key: "test-key")) == nil)
    expect((try? SpeechModelRequest.transcription(audio, language: "auto", provider: custom, endpoint: endpoint,
                                                   model: "custom-stt", key: "test-key\r\n")) == nil)

    let result = try SpeechModelRequest.result(from: Data(#"{"text":" Привет, мир! "}"#.utf8), status: 200)
    let silence = try SpeechModelRequest.result(from: Data(#"{"text":""}"#.utf8), status: 200)
    expect(result == "Привет, мир!" && silence.isEmpty)
    expect((try? SpeechModelRequest.result(from: Data(#"{"transcript":"Привет"}"#.utf8), status: 200)) == nil)
    let failures: [(Int, SpeechModelError)] = [(307, .redirect), (401, .authentication), (413, .audioTooLarge),
                                               (429, .quota), (503, .connection)]
    for (status, error) in failures {
        do {
            _ = try SpeechModelRequest.result(from: Data(), status: status)
            expect(false)
        } catch let failure as SpeechModelError {
            expect(failure == error)
        }
    }
}
