import FluidAudio

/// A part of a recording, with the recording sample index where it ends.
struct Segment {
    let audio: [Float]
    let end: Int
}

/// Cuts a recording into segments at pauses, so each segment is transcribed on its own. Only
/// segments with speech are returned.
///
/// A segment ends where the detector reports the end of speech. A segment that keeps going for
/// 20 s ends at the quietest chunk of its last 3 s. While there is no speech, only the last
/// 0.5 s is kept, so a segment starts just before its first word.
struct Segmenter {
    static let maxSegmentLength = 20 * Int(Recorder.sampleRate)
    static let preRollLength = Int(Recorder.sampleRate) / 2
    static let quietestWindow = 12  // Chunks, about 3 s

    private let detector: any SpeechDetector
    private var state = VadStreamState.initial()
    private var pending: [Float] = []  // Audio that does not fill a detector chunk yet
    private var audio: [Float] = []  // Audio not yet returned in a segment
    private var audioStart = 0  // Recording sample index of `audio[0]`
    private var recent: [(end: Int, probability: Float)] = []  // Last chunks, for the quietest cut

    init(detector: any SpeechDetector) {
        self.detector = detector
    }

    mutating func append(_ input: [Float]) async throws -> [Segment] {
        pending += input
        var segments: [Segment] = []
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            audio += chunk
            let result = try await detector.detect(chunk, state: state)
            state = result.state
            recent.append((audioStart + audio.count, result.probability))
            if recent.count > Self.quietestWindow { recent.removeFirst() }

            if let event = result.event, event.isEnd {
                segments.append(cut(atSample: event.sampleIndex))
            } else if audio.count >= Self.maxSegmentLength,
                      let quietest = recent.min(by: { $0.probability < $1.probability }) {
                segments.append(cut(atSample: quietest.end))
            }
            if !state.triggered {
                drop(before: audioStart + audio.count - Self.preRollLength)
            }
        }
        return segments
    }

    /// Returns the segments left at the end of the recording. The last one is returned only
    /// when speech is still going on.
    mutating func finish() async throws -> [Segment] {
        pending += [Float](repeating: 0, count: (VadManager.chunkSize - pending.count) % VadManager.chunkSize)
        var segments = try await append([])
        if state.triggered {
            segments.append(cut(atSample: audioStart + audio.count))
        }
        return segments
    }

    /// Returns the audio before the sample index `sample` as a segment, and keeps the rest.
    private mutating func cut(atSample sample: Int) -> Segment {
        let end = min(max(sample, audioStart), audioStart + audio.count)
        let segment = Segment(audio: Array(audio.prefix(end - audioStart)), end: end)
        drop(before: end)
        recent = []
        return segment
    }

    private mutating func drop(before sample: Int) {
        let count = min(max(sample - audioStart, 0), audio.count)
        audio.removeFirst(count)
        audioStart += count
    }
}
