import Foundation

class DictationManager {
    private let audioRecorder = AudioRecorder()
    private let silenceDetector = SilenceDetector()
    private let cursorTracker = CursorTracker()
    private let cursorIndicator = CursorIndicator()
    private let textInserter = TextInserter()
    private let transcriber = WhisperTranscriber()

    private var currentAudioURL: URL?
    private var isTranscribing = false
    private var modelLoadTask: Task<Void, Never>?

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
                print("[DictationManager] Loading Whisper model...")
                try await transcriber.loadModel()
                print("[DictationManager] Whisper model loaded successfully")
                await MainActor.run {
                    isModelLoaded = true
                    onModelStateChange?(true)
                }
            } catch {
                print("[DictationManager] Failed to preload Whisper model: \(error)")
                await MainActor.run {
                    isModelLoaded = false
                    onModelStateChange?(true)
                }
            }
        }
    }

    func start() {
        guard !isActive else { return }

        print("[DictationManager] Starting dictation")
        isActive = true
        silenceDetector.reset()
        cursorIndicator.reset()

        onStateChange?(true)

        do {
            currentAudioURL = try audioRecorder.startRecording()
            print("[DictationManager] Recording started, file: \(currentAudioURL?.path ?? "nil")")
            cursorTracker.startTracking()
            cursorIndicator.show()
        } catch {
            print("[DictationManager] Failed to start recording: \(error)")
            stop()
        }
    }

    func stop() {
        guard isActive else { return }

        print("[DictationManager] Stopping dictation (no paste)")
        isActive = false
        onStateChange?(false)

        _ = audioRecorder.stopRecording()
        cursorTracker.stopTracking()
        cursorIndicator.hide()
        silenceDetector.reset()

        audioRecorder.cleanup()
        currentAudioURL = nil
    }

    func stopAndPaste() {
        guard isActive else { return }

        print("[DictationManager] Stopping dictation and pasting")
        let audioURL = audioRecorder.stopRecording()
        cursorTracker.stopTracking()
        cursorIndicator.hide()

        isActive = false
        onStateChange?(false)

        if let url = audioURL {
            print("[DictationManager] Final audio file: \(url.path)")
            Task {
                await transcribeAndInsert(url: url)
            }
        }
    }

    private func handleSilenceDetected() {
        print("[DictationManager] handleSilenceDetected called, isActive: \(isActive), isTranscribing: \(isTranscribing)")
        guard isActive, !isTranscribing else {
            print("[DictationManager] Ignoring silence - not active or already transcribing")
            return
        }

        guard let audioURL = audioRecorder.stopRecording() else {
            print("[DictationManager] No audio URL from stopRecording")
            return
        }

        print("[DictationManager] Got audio file for transcription: \(audioURL.path)")
        isTranscribing = true

        Task {
            await transcribeAndContinue(url: audioURL)
        }
    }

    private func transcribeAndContinue(url: URL) async {
        print("[DictationManager] transcribeAndContinue starting")

        if let task = modelLoadTask {
            await task.value
        }

        guard await transcriber.isReady else {
            print("[DictationManager] Transcriber not ready")
            await MainActor.run { isTranscribing = false }
            return
        }

        do {
            print("[DictationManager] Starting transcription...")
            let text = try await transcriber.transcribe(audioURL: url)
            print("[DictationManager] Transcription completed: '\(text)'")

            if !text.isEmpty {
                await MainActor.run {
                    textInserter.insertIncremental(text + " ")
                }
            }
        } catch {
            print("[DictationManager] Transcription failed: \(error)")
        }

        try? FileManager.default.removeItem(at: url)

        await MainActor.run {
            isTranscribing = false
            if self.isActive {
                print("[DictationManager] Restarting recording after transcription")
                self.silenceDetector.reset()
                do {
                    self.currentAudioURL = try self.audioRecorder.startRecording()
                } catch {
                    print("[DictationManager] Failed to restart recording: \(error)")
                    self.stop()
                }
            }
        }
    }

    private func transcribeAndInsert(url: URL) async {
        print("[DictationManager] transcribeAndInsert starting")

        if let task = modelLoadTask {
            await task.value
        }

        if await transcriber.isReady {
            do {
                print("[DictationManager] Final transcription...")
                let text = try await transcriber.transcribe(audioURL: url)
                print("[DictationManager] Final transcription result: '\(text)'")

                if !text.isEmpty {
                    await MainActor.run {
                        textInserter.insertIncremental(text)
                    }
                }
            } catch {
                print("[DictationManager] Final transcription failed: \(error)")
            }
        }

        try? FileManager.default.removeItem(at: url)

        await MainActor.run {
            audioRecorder.cleanup()
            currentAudioURL = nil
        }
    }

    func cleanup() {
        stop()
        cursorIndicator.cleanup()
        modelLoadTask?.cancel()
    }
}
