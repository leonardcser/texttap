import AVFoundation

/// Captures microphone audio as 16 kHz mono samples, the format Whisper expects.
final class Recorder {
    static let sampleRate = 16000.0

    private var engine: AVAudioEngine?

    /// Starts recording. `onSamples` receives each captured buffer on the main actor.
    func start(onSamples: @escaping @MainActor ([Float]) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw RecorderError.unsupportedInput
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            // Supply each input buffer once; the converter keeps any remainder for the next call.
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            DispatchQueue.main.async { MainActor.assumeIsolated { onSamples(samples) } }
        }

        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    static func level(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    static func pcm16(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * Float(Int16.max))
    }
}

enum RecorderError: Error {
    case unsupportedInput
}
