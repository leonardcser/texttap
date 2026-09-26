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

    private var currentAudioURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionID: UUID?
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

        dictationState = .recording
        cursorIndicator.reset()
        cursorIndicator.setState(.recording)
        onStateChange?(.recording)

        do {
            currentAudioURL = try audioRecorder.startRecording()
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
            let audioURL = audioRecorder.stopRecording()

            dictationState = .transcribing
            cursorIndicator.setState(.loading)
            onStateChange?(.transcribing)

            guard let url = audioURL else {
                print("[TextTap] No audio URL returned from stopRecording")
                finishAndCleanup()
                return
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? Int64 {
                print("[TextTap] Audio file ready: \(url.lastPathComponent), size: \(fileSize) bytes")
            }

            let id = UUID()
            transcriptionID = id
            transcriptionTask = Task {
                await transcribe(url: url, id: id)
            }

        case .transcribing:
            // Second stop while transcribing → cancel
            transcriptionTask?.cancel()
            transcriptionTask = nil
            finishAndCleanup()
        }
    }

    /// Cancel recording without transcribing (e.g. Esc key)
    func cancel() {
        switch dictationState {
        case .idle:
            return
        case .recording:
            if let url = audioRecorder.stopRecording() {
                try? FileManager.default.removeItem(at: url)
            }
            audioRecorder.cleanup()
        case .transcribing:
            transcriptionTask?.cancel()
            transcriptionTask = nil
        }
        finishAndCleanup()
    }

    // MARK: - Transcription

    @MainActor
    private func transcribe(url: URL, id: UUID) async {
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let text = try await transcriber.transcribe(audioURL: url, config: Config.shared.transcription) {
                if let task = self.modelLoadTask {
                    await task.value
                }
                try Task.checkCancellation()
                try await self.whisperTranscriber.loadModel()
                try Task.checkCancellation()
                return try await self.whisperTranscriber.transcribe(audioURL: url)
            }

            guard transcriptionID == id, !Task.isCancelled else { return }
            if !isNoiseTranscription(text) {
                textInserter.insertIncremental(text)
            }
            finishAndCleanup()
        } catch {
            guard transcriptionID == id, !Task.isCancelled else { return }
            print("[TextTap] Transcription failed")
            finishAndCleanup()
        }
    }

    private func finishAndCleanup() {
        transcriptionID = nil
        dictationState = .idle
        onStateChange?(.idle)

        cursorTracker.stopTracking()
        cursorIndicator.hide()

        audioRecorder.cleanup()
        currentAudioURL = nil
        transcriptionTask = nil
    }

    private func isNoiseTranscription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || noisePatterns.contains(trimmed)
    }

    func cleanup() {
        transcriptionID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let url = audioRecorder.stopRecording() {
            try? FileManager.default.removeItem(at: url)
        }
        cursorTracker.stopTracking()
        cursorIndicator.hide()
        audioRecorder.cleanup()
        currentAudioURL = nil
        cursorIndicator.cleanup()
        modelLoadTask?.cancel()
        dictationState = .idle
    }
}
