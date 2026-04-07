import Cocoa

class OverlayWindow {
    private var panel: NSPanel!
    private var circleView: NSView!

    func setup() {
        let size: CGFloat = 48

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - size - 20
            let y = screen.visibleFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        circleView = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        circleView.wantsLayer = true
        circleView.layer?.cornerRadius = size / 2
        panel.contentView = circleView
    }

    func showRecording() {
        circleView.layer?.backgroundColor = NSColor.systemRed.cgColor
        circleView.layer?.opacity = 1.0

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        circleView.layer?.add(pulse, forKey: "pulse")

        panel.orderFront(nil)
    }

    func showProcessing() {
        circleView.layer?.removeAnimation(forKey: "pulse")
        circleView.layer?.backgroundColor = NSColor.systemYellow.cgColor
        circleView.layer?.opacity = 1.0
    }

    func hide() {
        circleView.layer?.removeAllAnimations()
        panel.orderOut(nil)
    }
}
