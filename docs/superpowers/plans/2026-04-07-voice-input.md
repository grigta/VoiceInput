# VoiceInput Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Swift macOS menu bar app that converts speech to text using sherpa-onnx (Silero VAD + Whisper) and pastes the result at the cursor position via push-to-talk on Right Shift.

**Architecture:** Single-process SwiftUI macOS app with no Dock icon. CGEvent tap intercepts Right Shift for push-to-talk. AVAudioEngine captures microphone audio at 16kHz mono. Silero VAD segments speech in real-time, Whisper offline recognizes segments after key release. Text inserted via clipboard save/paste/restore.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, sherpa-onnx (C API via XCFramework), AVAudioEngine, CGEvent, NSPasteboard, XcodeGen

---

## File Structure

```
VoiceInput/
├── project.yml                          # XcodeGen project spec
├── scripts/
│   └── build-sherpa-onnx.sh             # Build XCFramework from source
├── Frameworks/
│   └── sherpa-onnx.xcframework/         # Built by script
├── VoiceInput/
│   ├── App/
│   │   ├── VoiceInputApp.swift          # @main, MenuBarExtra, wires components
│   │   ├── AppState.swift               # ObservableObject shared state
│   │   └── Info.plist                   # LSUIElement, microphone usage
│   ├── Core/
│   │   ├── HotkeyManager.swift          # CGEvent tap for Right Shift
│   │   ├── AudioCaptureEngine.swift     # AVAudioEngine 16kHz mono capture
│   │   ├── SherpaRecognizer.swift       # VAD + Whisper wrapper
│   │   ├── ClipboardInserter.swift      # Save → paste → restore clipboard
│   │   └── ModelManager.swift           # Download, store, switch models
│   ├── UI/
│   │   ├── MenuBarView.swift            # Menu dropdown content
│   │   └── OverlayWindow.swift          # Floating animated circle
│   ├── Bridge/
│   │   ├── SherpaOnnx.swift             # Swift wrapper (from sherpa-onnx repo)
│   │   └── BridgingHeader.h             # Imports sherpa-onnx C API
│   └── VoiceInput.entitlements          # Audio input + accessibility
├── VoiceInputTests/
│   ├── ModelManagerTests.swift
│   └── AudioBufferTests.swift
```

---

### Task 1: Build sherpa-onnx XCFramework

**Files:**
- Create: `scripts/build-sherpa-onnx.sh`

- [ ] **Step 1: Install build dependencies**

```bash
brew install cmake
```

- [ ] **Step 2: Create the build script**

Create `scripts/build-sherpa-onnx.sh`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/sherpa-onnx"
FRAMEWORK_DIR="$PROJECT_DIR/Frameworks"

# Clone if not already present
if [ ! -d "$BUILD_DIR/sherpa-onnx" ]; then
  echo "Cloning sherpa-onnx..."
  mkdir -p "$BUILD_DIR"
  git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx.git "$BUILD_DIR/sherpa-onnx"
fi

cd "$BUILD_DIR/sherpa-onnx"

echo "Building sherpa-onnx for macOS (arm64 + x86_64)..."

mkdir -p build-macos && cd build-macos

cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_INSTALL_PREFIX=./install \
  ..

make -j$(sysctl -n hw.logicalcpu)
make install

echo "Merging static libraries..."

cd install/lib
libtool -static -o libsherpa-onnx.a \
  libsherpa-onnx-c-api.a \
  libsherpa-onnx-core.a \
  libkaldi-native-fbank-core.a \
  libkissfft-float.a \
  libsherpa-onnx-fstfar.a \
  libsherpa-onnx-fst.a \
  libsherpa-onnx-kaldifst-core.a \
  libkaldi-decoder-core.a \
  libucd.a \
  libpiper_phonemize.a \
  libespeak-ng.a \
  libssentencepiece_core.a \
  libonnxruntime.a 2>/dev/null || \
libtool -static -o libsherpa-onnx.a *.a

cd ../..

echo "Creating XCFramework..."
mkdir -p "$FRAMEWORK_DIR"
rm -rf "$FRAMEWORK_DIR/sherpa-onnx.xcframework"

xcodebuild -create-xcframework \
  -library install/lib/libsherpa-onnx.a \
  -headers install/include \
  -output "$FRAMEWORK_DIR/sherpa-onnx.xcframework"

echo "Copying SherpaOnnx.swift wrapper..."
cp "$BUILD_DIR/sherpa-onnx/swift-api-examples/SherpaOnnx.swift" \
   "$PROJECT_DIR/VoiceInput/Bridge/SherpaOnnx.swift"

echo "Done! XCFramework at: $FRAMEWORK_DIR/sherpa-onnx.xcframework"
```

- [ ] **Step 3: Run the build script**

```bash
chmod +x scripts/build-sherpa-onnx.sh
./scripts/build-sherpa-onnx.sh
```

Expected: `Frameworks/sherpa-onnx.xcframework/` created, `VoiceInput/Bridge/SherpaOnnx.swift` copied.

- [ ] **Step 4: Download development models (Whisper small + Silero VAD)**

```bash
MODEL_DIR="$HOME/Library/Application Support/VoiceInput/Models"
mkdir -p "$MODEL_DIR"

