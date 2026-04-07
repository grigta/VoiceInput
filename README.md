# VoiceInput

Lightweight push-to-talk voice input for macOS. Hold a hotkey, speak in English or Russian, release — text appears at your cursor.

- **Fully offline** — uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration
- **Automatic language detection** — English and Russian
- **Configurable hotkey** — default `⌥D` (Option+D)
- **Menubar app** — no Dock icon, minimal footprint

## Install

1. Download **`VoiceInput-vX.X.X-arm64.dmg`** from [Releases](../../releases)
2. Open the DMG and drag **VoiceInput** to **Applications**
3. Open Terminal and run:
   ```bash
   xattr -cr /Applications/VoiceInput.app
   ```
   This is required because the app is not notarized by Apple (no $99/yr Developer Account). The command removes the quarantine flag so macOS allows it to run.
4. Open **VoiceInput** from Applications

## First Launch

1. **Model download** — choose a Whisper model (base recommended, 142 MB)
2. **Microphone** — macOS will ask for microphone permission
3. **Accessibility** — add VoiceInput in System Settings → Privacy & Security → Accessibility

## Usage

1. Hold `⌥D` (or your configured hotkey)
2. Speak in English or Russian
3. Release the hotkey
4. Text is inserted at your cursor position

## Configuration

Click the mic icon in the menubar:
- **Shortcut** — click to record a new hotkey
- **Model** — switch between tiny/base/small/medium

## Build from Source

Requires macOS 14+ and Xcode 15+.

```bash
git clone --recursive https://github.com/<your-username>/VoiceInput.git
cd VoiceInput
swift build -c release
./scripts/bundle.sh
open .build/release/VoiceInput.app
```

## System Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- ~200 MB free space (app + base model)

## License

MIT
