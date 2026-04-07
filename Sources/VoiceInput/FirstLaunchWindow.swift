import Cocoa

class FirstLaunchWindow: NSObject {
    private var window: NSWindow!
    private var progressIndicator: NSProgressIndicator!
    private var downloadButton: NSButton!
    private var statusLabel: NSTextField!
    private var selectedSize: ModelSize = .base
    private var radioButtons: [ModelSize: NSButton] = [:]

    private var modelManager: ModelManager?
    private var completion: ((ModelSize) -> Void)?
    private var progressObserver: NSKeyValueObservation?

    func show(modelManager: ModelManager, completion: @escaping (ModelSize) -> Void) {
        self.modelManager = modelManager
        self.completion = completion

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput — First Launch Setup"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // Title
        let titleLabel = makeLabel(
            "Choose a Whisper model",
            font: .systemFont(ofSize: 18, weight: .semibold),
            frame: NSRect(x: 30, y: 260, width: 360, height: 30)
        )
        contentView.addSubview(titleLabel)

        let subtitleLabel = makeLabel(
            "Larger models are more accurate but use more memory and are slower.",
            font: .systemFont(ofSize: 12),
            frame: NSRect(x: 30, y: 235, width: 360, height: 20)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        contentView.addSubview(subtitleLabel)

        // Radio buttons
        var y = 195
        for size in [ModelSize.tiny, .base, .small] {
            let radio = NSButton(radioButtonWithTitle: size.displayName,
                                 target: self,
                                 action: #selector(radioSelected(_:)))
            radio.frame = NSRect(x: 30, y: y, width: 300, height: 24)
            radio.tag = ModelSize.allCases.firstIndex(of: size)!
            if size == .base {
                radio.title += "  ← recommended"
                radio.state = .on
            }
            contentView.addSubview(radio)
            radioButtons[size] = radio
            y -= 30
        }

        // Download button
        downloadButton = NSButton(
            title: "Download",
            target: self,
            action: #selector(downloadClicked)
        )
        downloadButton.bezelStyle = .rounded
        downloadButton.frame = NSRect(x: 30, y: 70, width: 100, height: 32)
        contentView.addSubview(downloadButton)

        // Progress indicator
        progressIndicator = NSProgressIndicator(
            frame: NSRect(x: 30, y: 50, width: 360, height: 10)
        )
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isIndeterminate = false
        progressIndicator.isHidden = true
        contentView.addSubview(progressIndicator)

        // Status label
        statusLabel = makeLabel(
            "",
            font: .systemFont(ofSize: 11),
            frame: NSRect(x: 30, y: 25, width: 360, height: 18)
        )
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func radioSelected(_ sender: NSButton) {
        let index = sender.tag
        if index < ModelSize.allCases.count {
            selectedSize = ModelSize.allCases[index]
        }
    }

    @objc private func downloadClicked() {
        guard let modelManager = modelManager else { return }

        downloadButton.isEnabled = false
        radioButtons.values.forEach { $0.isEnabled = false }
        progressIndicator.isHidden = false
        statusLabel.stringValue = "Downloading \(selectedSize.displayName)..."

        // Observe progress
        progressObserver = modelManager.observe(\.downloadProgress, options: [.new]) {
            [weak self] _, change in
            DispatchQueue.main.async {
                if let progress = change.newValue {
                    self?.progressIndicator.doubleValue = progress
                    let percent = Int(progress * 100)
                    self?.statusLabel.stringValue = "Downloading... \(percent)%"
                }
            }
        }

        modelManager.downloadModel(selectedSize) { [weak self] result in
            guard let self = self else { return }
            self.progressObserver?.invalidate()

            switch result {
            case .success:
                self.modelManager?.setCurrentModel(self.selectedSize)
                self.window.close()
                self.completion?(self.selectedSize)
            case .failure(let error):
                self.statusLabel.stringValue = "Error: \(error.localizedDescription)"
                self.downloadButton.isEnabled = true
                self.radioButtons.values.forEach { $0.isEnabled = true }
            }
        }
    }

    private func makeLabel(_ text: String, font: NSFont, frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.font = font
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        return label
    }
}
