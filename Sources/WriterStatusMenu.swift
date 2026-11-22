import AppKit

@MainActor
final class WriterStatusMenu: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?

    private var statusItem: NSStatusItem?

    private(set) lazy var menu: NSMenu = {
        let menu = NSMenu()
        // Keep Quit enabled while the status menu is open without a key window.
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Open NTFS Writer", action: #selector(showMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NTFS Writer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        quit.isEnabled = true
        menu.addItem(quit)
        return menu
    }()

    func setVisible(_ isVisible: Bool) {
        if isVisible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "NTFS Writer"
            item.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NTFS Writer")
            item.button?.toolTip = "NTFS Writer"
            item.menu = menu
            statusItem = item
        } else if !isVisible, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        statusItem == nil
    }

    @objc private func showMainWindow() {
        NSApplication.shared.activate()
        openMainWindow?()
    }

    @objc private func showSettings() {
        NSApplication.shared.activate()
        openSettings?()
    }
}
