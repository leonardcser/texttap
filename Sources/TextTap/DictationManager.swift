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
    private var pendingSegments: [URL] = []
    private var processingTask: Task<Void, Never>?
    private var isFinalSegmentQueued = false
    private var modelLoadTask: Task<Void, Never>?
    private var dictationState: DictationState = .idle

    var isActive = false
    var isModelLoaded = false
    var onStateChange: ((Bool) -> Void)?
    var onTranscribingChange: ((Bool) -> Void)?
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

            processingTask?.cancel()
            processingTask = nil

            for url in pendingSegments {
                try? FileManager.default.removeItem(at: url)
            }
            pendingSegments.removeAll()
            isFinalSegmentQueued = false

            audioRecorder.cleanup()
            currentAudioURL = nil

        case .loading:
            dictationState = .stopping

        case .stopping:
            processingTask?.cancel()
            processingTask = nil
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
            onTranscribingChange?(true)

            if let url = audioURL {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let fileSize = attrs[.size] as? Int64 {
                    print("[TextTap] Audio file ready: \(url.lastPathComponent), size: \(fileSize) bytes")
                }
                pendingSegments.append(url)
                isFinalSegmentQueued = true
                startProcessingIfNeeded()
            } else {
                print("[TextTap] No audio URL returned from stopRecording")
                finishAndCleanup()
            }

        case .loading:
            dictationState = .stopping

        case .stopping:
            processingTask?.cancel()
            processingTask = nil
            finishAndCleanup()
        }
    }

    private func finishAndCleanup() {
        dictationState = .idle
        isActive = false
        onStateChange?(false)
        onTranscribingChange?(false)

        cursorTracker.stopTracking()
        cursorIndicator.hide()

        audioRecorder.cleanup()
        currentAudioURL = nil
        pendingSegments.removeAll()
        isFinalSegmentQueued = false
        processingTask = nil
    }

    // MARK: - Silence Detection & Segment Queue

    private func handleSilenceDetected() {
        print("[TextTap] Silence detected, state=\(dictationState)")
        guard dictationState == .recording else {
            print("[TextTap] Ignoring silence: not recording")
            return
        }
        guard let audioURL = audioRecorder.stopRecording() else {
            print("[TextTap] Failed to get audio URL from stopRecording")
            return
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
           let fileSize = attrs[.size] as? Int64 {
            print("[TextTap] Audio file size: \(fileSize) bytes")
        }

        pendingSegments.append(audioURL)

        silenceDetector.reset()
        do {
            currentAudioURL = try audioRecorder.startRecording()
            print("[TextTap] Recording restarted immediately after silence detection")
        } catch {
            print("[TextTap] Failed to restart recording: \(error)")
            dictationState = .loading
            cursorIndicator.setState(.loading)
            onTranscribingChange?(true)
        }

        startProcessingIfNeeded()
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task {
            await processSegments()
        }
    }

    private func processSegments() async {
        while true {
            if Task.isCancelled {
                await MainActor.run {
                    for url in pendingSegments {
                        try? FileManager.default.removeItem(at: url)
                    }
                    pendingSegments.removeAll()
                    processingTask = nil
                }
                return
            }

            let segment: (url: URL, isFinal: Bool)? = await MainActor.run {
                if pendingSegments.isEmpty {
                    if isFinalSegmentQueued {
                        finishAndCleanup()
                    }
                    processingTask = nil
                    return nil
                }
                let url = pendingSegments.removeFirst()
                let isFinal = pendingSegments.isEmpty && isFinalSegmentQueued
                return (url, isFinal)
            }

            guard let segment = segment else { return }

            await transcribeSegment(url: segment.url, isFinal: segment.isFinal)
        }
    }

    private func transcribeSegment(url: URL, isFinal: Bool) async {
        print("[TextTap] transcribeSegment starting for \(url.lastPathComponent), isFinal=\(isFinal)")

        if let task = modelLoadTask {
            print("[TextTap] Waiting for model to load...")
            await task.value
        }

        if Task.isCancelled {
            print("[TextTap] Task cancelled before transcription")
            try? FileManager.default.removeItem(at: url)
            return
        }

        guard await transcriber.isReady else {
            print("[TextTap] Transcriber not ready, skipping")
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            let text = try await transcriber.transcribe(audioURL: url)
            print("[TextTap] Transcription result: '\(text)' (length: \(text.count))")

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                return
            }

            if !isNoiseTranscription(text) {
                let insertText = isFinal ? text : text + " "
                print("[TextTap] Inserting text: '\(insertText)'")
                await MainActor.run {
                    textInserter.insertIncremental(insertText)
                }
            } else {
                print("[TextTap] Filtered as noise: '\(text)'")
            }
        } catch {
            print("[TextTap] Transcription error: \(error)")
        }

        try? FileManager.default.removeItem(at: url)

        if isFinal {
            await MainActor.run {
                if dictationState == .stopping {
                    finishAndCleanup()
                }
            }
        }
    }

    private func isNoiseTranscription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || noisePatterns.contains(trimmed)
    }

    func cleanup() {
        processingTask?.cancel()
        processingTask = nil
        dictationState = .idle
        isActive = false

        _ = audioRecorder.stopRecording()
        cursorTracker.stopTracking()
        cursorIndicator.hide()
        silenceDetector.reset()

        for url in pendingSegments {
            try? FileManager.default.removeItem(at: url)
        }
        pendingSegments.removeAll()
        isFinalSegmentQueued = false

        audioRecorder.cleanup()
        currentAudioURL = nil

        cursorIndicator.cleanup()
        modelLoadTask?.cancel()
    }
}
