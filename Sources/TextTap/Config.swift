import Foundation
import Cocoa

extension String {
    func toNSColor() -> NSColor {
        switch self.lowercased() {
        case "white": return .white
        case "black": return .black
        case "red", "systemred": return .systemRed
        case "blue", "systemblue": return .systemBlue
        case "green", "systemgreen": return .systemGreen
        case "orange", "systemorange": return .systemOrange
        case "yellow", "systemyellow": return .systemYellow
        case "purple", "systempurple": return .systemPurple
        case "pink", "systempink": return .systemPink
        case "gray", "systemgray": return .systemGray
        case "cyan", "systemcyan": return .systemCyan
        case "teal", "systemteal": return .systemTeal
        case "indigo", "systemindigo": return .systemIndigo
        default:
            // Try hex color (e.g., "#FF0000")
            if self.hasPrefix("#") {
                let hex = String(self.dropFirst())
                if let rgb = UInt64(hex, radix: 16) {
                    let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
                    let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
                    let b = CGFloat(rgb & 0xFF) / 255.0
                    return NSColor(red: r, green: g, blue: b, alpha: 1.0)
                }
            }
            return .systemBlue
        }
    }
}

struct HotkeyConfig {
    var doubleTapInterval: Double = 0.3
}

struct AudioConfig {
    var silenceThreshold: Float = 0.01
    var silenceDuration: Double = 1.0
    var sampleRate: Double = 16000
}

struct TranscriptionConfig {
    var model: String = "small.en"
    var language: String = "en"
}

struct IndicatorConfig {
    var enabled: Bool = true
    var width: CGFloat = 44
    var height: CGFloat = 18
    var offsetX: CGFloat = 8
    var offsetY: CGFloat = 0
    var barCount: Int = 9
    var bgColor: String = "systemBlue"  // Apple blue
    var fgColor: String = "white"
}

struct Config {
    var hotkey = HotkeyConfig()
    var audio = AudioConfig()
    var transcription = TranscriptionConfig()
    var indicator = IndicatorConfig()

    private(set) static var shared: Config = {
        var config = Config()
        config.load()
        return config
    }()

    static func reload() {
        var config = Config()
        config.load()
        shared = config
        print("[Config] Configuration reloaded")
    }

    private static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/texttap/config.toml"
    }()

    mutating func load() {
        guard FileManager.default.fileExists(atPath: Self.configPath),
              let contents = try? String(contentsOfFile: Self.configPath, encoding: .utf8) else {
            return
        }

        let parsed = parseTOML(contents)

        // Hotkey section
        if let hotkeySection = parsed["hotkey"] as? [String: Any] {
            if let val = hotkeySection["double_tap_interval"] as? Double {
                hotkey.doubleTapInterval = val
            }
        }

        // Audio section
        if let audioSection = parsed["audio"] as? [String: Any] {
            if let val = audioSection["silence_threshold"] as? Double {
                audio.silenceThreshold = Float(val)
            }
            if let val = audioSection["silence_duration"] as? Double {
                audio.silenceDuration = val
            }
            if let val = audioSection["sample_rate"] as? Double {
                audio.sampleRate = val
            }
        }

        // Transcription section
        if let transcriptionSection = parsed["transcription"] as? [String: Any] {
            if let val = transcriptionSection["model"] as? String {
                transcription.model = val
            }
            if let val = transcriptionSection["language"] as? String {
                transcription.language = val
            }
        }

        // Indicator section
        if let indicatorSection = parsed["indicator"] as? [String: Any] {
            if let val = indicatorSection["enabled"] as? Bool {
                indicator.enabled = val
            }
            if let val = indicatorSection["width"] as? Double {
                indicator.width = CGFloat(val)
            }
            if let val = indicatorSection["height"] as? Double {
                indicator.height = CGFloat(val)
            }
            if let val = indicatorSection["offset_x"] as? Double {
                indicator.offsetX = CGFloat(val)
            }
            if let val = indicatorSection["offset_y"] as? Double {
                indicator.offsetY = CGFloat(val)
            }
            if let val = indicatorSection["bar_count"] as? Int {
                indicator.barCount = val
            }
            if let val = indicatorSection["bg_color"] as? String {
                indicator.bgColor = val
            }
            if let val = indicatorSection["fg_color"] as? String {
                indicator.fgColor = val
            }
        }
    }

    private func parseTOML(_ content: String) -> [String: Any] {
        var result: [String: Any] = [:]
        var currentSection: String?
        var currentDict: [String: Any] = [:]

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Save previous section
                if let section = currentSection {
                    result[section] = currentDict
                }
                currentSection = String(trimmed.dropFirst().dropLast())
                currentDict = [:]
                continue
            }

            // Key-value pair
            if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)

                // Parse value
                let parsedValue: Any
                if value == "true" {
                    parsedValue = true
                } else if value == "false" {
                    parsedValue = false
                } else if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    parsedValue = String(value.dropFirst().dropLast())
                } else if let intVal = Int(value) {
                    parsedValue = intVal
                } else if let doubleVal = Double(value) {
                    parsedValue = doubleVal
                } else {
                    parsedValue = value
                }

                currentDict[key] = parsedValue
            }
        }

        // Save last section
        if let section = currentSection {
            result[section] = currentDict
        }

        return result
    }
}
