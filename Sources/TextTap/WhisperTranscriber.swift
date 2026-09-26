import Foundation
import WhisperKit

actor WhisperTranscriber {
    private var whisperKit: WhisperKit?
    private var modelLoadTask: Task<WhisperKit, Error>?

    var isReady: Bool {
        whisperKit != nil
    }

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

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit = whisperKit else {
            print("[TextTap] WhisperKit not initialized")
            throw TranscriptionError.modelNotLoaded
        }

        // Without VAD, Whisper's seek-loop can jump forward on long audio and skip most segments.
        let options = DecodingOptions(
            language: Config.shared.transcription.language,
            chunkingStrategy: .vad
        )

        print("[TextTap] Starting WhisperKit transcription for \(audioURL.lastPathComponent)")
        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
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
