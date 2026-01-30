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

enum HotkeyMode: String {
    case doubleTap = "double_tap"
    case shortcut = "shortcut"
}

struct HotkeyConfig {
    var mode: HotkeyMode = .doubleTap
    var key: String = "rightcmd"             // For double_tap mode: key to double-tap
    var shortcut: String = "cmd-shift-m"     // For shortcut mode: dash-separated binding
    var doubleTapInterval: Double = 0.3      // Only used in double_tap mode

    // Parsed shortcut components (computed from shortcut string)
    var parsedShortcut: (key: String, modifiers: [String])? {
        return Self.parseBinding(shortcut)
    }

    // Parse dash-separated binding (e.g., "cmd-shift-d" -> key: "d", modifiers: ["cmd", "shift"])
    static func parseBinding(_ binding: String) -> (key: String, modifiers: [String])? {
        let parts = binding.lowercased().split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }

        // Last part is the key, rest are modifiers
        let key = parts.last!
        let modifiers = Array(parts.dropLast())

        // Validate key exists
        guard keyCode(for: key) != nil else { return nil }

        // Validate all modifiers
        for mod in modifiers {
            guard modifierFlag(for: mod) != nil else { return nil }
        }

        return (key: key, modifiers: modifiers)
    }

    // Map key string to CGKeyCode
    static func keyCode(for key: String) -> UInt16? {
        switch key.lowercased() {
        // Letters
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06
        // Numbers
        case "0": return 0x1D
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        // Function keys
        case "f1": return 0x7A
        case "f2": return 0x78
        case "f3": return 0x63
        case "f4": return 0x76
        case "f5": return 0x60
        case "f6": return 0x61
        case "f7": return 0x62
        case "f8": return 0x64
        case "f9": return 0x65
        case "f10": return 0x6D
        case "f11": return 0x67
        case "f12": return 0x6F
        // Special keys
        case "escape", "esc": return 0x35
        case "space": return 0x31
        case "tab": return 0x30
        case "return", "enter": return 0x24
        case "delete", "backspace": return 0x33
        case "forwarddelete": return 0x75
        default: return nil
        }
    }

    // Map key string to CGEventFlags for modifier keys
    static func modifierFlag(for key: String) -> CGEventFlags? {
        switch key.lowercased() {
        case "command", "cmd", "leftcmd", "leftcommand", "rightcmd", "rightcommand":
            return .maskCommand
        case "option", "opt", "alt", "leftoption", "leftopt", "leftalt", "rightoption", "rightopt", "rightalt":
            return .maskAlternate
        case "control", "ctrl", "leftcontrol", "leftctrl", "rightcontrol", "rightctrl":
            return .maskControl
        case "shift", "leftshift", "rightshift": return .maskShift
        case "fn", "function": return .maskSecondaryFn
        default: return nil
        }
    }

    // Raw flag masks for left/right specific modifier detection (NX_DEVICE*KEYMASK values)
    static func deviceModifierMask(for key: String) -> UInt64? {
        switch key.lowercased() {
        case "leftcmd", "leftcommand": return 0x00000008      // NX_DEVICELCMDKEYMASK
        case "rightcmd", "rightcommand": return 0x00000010    // NX_DEVICERCMDKEYMASK
        case "leftshift": return 0x00000002                   // NX_DEVICELSHIFTKEYMASK
        case "rightshift": return 0x00000004                  // NX_DEVICERSHIFTKEYMASK
        case "leftctrl", "leftcontrol": return 0x00000001     // NX_DEVICELCTLKEYMASK
        case "rightctrl", "rightcontrol": return 0x00002000   // NX_DEVICERCTLKEYMASK
        case "leftoption", "leftopt", "leftalt": return 0x00000020   // NX_DEVICELALTKEYMASK
        case "rightoption", "rightopt", "rightalt": return 0x00000040 // NX_DEVICERALTKEYMASK
        default: return nil
        }
    }

    // Check if a key string is a modifier key
    static func isModifier(_ key: String) -> Bool {
        return modifierFlag(for: key) != nil
    }

    // Check if key requires side-specific detection
    static func isSideSpecificModifier(_ key: String) -> Bool {
        return deviceModifierMask(for: key) != nil
    }
}

struct AudioConfig {
    var silenceThreshold: Float = 0.01
    var silenceDuration: Double = 1.0
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
            if let val = hotkeySection["mode"] as? String,
               let mode = HotkeyMode(rawValue: val) {
                hotkey.mode = mode
            }
            if let val = hotkeySection["key"] as? String {
                hotkey.key = val
            }
            if let val = hotkeySection["shortcut"] as? String {
                hotkey.shortcut = val
            }
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
                } else if value.hasPrefix("[") && value.hasSuffix("]") {
                    // Parse array
                    let arrayContent = String(value.dropFirst().dropLast())
                    let elements = arrayContent.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .map { element -> String in
                            var e = element
                            if e.hasPrefix("\"") && e.hasSuffix("\"") {
                                e = String(e.dropFirst().dropLast())
                            }
                            return e
                        }
                    parsedValue = elements
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
