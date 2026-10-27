import Foundation
import WhisperKit

actor WhisperTranscriber {
    private var whisperKit: WhisperKit?
    private var modelLoadTask: Task<WhisperKit, Error>?

    private static let baseDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".texttap")
    }()

    func loadModel() async throws {
        guard whisperKit == nil else { return }
        if let task = modelLoadTask {
            whisperKit = try await task.value
            return
        }

        let modelName = Config.shared.transcription.model
        let task = Task {
            try FileManager.default.createDirectory(
                at: Self.baseDirectory,
                withIntermediateDirectories: true
            )
            return try await WhisperKit(WhisperKitConfig(
                model: modelName,
                downloadBase: Self.baseDirectory,
                load: true,
                download: true
            ))
        }
        modelLoadTask = task
        defer { modelLoadTask = nil }
        whisperKit = try await task.value
    }

    // Artifacts to filter out
    private let artifactPatterns = [
        #"\[[^\]]*\]"#,   // Anything in square brackets
        #"\([^)]*\)"#,    // Anything in parentheses
        #"<\|[^|]*\|>"#,  // Special tokens like <|startoftranscript|>
    ]

    func transcribe(audio: [Float]) async throws -> String {
        guard let whisperKit = whisperKit else {
            print("[TextTap] WhisperKit not initialized")
            throw TranscriptionError.modelNotLoaded
        }

        // Without VAD, Whisper's seek-loop can jump forward on long audio and skip most segments.
        let options = DecodingOptions(
            language: Config.shared.transcription.language,
            chunkingStrategy: .vad
        )

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: options
        )

        print("[TextTap] WhisperKit returned \(results.count) segment(s)")

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

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalText
    }
}

enum TranscriptionError: Error, LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        }
    }
}
