import Foundation
import WhisperKit

actor WhisperTranscriber {
    private var whisperKit: WhisperKit?
    private var isLoading = false

    var isReady: Bool {
        whisperKit != nil
    }

    func loadModel() async throws {
        guard !isLoading && whisperKit == nil else { return }

        isLoading = true
        defer { isLoading = false }

        let modelName = Config.shared.transcription.model
        let config = WhisperKitConfig(model: modelName, load: true)
        whisperKit = try await WhisperKit(config)
    }

    // Artifacts to filter out
    private let artifactPatterns = [
        #"\[BLANK_AUDIO\]"#,
        #"\[\s*[Ss]ilence\s*\]"#,
        #"\(\s*[Ss]ilence\s*\)"#,
        #"\[\s*[Mm]usic\s*\]"#,
        #"\(\s*[Mm]usic\s*\)"#,
        #"\[\s*[Ii]naudible\s*\]"#,
        #"\(\s*[Ii]naudible\s*\)"#,
        #"<\|[^|]*\|>"#,  // Special tokens like <|startoftranscript|>
    ]

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: Config.shared.transcription.language
        )

        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        let rawText = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WhisperTranscriber] Raw result: '\(rawText)'")

        var text = rawText

        // Filter out artifacts
        for pattern in artifactPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
            }
        }

        let filtered = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if filtered != rawText {
            print("[WhisperTranscriber] Filtered result: '\(filtered)'")
        }

        return filtered
    }

    func unload() {
        whisperKit = nil
    }
}

enum TranscriptionError: Error, LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
