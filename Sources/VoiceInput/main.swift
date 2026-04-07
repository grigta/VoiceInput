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
                    self?.menuBar.updateStatus(model: size, ready: true)
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

    private func startHotkeyListener() {
        guard HotkeyManager.checkAccessibility(prompt: true) else {
            print("Accessibility permission required")
            return
        }

        hotkeyManager.start { [weak self] isKeyDown in
            DispatchQueue.main.async {
                if isKeyDown {
                    self?.startRecording()
                } else {
                    self?.stopRecordingAndTranscribe()
                }
            }
        }
    }

    // MARK: - Push-to-Talk Cycle

    private func startRecording() {
        guard whisperContext != nil, !isRecording else { return }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            overlay.showRecording()
            menuBar.updateIcon(recording: true, micDenied: false)
        } catch {
            menuBar.updateIcon(recording: false, micDenied: true)
            print("Failed to start recording: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        let samples = audioRecorder.stopRecording()
        isRecording = false
        menuBar.updateIcon(recording: false, micDenied: false)

        guard !samples.isEmpty, let ctx = whisperContext else {
            overlay.hide()
            return
        }

        overlay.showProcessing()

        Task {
            do {
                let text = try await ctx.transcribe(samples)
                await MainActor.run {
                    if !text.isEmpty {
                        self.textInjector.inject(text)
                    }
                    self.overlay.hide()
                }
            } catch {
                await MainActor.run {
                    self.overlay.hide()
                    print("Transcription failed: \(error)")
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
            menuBar.updateStatus(model: size, ready: false)
            modelManager.downloadModel(
                size,
                progress: { _ in },
                completion: { [weak self] result in
                    switch result {
                    case .success:
                        self?.modelManager.setCurrentModel(size)
                        self?.loadModelAndStart()
                    case .failure(let error):
                        print("Download failed: \(error)")
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