# Silero VAD
curl -L -o "$MODEL_DIR/silero_vad.onnx" \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx

# Whisper small
cd "$MODEL_DIR"
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-small.tar.bz2
tar xjf sherpa-onnx-whisper-small.tar.bz2
rm sherpa-onnx-whisper-small.tar.bz2
```

Expected: `silero_vad.onnx` and `sherpa-onnx-whisper-small/` directory with `small-encoder.int8.onnx`, `small-decoder.int8.onnx`, `small-tokens.txt`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-sherpa-onnx.sh
git commit -m "feat: add sherpa-onnx XCFramework build script"
```

---

### Task 2: Xcode Project Skeleton

**Files:**
- Create: `project.yml`
- Create: `VoiceInput/App/Info.plist`
- Create: `VoiceInput/VoiceInput.entitlements`
- Create: `VoiceInput/Bridge/BridgingHeader.h`

- [ ] **Step 1: Install XcodeGen**

```bash
brew install xcodegen
```

- [ ] **Step 2: Create Info.plist**

Create `VoiceInput/App/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceInput needs microphone access to convert your speech to text.</string>
    <key>CFBundleName</key>
    <string>VoiceInput</string>
    <key>CFBundleDisplayName</key>
    <string>VoiceInput</string>
    <key>CFBundleIdentifier</key>
    <string>com.voiceinput.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
</dict>
</plist>
```

- [ ] **Step 3: Create entitlements**

Create `VoiceInput/VoiceInput.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create bridging header**

Create `VoiceInput/Bridge/BridgingHeader.h`:

```c
#ifndef BridgingHeader_h
#define BridgingHeader_h

#include "sherpa-onnx/c-api/c-api.h"

#endif
```

- [ ] **Step 5: Create project.yml for XcodeGen**

Create `project.yml`:

```yaml
name: VoiceInput
options:
  bundleIdPrefix: com.voiceinput
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_OBJC_BRIDGING_HEADER: VoiceInput/Bridge/BridgingHeader.h
    OTHER_LDFLAGS:
      - "-lc++"
      - "-framework CoreML"
      - "-framework Foundation"
      - "-framework AVFoundation"
      - "-framework CoreAudio"
      - "-framework ApplicationServices"
      - "-framework AppKit"

targets:
  VoiceInput:
    type: application
    platform: macOS
    sources:
      - path: VoiceInput
        excludes:
          - "**/*.entitlements"
    settings:
      base:
        INFOPLIST_FILE: VoiceInput/App/Info.plist
        CODE_SIGN_ENTITLEMENTS: VoiceInput/VoiceInput.entitlements
        PRODUCT_BUNDLE_IDENTIFIER: com.voiceinput.app
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
    dependencies:
      - framework: Frameworks/sherpa-onnx.xcframework
        embed: false
    entitlements:
      path: VoiceInput/VoiceInput.entitlements

  VoiceInputTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: VoiceInputTests
    dependencies:
      - target: VoiceInput
```

- [ ] **Step 6: Create placeholder App file so project generates**

Create `VoiceInput/App/VoiceInputApp.swift`:

```swift
import SwiftUI

