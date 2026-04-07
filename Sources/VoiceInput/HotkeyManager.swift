import Cocoa
import Carbon.HIToolbox

// Top-level C-compatible callback — CGEvent tap requires this
private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type: type, event: event)
}

class HotkeyManager {
    typealias HotkeyAction = (Bool) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onHotkey: HotkeyAction?
    private var retainedSelf: Unmanaged<HotkeyManager>?

    var modifierFlags: CGEventFlags = .maskAlternate
    var keyCode: CGKeyCode = CGKeyCode(kVK_ANSI_D)

    private var isHotkeyDown = false

    static func checkAccessibility(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func loadFromDefaults() {
        let defaults = UserDefaults.standard
        if let rawFlags = defaults.object(forKey: "hotkeyModifiers") as? UInt64 {
            modifierFlags = CGEventFlags(rawValue: rawFlags)
        }
        if let code = defaults.object(forKey: "hotkeyKeyCode") as? UInt16 {
            keyCode = code
        }
    }

    func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(modifierFlags.rawValue, forKey: "hotkeyModifiers")
        defaults.set(keyCode, forKey: "hotkeyKeyCode")
    }

    func updateHotkey(modifiers: CGEventFlags, keyCode: CGKeyCode) {
        self.modifierFlags = modifiers
        self.keyCode = keyCode
        saveToDefaults()
    }

    func start(onHotkey: @escaping HotkeyAction) -> Bool {
        stop()  // Clean up any existing tap

        self.onHotkey = onHotkey

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        // Retain self for the C callback
        retainedSelf = Unmanaged.passRetained(self)
        let selfPtr = retainedSelf!.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: selfPtr
        ) else {
            print("[HotkeyManager] ERROR: CGEvent.tapCreate returned nil — accessibility not granted?")
            retainedSelf?.release()
            retainedSelf = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[HotkeyManager] Event tap created successfully. Listening for keyCode=\(keyCode) modifiers=\(modifierFlags.rawValue)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        retainedSelf?.release()
        retainedSelf = nil
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[HotkeyManager] Tap was disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags

        // Check if required modifiers are present (ignore extra modifiers like numpad, fn)
        let relevantMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let requiredMods = modifierFlags.intersection(relevantMask)
        let eventMods = eventFlags.intersection(relevantMask)
        let modifiersMatch = eventMods.contains(requiredMods)

        if type == .keyDown && eventKeyCode == keyCode && modifiersMatch && !isHotkeyDown {
            isHotkeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(true)
            }
            return nil  // Consume the event
        }

        if type == .keyUp && eventKeyCode == keyCode && isHotkeyDown {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(false)
            }
            return nil  // Consume the event
        }

        // If modifier released while hotkey was down
        if type == .flagsChanged && isHotkeyDown && !modifiersMatch {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(false)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}
