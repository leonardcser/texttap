import Foundation
import WhisperKit

actor WhisperTranscriber {
    private var whisperKit: WhisperKit?
    private var isLoading = false

    var isReady: Bool {
        whisperKit != nil
    }

    private static let baseDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".texttap")
    }()

    func loadModel() async throws {
        guard !isLoading && whisperKit == nil else { return }

        isLoading = true
        defer { isLoading = false }

        try? FileManager.default.createDirectory(
            at: Self.baseDirectory,
            withIntermediateDirectories: true
        )

        let modelName = Config.shared.transcription.model
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: Self.baseDirectory,
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
            print("[TextTap] WhisperKit not initialized")
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: Config.shared.transcription.language
        )

        print("[TextTap] Starting WhisperKit transcription for \(audioURL.lastPathComponent)")
        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        print("[TextTap] WhisperKit returned \(results.count) segment(s)")
        for (i, segment) in results.enumerated() {
            print("[TextTap]   Segment \(i): '\(segment.text)'")
        }

        let rawText = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("[TextTap] Raw joined text: '\(rawText)' (length: \(rawText.count))")

        var text = rawText

        // Filter out artifacts
        for pattern in artifactPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let before = text
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
                if before != text {
                    print("[TextTap] Artifact filter '\(pattern)' changed: '\(before)' -> '\(text)'")
                }
            }
        }

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[TextTap] Final transcription: '\(finalText)' (length: \(finalText.count))")
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
