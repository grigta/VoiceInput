# VoiceInput — macOS Speech-to-Text App Design

## Overview

Native Swift macOS menu bar application for speech-to-text input. Converts voice to text and pastes it at the current cursor position in any application. Uses sherpa-onnx (k2-fsa) with Silero VAD + Whisper for offline recognition on Apple Silicon.

## Requirements

- **Language**: Russian with English word sprinkles
- **Activation**: Push-to-talk on Right Shift (hold to record, release to recognize and paste)
- **Platform**: Swift macOS app, menu bar only (no Dock icon)
- **Recognition engine**: sherpa-onnx — Silero VAD + Whisper offline
- **Text insertion**: Clipboard-based (save → paste via Cmd+V → restore)
- **Visual feedback**: Menu bar icon + floating animated circle at bottom-center
- **Auto-start**: Login item
- **Model selection**: Start with Whisper small, user can switch to medium/large-v3 in settings

## Architecture

Single-process Swift macOS application.

```
┌─────────────────────────────────────────────┐
│              VoiceInputApp                   │
│                                              │
│  ┌──────────────┐   ┌────────────────────┐  │
│  │ HotkeyManager│   │  AudioCaptureEngine│  │
│  │ (CGEvent tap)│──▶│  (AVAudioEngine)   │  │
│  └──────────────┘   └────────┬───────────┘  │
│                              │ float32 PCM   │
│                              ▼               │
│                     ┌────────────────────┐   │
│                     │   SherpaRecognizer │   │
│                     │  VAD (Silero) +    │   │
│                     │  Whisper (offline)  │   │
│                     └────────┬───────────┘   │
│                              │ text          │
│                              ▼               │
│                     ┌────────────────────┐   │
│                     │ ClipboardInserter  │   │
│                     │ save → paste →     │   │
│                     │ restore            │   │
│                     └────────────────────┘   │
│                                              │
│  ┌──────────────┐   ┌────────────────────┐  │
│  │ MenuBarView  │   │ OverlayWindow      │  │
│  │ (status icon)│   │ (animated circle)  │  │
│  └──────────────┘   └────────────────────┘  │
└─────────────────────────────────────────────┘
```

### Components

- **HotkeyManager** — Global Right Shift intercept via `CGEvent` tap. Tracks `.flagsChanged` events, keyCode 60 for right shift.
- **AudioCaptureEngine** — Microphone recording via `AVAudioEngine`, converts to 16kHz mono float32. Buffer size: 512 samples (~32ms).
- **SherpaRecognizer** — Wrapper over sherpa-onnx C API. Runs Silero VAD during recording to segment speech. Runs Whisper offline on accumulated segments after key release.
- **ClipboardInserter** — Saves `NSPasteboard.general` contents, writes recognized text, simulates Cmd+V via `CGEvent`, restores original clipboard after ~100ms.
- **MenuBarView** — SwiftUI `MenuBarExtra` with status icon and dropdown settings.
- **OverlayWindow** — Floating `NSWindow` with animated circle visualizing voice amplitude.

## Push-to-Talk Lifecycle

```
Right Shift Down                              Right Shift Up
     │                                              │
     ▼                                              ▼
 ┌─ Show overlay                               ┌─ Hide overlay
 ├─ Menu bar → red icon                        ├─ Menu bar → normal icon
 ├─ Start AVAudioEngine recording              ├─ Stop recording
 ├─ Start VAD (Silero)                         ├─ Flush VAD (remaining audio)
 │                                             ├─ Whisper recognizes all segments
 │  While holding:                             ├─ Text → clipboard → Cmd+V
 │  ├─ Audio → VAD (segments speech)           ├─ Restore clipboard
 │  ├─ VAD accumulates speech segments         └─ Done
 │  └─ RMS amplitude → circle animation
```

- VAD segments audio in real-time during recording
- Whisper runs only after key release — on all accumulated segments
- Long speech (>20s) is auto-segmented by VAD; Whisper processes each segment and concatenates results
- Expected latency between key release and text insertion: ~1-3 sec depending on duration and model

## UI/UX

### Menu Bar

- Icon: SF Symbol `mic.fill` — gray (idle), red (recording)
- Click opens dropdown menu:
  - Status: "Ready" / "Recording..." / "Recognizing..."
  - Model: Whisper small / medium / large-v3 (selection, download if missing)
  - Hotkey: displays current (Right Shift)
  - Auto-start: on/off toggle
  - Quit

### Overlay (Floating Circle)

- Position: horizontally centered, ~100pt from bottom edge
- Size: ~60pt diameter
- Appearance: semi-transparent circle with `.ultraThinMaterial` blur
- Animation: scale pulses proportional to RMS voice amplitude (scale ~1.0–1.4)
- Appear/disappear: fade in/out ~0.2s
- Non-interactive: `.ignoresMouseEvents = true`
- Window level: `NSWindow.Level.floating`

### Permissions

On first launch, requests:
- **Microphone** — standard system dialog
- **Accessibility** — required for global key intercept (CGEvent tap). App guides user to System Settings → Privacy → Accessibility

## Model Management

### Storage

- Models stored in `~/Library/Application Support/VoiceInput/Models/`
- Each model in its own folder: `whisper-small/`, `whisper-medium/`, `whisper-large-v3/`
- VAD model (`silero_vad.onnx`) downloaded on first launch, ~2MB

### Download

- First launch: auto-downloads Whisper small + Silero VAD
- Other models downloadable from settings — progress bar in menu
- Source: GitHub releases `k2-fsa/sherpa-onnx` (tar.bz2 archives)
- Skip download if model already exists

### Switching

- Select model in menu bar → applies immediately (recreates `OfflineRecognizer`)
- Current model persisted in `UserDefaults`

### Model Sizes

| Model | Size | Speed (5s audio, M1) |
|-------|------|---------------------|
| whisper-small | ~460MB | ~1-2s |
| whisper-medium | ~1.5GB | ~2-4s |
| whisper-large-v3 | ~3GB | ~4-6s |

## Technical Details

### sherpa-onnx Integration

- Build XCFramework via `build-swift-macos.sh` from sherpa-onnx repo
- Embed in Xcode project as embedded framework
- Swift wrapper: adapt `SherpaOnnx.swift` from the repo

### Audio Pipeline

- `AVAudioEngine` → input node tap → convert to 16kHz mono float32
- Buffer: 512 samples (~32ms) — fed to VAD and accumulated for Whisper
- RMS computed per buffer for circle animation

### Right Shift Detection

- `CGEvent.tapCreate` with mask for `.flagsChanged`
- Right Shift identified via `keyCode == 60`
- Track flag appearance/disappearance to detect hold/release

### Clipboard Flow

1. Save `NSPasteboard.general` contents (all types)
2. Write recognized text to pasteboard as string
3. Simulate Cmd+V via `CGEvent`
4. After ~100ms delay, restore original pasteboard contents

## Edge Cases

- **Empty speech**: VAD finds no speech segments → nothing inserted
- **Microphone unavailable**: Show alert, menu bar icon gray with cross
- **Accessibility not granted**: Cannot intercept keys, show instruction dialog
- **Model not downloaded**: On record attempt, show "Download model in settings"
- **Long speech (>60s)**: VAD segments, Whisper processes sequentially, concatenates results
