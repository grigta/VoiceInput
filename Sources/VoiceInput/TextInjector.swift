import Cocoa

class TextInjector {
    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems = savePasteboard(pasteboard)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.restorePasteboard(pasteboard, items: savedItems)
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        return pasteboard.pasteboardItems?.compactMap { item in
            var dict = [String: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[String: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let pasteboardItems = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (typeStr, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
