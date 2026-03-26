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
    private let transcriber = WhisperTranscriber()

    // Whisper noise artifacts to filter out
    private let noisePatterns: Set<String> = ["[", "]", "(", ")", ".", ",", "!", "?", "-", "—", "..."]

    private var currentAudioURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    private(set) var dictationState: DictationState = .idle

    var isActive: Bool { dictationState == .recording }
    var isModelLoaded = false
    var onStateChange: ((DictationState) -> Void)?
    var onModelStateChange: ((Bool) -> Void)?

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
            await MainActor.run { onModelStateChange?(false) }
            do {
                try await transcriber.loadModel()
                await MainActor.run {
                    isModelLoaded = true
                    onModelStateChange?(true)
                }
            } catch {
                print("[TextTap] Failed to load model: \(error)")
                await MainActor.run {
                    isModelLoaded = false
                    onModelStateChange?(true)
                }
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

            transcriptionTask = Task {
                await transcribe(url: url)
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
            _ = audioRecorder.stopRecording()
            audioRecorder.cleanup()
        case .transcribing:
            transcriptionTask?.cancel()
            transcriptionTask = nil
        }
        finishAndCleanup()
    }

    // MARK: - Transcription

    private func transcribe(url: URL) async {
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        if let task = modelLoadTask {
            print("[TextTap] Waiting for model to load...")
            await task.value
        }

        guard !Task.isCancelled else { return }

        guard await transcriber.isReady else {
            print("[TextTap] Transcriber not ready")
            await MainActor.run { finishAndCleanup() }
            return
        }

        do {
            let text = try await transcriber.transcribe(audioURL: url)
            print("[TextTap] Transcription result: '\(text)' (length: \(text.count))")

            guard !Task.isCancelled else { return }

            if !isNoiseTranscription(text) {
                await MainActor.run {
                    textInserter.insertIncremental(text)
                }
            } else {
                print("[TextTap] Filtered as noise: '\(text)'")
            }
        } catch {
            print("[TextTap] Transcription error: \(error)")
        }

        await MainActor.run { finishAndCleanup() }
    }

    private func finishAndCleanup() {
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
        transcriptionTask?.cancel()
        transcriptionTask = nil
        _ = audioRecorder.stopRecording()
        cursorTracker.stopTracking()
        cursorIndicator.hide()
        audioRecorder.cleanup()
        currentAudioURL = nil
        cursorIndicator.cleanup()
        modelLoadTask?.cancel()
        dictationState = .idle
    }
}
