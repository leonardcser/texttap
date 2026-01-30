# TextTap

Voice-to-text dictation for macOS. Double-tap Command to start dictating, double-tap again to insert the transcribed text.

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
3. Double-tap the Command key to start dictation
4. Speak - text is transcribed after detecting silence
5. Double-tap Command again to stop and insert final text
6. Press Escape to cancel without inserting

### Selection Replacement

Select text before dictating to replace it with your spoken words.

## Configuration

Create `~/.config/texttap/config.toml` to customize settings:

```toml
[hotkey]
double_tap_interval = 0.3     # Max seconds between taps

[audio]
silence_threshold = 0.01      # RMS threshold for silence detection (0.0-1.0)
silence_duration = 1.0        # Seconds of silence before auto-transcribing
sample_rate = 16000           # Audio sample rate

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
