<p align="center">
  <img src="assets/icon-readme.png" alt="TextTap Icon" width="128" height="128">
</p>

<h1 align="center">TextTap</h1>

<p align="center">
  <em>Local voice-to-text dictation for macOS using Whisper.<br>Double-tap Command to start dictating, double-tap again to insert the transcribed text.</em>
</p>

<p align="center">
  <img src="assets/demo.gif" alt="TextTap Demo">
</p>

## Requirements

- macOS 14+
- Accessibility permissions (for text insertion)
- Microphone permissions

## Building

```bash
swift build
```

Or use the Makefile:

```bash
make build   # Build the app
make run     # Build and run
```

## Usage

1. Launch TextTap
2. Grant accessibility and microphone permissions when prompted
3. Double-tap the Command key to start dictation (or use your configured shortcut)
4. Speak - text is transcribed after detecting silence
5. Double-tap Command again to stop and insert final text
6. Press Escape to cancel without inserting

### Selection Replacement

Select text before dictating to replace it with your spoken words.

## Configuration

Create `~/.config/texttap/config.toml` to customize settings (see `config.example.toml`):

```toml
[hotkey]
# Activation mode: "double_tap" or "shortcut"
mode = "double_tap"
key = "cmd"                   # Key to double-tap (cmd, alt, ctrl, shift, fn, or a-z, 0-9, f1-f12, etc.)
shortcut = "cmd-shift-d"      # For shortcut mode: dash-separated binding
double_tap_interval = 0.3     # Max seconds between taps (double_tap mode only)

[audio]
silence_threshold = 0.01      # RMS threshold for silence (0.0-1.0)
silence_duration = 1.0        # Seconds of silence before transcribing

[transcription]
model = "small.en"            # Whisper model: tiny, base, small, medium, large-v3
language = "en"               # Language code

[indicator]
enabled = true                # Show waveform indicator near cursor
width = 44
height = 18
offset_x = 8
offset_y = 0
bar_count = 9
bg_color = "systemBlue"       # systemBlue, white, #FF0000, etc.
fg_color = "white"
```

## How It Works

1. Records audio to a temporary WAV file
2. Detects silence to automatically trigger transcription
3. Uses WhisperKit for local on-device transcription
4. Inserts text at cursor position via accessibility API or keyboard events
