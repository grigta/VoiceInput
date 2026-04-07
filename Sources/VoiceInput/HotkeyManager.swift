import Cocoa
import Carbon.HIToolbox

class HotkeyManager {
    typealias HotkeyAction = (Bool) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onHotkey: HotkeyAction?

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

    func start(onHotkey: @escaping HotkeyAction) {
        self.onHotkey = onHotkey

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Unmanaged<HotkeyManager>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags

        let modifiersMatch = eventFlags.contains(modifierFlags)

        if type == .keyDown && eventKeyCode == keyCode && modifiersMatch && !isHotkeyDown {
            isHotkeyDown = true
            onHotkey?(true)
            return nil
        }

        if type == .keyUp && eventKeyCode == keyCode && isHotkeyDown {
            isHotkeyDown = false
            onHotkey?(false)
            return nil
        }

        if type == .flagsChanged && isHotkeyDown && !modifiersMatch {
            isHotkeyDown = false
            onHotkey?(false)
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}
