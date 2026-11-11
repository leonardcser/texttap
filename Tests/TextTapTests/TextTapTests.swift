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

/// Returns `text`, or throws `error`, and counts its calls.
private final class StubSpeechToText: SpeechToText {
    var text = "local"
    var error: Error?
    private(set) var calls = 0

    func transcribe(_ audio: [Float]) async throws -> String {
        calls += 1
        if let error { throw error }
        return text
    }
}

private struct StubError: Error {}

final class TextTapTests: XCTestCase {
    private let audio: [Float] = [0, 0.5, -1]

    override func tearDown() {
        StubProtocol.handler = nil
    }

    private func remote(_ config: TranscriptionConfig = remoteTestConfig(), key: String? = "test-key") -> RemoteSpeechToText {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubProtocol.self]
        return RemoteSpeechToText(config: config, sessionConfiguration: session, apiKey: { _ in key })
    }

    /// Transcribes with `remote` falling back to a local stub, and returns the text and the stub.
    private func transcribe(_ remote: RemoteSpeechToText) async throws -> (String, StubSpeechToText) {
        let local = StubSpeechToText()
        let text = try await FallbackSpeechToText(primary: remote, fallback: local).transcribe(audio)
        return (text, local)
    }

    func testConfiguration() {
        var config = Config()
        XCTAssertFalse(config.transcription.remoteEnabled)
        XCTAssertEqual(config.transcription.remoteURL, "")
        XCTAssertEqual(config.transcription.remoteModel, "")
        XCTAssertEqual(config.transcription.apiKeyEnvironment, "")
        XCTAssertEqual(config.transcription.remoteTimeout, 5)
        XCTAssertTrue(config.indicator.preview)
        config.load(contents: """
        [hotkey]
        mode = "shortcut"
        double_tap_interval = 1
        [transcription]
        remote_enabled = true
        remote_url = "https://example.test/transcribe"
        remote_model = "speech-model"
        remote_timeout = 3
        api_key_env = "CUSTOM_KEY"
        [indicator]
        preview = false
        bar_count = 5
        width = 50.5
        """)
        XCTAssertEqual(config.hotkey.mode, .shortcut)
        XCTAssertEqual(config.hotkey.doubleTapInterval, 1)
        XCTAssertTrue(config.transcription.remoteEnabled)
        XCTAssertEqual(config.transcription.remoteURL, "https://example.test/transcribe")
        XCTAssertEqual(config.transcription.remoteModel, "speech-model")
        XCTAssertEqual(config.transcription.apiKeyEnvironment, "CUSTOM_KEY")
        XCTAssertEqual(config.transcription.remoteTimeout, 3)
        XCTAssertFalse(config.indicator.preview)
        XCTAssertEqual(config.indicator.barCount, 5)
        XCTAssertEqual(config.indicator.width, 50.5)
        config.load(contents: "[transcription]\nremote_timeout = 0.25")
        for value in ["0", "-1", "nan", "true"] {
            config.load(contents: "[transcription]\nremote_timeout = \(value)")
            XCTAssertEqual(config.transcription.remoteTimeout, 0.25)
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

    func testShortcutParsing() {
        let parsed = Hotkey.parse("cmd-shift-m")
        XCTAssertEqual(parsed?.keyCode, 0x2E)
        XCTAssertEqual(parsed?.modifiers, [.maskCommand, .maskShift])
        XCTAssertNil(Hotkey.parse("cmd-nope"))
        XCTAssertNil(Hotkey.parse("hyper-m"))
    }

    func testIncompleteOrUnsafeConfigurationSkipsNetwork() async throws {
        StubProtocol.handler = { _ in XCTFail("Must not contact endpoint") }
        var configs: [TranscriptionConfig] = []
        for url in ["", "invalid", "http://example.test/stt", "https://user:password@example.test/stt"] {
            var config = remoteTestConfig()
            config.remoteURL = url
            configs.append(config)
        }
        var noModel = remoteTestConfig()
        noModel.remoteModel = ""
        configs.append(noModel)
        for config in configs {
            do {
                _ = try await remote(config).transcribe(audio)
                XCTFail("Accepted \(config.remoteURL)")
            } catch RemoteError.invalidConfiguration {}
        }
        do {
            _ = try await remote(key: nil).transcribe(audio)
            XCTFail("Sent without a key")
        } catch RemoteError.missingAPIKey {}
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
            XCTAssertNotNil(data.range(of: RemoteSpeechToText.wav(self.audio)))
            stub.respond(200, #"{"text":"  remote transcript\n"}"#)
        }
        let (text, local) = try await transcribe(remote())
        XCTAssertEqual(text, "remote transcript")
        XCTAssertEqual(local.calls, 0, "Remote success must not run local Whisper")
    }

    func testSilenceDoesNotFallBack() async throws {
        StubProtocol.handler = { $0.respond(200, #"{"text":""}"#) }
        let (text, local) = try await transcribe(remote())
        XCTAssertEqual(text, "")
        XCTAssertEqual(local.calls, 0)
    }

    func testHTTPAndDecodingFailuresFallBackOnce() async throws {
        for (status, body) in [(401, "unauthorized"), (503, "offline"), (302, "redirect"), (200, "not json"), (200, "{}"), (200, #"{"text":null}"#)] {
            StubProtocol.handler = { $0.respond(status, body) }
            let (text, local) = try await transcribe(remote())
            XCTAssertEqual(text, "local")
            XCTAssertEqual(local.calls, 1)
        }
    }

    func testNetworkFailuresFallBack() async throws {
        for code in [URLError.notConnectedToInternet, .cannotConnectToHost, .timedOut] {
            StubProtocol.handler = { $0.client?.urlProtocol($0, didFailWithError: URLError(code)) }
            let (text, _) = try await transcribe(remote())
            XCTAssertEqual(text, "local")
        }
    }

    func testCancellationDoesNotFallBack() async throws {
        let started = expectation(description: "request started")
        StubProtocol.handler = { _ in started.fulfill() }
        let local = StubSpeechToText()
        let speechToText = FallbackSpeechToText(primary: remote(), fallback: local)
        let audio = audio
        let task = Task { try await speechToText.transcribe(audio) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled request returned text")
        } catch is CancellationError {}
        XCTAssertEqual(local.calls, 0)
    }

    func testFallbackErrorPropagates() async throws {
        let failing = StubSpeechToText()
        failing.error = StubError()
        let local = StubSpeechToText()
        local.error = StubError()
        do {
            _ = try await FallbackSpeechToText(primary: failing, fallback: local).transcribe(audio)
            XCTFail("Local error swallowed")
        } catch is StubError {}
    }

    func testRealHTTPTimeout() async throws {
        let server = try LoopbackServer(respond: false)
        defer { server.stop() }
        let port = try await server.start()
        var config = remoteTestConfig()
        config.remoteURL = "http://127.0.0.1:\(port)/transcribe"
        config.remoteTimeout = 0.2
        let started = Date()
        let (text, _) = try await transcribe(RemoteSpeechToText(config: config, apiKey: { _ in "test-key" }))
        XCTAssertEqual(text, "local")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRealHTTPRedirectIsNotFollowed() async throws {
        let server = try LoopbackServer(respond: true)
        defer { server.stop() }
        let port = try await server.start()
        var config = remoteTestConfig()
        config.remoteURL = "http://127.0.0.1:\(port)/transcribe"
        let (text, _) = try await transcribe(RemoteSpeechToText(config: config, apiKey: { _ in "test-key" }))
        XCTAssertEqual(text, "local")
        XCTAssertEqual(server.requestCount, 1, "Redirect must not forward audio or credentials")
    }

    func testWAVEncoding() {
        let wav = RemoteSpeechToText.wav([0, 0.5, -1, 2])
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

    func testKeyClicksAreNotSpeech() {
        var segmenter = Segmenter()
        _ = segmenter.append(tone(seconds: 1))
        let quiet = [Float](repeating: 0.001, count: 4000)
        let clicks = (0..<4).flatMap { _ in click() + quiet }
        XCTAssertFalse(segmenter.containsSpeech(quiet + clicks))
        XCTAssertFalse(segmenter.containsSpeech([]))
        XCTAssertTrue(segmenter.containsSpeech(quiet + Array(tone(seconds: 1).prefix(4000)) + quiet), "A 250 ms word is speech")
    }

    func testPartsWithoutSpeechAreNotTranscribed() async throws {
        let speech = StubSpeechToText()
        let session = DictationSession(speechToText: speech)
        let pause = [Float](repeating: 0, count: 4800)
        session.append(tone(seconds: 4) + pause)
        session.append(pause + click() + pause + click())
        let text = try await session.finish()
        XCTAssertEqual(text, "local")
        XCTAssertEqual(speech.calls, 1, "Only the spoken part is transcribed")
    }

    func testSegmentJoining() {
        XCTAssertEqual(DictationSession.join([]), "")
        XCTAssertEqual(DictationSession.join(["We will review the budget.", "the hiring plan."]), "We will review the budget the hiring plan.")
        XCTAssertEqual(DictationSession.join(["First sentence.", "Second one."]), "First sentence. Second one.")
        XCTAssertEqual(DictationSession.join(["Wait...", "then go"]), "Wait... then go")
    }

    func testSessionTranscribesPartsInOrderAndDropsNoise() async throws {
        // Parts run concurrently, so each reply depends only on its part's length in seconds.
        struct BySeconds: SpeechToText {
            func transcribe(_ audio: [Float]) async throws -> String {
                try await Task.sleep(for: .milliseconds(audio.count > 70_000 ? 50 : 0))
                return [4: "First part.", 5: ".", 1: "second part."][audio.count / 16000]!
            }
        }
        let session = DictationSession(speechToText: BySeconds())
        let pause = [Float](repeating: 0, count: 4800)
        session.append(tone(seconds: 4) + pause + tone(seconds: 5) + pause)
        session.append(tone(seconds: 1))
        let text = try await session.finish()
        XCTAssertEqual(text, "First part second part.")
    }

    func testProgressReportsOnlyFinishedLeadingParts() async throws {
        // The second part finishes first but is reported only with the first, once both are done.
        struct FirstIsSlow: SpeechToText {
            func transcribe(_ audio: [Float]) async throws -> String {
                if audio.count > 70_000 {
                    try await Task.sleep(for: .milliseconds(100))
                    return "One."
                }
                return "two."
            }
        }
        let session = DictationSession(speechToText: FirstIsSlow())
        var progress: [(String, TimeInterval)] = []
        let reported = expectation(description: "progress")
        session.onProgress = { text, time in
            progress.append((text, time))
            reported.fulfill()
        }
        let pause = [Float](repeating: 0, count: 4800)
        session.append(tone(seconds: 5) + pause + tone(seconds: 4) + pause)
        await fulfillment(of: [reported], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(progress.map(\.0), ["One two."])
        XCTAssertEqual(progress.map(\.1), [9.6])
    }

    func testPreviewShowsLiveWordsAfterTheTranscript() {
        var preview = PreviewText()
        preview.update([
            TimedText(text: "Hello", start: 0, end: 0.5),
            TimedText(text: " word", start: 1.2, end: 1.8),
            TimedText(text: " there", start: 2.9, end: 3.9),  // Mostly after the transcribed audio
        ])
        XCTAssertEqual(preview.committed, "")
        XCTAssertEqual(preview.pending, "Hello word there")
        preview.commit("Hello world.", through: 3)
        XCTAssertEqual(preview.committed, "Hello world.")
        XCTAssertEqual(preview.pending, "there")
        preview.commit("Hello world. There.", through: 4)
        XCTAssertEqual(preview.pending, "")
        // A live result still covering transcribed audio is hidden until it moves past it.
        preview.update([TimedText(text: "Hello world there and", start: 0, end: 5)])
        XCTAssertEqual(preview.pending, "")
        preview.update([TimedText(text: "Hello world there", start: 0, end: 4), TimedText(text: " and more", start: 4, end: 5)])
        XCTAssertEqual(preview.pending, "and more")
    }
}

private func tone(seconds: Int) -> [Float] {
    (0..<seconds * 16000).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16000) }
}

/// A loud key click that rings for about 40 ms.
private func click() -> [Float] {
    (0..<800).map { (i: Int) -> Float in
        let t = Float(i)
        return 0.5 * exp(-t / 160) * sin(t * 2 * .pi * 2500 / 16000)
    }
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
        guard config.transcription.remoteEnabled else {
            XCTFail("Live test configuration must explicitly enable remote transcription")
            return
        }
        let remote = RemoteSpeechToText(config: config.transcription)
        for _ in 0..<2 {
            let text = try await remote.transcribe(audio)
            XCTAssertTrue(text.lowercased().contains("quick brown fox"))
        }
    }

    func testLocal() async throws {
        let audio = try audioFile()
        let local = LocalSpeechToText(whisper: Whisper(model: Config().transcription.model), language: "en")
        let text = try await local.transcribe(audio)
        XCTAssertTrue(text.lowercased().contains("quick brown fox"))
    }
}
