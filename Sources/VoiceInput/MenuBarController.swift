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

    @objc private func startRecordingShortcut() {
        shortcutMenuItem.title = "Press new shortcut..."
        isRecordingShortcut = true

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecordingShortcut else { return event }

            let modifiers = event.cgEvent?.flags ?? []
            let keyCode = CGKeyCode(event.keyCode)

            // Require at least one modifier
            let hasModifier = modifiers.contains(.maskCommand) ||
                modifiers.contains(.maskAlternate) ||
                modifiers.contains(.maskControl) ||
                modifiers.contains(.maskShift)

            guard hasModifier else { return nil }

            self.isRecordingShortcut = false
            if let monitor = self.shortcutMonitor {
                NSEvent.removeMonitor(monitor)
                self.shortcutMonitor = nil
            }

            self.currentModifiers = modifiers.intersection(
                [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            )
            self.currentKeyCode = keyCode
            self.shortcutMenuItem.title = self.shortcutDisplayString()
            self.delegate?.menuBarDidRecordShortcut(modifiers: self.currentModifiers, keyCode: keyCode)

            return nil
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? ModelSize else { return }
        delegate?.menuBarDidSelectModel(size)
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
