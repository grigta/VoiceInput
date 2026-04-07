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

    // Fallback: NSEvent monitors when CGEvent tap fails
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var usingFallback = false

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
        stop()

        self.onHotkey = onHotkey

        // Try CGEvent tap first (preferred — can consume events)
        if startCGEventTap() {
            usingFallback = false
            print("[HotkeyManager] Using CGEvent tap")
            return true
        }

        // Fallback to NSEvent global monitors (can't consume events, but works more reliably)
        print("[HotkeyManager] CGEvent tap failed, using NSEvent fallback")
        startNSEventFallback()
        usingFallback = true
        return true
    }

    // MARK: - CGEvent Tap (primary)

    private func startCGEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

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
            print("[HotkeyManager] CGEvent.tapCreate returned nil")
            retainedSelf?.release()
            retainedSelf = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - NSEvent Fallback

    private func startNSEventFallback() {
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleNSEvent(event, isKeyDown: true)
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) {
            [weak self] event in
            self?.handleNSEvent(event, isKeyDown: false)
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
        }
        print("[HotkeyManager] NSEvent fallback active for keyCode=\(keyCode)")
    }

    private func handleNSEvent(_ event: NSEvent, isKeyDown: Bool) {
        let eventKeyCode = CGKeyCode(event.keyCode)
        guard eventKeyCode == keyCode else { return }

        let mods = event.modifierFlags
        let modifiersMatch = checkNSModifiers(mods)

        if isKeyDown && modifiersMatch && !isHotkeyDown {
            isHotkeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(true)
            }
        } else if !isKeyDown && isHotkeyDown {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(false)
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        if isHotkeyDown && !checkNSModifiers(event.modifierFlags) {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(false)
            }
        }
    }

    private func checkNSModifiers(_ mods: NSEvent.ModifierFlags) -> Bool {
        if modifierFlags.contains(.maskCommand) && !mods.contains(.command) { return false }
        if modifierFlags.contains(.maskAlternate) && !mods.contains(.option) { return false }
        if modifierFlags.contains(.maskControl) && !mods.contains(.control) { return false }
        if modifierFlags.contains(.maskShift) && !mods.contains(.shift) { return false }
        return true
    }

    // MARK: - Stop

    func stop() {
        // Stop CGEvent tap
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

        // Stop NSEvent monitors
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyUpMonitor { NSEvent.removeMonitor(m) }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        globalKeyDownMonitor = nil
        globalKeyUpMonitor = nil
        globalFlagsMonitor = nil

        isHotkeyDown = false
    }

    // MARK: - CGEvent callback handler

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[HotkeyManager] Tap disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags

        let relevantMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let requiredMods = modifierFlags.intersection(relevantMask)
        let eventMods = eventFlags.intersection(relevantMask)
        let modifiersMatch = eventMods.contains(requiredMods)

        if type == .keyDown && eventKeyCode == keyCode && modifiersMatch && !isHotkeyDown {
            isHotkeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(true)
            }
            return nil
        }

        if type == .keyUp && eventKeyCode == keyCode && isHotkeyDown {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?(false)
            }
            return nil
        }

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
