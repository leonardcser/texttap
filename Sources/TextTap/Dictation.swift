import Foundation

enum DictationState {
    case idle
    case recording
    case transcribing
}

/// Records speech, shows it in the overlay, and inserts the transcript at the cursor.
final class Dictation {
    var onStateChange: (DictationState) -> Void = { _ in }
    private(set) var state = DictationState.idle {
        didSet { onStateChange(state) }
    }

    private let config: Config
    private let whisper: Whisper
    private let recorder = Recorder()
    private let overlay: Overlay
    private let inserter = TextInserter()
    private var session: DictationSession?
    private var recognizer: LiveRecognizer?
    private var preview = PreviewText()

    init(config: Config, whisper: Whisper) {
        self.config = config
        self.whisper = whisper
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
        let session = DictationSession(speechToText: speechToText())
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
final class DictationSession {
    /// Receives, on the main queue, the transcript of the leading parts that are finished
    /// and the recording time they cover, each time it grows.
    var onProgress: (String, TimeInterval) -> Void = { _, _ in }

    private struct Part {
        let task: Task<String, Error>
        let end: Int  // Sample offset where the part ends in the recording
        var text: String?
    }

    private let speechToText: SpeechToText
    private var segmenter = Segmenter()
    private var parts: [Part] = []
    private var transcribedSamples = 0

    // Whisper output that is only noise
    private static let noise: Set<String> = ["[", "]", "(", ")", ".", ",", "!", "?", "-", "—", "..."]

    init(speechToText: SpeechToText) {
        self.speechToText = speechToText
    }

    func append(_ samples: [Float]) {
        segmenter.append(samples).forEach(transcribe)
    }

    /// Transcribes the remaining audio and returns the whole transcript.
    func finish() async throws -> String {
        transcribe(segmenter.finish())
        var texts: [String] = []
        for part in parts {
            texts.append(try await part.task.value)
        }
        return Self.transcript(texts)
    }

    func cancel() {
        parts.forEach { $0.task.cancel() }
    }

    /// Whisper invents text such as "Thank you." for audio without speech, so such parts,
    /// like the noise and key clicks after the last pause, are skipped.
    private func transcribe(_ audio: [Float]) {
        transcribedSamples += audio.count
        guard segmenter.containsSpeech(audio) else { return }
        let speechToText = speechToText
        let task = Task { try await speechToText.transcribe(audio) }
        parts.append(Part(task: task, end: transcribedSamples))
        let index = parts.count - 1
        Task { [weak self] in
            guard let text = try? await task.value else { return }
            DispatchQueue.main.async { self?.finished(index, text) }
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

/// Splits audio at pauses. A segment ends after 300 ms below a tenth of the loudest level
/// so far once it is at least 3 seconds long, or at the quietest point of its last
/// 3 seconds when it reaches 15 seconds without a pause.
struct Segmenter {
    static let frameLength = Int(Recorder.sampleRate) / 10  // 100 ms
    private let minFrames = 30
    private let maxFrames = 150
    private let pauseFrames = 3

    private var samples: [Float] = []
    private var levels: [Float] = []  // Level of each complete frame in `samples`
    private var loudest: Float = 0

    mutating func append(_ input: [Float]) -> [[Float]] {
        samples += input
        var segments: [[Float]] = []
        while (levels.count + 1) * Self.frameLength <= samples.count {
            let start = levels.count * Self.frameLength
            let level = Recorder.level(samples[start..<start + Self.frameLength])
            levels.append(level)
            loudest = max(loudest, level)

            if levels.count >= minFrames, levels.suffix(pauseFrames).allSatisfy({ $0 < threshold }) {
                segments.append(cut(atFrame: levels.count))
            } else if levels.count >= maxFrames {
                let recent = levels.indices.suffix(minFrames)
                let quietest = recent.min { levels[$0] < levels[$1] }!
                segments.append(cut(atFrame: quietest + 1))
            }
        }
        return segments
    }

    /// Whether `audio` is above the threshold for at least 200 ms in total. Short windows keep
    /// brief clicks, such as the hotkey's, from counting as speech.
    func containsSpeech(_ audio: [Float]) -> Bool {
        let window = Self.frameLength / 5  // 20 ms
        let loud = stride(from: 0, to: audio.count - window + 1, by: window).count { start in
            Recorder.level(audio[start..<start + window]) >= threshold
        }
        return loud >= 10
    }

    /// Speech level: a tenth of the loudest so far, with a floor for near-silent recordings.
    private var threshold: Float {
        max(loudest / 10, 0.002)
    }

    /// Returns the audio not yet returned as a segment.
    mutating func finish() -> [Float] {
        defer {
            samples = []
            levels = []
        }
        return samples
    }

    private mutating func cut(atFrame frame: Int) -> [Float] {
        let end = frame * Self.frameLength
        let segment = Array(samples[..<end])
        samples.removeFirst(end)
        levels.removeFirst(frame)
        return segment
    }
}