@main
struct VoiceInputApp: App {
    var body: some Scene {
        MenuBarExtra("VoiceInput", systemImage: "mic.fill") {
            Text("VoiceInput is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

- [ ] **Step 7: Generate Xcode project and verify build**

```bash
xcodegen generate
xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Expected: Build succeeds. App shows mic icon in menu bar when run.

- [ ] **Step 8: Commit**

```bash
git add project.yml VoiceInput/ Frameworks/ VoiceInputTests/
echo ".build/" >> .gitignore
echo "*.xcodeproj/" >> .gitignore
git add .gitignore
git commit -m "feat: add Xcode project skeleton with sherpa-onnx XCFramework"
```

Note: `.xcodeproj` is gitignored because it's generated by XcodeGen from `project.yml`.

---

### Task 3: AppState — Shared Observable State

**Files:**
- Create: `VoiceInput/App/AppState.swift`

- [ ] **Step 1: Create AppState**

Create `VoiceInput/App/AppState.swift`:

```swift
import Foundation
import SwiftUI

enum RecordingState {
    case idle
    case recording
    case recognizing
}

enum WhisperModel: String, CaseIterable {
    case small = "whisper-small"
    case medium = "whisper-medium"
    case largeV3 = "whisper-large-v3"

    var displayName: String {
        switch self {
        case .small: return "Whisper Small (~460MB)"
        case .medium: return "Whisper Medium (~1.5GB)"
        case .largeV3: return "Whisper Large v3 (~3GB)"
        }
    }

    var encoderFilename: String {
        switch self {
        case .small: return "small-encoder.int8.onnx"
        case .medium: return "medium-encoder.int8.onnx"
        case .largeV3: return "large-v3-encoder.int8.onnx"
        }
    }

    var decoderFilename: String {
        switch self {
        case .small: return "small-decoder.int8.onnx"
        case .medium: return "medium-decoder.int8.onnx"
        case .largeV3: return "large-v3-decoder.int8.onnx"
        }
    }

    var tokensFilename: String {
        switch self {
        case .small: return "small-tokens.txt"
        case .medium: return "medium-tokens.txt"
        case .largeV3: return "large-v3-tokens.txt"
        }
    }

    var downloadURL: String {
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-\(rawValue).tar.bz2"
    }

    var directoryName: String {
        "sherpa-onnx-\(rawValue)"
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var audioLevel: Float = 0.0
    @Published var selectedModel: WhisperModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedModel") }
    }
    @Published var downloadProgress: [WhisperModel: Double] = [:]
    @Published var downloadedModels: Set<WhisperModel> = []
    @Published var isModelLoaded: Bool = false
    @Published var lastError: String?

    static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceInput/Models")
    }()

    static let vadModelPath: String = {
        modelsDirectory.appendingPathComponent("silero_vad.onnx").path
    }()

    init() {
        let saved = UserDefaults.standard.string(forKey: "selectedModel") ?? WhisperModel.small.rawValue
        self.selectedModel = WhisperModel(rawValue: saved) ?? .small
        refreshDownloadedModels()
    }

    func refreshDownloadedModels() {
        downloadedModels = Set(WhisperModel.allCases.filter { model in
            let dir = Self.modelsDirectory.appendingPathComponent(model.directoryName)
            let encoder = dir.appendingPathComponent(model.encoderFilename)
            return FileManager.default.fileExists(atPath: encoder.path)
        })
    }

    func modelDirectory(for model: WhisperModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.directoryName)
    }

    func encoderPath(for model: WhisperModel) -> String {
        modelDirectory(for: model).appendingPathComponent(model.encoderFilename).path
    }

    func decoderPath(for model: WhisperModel) -> String {
        modelDirectory(for: model).appendingPathComponent(model.decoderFilename).path
    }

    func tokensPath(for model: WhisperModel) -> String {
        modelDirectory(for: model).appendingPathComponent(model.tokensFilename).path
    }
}
```

- [ ] **Step 2: Verify build**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add VoiceInput/App/AppState.swift
git commit -m "feat: add AppState with model definitions and state management"
```

---

### Task 4: HotkeyManager — Right Shift Push-to-Talk

**Files:**
- Create: `VoiceInput/Core/HotkeyManager.swift`

- [ ] **Step 1: Create HotkeyManager**

Create `VoiceInput/Core/HotkeyManager.swift`:

```swift
import Cocoa

final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightShiftDown = false

    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkEnd: (() -> Void)?

    func start() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // keyCode 60 = Right Shift
        guard keyCode == 60 else {
            return Unmanaged.passRetained(event)
        }

        let shiftPressed = event.flags.contains(.maskShift)

        if shiftPressed && !isRightShiftDown {
            isRightShiftDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onPushToTalkStart?()
            }
        } else if !shiftPressed && isRightShiftDown {
            isRightShiftDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onPushToTalkEnd?()
            }
        }

        return Unmanaged.passRetained(event)
    }

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
```

- [ ] **Step 2: Wire into VoiceInputApp for testing**

Update `VoiceInput/App/VoiceInputApp.swift`:

```swift
import SwiftUI

@main
struct VoiceInputApp: App {
    @StateObject private var appState = AppState()
    private let hotkeyManager = HotkeyManager()

    init() {
        setupHotkey()
    }

    var body: some Scene {
        MenuBarExtra(
            "VoiceInput",
            systemImage: appState.recordingState == .recording ? "mic.fill" : "mic"
        ) {
            Text("State: \(String(describing: appState.recordingState))")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func setupHotkey() {
        if !HotkeyManager.checkAccessibilityPermission() {
            print("⚠️ Accessibility permission required. Grant in System Settings → Privacy → Accessibility")
        }

        hotkeyManager.onPushToTalkStart = {
            print("🎤 Recording started")
        }
        hotkeyManager.onPushToTalkEnd = {
            print("🛑 Recording stopped")
        }

        if !hotkeyManager.start() {
            print("❌ Failed to create event tap. Check Accessibility permissions.")
        }
    }
}
```

- [ ] **Step 3: Build, run, and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Run the app. Grant Accessibility permission when prompted. Press and release Right Shift. Expected console output:
```
🎤 Recording started
🛑 Recording stopped
```

- [ ] **Step 4: Commit**

```bash
git add VoiceInput/Core/HotkeyManager.swift VoiceInput/App/VoiceInputApp.swift
git commit -m "feat: add HotkeyManager with Right Shift push-to-talk detection"
```

---

### Task 5: AudioCaptureEngine — Microphone Recording

**Files:**
- Create: `VoiceInput/Core/AudioCaptureEngine.swift`

- [ ] **Step 1: Create AudioCaptureEngine**

Create `VoiceInput/Core/AudioCaptureEngine.swift`:

```swift
import AVFoundation

final class AudioCaptureEngine {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16000
    private let targetFormat: AVAudioFormat

    var onAudioBuffer: (([Float]) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noMicrophone
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard converter != nil else {
            throw AudioCaptureError.converterFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var hasData = true
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil { return }

        let samples = extractSamples(from: outputBuffer)
        if samples.isEmpty { return }

        // Compute RMS for audio level visualization
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(rms)
        }

        onAudioBuffer?(samples)
    }

    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}

enum AudioCaptureError: LocalizedError {
    case noMicrophone
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone available"
        case .converterFailed: return "Failed to create audio converter"
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add VoiceInput/Core/AudioCaptureEngine.swift
git commit -m "feat: add AudioCaptureEngine with 16kHz mono capture and RMS metering"
```

---

### Task 6: SherpaRecognizer — VAD + Whisper Pipeline

**Files:**
- Create: `VoiceInput/Core/SherpaRecognizer.swift`
- Already present: `VoiceInput/Bridge/SherpaOnnx.swift` (copied in Task 1)

- [ ] **Step 1: Verify SherpaOnnx.swift is in place**

```bash
ls -la VoiceInput/Bridge/SherpaOnnx.swift
```

Expected: File exists (copied by build script in Task 1). If missing, copy it:
```bash
cp .build/sherpa-onnx/sherpa-onnx/swift-api-examples/SherpaOnnx.swift VoiceInput/Bridge/SherpaOnnx.swift
```

- [ ] **Step 2: Create SherpaRecognizer**

Create `VoiceInput/Core/SherpaRecognizer.swift`:

```swift
import Foundation

final class SherpaRecognizer {
    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let vadWindowSize = 512
    private var audioBuffer: [Float] = []
    private var speechSegments: [[Float]] = []
    private let queue = DispatchQueue(label: "com.voiceinput.recognizer", qos: .userInteractive)

    var isLoaded: Bool { vad != nil && recognizer != nil }

    func load(
        vadModelPath: String,
        encoderPath: String,
        decoderPath: String,
        tokensPath: String
    ) throws {
        // Configure VAD
        let sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: vadModelPath,
            threshold: 0.5,
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.25,
            windowSize: Int(vadWindowSize),
            maxSpeechDuration: 20.0
        )
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: 16000,
            numThreads: 1,
            provider: "cpu"
        )
        let newVad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig,
            buffer_size_in_seconds: 120
        )

        // Configure Whisper offline recognizer
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        let whisperConfig = sherpaOnnxOfflineWhisperModelConfig(
            encoder: encoderPath,
            decoder: decoderPath,
            language: "ru",
            task: "transcribe",
            tailPaddings: -1
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            whisper: whisperConfig,
            numThreads: 2,
            provider: "cpu"
        )
        var recConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )
        let newRecognizer = SherpaOnnxOfflineRecognizer(config: &recConfig)

        self.vad = newVad
        self.recognizer = newRecognizer
    }

    func reset() {
        queue.sync {
            audioBuffer.removeAll()
            speechSegments.removeAll()
            vad?.reset()
        }
    }

    func feedAudio(samples: [Float]) {
        queue.sync {
            audioBuffer.append(contentsOf: samples)

            // Feed VAD in chunks of exactly vadWindowSize
            while audioBuffer.count >= vadWindowSize {
                let chunk = Array(audioBuffer.prefix(vadWindowSize))
                audioBuffer.removeFirst(vadWindowSize)
                vad?.acceptWaveform(samples: chunk)

                // Drain any completed speech segments
                drainVADSegments()
            }
        }
    }

    func recognize() -> String {
        return queue.sync {
            guard let vad = vad, let recognizer = recognizer else { return "" }

            // Flush remaining audio through VAD
            if !audioBuffer.isEmpty {
                // Pad to vadWindowSize
                let padded = audioBuffer + [Float](repeating: 0, count: vadWindowSize - audioBuffer.count)
                vad.acceptWaveform(samples: padded)
                audioBuffer.removeAll()
            }
            vad.flush()
            drainVADSegments()

            // Recognize all accumulated speech segments
            guard !speechSegments.isEmpty else { return "" }

            var results: [String] = []
            for segment in speechSegments {
                let result = recognizer.decode(samples: segment, sampleRate: 16000)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    results.append(text)
                }
            }

            speechSegments.removeAll()
            vad.reset()

            return results.joined(separator: " ")
        }
    }

    private func drainVADSegments() {
        guard let vad = vad else { return }
        while !vad.isEmpty() {
            let segment = vad.front()
            speechSegments.append(segment.samples)
            vad.pop()
        }
    }

    func unload() {
        vad = nil
        recognizer = nil
        audioBuffer.removeAll()
        speechSegments.removeAll()
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Expected: Build succeeds. If SherpaOnnx.swift has API differences from what's shown above (e.g., different parameter names or missing methods), adjust SherpaRecognizer to match the actual API in the copied file.

- [ ] **Step 4: Commit**

```bash
git add VoiceInput/Core/SherpaRecognizer.swift VoiceInput/Bridge/SherpaOnnx.swift VoiceInput/Bridge/BridgingHeader.h
git commit -m "feat: add SherpaRecognizer with VAD + Whisper offline pipeline"
```

---

### Task 7: ClipboardInserter — Paste Text at Cursor

**Files:**
- Create: `VoiceInput/Core/ClipboardInserter.swift`

- [ ] **Step 1: Create ClipboardInserter**

Create `VoiceInput/Core/ClipboardInserter.swift`:

```swift
import Cocoa

final class ClipboardInserter {
    private struct PasteboardBackup {
        let items: [NSPasteboardItem]
        let changeCount: Int
    }

    func insert(text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents
        let backup = savePasteboard(pasteboard)

        // 2. Set recognized text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Simulate Cmd+V
        simulatePaste()

        // 4. Restore clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.restorePasteboard(pasteboard, from: backup)
        }
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> PasteboardBackup {
        var savedItems: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            savedItems.append(copy)
        }
        return PasteboardBackup(items: savedItems, changeCount: pasteboard.changeCount)
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, from backup: PasteboardBackup) {
        // Only restore if nothing else has changed the clipboard since our paste
        guard pasteboard.changeCount == backup.changeCount + 1 else { return }
        pasteboard.clearContents()
        if !backup.items.isEmpty {
            pasteboard.writeObjects(backup.items)
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd + V (keyCode 9 = V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) else { return }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        // Key up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add VoiceInput/Core/ClipboardInserter.swift
git commit -m "feat: add ClipboardInserter with clipboard save/paste/restore"
```

---

### Task 8: OverlayWindow — Floating Animated Circle

**Files:**
- Create: `VoiceInput/UI/OverlayWindow.swift`

- [ ] **Step 1: Create OverlayWindow**

Create `VoiceInput/UI/OverlayWindow.swift`:

```swift
import SwiftUI

final class OverlayWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayCircleView>?
    private let circleViewModel = OverlayCircleViewModel()

    func show() {
        guard window == nil else { return }

        let view = OverlayCircleView(viewModel: circleViewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let windowX = screenFrame.midX - 50
        let windowY = screenFrame.minY + 100

        let win = NSWindow(
            contentRect: NSRect(x: windowX, y: windowY, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.contentView = hosting

        win.alphaValue = 0
        win.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            win.animator().alphaValue = 1
        }

        self.window = win
        self.hostingView = hosting
    }

    func hide() {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            self?.window = nil
            self?.hostingView = nil
            self?.circleViewModel.audioLevel = 0
        })
    }

    func updateAudioLevel(_ level: Float) {
        circleViewModel.audioLevel = level
    }
}

@Observable
final class OverlayCircleViewModel {
    var audioLevel: Float = 0.0
}

struct OverlayCircleView: View {
    let viewModel: OverlayCircleViewModel

    var body: some View {
        let scale = 1.0 + Double(min(viewModel.audioLevel * 3.0, 0.4))

        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.red.opacity(0.6), .red.opacity(0.2)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
            )
            .frame(width: 60, height: 60)
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.1), value: scale)
            .frame(width: 100, height: 100)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add VoiceInput/UI/OverlayWindow.swift
git commit -m "feat: add OverlayWindow with animated circle for recording feedback"
```

---

### Task 9: Wire Push-to-Talk Pipeline

**Files:**
- Modify: `VoiceInput/App/VoiceInputApp.swift`

This task connects all components into the working push-to-talk flow.

- [ ] **Step 1: Rewrite VoiceInputApp with full pipeline**

Replace `VoiceInput/App/VoiceInputApp.swift` with:

```swift
import SwiftUI

@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "VoiceInput",
            systemImage: appDelegate.appState.recordingState == .recording ? "mic.fill" : "mic"
        ) {
            MenuBarView(appState: appDelegate.appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let hotkeyManager = HotkeyManager()
    private let audioEngine = AudioCaptureEngine()
    private let recognizer = SherpaRecognizer()
    private let clipboardInserter = ClipboardInserter()
    private let overlayController = OverlayWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadModel()
        setupHotkey()
    }

    private func loadModel() {
        let model = appState.selectedModel
        guard appState.downloadedModels.contains(model) else {
            appState.lastError = "Model \(model.displayName) not downloaded"
            return
        }

        Task.detached(priority: .userInitiated) { [self] in
            do {
                try recognizer.load(
                    vadModelPath: AppState.vadModelPath,
                    encoderPath: appState.encoderPath(for: model),
                    decoderPath: appState.decoderPath(for: model),
                    tokensPath: appState.tokensPath(for: model)
                )
                await MainActor.run {
                    appState.isModelLoaded = true
                    appState.lastError = nil
                }
            } catch {
                await MainActor.run {
                    appState.lastError = "Failed to load model: \(error.localizedDescription)"
                }
            }
        }
    }

    private func setupHotkey() {
        if !HotkeyManager.checkAccessibilityPermission() {
            appState.lastError = "Grant Accessibility permission in System Settings"
        }

        hotkeyManager.onPushToTalkStart = { [weak self] in
            self?.startRecording()
        }
        hotkeyManager.onPushToTalkEnd = { [weak self] in
            self?.stopRecordingAndRecognize()
        }

        if !hotkeyManager.start() {
            appState.lastError = "Failed to start hotkey listener. Check Accessibility permissions."
        }
    }

    private func startRecording() {
        guard recognizer.isLoaded else {
            appState.lastError = "Model not loaded"
            return
        }
        guard appState.recordingState == .idle else { return }

        recognizer.reset()
        appState.recordingState = .recording
        overlayController.show()

        audioEngine.onAudioBuffer = { [weak self] samples in
            self?.recognizer.feedAudio(samples: samples)
        }
        audioEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.appState.audioLevel = level
                self?.overlayController.updateAudioLevel(level)
            }
        }

