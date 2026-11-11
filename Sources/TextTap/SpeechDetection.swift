import FluidAudio

/// Classifies 256 ms chunks of 16 kHz mono audio as speech or not, and reports where speech
/// starts and ends.
protocol SpeechDetector {
    func detect(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult
}

extension VadManager: SpeechDetector {
    func detect(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        try await processStreamingChunk(chunk, state: state, config: VadSegmentationConfig(minSilenceDuration: 0.5))
    }
}

/// The Silero VAD model, shared by every dictation.
typealias SileroVAD = ModelLoader<VadManager>

extension SileroVAD {
    init() {
        self.init("Silero VAD") { try await VadManager() }
    }
}
