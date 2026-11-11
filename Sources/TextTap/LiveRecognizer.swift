import AVFoundation
import Speech

/// Recognized text and when it is spoken in the recording.
struct TimedText: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Recognizes words as they are spoken, using Apple's on-device recognizer, and revises the
/// latest ones as more audio arrives. Does nothing before macOS 26.
final class LiveRecognizer {
    private let samples: AsyncStream<[Float]>.Continuation
    private let task: Task<Void, Never>

    /// `onWords` receives every word recognized so far, each time they change.
    init(language: String, onWords: @escaping @MainActor ([TimedText]) -> Void) {
        let (stream, samples) = AsyncStream<[Float]>.makeStream()
        self.samples = samples
        task = Task {
            guard #available(macOS 26, *) else { return }
            do {
                try await Self.recognize(stream, language: language, onWords: onWords)
            } catch {
                if !Task.isCancelled { print("[TextTap] Live recognition unavailable: \(error)") }
            }
        }
    }

    func append(_ samples: [Float]) {
        self.samples.yield(samples)
    }

    func stop() {
        samples.finish()
        task.cancel()
    }

    @available(macOS 26, *)
    private static func recognize(
        _ stream: AsyncStream<[Float]>,
        language: String,
        onWords: @escaping @MainActor ([TimedText]) -> Void
    ) async throws {
        let requested = language.isEmpty ? Locale.current : Locale(identifier: language)
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Recorder.sampleRate, channels: 1, interleaved: false)!
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format),
              best.commonFormat == format.commonFormat,
              best.sampleRate == format.sampleRate,
              best.channelCount == format.channelCount else { return }

        let input = stream.map { samples in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            let channel = buffer.int16ChannelData![0]
            for (index, sample) in samples.enumerated() {
                channel[index] = Recorder.pcm16(sample)
            }
            return AnalyzerInput(buffer: buffer)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await withTaskCancellationHandler {
            try await analyzer.start(inputSequence: input)
            // Final results replace their volatile versions and time each word; the newest
            // volatile result is a single run covering everything after the last final one.
            var final: [TimedText] = []
            for try await result in transcriber.results {
                let words = result.text.runs.map { run in
                    let time = run.audioTimeRange ?? result.range
                    return TimedText(text: String(result.text[run.range].characters), start: time.start.seconds, end: time.end.seconds)
                }
                if result.isFinal { final += words }
                await onWords(result.isFinal ? final : final + words)
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