        do {
            try audioEngine.start()
        } catch {
            appState.recordingState = .idle
            overlayController.hide()
            appState.lastError = "Microphone error: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndRecognize() {
        guard appState.recordingState == .recording else { return }

        audioEngine.stop()
        appState.recordingState = .recognizing

        Task.detached(priority: .userInitiated) { [self] in
            let text = recognizer.recognize()

            await MainActor.run {
                overlayController.hide()
                appState.recordingState = .idle
                appState.audioLevel = 0

                if !text.isEmpty {
                    clipboardInserter.insert(text: text)
                }
            }
        }
    }

    func reloadModel() {
        recognizer.unload()
        appState.isModelLoaded = false
        loadModel()
    }
}
```

- [ ] **Step 2: Create placeholder MenuBarView**

Create `VoiceInput/UI/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack {
            switch appState.recordingState {
            case .idle:
                Text("Ready")
            case .recording:
                Text("Recording...")
                    .foregroundStyle(.red)
            case .recognizing:
                Text("Recognizing...")
                    .foregroundStyle(.orange)
            }

            if let error = appState.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
```

- [ ] **Step 3: Build and test end-to-end**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Run the app. Ensure model is downloaded (Task 1 Step 4). Open a text editor. Hold Right Shift, speak in Russian, release. Expected: text appears in the editor after 1-3 seconds.

- [ ] **Step 4: Commit**

```bash
git add VoiceInput/App/VoiceInputApp.swift VoiceInput/UI/MenuBarView.swift
git commit -m "feat: wire push-to-talk pipeline — hotkey → audio → VAD + Whisper → paste"
```

---

### Task 10: MenuBarView with Full Settings

**Files:**
- Modify: `VoiceInput/UI/MenuBarView.swift`

- [ ] **Step 1: Replace MenuBarView with full settings UI**

Replace `VoiceInput/UI/MenuBarView.swift` with:

```swift
import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            if let error = appState.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Divider()

            // Model selection
            Text("Model")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(WhisperModel.allCases, id: \.self) { model in
                Button {
                    selectModel(model)
                } label: {
                    HStack {
                        if model == appState.selectedModel {
                            Image(systemName: "checkmark")
                        }
                        Text(model.displayName)
                        Spacer()
                        if appState.downloadedModels.contains(model) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if let progress = appState.downloadProgress[model] {
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                        } else {
                            Text("Download")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .disabled(appState.downloadProgress[model] != nil)
            }

            Divider()

            // Hotkey
            HStack {
                Text("Push-to-talk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Right Shift")
                    .font(.caption)
            }

            Divider()

            // Launch at login
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    toggleLaunchAtLogin(newValue)
                }

            Divider()

            Button("Quit VoiceInput") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 260)
    }

    private var statusText: String {
        switch appState.recordingState {
        case .idle: return appState.isModelLoaded ? "Ready" : "Loading model..."
        case .recording: return "Recording..."
        case .recognizing: return "Recognizing..."
        }
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle: return appState.isModelLoaded ? .green : .yellow
        case .recording: return .red
        case .recognizing: return .orange
        }
    }

    private func selectModel(_ model: WhisperModel) {
        if appState.downloadedModels.contains(model) {
            appState.selectedModel = model
            // Trigger model reload in AppDelegate
            NotificationCenter.default.post(name: .reloadModel, object: nil)
        } else {
            // Trigger download
            NotificationCenter.default.post(
                name: .downloadModel,
                object: model
            )
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }
}

