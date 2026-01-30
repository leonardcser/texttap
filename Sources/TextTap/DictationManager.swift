import Foundation

enum DictationState {
    case idle
    case recording
    case loading       // Transcribing, first stop requested
    case stopping      // Loading + second stop requested (will cancel)
}

class DictationManager {
    private let audioRecorder = AudioRecorder()
    private let silenceDetector = SilenceDetector()
    private let cursorTracker = CursorTracker()
    private let cursorIndicator = CursorIndicator()
    private let textInserter = TextInserter()
    private let transcriber = WhisperTranscriber()

    // Whisper noise artifacts to filter out
    private let noisePatterns: Set<String> = ["[", "]", "(", ")", ".", ",", "!", "?", "-", "—", "..."]

    private var currentAudioURL: URL?
    private var isTranscribing = false
    private var modelLoadTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var dictationState: DictationState = .idle

    var isActive = false
    var isModelLoaded = false
    var onStateChange: ((Bool) -> Void)?
    var onModelStateChange: ((Bool) -> Void)?

    init() {
        setupCallbacks()
        preloadModel()
    }

    private func setupCallbacks() {
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.silenceDetector.processLevel(level)
            self?.cursorIndicator.updateLevel(level)
        }

        silenceDetector.onSilenceDetected = { [weak self] in
            self?.handleSilenceDetected()
        }

