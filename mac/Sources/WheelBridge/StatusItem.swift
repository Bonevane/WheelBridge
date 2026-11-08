import AppKit
import Combine
import SwiftUI

/// The menu bar item, with a borderless panel so the SwiftUI view can draw its
/// own glass shape. This follows the same approach as Bridge, because
/// `MenuBarExtra` gives a square panel and no right-click.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openWindow: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var outsideClicks: Any?
    private var cancellable: AnyCancellable?

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        if let button = item.button {
            button.image = WheelGlyph.templateImage()
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Dimmed when nothing is connected, the way Wi-Fi's icon is.
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.item.button?.alphaValue = self.model.wheelReady ? 1 : 0.5
            }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open WheelBridge", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit WheelBridge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openMain() { openWindow() }

    @objc private func quit() { NSApp.terminate(nil) }

    func openPanel() {
        let view = MenuPanel(model: model) { [weak self] in
            self?.closePanel()
            self?.openWindow()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        // Added a moment later, or the click that opened the panel would close it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.panel != nil else { return }
            self.outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let panel = self.panel else { return }
                    if !panel.frame.contains(NSEvent.mouseLocation) { self.closePanel() }
                }
            }
        }
    }

    private func position(_ panel: NSPanel) {
        guard let button = item.button, let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = frame.midX - panel.frame.width / 2
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(visible.minX + 8, x), visible.maxX - panel.frame.width - 8)
        }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: frame.minY - 6))
    }

    func closePanel() {
        if let monitor = outsideClicks { NSEvent.removeMonitor(monitor) }
        outsideClicks = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
