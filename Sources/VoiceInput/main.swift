import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, MenuBarDelegate {
    private var menuBar: MenuBarController!
    private var overlay: OverlayWindow!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var textInjector: TextInjector!
    private var modelManager: ModelManager!
    private var firstLaunchWindow: FirstLaunchWindow?
    private var whisperContext: WhisperContext?

    private var isRecording = false
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        menuBar.setup()
        menuBar.delegate = self

        overlay = OverlayWindow()
        overlay.setup()

        audioRecorder = AudioRecorder()
        textInjector = TextInjector()
        modelManager = ModelManager()
        hotkeyManager = HotkeyManager()
        hotkeyManager.loadFromDefaults()

        menuBar.updateShortcut(
            modifiers: hotkeyManager.modifierFlags,
            keyCode: hotkeyManager.keyCode
        )

        if !modelManager.hasAnyModel() {
            showFirstLaunch()
        } else {
            loadModelAndStart()
        }
    }

    // MARK: - First Launch

    private func showFirstLaunch() {
        firstLaunchWindow = FirstLaunchWindow()
        firstLaunchWindow?.show(modelManager: modelManager) { [weak self] size in
            self?.firstLaunchWindow = nil
            self?.loadModelAndStart()
        }
    }

    // MARK: - Model Loading

    private func loadModelAndStart() {
        let size = modelManager.currentModelSize()
        let path = modelManager.modelPath(for: size).path

        guard FileManager.default.fileExists(atPath: path) else {
            // Configured model is missing, try to find any downloaded model
            if let availableSize = ModelSize.allCases.first(where: { modelManager.isModelDownloaded($0) }) {
                modelManager.setCurrentModel(availableSize)
                loadModelAndStart()
            } else {
                showFirstLaunch()
            }
            return
        }

        menuBar.updateStatus(model: size, ready: false)

        Task.detached { [weak self] in
            do {
                let ctx = try WhisperContext.create(modelPath: path)
                await MainActor.run {
                    self?.whisperContext = ctx
                    print("[App] Model loaded: \(size.rawValue)")
                    self?.startHotkeyListener()
                }
            } catch {
                await MainActor.run {
                    self?.menuBar.updateStatus(model: size, ready: false)
                    print("Failed to load model: \(error)")
                }
            }
        }
    }

    // MARK: - Hotkey

    private var hasPromptedAccessibility = false

    private func startHotkeyListener() {
        // Stop any existing retry timer
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil

        // Check accessibility — only show prompt once per launch
        let isTrusted = HotkeyManager.checkAccessibility(prompt: !hasPromptedAccessibility)
        hasPromptedAccessibility = true

        if !isTrusted {
            print("[App] Accessibility not granted — polling every 2s...")
            menuBar.updateStatus(
                model: modelManager.currentModelSize(),
                ready: false,
                message: "Waiting for Accessibility permission..."
            )
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
                [weak self] timer in
                if HotkeyManager.checkAccessibility(prompt: false) {
                    timer.invalidate()
                    self?.accessibilityTimer = nil
                    print("[App] Accessibility granted!")
                    self?.startHotkeyListener()
                }
            }
            return
        }

        // Try to create the event tap
        let success = hotkeyManager.start { [weak self] isKeyDown in
            if isKeyDown {
                self?.startRecording()
            } else {
                self?.stopRecordingAndTranscribe()
            }
        }

        if success {
            print("[App] Hotkey listener started — press Option+D to record")
            menuBar.updateStatus(model: modelManager.currentModelSize(), ready: true)
        } else {
            print("[App] Failed to create event tap — retrying in 3s...")
            menuBar.updateStatus(
                model: modelManager.currentModelSize(),
                ready: false,
                message: "Hotkey failed — try restarting app"
            )
            // Retry once after delay (macOS sometimes needs time after granting permission)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.startHotkeyListener()
            }
        }
    }

    // MARK: - Push-to-Talk Cycle

    private func startRecording() {
        guard whisperContext != nil, !isRecording else {
            print("[App] startRecording skipped: context=\(whisperContext != nil) isRecording=\(isRecording)")
            return
        }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            overlay.showRecording()
            menuBar.updateIcon(recording: true, micDenied: false)
            print("[App] Recording started")
        } catch {
            menuBar.updateIcon(recording: false, micDenied: true)
            print("[App] Failed to start recording: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        let samples = audioRecorder.stopRecording()
        isRecording = false
        menuBar.updateIcon(recording: false, micDenied: false)

        print("[App] Recording stopped. Samples: \(samples.count) (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

        guard !samples.isEmpty, let ctx = whisperContext else {
            print("[App] No samples or no context — skipping transcription")
            overlay.hide()
            return
        }

        // Need at least 0.5s of audio
        guard samples.count > 8000 else {
            print("[App] Audio too short (\(samples.count) samples) — skipping")
            overlay.hide()
            return
        }

        overlay.showProcessing()

        Task {
            do {
                print("[App] Transcribing \(samples.count) samples...")
                let text = try await ctx.transcribe(samples)
                print("[App] Transcription result: '\(text)'")
                await MainActor.run {
                    if !text.isEmpty {
                        print("[App] Injecting text: '\(text)'")
                        self.textInjector.inject(text)
                    } else {
                        print("[App] Transcription returned empty string")
                    }
                    self.overlay.hide()
                }
            } catch {
                await MainActor.run {
                    self.overlay.hide()
                    print("[App] Transcription error: \(error)")
                }
            }
        }
    }

    // MARK: - MenuBarDelegate

    func menuBarDidRequestQuit() {
        hotkeyManager.stop()
        NSApplication.shared.terminate(nil)
    }

    func menuBarDidSelectModel(_ size: ModelSize) {
        if modelManager.isModelDownloaded(size) {
            modelManager.setCurrentModel(size)
            whisperContext = nil
            loadModelAndStart()
        } else {
            menuBar.updateStatus(model: size, ready: false, message: "Downloading \(size.displayName)...")
            print("[App] Downloading model: \(size.displayName)")
            modelManager.downloadModel(
                size,
                progress: { [weak self] progress in
                    let pct = Int(progress * 100)
                    self?.menuBar.updateStatus(model: size, ready: false, message: "Downloading... \(pct)%")
                },
                completion: { [weak self] result in
                    switch result {
                    case .success:
                        print("[App] Download complete: \(size.displayName)")
                        self?.modelManager.setCurrentModel(size)
                        self?.loadModelAndStart()
                    case .failure(let error):
                        self?.menuBar.updateStatus(model: size, ready: false, message: "Download failed")
                        print("[App] Download failed: \(error)")
                    }
                }
            )
        }
    }

    func menuBarDidRecordShortcut(modifiers: CGEventFlags, keyCode: CGKeyCode) {
        hotkeyManager.stop()
        hotkeyManager.updateHotkey(modifiers: modifiers, keyCode: keyCode)
        startHotkeyListener()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