        cursorTracker.onCursorPositionChanged = { [weak self] rect in
            self?.cursorIndicator.updatePosition(rect)
        }
    }

    private func preloadModel() {
        modelLoadTask = Task {
            await MainActor.run {
                onModelStateChange?(false)
            }
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

    func start() {
        guard dictationState == .idle else { return }

        dictationState = .recording
        isActive = true
        silenceDetector.reset()
        cursorIndicator.reset()
        cursorIndicator.setState(.recording)

        onStateChange?(true)

        do {
            currentAudioURL = try audioRecorder.startRecording()
            cursorTracker.startTracking()
            cursorIndicator.show()
        } catch {
            print("[TextTap] Failed to start recording: \(error)")
            stop()
        }
    }

    func stop() {
        switch dictationState {
        case .idle:
            return

        case .recording:
            dictationState = .idle
            isActive = false
            onStateChange?(false)

            _ = audioRecorder.stopRecording()
            cursorTracker.stopTracking()
            cursorIndicator.hide()
            silenceDetector.reset()

            audioRecorder.cleanup()
            currentAudioURL = nil

        case .loading:
            dictationState = .stopping

        case .stopping:
            transcriptionTask?.cancel()
            transcriptionTask = nil
            finishAndCleanup()
        }
    }

    func stopAndPaste() {
        print("[TextTap] stopAndPaste called, state=\(dictationState)")
        switch dictationState {
        case .idle:
            print("[TextTap] Already idle, nothing to do")
            return

        case .recording:
            let audioURL = audioRecorder.stopRecording()
            silenceDetector.reset()

            dictationState = .loading
            cursorIndicator.setState(.loading)
            isActive = false
            onStateChange?(false)

            if let url = audioURL {
                // Log file size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let fileSize = attrs[.size] as? Int64 {
                    print("[TextTap] Audio file ready: \(url.lastPathComponent), size: \(fileSize) bytes")
                }
                transcriptionTask = Task {
                    await transcribeAndInsert(url: url)
                }
            } else {
                print("[TextTap] No audio URL returned from stopRecording")
                finishAndCleanup()
            }

        case .loading:
            dictationState = .stopping

        case .stopping:
            transcriptionTask?.cancel()
            transcriptionTask = nil
            finishAndCleanup()
        }
    }

    private func finishAndCleanup() {
        dictationState = .idle
        isActive = false
        onStateChange?(false)

        cursorTracker.stopTracking()
        cursorIndicator.hide()

        audioRecorder.cleanup()
        currentAudioURL = nil
        isTranscribing = false
    }

    private func handleSilenceDetected() {
        print("[TextTap] Silence detected, state=\(dictationState), isTranscribing=\(isTranscribing)")
        guard dictationState == .recording, !isTranscribing else {
            print("[TextTap] Ignoring silence: wrong state or already transcribing")
            return
        }
        guard let audioURL = audioRecorder.stopRecording() else {
            print("[TextTap] Failed to get audio URL from stopRecording")
            return
        }

        // Log file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
           let fileSize = attrs[.size] as? Int64 {
            print("[TextTap] Audio file size: \(fileSize) bytes")
        }

        isTranscribing = true
        dictationState = .loading
        cursorIndicator.setState(.loading)

        transcriptionTask = Task {
            await transcribeAndContinue(url: audioURL)
        }
    }

    private func transcribeAndContinue(url: URL) async {
        print("[TextTap] transcribeAndContinue starting for \(url.lastPathComponent)")
        if let task = modelLoadTask {
            print("[TextTap] Waiting for model to load...")
            await task.value
        }

        if Task.isCancelled {
            print("[TextTap] Task cancelled before transcription")
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { finishAndCleanup() }
            return
        }

        guard await transcriber.isReady else {
            print("[TextTap] Transcriber not ready, skipping")
            await MainActor.run {
                isTranscribing = false
                cursorIndicator.setState(.recording)
            }
            return
        }

        do {
            let text = try await transcriber.transcribe(audioURL: url)
            print("[TextTap] Transcription result: '\(text)' (length: \(text.count))")

            if Task.isCancelled {
                print("[TextTap] Task cancelled after transcription")
                try? FileManager.default.removeItem(at: url)
                await MainActor.run { finishAndCleanup() }
                return
            }

            if !isNoiseTranscription(text) {
                print("[TextTap] Inserting text: '\(text + " ")'")
                await MainActor.run {
                    textInserter.insertIncremental(text + " ")
                }
            } else {
                print("[TextTap] Filtered as noise: '\(text)'")
            }
        } catch {
            print("[TextTap] Transcription error: \(error)")
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                await MainActor.run { finishAndCleanup() }
                return
            }
        }

        try? FileManager.default.removeItem(at: url)

        await MainActor.run {
            isTranscribing = false

            if dictationState == .stopping {
                finishAndCleanup()
                return
            }

            if dictationState == .loading && isActive {
                dictationState = .recording
                cursorIndicator.setState(.recording)
                silenceDetector.reset()
                do {
                    currentAudioURL = try audioRecorder.startRecording()
                } catch {
                    stop()
                }
            }
        }
    }

    private func transcribeAndInsert(url: URL) async {
        print("[TextTap] transcribeAndInsert starting for \(url.lastPathComponent)")

        // Log file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int64 {
            print("[TextTap] Audio file size: \(fileSize) bytes")
        }

        if let task = modelLoadTask {
            print("[TextTap] Waiting for model to load...")
            await task.value
        }

        if Task.isCancelled {
            print("[TextTap] Task cancelled before transcription")
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { finishAndCleanup() }
            return
        }

        if await transcriber.isReady {
            do {
                let text = try await transcriber.transcribe(audioURL: url)
                print("[TextTap] Transcription result: '\(text)' (length: \(text.count))")

                if Task.isCancelled {
                    print("[TextTap] Task cancelled after transcription")
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run { finishAndCleanup() }
                    return
                }

                if !isNoiseTranscription(text) {
                    print("[TextTap] Inserting text: '\(text)'")
                    await MainActor.run {
                        textInserter.insertIncremental(text)
                    }
                } else {
                    print("[TextTap] Filtered as noise: '\(text)'")
                }
            } catch {
                print("[TextTap] Transcription error: \(error)")
            }
        } else {
            print("[TextTap] Transcriber not ready, skipping transcription")
        }

        try? FileManager.default.removeItem(at: url)

        await MainActor.run {
            finishAndCleanup()
        }
    }

    private func isNoiseTranscription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || noisePatterns.contains(trimmed)
    }

    func cleanup() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        dictationState = .idle
        isActive = false

        _ = audioRecorder.stopRecording()
        cursorTracker.stopTracking()
        cursorIndicator.hide()
        silenceDetector.reset()
        audioRecorder.cleanup()
        currentAudioURL = nil

        cursorIndicator.cleanup()
        modelLoadTask?.cancel()
    }
}
