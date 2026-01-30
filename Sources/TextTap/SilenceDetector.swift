import Foundation

class SilenceDetector {
    private var silenceStartTime: Date?
    private var hasHadVoiceActivity = false
    private var lastLogTime: Date?

    var onSilenceDetected: (() -> Void)?

    private let threshold: Float
    private let duration: Double

    init(threshold: Float = Config.shared.audio.silenceThreshold,
         duration: Double = Config.shared.audio.silenceDuration) {
        self.threshold = threshold
        self.duration = duration
        print("[SilenceDetector] Initialized with threshold: \(threshold), duration: \(duration)s")
    }

    func processLevel(_ level: Float) {
        // Log periodically (every 0.5s) to avoid spam
        let now = Date()
        if lastLogTime == nil || now.timeIntervalSince(lastLogTime!) > 0.5 {
            let status = level > threshold ? "VOICE" : "silent"
            let silenceDur = currentSilenceDuration.map { String(format: "%.1fs", $0) } ?? "-"
            print("[SilenceDetector] level: \(String(format: "%.4f", level)) (\(status)) | hadVoice: \(hasHadVoiceActivity) | silenceDur: \(silenceDur)")
            lastLogTime = now
        }

        if level > threshold {
            // Voice activity detected
            if !hasHadVoiceActivity {
                print("[SilenceDetector] First voice activity detected!")
            }
            hasHadVoiceActivity = true
            silenceStartTime = nil
        } else if hasHadVoiceActivity {
            // Below threshold (silence)
            if silenceStartTime == nil {
                silenceStartTime = Date()
                print("[SilenceDetector] Silence started")
            } else if let startTime = silenceStartTime {
                let silenceDuration = Date().timeIntervalSince(startTime)
                if silenceDuration >= duration {
                    print("[SilenceDetector] Silence threshold reached (\(String(format: "%.1f", silenceDuration))s) - triggering callback")
                    onSilenceDetected?()
                    reset()
                }
            }
        }
    }

    func reset() {
        print("[SilenceDetector] Reset")
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
