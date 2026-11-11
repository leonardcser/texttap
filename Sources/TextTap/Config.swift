import Foundation

struct HotkeyConfig {
    enum Mode: String {
        case doubleTap = "double_tap"
        case shortcut
    }

    var mode = Mode.doubleTap
    var key = "rightcmd"             // Modifier to double-tap or hold
    var shortcut = "cmd-shift-m"     // Dash-separated binding for shortcut mode
    var doubleTapInterval = 0.3
}

struct TranscriptionConfig {
    var model = "small.en"
    var language = "en"
    var remoteEnabled = false
    var remoteURL = ""
    var remoteModel = ""
    var remoteTimeout: TimeInterval = 5
    var apiKeyEnvironment = ""
}

struct IndicatorConfig {
    var enabled = true
    var preview = true
    var width: CGFloat = 44
    var height: CGFloat = 18
    var offsetX: CGFloat = 8
    var offsetY: CGFloat = 0
    var barCount = 9
    var bgColor = "systemBlue"
    var fgColor = "white"
}

/// Settings from `~/.config/texttap/config.toml`, falling back to defaults.
struct Config {
    var hotkey = HotkeyConfig()
    var transcription = TranscriptionConfig()
    var indicator = IndicatorConfig()

    private(set) static var shared = Config.fromFile()

    static func reload() {
        shared = fromFile()
    }

    private static func fromFile() -> Config {
        var config = Config()
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/texttap/config.toml")
        if let contents = try? String(contentsOf: path, encoding: .utf8) {
            config.load(contents: contents)
        }
        return config
    }

    /// Applies the settings present in `contents`, keeping current values for the rest.
    mutating func load(contents: String) {
        let toml = TOML(contents)

        hotkey.mode = toml.string("hotkey", "mode").flatMap(HotkeyConfig.Mode.init) ?? hotkey.mode
        hotkey.key = toml.string("hotkey", "key") ?? hotkey.key
        hotkey.shortcut = toml.string("hotkey", "shortcut") ?? hotkey.shortcut
        hotkey.doubleTapInterval = toml.number("hotkey", "double_tap_interval") ?? hotkey.doubleTapInterval

        transcription.model = toml.string("transcription", "model") ?? transcription.model
        transcription.language = toml.string("transcription", "language") ?? transcription.language
        transcription.remoteEnabled = toml.bool("transcription", "remote_enabled") ?? transcription.remoteEnabled
        transcription.remoteURL = toml.string("transcription", "remote_url") ?? transcription.remoteURL
        transcription.remoteModel = toml.string("transcription", "remote_model") ?? transcription.remoteModel
        if let timeout = toml.number("transcription", "remote_timeout"), timeout.isFinite, timeout > 0 {
            transcription.remoteTimeout = timeout
        }
        transcription.apiKeyEnvironment = toml.string("transcription", "api_key_env") ?? transcription.apiKeyEnvironment

        indicator.enabled = toml.bool("indicator", "enabled") ?? indicator.enabled
        indicator.preview = toml.bool("indicator", "preview") ?? indicator.preview
        indicator.width = toml.number("indicator", "width").map { CGFloat($0) } ?? indicator.width
        indicator.height = toml.number("indicator", "height").map { CGFloat($0) } ?? indicator.height
        indicator.offsetX = toml.number("indicator", "offset_x").map { CGFloat($0) } ?? indicator.offsetX
        indicator.offsetY = toml.number("indicator", "offset_y").map { CGFloat($0) } ?? indicator.offsetY
        indicator.barCount = toml.number("indicator", "bar_count").map { Int($0) } ?? indicator.barCount
        indicator.bgColor = toml.string("indicator", "bg_color") ?? indicator.bgColor
        indicator.fgColor = toml.string("indicator", "fg_color") ?? indicator.fgColor
    }
}

/// The subset of TOML used by the config file: sections with string, boolean and number values.
private struct TOML {
    private var values: [String: String] = [:]  // "section.key" → raw value

    init(_ contents: String) {
        var section = ""
        for line in contents.components(separatedBy: .newlines) {
            let line = Self.stripComment(line).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            } else if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                values["\(section).\(key)"] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    func string(_ section: String, _ key: String) -> String? {
        guard let value = values["\(section).\(key)"], value.count >= 2,
              value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    func bool(_ section: String, _ key: String) -> Bool? {
        switch values["\(section).\(key)"] {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    func number(_ section: String, _ key: String) -> Double? {
        values["\(section).\(key)"].flatMap(Double.init)
    }

    /// Removes a `#` comment, ignoring `#` inside quoted values such as hex colors.
    private static func stripComment(_ line: String) -> Substring {
        var quoted = false
        var escaped = false
        return line.prefix { character in
            if escaped {
                escaped = false
            } else if quoted && character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "#" && !quoted {
                return false
            }
            return true
        }
    }
}
