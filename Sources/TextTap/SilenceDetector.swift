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

    func processLevel(_ level: Float) {
        if level > threshold {
            hasHadVoiceActivity = true
            silenceStartTime = nil
        } else if hasHadVoiceActivity {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let startTime = silenceStartTime {
                let silenceDuration = Date().timeIntervalSince(startTime)
                if silenceDuration >= duration {
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
