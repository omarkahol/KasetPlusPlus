import AppKit
import SwiftUI

// MARK: - MainWindowOpener

/// Utility to open or bring Kaset's main window to the front.
enum MainWindowOpener {
    @MainActor
    static func bringMainWindowToFront(openWindow: OpenWindowAction? = nil) {
        if self.focusExistingMainWindow() {
            return
        }

        openWindow?(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            _ = self.focusExistingMainWindow()
        }
    }

    @MainActor
    @discardableResult
    static func focusExistingMainWindow() -> Bool {
        // Find and show the main window by frameAutosaveName
        for window in NSApplication.shared.windows where window.frameAutosaveName == MainWindowLayout.autosaveName {
            MainWindowLayout.configure(window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        // Find by window title
        for window in NSApplication.shared.windows where window.title == MainWindowLayout.windowTitle && !self.isAuxiliaryPlayerWindow(window) {
            MainWindowLayout.configure(window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        // Fallback: any main-capable window that is not auxiliary
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if self.isAuxiliaryPlayerWindow(window) {
                continue
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        return false
    }

    @MainActor
    private static func isAuxiliaryPlayerWindow(_ window: NSWindow) -> Bool {
        AccessibilityID.isAuxiliaryPlayerWindowIdentifier(window.identifier?.rawValue)
    }
}
