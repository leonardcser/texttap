import Foundation
import LocalAuthentication
import Security
import WhisperKit

/// Transcribes 16 kHz mono speech.
protocol SpeechToText {
    func transcribe(_ audio: [Float]) async throws -> String
}

/// Uses `primary`, and `fallback` when `primary` fails for any reason except cancellation.
struct FallbackSpeechToText: SpeechToText {
    let primary: SpeechToText
    let fallback: SpeechToText

    func transcribe(_ audio: [Float]) async throws -> String {
        do {
            let text = try await primary.transcribe(audio)
            try Task.checkCancellation()
            return text
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Do not log credentials, recordings, transcripts, or server response bodies.
            print("[TextTap] Remote transcription unavailable; using local Whisper")
        }
        return try await fallback.transcribe(audio)
    }
}

// MARK: - Remote

/// An OpenAI-compatible audio transcription endpoint.
struct RemoteSpeechToText: SpeechToText {
    let config: TranscriptionConfig
    var sessionConfiguration: URLSessionConfiguration = .ephemeral
    var apiKey: (String) -> String? = Credentials.apiKey

    func transcribe(_ audio: [Float]) async throws -> String {
        guard let url = URL(string: config.remoteURL),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              !config.remoteModel.isEmpty,
              config.remoteTimeout.isFinite, config.remoteTimeout > 0 else {
            throw RemoteError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        if !config.apiKeyEnvironment.isEmpty {
            guard let key = apiKey(config.apiKeyEnvironment)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty, key.rangeOfCharacter(from: .newlines) == nil else {
                throw RemoteError.missingAPIKey
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "TextTap-\(UUID().uuidString)"
        var body = Data()
        var fields = [("model", config.remoteModel), ("response_format", "json"), ("temperature", "0")]
        if !config.language.isEmpty {
            fields.append(("language", config.language))
        }
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(Self.wav(audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = config.remoteTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let settings = sessionConfiguration.copy() as! URLSessionConfiguration
        settings.timeoutIntervalForRequest = config.remoteTimeout
        settings.timeoutIntervalForResource = config.remoteTimeout
        settings.waitsForConnectivity = false
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw RemoteError.serverResponse
        }
        // An empty successful transcription represents silence, not a backend failure.
        return try JSONDecoder().decode(Response.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Encodes 16 kHz mono samples as a 16-bit PCM WAV file.
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(Recorder.sampleRate)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + samples.count * 2))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(samples.count * 2))
        for sample in samples {
            append(Recorder.pcm16(sample))
        }
        return data
    }

    private struct Response: Decodable {
        let text: String
    }
}

enum RemoteError: Error {
    case invalidConfiguration
    case missingAPIKey
    case serverResponse
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward recorded audio or credentials to a redirected destination.
        completionHandler(nil)
    }
}

/// The remote API key, from its environment variable or the Keychain.
enum Credentials {
    static let keychainService = "com.leo.texttap.stt"

    static func storeAPIKeyFromEnvironment(environmentVariable: String) -> OSStatus {
        guard let value = ProcessInfo.processInfo.environment[environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil else {
            return errSecParam
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: environmentVariable,
        ]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecItemNotFound { return status }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    static func apiKey(environmentVariable: String) -> String? {
        guard !environmentVariable.isEmpty else { return nil }
        if let value = ProcessInfo.processInfo.environment[environmentVariable],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: environmentVariable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Local

/// Transcribes with the shared local Whisper model.
struct LocalSpeechToText: SpeechToText {
    let whisper: Whisper
    let language: String

    func transcribe(_ audio: [Float]) async throws -> String {
        try Task.checkCancellation()
        return try await whisper.transcribe(audio, language: language)
    }
}

/// The local WhisperKit model, loaded once and shared by every dictation.
actor Whisper {
    private let model: String
    private var loading: Task<WhisperKit, Error>?

    // Whisper marks non-speech in brackets and parentheses, and may leak special tokens.
    private static let artifacts = [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"<\|[^|]*\|>"#]
        .map { try! NSRegularExpression(pattern: $0) }

    init(model: String) {
        self.model = model
    }

    func preload() async {
        do {
            _ = try await kit()
        } catch {
            print("[TextTap] Local Whisper preload failed; will retry when needed")
        }
    }

    func transcribe(_ audio: [Float], language: String) async throws -> String {
        let kit = try await kit()
        // Without VAD, Whisper's seek loop can jump forward on long audio and skip segments.
        let options = DecodingOptions(language: language, chunkingStrategy: .vad)
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        var text = results.map(\.text).joined(separator: " ")
        for artifact in Self.artifacts {
            text = artifact.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func kit() async throws -> WhisperKit {
        if loading == nil {
            let model = model
            loading = Task {
                let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".texttap")
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                return try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, load: true, download: true))
            }
        }
        do {
            return try await loading!.value
        } catch {
            loading = nil
            throw error
        }
    }
}
