import Foundation

enum DictationState {
    case idle
    case recording
    case transcribing
}

/// Records speech, shows it in the overlay, and inserts the transcript at the cursor.
@MainActor
final class Dictation {
    var onStateChange: (DictationState) -> Void = { _ in }
    private(set) var state = DictationState.idle {
        didSet { onStateChange(state) }
    }

    private let config: Config
    private let whisper: Whisper
    private let vad: SileroVAD
    private let recorder = Recorder()
    private let overlay: Overlay
    private let inserter = TextInserter()
    private var session: DictationSession?
    private var recognizer: LiveRecognizer?
    private var preview = PreviewText()

    init(config: Config, whisper: Whisper, vad: SileroVAD) {
        self.config = config
        self.whisper = whisper
        self.vad = vad
        overlay = Overlay(config: config.indicator)
    }

    /// Starts recording, stops and inserts, or cancels a pending transcription.
    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .transcribing: cancel()
        }
    }

    func start() {
        guard state == .idle else { return }
        let session = DictationSession(speechToText: speechToText()) { [vad] in try await vad.model() }
        var recognizer: LiveRecognizer?
        if config.indicator.enabled && config.indicator.preview {
            session.onProgress = { [weak self] text, time in
                guard let self, self.session === session else { return }
                self.preview.commit(text, through: time)
                self.showPreview()
            }
            recognizer = LiveRecognizer(language: config.transcription.language) { [weak self] words in
                guard let self, self.session === session else { return }
                self.preview.update(words)
                self.showPreview()
            }
        }
        do {
            try recorder.start { [weak self] samples in
                guard let self, self.session === session else { return }
                session.append(samples)
                recognizer?.append(samples)
                self.overlay.setLevel(Recorder.level(samples[...]))
            }
        } catch {
            print("[TextTap] Failed to start recording: \(error)")
            recognizer?.stop()
            return
        }
        self.session = session
        self.recognizer = recognizer
        preview = PreviewText()
        overlay.show()
        state = .recording
    }

    /// Stops recording and inserts the transcript once every part is transcribed.
    func stop() {
        guard state == .recording, let session else { return }
        recorder.stop()
        recognizer?.stop()
        overlay.setBusy(true)
        state = .transcribing
        // Runs after the buffers the recorder already queued on the main queue.
        DispatchQueue.main.async {
            Task { @MainActor [weak self] in
                do {
                    let text = try await session.finish()
                    guard let self, self.session === session else { return }
                    self.inserter.insert(text)
                } catch {
                    guard self?.session === session else { return }
                    print("[TextTap] Transcription failed")
                }
                self?.reset()
            }
        }
    }

    /// Discards the recording or pending transcription without inserting anything.
    func cancel() {
        guard state != .idle else { return }
        recorder.stop()
        session?.cancel()
        reset()
    }

    private func reset() {
        session = nil
        recognizer?.stop()
        recognizer = nil
        overlay.hide()
        state = .idle
    }

    private func showPreview() {
        overlay.setText(preview.committed, pending: preview.pending)
    }

    private func speechToText() -> SpeechToText {
        let local = LocalSpeechToText(whisper: whisper, language: config.transcription.language)
        guard config.transcription.remoteEnabled else { return local }
        return FallbackSpeechToText(primary: RemoteSpeechToText(config: config.transcription), fallback: local)
    }
}

/// Transcribes one recording in parts cut at pauses, while recording continues, so only
/// the last part remains when recording stops.
@MainActor
final class DictationSession {
    /// Receives the transcript of the leading parts that are finished and the recording time
    /// they cover, each time it grows.
    var onProgress: (String, TimeInterval) -> Void = { _, _ in }

    private struct Part {
        let task: Task<String, Error>
        let end: Int  // Sample offset where the part ends in the recording
        var text: String?
    }

    private let speechToText: SpeechToText
    private let audio: AsyncStream<[Float]>.Continuation
    private var segmenting: Task<Void, Error>?
    private var parts: [Part] = []

    // Whisper output that is only noise
    private static let noise: Set<String> = ["[", "]", "(", ")", ".", ",", "!", "?", "-", "—", "..."]

    /// `detector` provides the speech detector, which may still be loading.
    init(speechToText: SpeechToText, detector: @escaping () async throws -> any SpeechDetector) {
        self.speechToText = speechToText
        let (stream, audio) = AsyncStream<[Float]>.makeStream()
        self.audio = audio
        segmenting = Task {
            var segmenter = Segmenter(detector: try await detector())
            for await samples in stream {
                for segment in try await segmenter.append(samples) { transcribe(segment) }
            }
            for segment in try await segmenter.finish() { transcribe(segment) }
        }
    }

    func append(_ samples: [Float]) {
        audio.yield(samples)
    }

    /// Waits for the remaining audio to be transcribed and returns the whole transcript.
    func finish() async throws -> String {
        audio.finish()
        try await segmenting?.value
        var texts: [String] = []
        for part in parts {
            texts.append(try await part.task.value)
        }
        return Self.transcript(texts)
    }

    func cancel() {
        audio.finish()
        segmenting?.cancel()
        parts.forEach { $0.task.cancel() }
    }

    private func transcribe(_ segment: Segment) {
        guard !segment.audio.isEmpty else { return }
        let speechToText = speechToText
        let audio = segment.audio
        let task = Task { try await speechToText.transcribe(audio) }
        parts.append(Part(task: task, end: segment.end))
        let index = parts.count - 1
        Task { [weak self] in
            guard let text = try? await task.value else { return }
            self?.finished(index, text)
        }
    }

    private func finished(_ index: Int, _ text: String) {
        parts[index].text = text
        let done = parts.prefix { $0.text != nil }
        guard done.count > index else { return }  // An earlier part is still pending
        onProgress(Self.transcript(done.map { $0.text! }), Double(done.last!.end) / Recorder.sampleRate)
    }

    private static func transcript(_ texts: [String]) -> String {
        join(texts.filter { !noise.contains($0) && !$0.isEmpty })
    }

    /// Joins part transcripts. A part cut mid-sentence often ends with a period while the
    /// next one starts in lowercase, so that period is dropped.
    static func join(_ texts: [String]) -> String {
        texts.reduce("") { text, next in
            guard !text.isEmpty else { return next }
            var text = text
            if next.first?.isLowercase == true, text.hasSuffix("."), !text.hasSuffix("..") {
                text.removeLast()
            }
            return text + " " + next
        }
    }
}

/// The overlay text: Whisper's transcript of the finished parts, which is what gets inserted,
/// then the live words recognized after them, which Whisper has not transcribed yet.
struct PreviewText {
    private(set) var committed = ""
    private var committedThrough: TimeInterval = 0
    private var words: [TimedText] = []

    /// Live words spoken mostly after the transcribed audio. Comparing midpoints also handles
    /// the newest live result, which is timed only as a whole.
    var pending: String {
        words.filter { ($0.start + $0.end) / 2 > committedThrough }.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func commit(_ transcript: String, through time: TimeInterval) {
        committed = transcript
        committedThrough = time
    }

    mutating func update(_ words: [TimedText]) {
        self.words = words
    }
}
