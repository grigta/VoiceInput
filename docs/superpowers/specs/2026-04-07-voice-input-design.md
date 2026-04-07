# VoiceInput — Design Specification

**Date:** 2026-04-07
**Status:** Approved

Lightweight open-source push-to-talk voice input app for macOS Apple Silicon. Transcribes speech to text using whisper.cpp and inserts it at the cursor position. Supports English and Russian with automatic language detection.

---

## Architecture

### Approach

whisper.cpp v1.7.2 as a git submodule with its own Package.swift (includes Metal+Accelerate support). Referenced as a local SPM package dependency — no custom C bridging target needed. Swift imports `whisper` directly.

### Project Structure

```
VoiceInput/
├── Package.swift                  # SPM manifest, depends on vendor/whisper.cpp
├── Sources/VoiceInput/
│   ├── main.swift                 # Entry point, AppDelegate, orchestration
│   ├── AudioRecorder.swift        # AVAudioEngine, microphone capture
│   ├── WhisperWrapper.swift       # Swift actor wrapping whisper.cpp C API
│   ├── HotkeyManager.swift        # global hotkey (CGEvent tap)
│   ├── TextInjector.swift         # clipboard-based text insertion
│   ├── ModelManager.swift         # model download/storage
│   ├── OverlayWindow.swift        # floating recording indicator
│   ├── MenuBarController.swift    # NSStatusItem, settings menu
│   └── FirstLaunchWindow.swift    # model selection on first run
├── vendor/
│   └── whisper.cpp/               # git submodule pinned to v1.7.2
├── Resources/
│   └── Info.plist
├── scripts/
│   └── bundle.sh                  # .app bundle assembly
└── .github/
    └── workflows/
        └── build.yml              # CI: build + Release
```

### Module Responsibilities

| Module | Responsibility |
|--------|---------------|
| `main.swift` | App lifecycle, NSApplication setup, push-to-talk orchestration |
| `AudioRecorder.swift` | AVAudioEngine capture, PCM Float32 16kHz mono buffer |
| `WhisperWrapper.swift` | Load model, call whisper_full(), return transcribed text |
| `HotkeyManager.swift` | CGEvent tap for global configurable hotkey |
| `TextInjector.swift` | Simulate keyboard events to type text at cursor |
| `ModelManager.swift` | Download models from HuggingFace, SHA256 verify, storage |
| `OverlayWindow.swift` | Floating NSPanel indicator (recording/processing states) |
| `MenuBarController.swift` | NSStatusItem, dropdown menu, settings |
| `FirstLaunchWindow.swift` | Model selection window on first run |

---

## Data Flow (Push-to-Talk Cycle)

```
User holds hotkey (default: Option+D)
        │
        ▼
  HotkeyManager (CGEvent tap)
        │ keyDown event
        ▼
  AudioRecorder.startRecording()
        │ AVAudioEngine → PCM Float32, 16kHz mono
        │ buffer accumulates in memory (Array<Float>)
        ▼
  OverlayWindow.show()  ← red pulsing circle
        │
  ══════ user speaks... ══════
        │
User releases hotkey
        │
        ▼
  AudioRecorder.stopRecording() → [Float]
        │
        ▼
  OverlayWindow.showProcessing()  ← yellow circle
        │
        ▼
  WhisperWrapper.transcribe(audio: [Float])
        │ background thread (DispatchQueue.global)
        │ whisper_full() with language="auto"
        │ Metal acceleration for encoder
        │ returns String
        ▼
  TextInjector.type(text)
        │ CGEvent keyboard simulation
        │ inserts text at current cursor position
        ▼
  OverlayWindow.hide()
```

**Audio format:** PCM Float32, 16kHz, mono — required by whisper.cpp.

**Buffer size:** 16kHz × 4 bytes = 64KB/sec. 30 seconds of speech ≈ 2MB. Negligible.

**Transcription speed:** `base` model on M2 with Metal — ~0.5-1sec for 10 seconds of speech.

**Text insertion:** CGEvent simulates keystrokes. Works in any application. Does not overwrite clipboard.

**Hotkey:** Configurable via menubar UI. Default `Option+D`. Stored in UserDefaults. User records a new shortcut by clicking the shortcut field and pressing desired key combination.

---

## UI Components

### Menubar