extension Notification.Name {
    static let reloadModel = Notification.Name("reloadModel")
    static let downloadModel = Notification.Name("downloadModel")
}
```

- [ ] **Step 2: Add notification handlers in AppDelegate**

In `VoiceInput/App/VoiceInputApp.swift`, add to `applicationDidFinishLaunching`:

```swift
NotificationCenter.default.addObserver(
    forName: .reloadModel, object: nil, queue: .main
) { [weak self] _ in
    self?.reloadModel()
}
NotificationCenter.default.addObserver(
    forName: .downloadModel, object: nil, queue: .main
) { [weak self] notification in
    guard let model = notification.object as? WhisperModel else { return }
    self?.downloadModel(model)
}
```

Add the `downloadModel` stub method to `AppDelegate`:

```swift
private func downloadModel(_ model: WhisperModel) {
    // Will be implemented in Task 11 (ModelManager)
    appState.lastError = "Download not yet implemented"
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Run the app. Click menu bar icon. Expected: dropdown with status, model list, hotkey display, launch at login toggle, quit button.

- [ ] **Step 4: Commit**

```bash
git add VoiceInput/UI/MenuBarView.swift VoiceInput/App/VoiceInputApp.swift
git commit -m "feat: add full MenuBarView with model selection, status, and settings"
```

---

### Task 11: ModelManager — Download and Manage Models

**Files:**
- Create: `VoiceInput/Core/ModelManager.swift`
- Modify: `VoiceInput/App/VoiceInputApp.swift` (wire downloadModel)

- [ ] **Step 1: Create ModelManager**

Create `VoiceInput/Core/ModelManager.swift`:

```swift
import Foundation

final class ModelManager {
    private var activeTasks: [WhisperModel: URLSessionDownloadTask] = [:]

    func download(
        model: WhisperModel,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        guard activeTasks[model] == nil else { return }

        let modelsDir = AppState.modelsDirectory
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        guard let url = URL(string: model.downloadURL) else {
            onComplete(.failure(ModelManagerError.invalidURL))
            return
        }

        let delegate = DownloadDelegate(
            model: model,
            destinationDir: modelsDir,
            onProgress: onProgress,
            onComplete: { [weak self] result in
                self?.activeTasks[model] = nil
                onComplete(result)
            }
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        activeTasks[model] = task
        task.resume()
    }

    func downloadVAD(
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        let vadPath = AppState.vadModelPath
        if FileManager.default.fileExists(atPath: vadPath) {
            onComplete(.success(()))
            return
        }

        let modelsDir = AppState.modelsDirectory
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        guard let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx") else {
            onComplete(.failure(ModelManagerError.invalidURL))
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            if let error = error {
                onComplete(.failure(error))
                return
            }
            guard let tempURL = tempURL else {
                onComplete(.failure(ModelManagerError.downloadFailed))
                return
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: vadPath))
                onComplete(.success(()))
            } catch {
                onComplete(.failure(error))
            }
        }
        task.resume()
    }

    func cancelDownload(model: WhisperModel) {
        activeTasks[model]?.cancel()
        activeTasks[model] = nil
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let model: WhisperModel
    let destinationDir: URL
    let onProgress: (Double) -> Void
    let onComplete: (Result<Void, Error>) -> Void

    init(
        model: WhisperModel,
        destinationDir: URL,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        self.model = model
        self.destinationDir = destinationDir
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(progress) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // Extract tar.bz2
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xjf", location.path, "-C", tempDir.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw ModelManagerError.extractionFailed
            }

            // Find the extracted directory and move to models dir
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let extractedDir = contents.first else {
                throw ModelManagerError.extractionFailed
            }

            let finalDir = destinationDir.appendingPathComponent(model.directoryName)
            if FileManager.default.fileExists(atPath: finalDir.path) {
                try FileManager.default.removeItem(at: finalDir)
            }
            try FileManager.default.moveItem(at: extractedDir, to: finalDir)
            try FileManager.default.removeItem(at: tempDir)

            DispatchQueue.main.async { self.onComplete(.success(())) }
        } catch {
            DispatchQueue.main.async { self.onComplete(.failure(error)) }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            DispatchQueue.main.async { self.onComplete(.failure(error)) }
        }
    }
}

enum ModelManagerError: LocalizedError {
    case invalidURL
    case downloadFailed
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid download URL"
        case .downloadFailed: return "Download failed"
        case .extractionFailed: return "Failed to extract model archive"
        }
    }
}
```

- [ ] **Step 2: Wire ModelManager into AppDelegate**

In `VoiceInput/App/VoiceInputApp.swift`, add `private let modelManager = ModelManager()` to `AppDelegate` properties.

Replace the `downloadModel` stub with:

```swift
private func downloadModel(_ model: WhisperModel) {
    appState.downloadProgress[model] = 0

    // Ensure VAD is downloaded first
    modelManager.downloadVAD { [weak self] result in
        if case .failure(let error) = result {
            DispatchQueue.main.async {
                self?.appState.lastError = "VAD download failed: \(error.localizedDescription)"
                self?.appState.downloadProgress[model] = nil
            }
            return
        }

        self?.modelManager.download(
            model: model,
            onProgress: { progress in
                DispatchQueue.main.async {
                    self?.appState.downloadProgress[model] = progress
                }
            },
            onComplete: { result in
                DispatchQueue.main.async {
                    self?.appState.downloadProgress[model] = nil
                    switch result {
                    case .success:
                        self?.appState.refreshDownloadedModels()
                        if self?.appState.selectedModel == model {
                            self?.reloadModel()
                        }
                    case .failure(let error):
                        self?.appState.lastError = "Download failed: \(error.localizedDescription)"
                    }
                }
            }
        )
    }
}
```

Also update `applicationDidFinishLaunching` to auto-download if needed:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    setupNotifications()
    setupHotkey()

    // Auto-download default model if not present
    if appState.downloadedModels.contains(appState.selectedModel) {
        loadModel()
    } else {
        downloadModel(appState.selectedModel)
    }
}

