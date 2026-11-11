import AppKit
import SwiftUI

/// Independent dashboard window, modeled on the Settings window: a regular
/// NSWindow hosting SwiftUI, with the app returning to accessory mode on close.
final class SystemMonitorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SystemMonitorWindowController()

    private var serviceIsVisible = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let window else { return }

        window.title = "System Monitor"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.delegate = self
        window.contentView = NSHostingView(rootView: SystemMonitorDashboard())

        let autosaveName = "AtollSystemMonitorWindow"
        window.setFrameAutosaveName(autosaveName)
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
    }

    func showWindow() {
        guard let window else { return }

        // Register before ordering the window so the Processes page (if it was
        // last visible) starts sampling immediately on reopen.
        setServiceVisible(true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        setServiceVisible(false)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, window.isVisible, !window.isMiniaturized else {
            setServiceVisible(false)
            return
        }
        setServiceVisible(window.occlusionState.contains(.visible))
    }

    func windowDidMiniaturize(_ notification: Notification) {
        setServiceVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        setServiceVisible(window.occlusionState.contains(.visible))
    }

    private func setServiceVisible(_ visible: Bool) {
        guard visible != serviceIsVisible else { return }
        serviceIsVisible = visible
        SystemMonitorService.shared.setDashboardVisible(visible)
    }
}
