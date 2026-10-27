import AVFoundation
import Foundation

/// Records 16 kHz mono audio and delivers it in segments cut at pauses, so finished
/// segments can be transcribed while recording continues.
final class AudioRecorder {
    static let sampleRate: Double = 16000  // Whisper expects 16kHz

    private var audioEngine: AVAudioEngine?
    private let lock = NSLock()
    private var segmenter = Segmenter()
    private var onSegment: (([Float], Bool) -> Void)?

    var onAudioLevel: ((Float) -> Void)?

    /// Starts recording. `onSegment` receives each segment on the main queue, in order;
    /// the final call after `stop()` has `isLast` set and may carry an empty segment.
    func start(onSegment: @escaping (_ samples: [Float], _ isLast: Bool) -> Void) throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.unsupportedInput
        }

        lock.withLock {
            segmenter = Segmenter()
            self.onSegment = onSegment
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))

            let level = Self.rms(samples[...])
            DispatchQueue.main.async { self.onAudioLevel?(level) }

            self.lock.withLock {
                guard let onSegment = self.onSegment else { return }
                for segment in self.segmenter.append(samples) {
                    DispatchQueue.main.async { onSegment(segment, false) }
                }
            }
        }

        try audioEngine.start()
        self.audioEngine = audioEngine
    }

    /// Stops recording and delivers the remaining audio as the last segment.
    /// With `deliver` false, the remaining audio is discarded and nothing is delivered.
    func stop(deliver: Bool = true) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        lock.withLock {
            // Clearing the callback also discards any tap buffer still in flight.
            guard let onSegment else { return }
            self.onSegment = nil
            guard deliver else { return }
            let rest = segmenter.finish()
            DispatchQueue.main.async { onSegment(rest, true) }
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

enum RecordingError: Error {
    case unsupportedInput
}

/// Splits audio at pauses. A segment ends after 300 ms below a tenth of the loudest level
/// so far once it is at least 3 seconds long, or at the quietest point of its last
/// 3 seconds when it reaches 15 seconds without a pause.
struct Segmenter {
    static let frameLength = Int(AudioRecorder.sampleRate) / 10  // 100 ms
    private let minFrames = 30
    private let maxFrames = 150
    private let pauseFrames = 3

    private var samples: [Float] = []
    private var levels: [Float] = []  // RMS of each complete frame in `samples`
    private var loudest: Float = 0

    mutating func append(_ input: [Float]) -> [[Float]] {
        samples += input
        var segments: [[Float]] = []
        while (levels.count + 1) * Self.frameLength <= samples.count {
            let start = levels.count * Self.frameLength
            let level = AudioRecorder.rms(samples[start..<start + Self.frameLength])
            levels.append(level)
            loudest = max(loudest, level)

            let threshold = max(loudest / 10, 0.002)
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
