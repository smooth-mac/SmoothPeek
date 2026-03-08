import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var dockMonitor: DockMonitor?
    private var previewController: PreviewPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 백그라운드 앱 (Dock 아이콘 없음)
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()
        checkPermissions()
        startMonitoring()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "DockPeek")
            button.action = #selector(statusBarClicked)
            button.target = self
        }
    }

    @objc private func statusBarClicked() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "DockPeek 실행 중", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Permissions

    private func checkPermissions() {
        // 접근성 권한
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("[DockPeek] 접근성 권한이 필요합니다.")
        }

        // 화면 녹화 권한은 ScreenCaptureKit 첫 사용 시 자동 요청됨
    }

    // MARK: - Core

    private func startMonitoring() {
        previewController = PreviewPanelController()

        dockMonitor = DockMonitor()
        dockMonitor?.onAppHovered = { [weak self] bundleID, app in
            self?.handleHover(bundleID: bundleID, app: app)
        }
        dockMonitor?.onHoverEnded = { [weak self] in
            self?.previewController?.hide()
        }
        dockMonitor?.start()
    }

    private func handleHover(bundleID: String?, app: NSRunningApplication?) {
        guard let app = app else {
            previewController?.hide()
            return
        }
        let windows = WindowEnumerator.windows(for: app)
        guard !windows.isEmpty else { return }

        previewController?.show(for: app, windows: windows)
    }
}
