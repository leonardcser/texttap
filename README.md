<p align="center">
  <img src="assets/icon-readme.png" alt="TextTap Icon" width="128" height="128">
</p>

<h1 align="center">TextTap</h1>

<p align="center">
  <em>Local voice-to-text dictation for macOS with optional remote transcription.<br>Double-tap Command to dictate, or hold it for push-to-talk.</em>
</p>

<p align="center">
  <img src="assets/demo.gif" alt="TextTap Demo">
</p>

## Install

Requires macOS 14+, microphone access, and Accessibility permission.

```bash
make install   # Build and install to /Applications
```

## Usage

- **Double-tap Command** to start or stop dictation.
- **Hold Command** for push-to-talk; release to transcribe.
- **Escape** cancels without inserting text.

Text appears at the cursor. Select existing text first to replace it.
Whisper downloads its local model on first launch, then works offline.

## Configuration

Customize hotkeys, language, models, and appearance in
`~/.config/texttap/config.toml`. See [config.example.toml](config.example.toml)
for all settings. Right-click the menu bar icon to reload configuration;
restart after changing the local model.

### Optional remote transcription

Transcription stays local by default. To use your own OpenAI-compatible STT
server, add these settings to your private config, replacing the placeholders:

```toml
[transcription]
remote_enabled = true
remote_url = "https://stt.example.com/v1/audio/transcriptions"
remote_model = "your-model"
api_key_env = "YOUR_STT_API_KEY"
```

Recordings go to that server, with automatic local fallback on failure or after
5 seconds (`remote_timeout`). Set `remote_enabled = false` to stay local.

Long dictations are split at pauses and each part is transcribed while you keep
talking, so text appears shortly after you stop, however long you spoke.

The API key comes from your chosen environment variable or Keychain. For Finder
and login launches, save it from a shell where that variable is already set:

```bash
/Applications/TextTap.app/Contents/MacOS/TextTap --store-stt-key
```

Keep secrets out of TOML and command-line arguments. TextTap does not log keys
or transcripts, and recordings stay in memory, never on disk.

## Local signing

To help preserve permissions across local updates, use the same code-signing
certificate each time. Select an identity from
`security find-identity -v -p codesigning` in `~/.config/texttap/build.mk`:

```make
SIGNING_IDENTITY = YOUR_CERTIFICATE_SHA1
```

Keep its private key in Keychain. Both build and install use this setting;
without it, builds are ad-hoc signed. Switching identities may require one final
permission approval. A local self-signed certificate is for your Mac, not public
distribution.

## Development

```bash
make build
swift test
```

Live tests are opt-in: set `TEXTTAP_TEST_AUDIO` to a WAV containing "the quick
brown fox" and `TEXTTAP_TEST_CONFIG` to your private config. These tests send the
fixture to your configured server and also exercise local fallback.
