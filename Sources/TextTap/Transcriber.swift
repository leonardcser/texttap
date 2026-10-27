import Foundation
import Security
import LocalAuthentication

struct Transcriber {
    private let sessionConfiguration: URLSessionConfiguration
    private let apiKey: (String) -> String?

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        apiKey: @escaping (String) -> String? = TranscriptionCredentials.apiKey
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.apiKey = apiKey
    }

    func transcribe(
        audio: [Float],
        config: TranscriptionConfig,
        local: () async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        if config.remoteEnabled {
            do {
                let text = try await transcribeRemotely(audio: audio, config: config)
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
        }
        try Task.checkCancellation()
        let text = try await local()
        try Task.checkCancellation()
        return text
    }

    private func transcribeRemotely(audio: [Float], config: TranscriptionConfig) async throws -> String {
        guard let url = URL(string: config.remoteURL),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              !config.remoteModel.isEmpty,
              config.remoteTimeout.isFinite, config.remoteTimeout > 0 else {
            throw RemoteTranscriptionError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        if !config.apiKeyEnvironment.isEmpty {
            guard let key = apiKey(config.apiKeyEnvironment)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty, key.rangeOfCharacter(from: .newlines) == nil else {
                throw RemoteTranscriptionError.missingAPIKey
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
        let session = URLSession(configuration: settings, delegate: NoTranscriptionRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw RemoteTranscriptionError.serverResponse
        }
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        // An empty successful transcription represents silence, not a backend failure.
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Transcriber {
    /// Encodes 16 kHz mono samples as a 16-bit PCM WAV file.
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(AudioRecorder.sampleRate)
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
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private enum RemoteTranscriptionError: Error {
    case invalidConfiguration
    case missingAPIKey
    case serverResponse
}

private final class NoTranscriptionRedirects: NSObject, URLSessionTaskDelegate {
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

enum TranscriptionCredentials {
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