- `NSStatusItem` with SF Symbol `mic.fill`
- Click opens dropdown menu:
  - Status line: `Model: base | Ready`
  - `Record Shortcut: ⌥D` — click to record new shortcut
  - `Model →` submenu: tiny / base / small / medium (current marked with checkmark, click downloads if missing)
  - `Quit`

### Overlay (Recording Indicator)

- Small circular NSPanel (~48pt) in bottom-right corner, 20pt from screen edge
- `level: .floating`, no shadow, no title bar
- Red pulsing circle — recording in progress
- Yellow — processing (transcription)
- Disappears after text insertion

### First Launch (No Model)

- Model selection window:
  - `tiny (75MB)` — fast, basic quality
  - `base (142MB)` — balance of speed and quality *(recommended)*
  - `small (466MB)` — high quality, slower
- Download progress bar
- Window closes after download, app is ready

---

## whisper.cpp Integration

### Build via SPM

- whisper.cpp v1.7.2 referenced as local package dependency: `.package(path: "vendor/whisper.cpp")`
- Its own Package.swift compiles all C sources with `-DGGML_USE_METAL`, `-O3`, Accelerate framework
- Metal shaders (`ggml-metal.metal`) included as SPM resource
- Swift imports via `import whisper`

### WhisperWrapper API

```swift
class WhisperWrapper {
    init(modelPath: String) throws    // whisper_init_from_file()
    func transcribe(_ audio: [Float]) -> String  // whisper_full() → segments → joined text
    deinit                            // whisper_free()
}
```

- Parameters: `language = "auto"`, `n_threads = 4`, `translate = false`
- Model stays in memory while app is running (~150MB for base)
- On model switch: `whisper_free()` → `whisper_init_from_file()`

### Models

- Stored in `~/Library/Application Support/VoiceInput/models/`
- Format: `ggml-base.bin`, `ggml-tiny.bin`, etc.
- Downloaded from `huggingface.co/ggerganov/whisper.cpp` (official GGML models)
- SHA256 verification after download
- URLSession downloadTask with Progress tracking

### Metal Acceleration

- Enabled by `-DGGML_METAL` compiler flag
- whisper.cpp automatically uses GPU for encoder when Metal is available
- ~2-3x speedup over CPU-only on M2

---

## Distribution

### GitHub Actions (`build.yml`)

```
trigger: push tag v*.*.*

steps:
  1. checkout with submodules (--recursive)
  2. swift build -c release (macOS 14+, Xcode 15+)
  3. Assemble .app bundle:
     - binary → VoiceInput.app/Contents/MacOS/
     - Info.plist → Contents/
     - Metal shaders → Contents/Resources/
  4. Ad-hoc sign (codesign --sign -)
  5. Package as VoiceInput-v1.0.0-arm64.zip
  6. Create GitHub Release, attach .zip
```

### Build from Source

```bash
git clone --recursive https://github.com/<user>/VoiceInput.git
cd VoiceInput
swift build -c release
```

### Constraints

- Apple Silicon only (arm64). No Intel support.
- No Apple notarization (requires $99/yr Developer Account). User right-clicks → Open on first launch, or runs `xattr -d com.apple.quarantine`. README explains this with screenshot.

### Future (not v1)

- Homebrew Cask formula
- Notarization if Developer Account obtained
- Universal binary (arm64 + x86_64)

---

## Permissions

| Permission | Mechanism | If Denied |
|------------|-----------|-----------|
| Microphone | `NSMicrophoneUsageDescription` in Info.plist | Menubar icon changes to `mic.slash`, tooltip with instructions |
| Accessibility | Manual: System Settings → Privacy & Security → Accessibility | Notification with "Open Settings" button on record attempt |

---

## Error Handling

| Situation | Behavior |
|-----------|----------|
| No model downloaded | First launch model selection window |
| Download error | Retry button + error message |
| Microphone denied | Icon changes to `mic.slash`, tooltip with instructions |
| Accessibility missing | Notification with "Open Settings" button |
| Empty transcription | Silently skip, overlay disappears |

---

## System Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3)
- ~200MB free space (app + base model)

---

## Testing

- **Unit tests:** `WhisperWrapper` (transcribe test .wav file), `ModelManager` (path validation, SHA256)
- **Manual tests:** push-to-talk cycle, model switching, first launch flow, hotkey customization