private func setupNotifications() {
    NotificationCenter.default.addObserver(
        forName: .reloadModel, object: nil, queue: .main
    ) { [weak self] _ in
        self?.reloadModel()
    }
    NotificationCenter.default.addObserver(
        forName: .downloadModel, object: nil, queue: .main
    ) { [weak self] notification in
        guard let model = notification.object as? WhisperModel else { return }
        self?.downloadModel(model)
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

Run the app. If model is not downloaded, it should auto-download Whisper small with progress shown in the menu. After download, model loads and status shows "Ready".

- [ ] **Step 4: Commit**

```bash
git add VoiceInput/Core/ModelManager.swift VoiceInput/App/VoiceInputApp.swift
git commit -m "feat: add ModelManager with download, extraction, and auto-download on first launch"
```

---

### Task 12: Unit Tests

**Files:**
- Create: `VoiceInputTests/ModelPathTests.swift`
- Create: `VoiceInputTests/AudioBufferTests.swift`

- [ ] **Step 1: Create model path tests**

Create `VoiceInputTests/ModelPathTests.swift`:

```swift
import XCTest
@testable import VoiceInput

final class ModelPathTests: XCTestCase {
    func testWhisperModelFilenames() {
        XCTAssertEqual(WhisperModel.small.encoderFilename, "small-encoder.int8.onnx")
        XCTAssertEqual(WhisperModel.small.decoderFilename, "small-decoder.int8.onnx")
        XCTAssertEqual(WhisperModel.small.tokensFilename, "small-tokens.txt")

        XCTAssertEqual(WhisperModel.medium.encoderFilename, "medium-encoder.int8.onnx")
        XCTAssertEqual(WhisperModel.largeV3.encoderFilename, "large-v3-encoder.int8.onnx")
    }

    func testWhisperModelDirectoryName() {
        XCTAssertEqual(WhisperModel.small.directoryName, "sherpa-onnx-whisper-small")
        XCTAssertEqual(WhisperModel.medium.directoryName, "sherpa-onnx-whisper-medium")
        XCTAssertEqual(WhisperModel.largeV3.directoryName, "sherpa-onnx-whisper-large-v3")
    }

    func testDownloadURL() {
        let url = WhisperModel.small.downloadURL
        XCTAssertTrue(url.contains("sherpa-onnx-whisper-small.tar.bz2"))
        XCTAssertTrue(url.hasPrefix("https://github.com/k2-fsa/sherpa-onnx/releases/"))
    }

    func testModelsDirectoryIsInApplicationSupport() {
        let path = AppState.modelsDirectory.path
        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.contains("VoiceInput"))
    }
}
```

- [ ] **Step 2: Run tests**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInputTests -configuration Debug test
```

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add VoiceInputTests/
git commit -m "test: add unit tests for model paths and configuration"
```

---

### Task 13: Final Polish — Edge Cases and First Launch

**Files:**
- Modify: `VoiceInput/App/VoiceInputApp.swift`

- [ ] **Step 1: Add Accessibility permission check with user guidance**

Add to `AppDelegate`:

```swift
private func checkPermissions() {
    // Check Accessibility
    if !HotkeyManager.checkAccessibilityPermission() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "VoiceInput needs Accessibility permission to detect the Right Shift key globally.\n\nPlease grant permission in:\nSystem Settings → Privacy & Security → Accessibility"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
```

Call `checkPermissions()` at the start of `applicationDidFinishLaunching`.

- [ ] **Step 2: Handle empty speech in the pipeline**

This is already handled — `SherpaRecognizer.recognize()` returns empty string when no speech segments found, and `AppDelegate.stopRecordingAndRecognize()` checks `if !text.isEmpty` before inserting. No changes needed.

- [ ] **Step 3: Handle microphone permission gracefully**

The system automatically shows a permission dialog when `AVAudioEngine` first accesses the microphone. If denied, `audioEngine.start()` throws an error which is already caught in `startRecording()`. No changes needed.

- [ ] **Step 4: Build final version and test all scenarios**

```bash
xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug build
```

**Manual test checklist:**
1. Launch app → mic icon appears in menu bar
2. Click icon → dropdown shows "Loading model..." then "Ready"
3. Hold Right Shift → overlay circle appears, menu bar icon changes
4. Speak in Russian → circle pulses with voice
5. Release Right Shift → circle fades, text appears at cursor position
6. Speak English words mixed with Russian → both recognized
7. Hold Right Shift but stay silent → release → nothing inserted
8. Select different model in menu → downloads if needed, switches
9. Toggle Launch at Login → verify in System Settings
10. Quit from menu → app terminates

- [ ] **Step 5: Commit**

```bash
git add VoiceInput/App/VoiceInputApp.swift
git commit -m "feat: add permission checks and first-launch flow"
```

---

## Final AppDelegate Reference

For clarity, here is the complete `AppDelegate` after all tasks, showing how all components connect:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let hotkeyManager = HotkeyManager()
    private let audioEngine = AudioCaptureEngine()
    private let recognizer = SherpaRecognizer()
    private let clipboardInserter = ClipboardInserter()
    private let overlayController = OverlayWindowController()
    private let modelManager = ModelManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkPermissions()
        setupNotifications()
        setupHotkey()

        if appState.downloadedModels.contains(appState.selectedModel) {
            loadModel()
        } else {
            downloadModel(appState.selectedModel)
        }
    }

    // checkPermissions() — Task 13
    // setupNotifications() — Task 10
    // setupHotkey() — Task 4
    // loadModel() — Task 9
    // startRecording() — Task 9
    // stopRecordingAndRecognize() — Task 9
    // reloadModel() — Task 9
    // downloadModel(_:) — Task 11
}
```
