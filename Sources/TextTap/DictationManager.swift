import Foundation

enum DictationState {
    case idle
    case recording
    case transcribing
}

class DictationManager {
    private let audioRecorder = AudioRecorder()
    private let cursorTracker = CursorTracker()
    private let cursorIndicator = CursorIndicator()
    private let textInserter = TextInserter()
    private let whisperTranscriber = WhisperTranscriber()
    private let transcriber = Transcriber()

    // Whisper noise artifacts to filter out
    private let noisePatterns: Set<String> = ["[", "]", "(", ")", ".", ",", "!", "?", "-", "—", "..."]

    // Segments are transcribed as soon as they are recorded, in recording order.
    private var segments: [Task<String, Error>] = []
    private var dictationID: UUID?
    private var modelLoadTask: Task<Void, Never>?
    private(set) var dictationState: DictationState = .idle

    var isActive: Bool { dictationState == .recording }
    var onStateChange: ((DictationState) -> Void)?

    init() {
        setupCallbacks()
        preloadModel()
    }

    private func setupCallbacks() {
        audioRecorder.onAudioLevel = { [weak self] level in
            guard self?.dictationState == .recording else { return }
            self?.cursorIndicator.updateLevel(level)
        }

        cursorTracker.onCursorPositionChanged = { [weak self] rect in
            self?.cursorIndicator.updatePosition(rect)
        }
    }

    private func preloadModel() {
        modelLoadTask = Task {
            do {
                try await whisperTranscriber.loadModel()
            } catch {
                print("[TextTap] Local Whisper preload failed; will retry when needed")
            }
        }
    }

    // MARK: - Recording Control

    func start() {
        guard dictationState == .idle else { return }

        let id = UUID()
        dictationID = id
        dictationState = .recording
        cursorIndicator.reset()
        cursorIndicator.setState(.recording)
        onStateChange?(.recording)

        do {
            try audioRecorder.start { [weak self] samples, isLast in
                guard let self, self.dictationID == id else { return }
                self.receive(samples, isLast: isLast)
            }
            cursorTracker.startTracking()
            cursorIndicator.show()
        } catch {
            print("[TextTap] Failed to start recording: \(error)")
            cancel()
        }
    }

    func stopAndPaste() {
        switch dictationState {
        case .idle:
            return

        case .recording:
            dictationState = .transcribing
            cursorIndicator.setState(.loading)
            onStateChange?(.transcribing)
            // The recorder delivers the last segment, which inserts the joined text.
            audioRecorder.stop()

        case .transcribing:
            // Second stop while transcribing → cancel
            cancel()
        }
    }

    /// Cancel recording without transcribing (e.g. Esc key)
    func cancel() {
        guard dictationState != .idle else { return }
        audioRecorder.stop(deliver: false)
        finishAndCleanup()
    }

    // MARK: - Transcription

    private func receive(_ samples: [Float], isLast: Bool) {
        if !samples.isEmpty {
            segments.append(Task { try await transcribe(samples) })
        }
        guard isLast, let id = dictationID else { return }
        let segments = segments
        Task { @MainActor in
            do {
                var texts: [String] = []
                for segment in segments {
                    texts.append(try await segment.value)
                }
                guard dictationID == id else { return }
                textInserter.insertIncremental(Self.join(texts.filter { !isNoiseTranscription($0) }))
            } catch {
                guard dictationID == id else { return }
                print("[TextTap] Transcription failed")
            }
            finishAndCleanup()
        }
    }

    private func transcribe(_ audio: [Float]) async throws -> String {
        try await transcriber.transcribe(audio: audio, config: Config.shared.transcription) {
            if let task = self.modelLoadTask {
                await task.value
            }
            try Task.checkCancellation()
            try await self.whisperTranscriber.loadModel()
            try Task.checkCancellation()
            return try await self.whisperTranscriber.transcribe(audio: audio)
        }
    }

    private func finishAndCleanup() {
        dictationID = nil
        segments.forEach { $0.cancel() }
        segments = []
        dictationState = .idle
        onStateChange?(.idle)

        cursorTracker.stopTracking()
        cursorIndicator.hide()
    }

    /// Joins segment transcripts. A segment cut mid-sentence often ends with a period while
    /// the next one starts in lowercase, so that period is dropped.
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

    private func isNoiseTranscription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || noisePatterns.contains(trimmed)
    }

    func cleanup() {
        audioRecorder.stop(deliver: false)
        finishAndCleanup()
        cursorIndicator.cleanup()
        modelLoadTask?.cancel()
    }
}
