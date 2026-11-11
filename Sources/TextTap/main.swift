import Cocoa

// Credential commands run before creating the app or loading local models.
if CommandLine.arguments.contains("--store-stt-key") {
    let status = Credentials.storeAPIKeyFromEnvironment(
        environmentVariable: Config.shared.transcription.apiKeyEnvironment
    )
    print(status == 0 ? "STT credential saved in Keychain." : "Could not save STT credential (status \(status)).")
    exit(status == 0 ? 0 : 1)
}
if CommandLine.arguments.contains("--check-stt-key") {
    let available = Credentials.apiKey(
        environmentVariable: Config.shared.transcription.apiKeyEnvironment
    ) != nil
    print(available ? "STT credential available." : "STT credential unavailable; local Whisper will be used.")
    exit(available ? 0 : 1)
}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
