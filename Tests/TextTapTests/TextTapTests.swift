@testable import TextTap
import XCTest
import Network
import WhisperKit

private func remoteTestConfig() -> TranscriptionConfig {
    TranscriptionConfig(
        remoteEnabled: true,
        remoteURL: "https://example.test/transcribe",
        remoteModel: "speech-model",
        apiKeyEnvironment: "TEST_STT_KEY"
    )
}

final class TextTapTests: XCTestCase {
    private let audio: [Float] = [0, 0.5, -1]

    override func tearDown() {
        StubProtocol.handler = nil
    }

    private func client(key: String? = "test-key") -> Transcriber {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubProtocol.self]
        return Transcriber(sessionConfiguration: session, apiKey: { _ in key })
    }

    func testConfiguration() {
        var config = Config()
        XCTAssertFalse(config.transcription.remoteEnabled)
        XCTAssertEqual(config.transcription.remoteURL, "")
        XCTAssertEqual(config.transcription.remoteModel, "")
        XCTAssertEqual(config.transcription.apiKeyEnvironment, "")
        XCTAssertEqual(config.transcription.remoteTimeout, 5)
        config.load(contents: """
        [transcription]
        remote_enabled = true
        remote_url = "https://example.test/transcribe"
        remote_model = "speech-model"
        remote_timeout = 3
        api_key_env = "CUSTOM_KEY"
        """)
        XCTAssertTrue(config.transcription.remoteEnabled)
        XCTAssertEqual(config.transcription.remoteURL, "https://example.test/transcribe")
        XCTAssertEqual(config.transcription.remoteModel, "speech-model")
        XCTAssertEqual(config.transcription.apiKeyEnvironment, "CUSTOM_KEY")
        XCTAssertEqual(config.transcription.remoteTimeout, 3)
        config.load(contents: "[transcription]\nremote_timeout = 0.25")
        for value in ["0", "-1", "nan", "true"] {
            config.load(contents: "[transcription]\nremote_timeout = \(value)")
            XCTAssertEqual(config.transcription.remoteTimeout, 0.25)
        }
    }

    func testDefaultsNeverContactRemoteOrReadCredentials() async throws {
        StubProtocol.handler = { _ in XCTFail("Default configuration must not send recordings") }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubProtocol.self]
        let transcriber = Transcriber(sessionConfiguration: session, apiKey: { _ in
            XCTFail("Default configuration must not look up credentials")
            return "unused"
        })
        let result = try await transcriber.transcribe(audio: audio, config: TranscriptionConfig()) { "local" }
        XCTAssertEqual(result, "local")
    }

    func testIncompleteRemoteConfigurationSkipsNetwork() async throws {
        StubProtocol.handler = { _ in XCTFail("Incomplete configuration must not send recordings") }
        for field in ["url", "model"] {
            var config = remoteTestConfig()
            if field == "url" { config.remoteURL = "" } else { config.remoteModel = "" }
            let result = try await client().transcribe(audio: audio, config: config) { "local" }
            XCTAssertEqual(result, "local")
        }
    }

    func testInlineComments() {
        var config = Config()
        config.load(contents: """
        [transcription] # remote settings
        remote_enabled = false # local only
        remote_model = "test#model" # hash inside string is not a comment
        remote_timeout = 2 # seconds
        """)
        XCTAssertFalse(config.transcription.remoteEnabled)
        XCTAssertEqual(config.transcription.remoteModel, "test#model")
        XCTAssertEqual(config.transcription.remoteTimeout, 2)
    }

    func testMultipartSuccess() async throws {
        StubProtocol.handler = { stub in
            let request = stub.request
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, remoteTestConfig().remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.timeoutInterval, 5)
            let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=TextTap-"))
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(decoding: data, as: UTF8.self)
            for field in ["model", "language", "response_format", "temperature", "file"] {
                XCTAssertTrue(body.contains("name=\"\(field)\""))
            }
            XCTAssertTrue(body.contains(remoteTestConfig().remoteModel))
            XCTAssertTrue(body.contains("filename=\"recording.wav\""))
            XCTAssertNotNil(data.range(of: Transcriber.wav(self.audio)))
            stub.respond(200, #"{"text":"  remote transcript\n"}"#)
        }
        let result = try await client().transcribe(audio: audio, config: remoteTestConfig()) {
            XCTFail("Remote success must not run local Whisper")
            return "local"
        }
        XCTAssertEqual(result, "remote transcript")
    }

    func testSilenceDoesNotFallBack() async throws {
        StubProtocol.handler = { $0.respond(200, #"{"text":""}"#) }
        let result = try await client().transcribe(audio: audio, config: remoteTestConfig()) {
            XCTFail("Silence is not a remote failure")
            return "local"
        }
        XCTAssertEqual(result, "")
    }

    func testHTTPAndDecodingFailuresFallBackOnce() async throws {
        for (status, body) in [(401, "unauthorized"), (503, "offline"), (302, "redirect"), (200, "not json"), (200, "{}"), (200, #"{"text":null}"#)] {
            StubProtocol.handler = { $0.respond(status, body) }
            var calls = 0
            let result = try await client().transcribe(audio: audio, config: remoteTestConfig()) {
                calls += 1
                return "local"
            }
            XCTAssertEqual(result, "local")
            XCTAssertEqual(calls, 1)
        }
    }

    func testNetworkFailuresFallBack() async throws {
        for code in [URLError.notConnectedToInternet, .cannotConnectToHost, .timedOut] {
            StubProtocol.handler = { $0.client?.urlProtocol($0, didFailWithError: URLError(code)) }
            let result = try await client().transcribe(audio: audio, config: remoteTestConfig()) { "local" }
            XCTAssertEqual(result, "local")
        }
    }

    func testDisabledMissingCredentialAndUnsafeURLsSkipNetwork() async throws {
        StubProtocol.handler = { _ in XCTFail("Must not contact endpoint") }
        var config = remoteTestConfig()
        config.remoteEnabled = false
        let disabled = try await client().transcribe(audio: audio, config: config) { "local" }
        XCTAssertEqual(disabled, "local")
        let missing = try await client(key: nil).transcribe(audio: audio, config: remoteTestConfig()) { "local" }
        XCTAssertEqual(missing, "local")
        config.remoteEnabled = true
        for url in ["invalid", "http://example.test/stt", "https://user:password@example.test/stt"] {
            config.remoteURL = url
            let result = try await client().transcribe(audio: audio, config: config) { "local" }
            XCTAssertEqual(result, "local")
        }
    }

    func testCancellationDoesNotFallBack() async throws {
        let started = expectation(description: "request started")
        StubProtocol.handler = { _ in started.fulfill() }
        let transcriber = client()
        let audio = audio
        let task = Task {
            try await transcriber.transcribe(audio: audio, config: remoteTestConfig()) {
                XCTFail("Cancellation must not run local fallback")
                return "local"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled request returned text")
        } catch is CancellationError {}
    }

    func testRealHTTPTimeout() async throws {
        let server = try LoopbackServer(respond: false)
        defer { server.stop() }
        let port = try await server.start()
        var config = remoteTestConfig()
        config.remoteURL = "http://127.0.0.1:\(port)/transcribe"
        config.remoteTimeout = 0.2
        let started = Date()
        let result = try await Transcriber(apiKey: { _ in "test-key" }).transcribe(audio: audio, config: config) { "local" }
        XCTAssertEqual(result, "local")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRealHTTPRedirectIsNotFollowed() async throws {
        let server = try LoopbackServer(respond: true)
        defer { server.stop() }
        let port = try await server.start()
        var config = remoteTestConfig()
        config.remoteURL = "http://127.0.0.1:\(port)/transcribe"
        let result = try await Transcriber(apiKey: { _ in "test-key" }).transcribe(audio: audio, config: config) { "local" }
        XCTAssertEqual(result, "local")
        XCTAssertEqual(server.requestCount, 1, "Redirect must not forward audio or credentials")
    }

    func testWAVEncoding() {
        let wav = Transcriber.wav([0, 0.5, -1, 2])
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        let samples = wav.suffix(8).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map(Int16.init(littleEndian:))
        XCTAssertEqual(samples, [0, 16383, -32767, 32767])
    }

    func testSegmentsCutAtPauses() {
        var segmenter = Segmenter()
        let speech = tone(seconds: 6)
        let pause = [Float](repeating: 0, count: 4800)
        XCTAssertEqual(segmenter.append(tone(seconds: 2) + pause).count, 0, "A pause before 3 seconds is not a cut")
        let segments = segmenter.append(speech + pause + speech)
        XCTAssertEqual(segments.map(\.count), [2 * 16000 + 4800 + 6 * 16000 + 4800])
        XCTAssertEqual(segmenter.finish().count, 6 * 16000)
        XCTAssertEqual(segmenter.finish().count, 0)
    }

    func testLongSpeechCutsAtQuietestPoint() {
        var segmenter = Segmenter()
        var audio = tone(seconds: 20)
        let quiet = 13 * 16000
        for i in quiet..<quiet + 1600 { audio[i] *= 0.5 }
        let segments = segmenter.append(audio)
        XCTAssertEqual(segments.map(\.count), [quiet + 1600])
        XCTAssertEqual(segmenter.finish().count, audio.count - quiet - 1600)
    }

    func testSegmentJoining() {
        XCTAssertEqual(DictationManager.join([]), "")
        XCTAssertEqual(DictationManager.join(["We will review the budget.", "the hiring plan."]), "We will review the budget the hiring plan.")
        XCTAssertEqual(DictationManager.join(["First sentence.", "Second one."]), "First sentence. Second one.")
        XCTAssertEqual(DictationManager.join(["Wait...", "then go"]), "Wait... then go")
    }

    func testLocalErrorPropagates() async throws {
        var config = remoteTestConfig()
        config.remoteEnabled = false
        do {
            _ = try await client().transcribe(audio: audio, config: config) { throw TranscriptionError.modelNotLoaded }
            XCTFail("Local error swallowed")
        } catch TranscriptionError.modelNotLoaded {}
    }
}

private func tone(seconds: Int) -> [Float] {
    (0..<seconds * 16000).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16000) }
}

private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((StubProtocol) -> Void)?
    static var handler: ((StubProtocol) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Connections are confined to queue; the cross-thread request count uses lock.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TextTapTests.HTTP")
    private let lock = NSLock()
    private var count = 0
    private var connections: [NWConnection] = []
    private let respond: Bool
    var requestCount: Int { lock.withLock { count } }

    init(respond: Bool) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
                    guard let self else { return }
                    let count = self.lock.withLock { self.count += 1; return self.count }
                    guard self.respond else { return }
                    let response: String
                    if count == 1 {
                        response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(self.listener.port!.rawValue)/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    } else {
                        let body = #"{"text":"redirected"}"#
                        response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    }
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

final class LiveTranscriptionTests: XCTestCase {
    private func audioFile() throws -> [Float] {
        guard let path = ProcessInfo.processInfo.environment["TEXTTAP_TEST_AUDIO"] else {
            throw XCTSkip("Set TEXTTAP_TEST_AUDIO to a WAV saying 'the quick brown fox' for live checks")
        }
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    }

    func testRemote() async throws {
        let audio = try audioFile()
        guard let path = ProcessInfo.processInfo.environment["TEXTTAP_TEST_CONFIG"] else {
            throw XCTSkip("Set TEXTTAP_TEST_CONFIG to your private TOML configuration for remote checks")
        }
        var config = Config()
        config.load(contents: try String(contentsOfFile: path, encoding: .utf8))
        guard config.transcription.remoteEnabled,
              !config.transcription.remoteURL.isEmpty,
              !config.transcription.remoteModel.isEmpty else {
            XCTFail("Live test configuration must explicitly enable and configure remote transcription")
            return
        }
        for _ in 0..<2 {
            let text = try await Transcriber().transcribe(audio: audio, config: config.transcription) {
                XCTFail("Live remote endpoint failed")
                return ""
            }
            XCTAssertTrue(text.lowercased().contains("quick brown fox"))
        }
    }

    func testLocalFallback() async throws {
        let audio = try audioFile()
        var config = remoteTestConfig()
        config.remoteURL = "http://127.0.0.1:1/v1/audio/transcriptions"
        config.apiKeyEnvironment = ""
        config.remoteTimeout = 0.5
        let whisper = WhisperTranscriber()
        let text = try await Transcriber().transcribe(audio: audio, config: config) {
            try await whisper.loadModel()
            return try await whisper.transcribe(audio: audio)
        }
        XCTAssertTrue(text.lowercased().contains("quick brown fox"))
    }
}