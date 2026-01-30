import Foundation
import WhisperKit

actor WhisperTranscriber {
    private var whisperKit: WhisperKit?
    private var isLoading = false

    var isReady: Bool {
        whisperKit != nil
    }

    private static let modelsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".texttap/models")
    }()

    func loadModel() async throws {
        guard !isLoading && whisperKit == nil else { return }

        isLoading = true
        defer { isLoading = false }

        // Ensure models directory exists
        try? FileManager.default.createDirectory(
            at: Self.modelsDirectory,
            withIntermediateDirectories: true
        )

        let modelName = Config.shared.transcription.model
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: Self.modelsDirectory,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
    }

    // Artifacts to filter out
    private let artifactPatterns = [
        #"\[[^\]]*\]"#,   // Anything in square brackets
        #"\([^)]*\)"#,    // Anything in parentheses
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

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
