import Foundation

class SilenceDetector {
    private var silenceStartTime: Date?
    private var hasHadVoiceActivity = false

    var onSilenceDetected: (() -> Void)?

    private let threshold: Float
    private let duration: Double

    init(threshold: Float = Config.shared.audio.silenceThreshold,
         duration: Double = Config.shared.audio.silenceDuration) {
        self.threshold = threshold
        self.duration = duration
    }

    private var lastLogTime: Date?

    func processLevel(_ level: Float) {
        if level > threshold {
            if !hasHadVoiceActivity {
                print("[TextTap] Voice activity started (level: \(String(format: "%.4f", level)) > threshold: \(threshold))")
            }
            hasHadVoiceActivity = true
            silenceStartTime = nil
        } else if hasHadVoiceActivity {
            if silenceStartTime == nil {
                silenceStartTime = Date()
                print("[TextTap] Silence started (level: \(String(format: "%.4f", level)) <= threshold: \(threshold))")
            } else if let startTime = silenceStartTime {
                let silenceDuration = Date().timeIntervalSince(startTime)
                if silenceDuration >= duration {
                    print("[TextTap] Silence duration (\(String(format: "%.2f", silenceDuration))s) exceeded threshold (\(duration)s), triggering transcription")
                    onSilenceDetected?()
                    reset()
                }
            }
        }
    }

    func reset() {
        silenceStartTime = nil
        hasHadVoiceActivity = false
    }

    var isSilent: Bool {
        silenceStartTime != nil
    }

    var currentSilenceDuration: Double? {
        guard let startTime = silenceStartTime else { return nil }
        return Date().timeIntervalSince(startTime)
    }
}
