import AppKit
import SwiftUI

/// Menu bar first, with one ordinary window for everything else.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var window: NSWindow?

    private var arguments: [String] { CommandLine.arguments }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let previewing = arguments.contains("--preview")

        // One at a time: a second copy could fight over settings.
        if !previewing, let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0 != NSRunningApplication.current }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(previewing ? .regular : .accessory)
        if !previewing { HelperAgent.start() }
        AppModel.shared.start()
        if !previewing { Updater.shared.start() }
        if previewing, let index = arguments.firstIndex(of: "--update"), arguments.indices.contains(index + 1) {
            Updater.shared.applyPreview(arguments[index + 1])
        }
        statusItem = StatusItemController(model: .shared) { [weak self] in self?.showWindow() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Back to menu bar only once the window has gone.
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
        if previewing {
            showWindow()
            if arguments.contains("--panel") {
                // Once the menu bar has placed the icon, so the panel hangs under it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.statusItem?.openPanel() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let index = arguments.firstIndex(of: "--screen"), arguments.indices.contains(index + 1),
           let screen = Screen(rawValue: arguments[index + 1]) {
            AppModel.shared.screen = screen
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "WheelBridge"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Only the title bar strip moves the window, so drags reach the sliders.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: .shared))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
