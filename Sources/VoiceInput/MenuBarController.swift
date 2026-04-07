import Cocoa
import Carbon.HIToolbox

protocol MenuBarDelegate: AnyObject {
    func menuBarDidRequestQuit()
    func menuBarDidSelectModel(_ size: ModelSize)
    func menuBarDidRecordShortcut(modifiers: CGEventFlags, keyCode: CGKeyCode)
}

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var shortcutMenuItem: NSMenuItem!
    private var modelMenuItems: [ModelSize: NSMenuItem] = [:]

    weak var delegate: MenuBarDelegate?

    private var currentModifiers: CGEventFlags = .maskAlternate
    private var currentKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_D)

    private var isRecordingShortcut = false
    private var shortcutMonitor: Any?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "VoiceInput"
            )
        }

        menu = NSMenu()

        // Status line
        statusMenuItem = NSMenuItem(title: "Model: base | Loading...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Shortcut
        shortcutMenuItem = NSMenuItem(
            title: shortcutDisplayString(),
            action: #selector(startRecordingShortcut),
            keyEquivalent: ""
        )
        shortcutMenuItem.target = self
        menu.addItem(shortcutMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Model submenu
        let modelMenu = NSMenu()
        for size in ModelSize.allCases {
            let item = NSMenuItem(
                title: size.displayName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = size
            modelMenu.addItem(item)
            modelMenuItems[size] = item
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        // Reset Permissions
        let resetItem = NSMenuItem(
            title: "Reset Accessibility...",
            action: #selector(resetAccessibility),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        menu.items.last?.target = self

        statusItem.menu = menu
    }

    func updateStatus(model: ModelSize, ready: Bool, message: String? = nil) {
        let modelName = model.rawValue
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
        if let message = message {
            statusMenuItem.title = message
        } else {
            statusMenuItem.title = "Model: \(modelName) | \(ready ? "Ready" : "Loading...")"
        }

        for (size, item) in modelMenuItems {
            item.state = size == model ? .on : .off
        }
    }

    func updateShortcut(modifiers: CGEventFlags, keyCode: CGKeyCode) {
        currentModifiers = modifiers
        currentKeyCode = keyCode
        shortcutMenuItem.title = shortcutDisplayString()
    }

    func updateIcon(recording: Bool, micDenied: Bool) {
        let name: String
        if micDenied {
            name = "mic.slash"
        } else if recording {
            name = "mic.fill"
        } else {
            name = "mic.fill"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "VoiceInput"
        )

        if recording {
            statusItem.button?.appearsDisabled = false
            statusItem.button?.contentTintColor = .systemRed
        } else {
            statusItem.button?.contentTintColor = nil
        }
    }

    // MARK: - Shortcut Recording

    private var recorderPanel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    @objc private func startRecordingShortcut() {
        // Open a small floating panel so we can capture key events
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Press new shortcut..."
        panel.level = .floating
        panel.center()
        panel.isReleasedWhenClosed = false

        let label = NSTextField(frame: NSRect(x: 20, y: 25, width: 260, height: 30))
        label.stringValue = "Press a key combination (e.g. ⌥D)..."
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        panel.contentView?.addSubview(label)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recorderPanel = panel

        shortcutMenuItem.title = "Recording..."

        // Use BOTH local (for events in this panel) and global (for events elsewhere) monitors
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleRecordedEvent(event)
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleRecordedEvent(event)
        }
    }

    private func handleRecordedEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags
        let keyCode = CGKeyCode(event.keyCode)

        // Require at least one modifier
        let hasModifier = modifiers.contains(.command) ||
            modifiers.contains(.option) ||
            modifiers.contains(.control) ||
            modifiers.contains(.shift)

        guard hasModifier else { return }

        // Clean up monitors and panel
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        globalMonitor = nil
        recorderPanel?.close()
        recorderPanel = nil

        // Convert NSEvent modifier flags to CGEventFlags
        var cgFlags: CGEventFlags = []
        if modifiers.contains(.command) { cgFlags.insert(.maskCommand) }
        if modifiers.contains(.option) { cgFlags.insert(.maskAlternate) }
        if modifiers.contains(.control) { cgFlags.insert(.maskControl) }
        if modifiers.contains(.shift) { cgFlags.insert(.maskShift) }

        currentModifiers = cgFlags
        currentKeyCode = keyCode
        shortcutMenuItem.title = shortcutDisplayString()
        delegate?.menuBarDidRecordShortcut(modifiers: cgFlags, keyCode: keyCode)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? ModelSize else { return }
        delegate?.menuBarDidSelectModel(size)
    }

    @objc private func resetAccessibility() {
        // Reset TCC accessibility permission for this app
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", "com.voiceinput.app"]
        try? process.run()
        process.waitUntilExit()

        let alert = NSAlert()
        alert.messageText = "Accessibility Reset"
        alert.informativeText = "Please quit VoiceInput, reopen it, and grant Accessibility permission again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func quit() {
        delegate?.menuBarDidRequestQuit()
    }

    // MARK: - Helpers

    private func shortcutDisplayString() -> String {
        var parts: [String] = []
        if currentModifiers.contains(.maskControl) { parts.append("⌃") }
        if currentModifiers.contains(.maskAlternate) { parts.append("⌥") }
        if currentModifiers.contains(.maskShift) { parts.append("⇧") }
        if currentModifiers.contains(.maskCommand) { parts.append("⌘") }

        let keyName = keyCodeToString(currentKeyCode)
        parts.append(keyName)

        return "Shortcut: \(parts.joined())"
    }

    private func keyCodeToString(_ keyCode: CGKeyCode) -> String {
        let mapping: [CGKeyCode: String] = [
            CGKeyCode(kVK_ANSI_A): "A", CGKeyCode(kVK_ANSI_B): "B",
            CGKeyCode(kVK_ANSI_C): "C", CGKeyCode(kVK_ANSI_D): "D",
            CGKeyCode(kVK_ANSI_E): "E", CGKeyCode(kVK_ANSI_F): "F",
            CGKeyCode(kVK_ANSI_G): "G", CGKeyCode(kVK_ANSI_H): "H",
            CGKeyCode(kVK_ANSI_I): "I", CGKeyCode(kVK_ANSI_J): "J",
            CGKeyCode(kVK_ANSI_K): "K", CGKeyCode(kVK_ANSI_L): "L",
            CGKeyCode(kVK_ANSI_M): "M", CGKeyCode(kVK_ANSI_N): "N",
            CGKeyCode(kVK_ANSI_O): "O", CGKeyCode(kVK_ANSI_P): "P",
            CGKeyCode(kVK_ANSI_Q): "Q", CGKeyCode(kVK_ANSI_R): "R",
            CGKeyCode(kVK_ANSI_S): "S", CGKeyCode(kVK_ANSI_T): "T",
            CGKeyCode(kVK_ANSI_U): "U", CGKeyCode(kVK_ANSI_V): "V",
            CGKeyCode(kVK_ANSI_W): "W", CGKeyCode(kVK_ANSI_X): "X",
            CGKeyCode(kVK_ANSI_Y): "Y", CGKeyCode(kVK_ANSI_Z): "Z",
            CGKeyCode(kVK_Space): "Space",
            CGKeyCode(kVK_Return): "Return",
            CGKeyCode(kVK_Tab): "Tab",
        ]
        return mapping[keyCode] ?? "Key\(keyCode)"
    }
}
