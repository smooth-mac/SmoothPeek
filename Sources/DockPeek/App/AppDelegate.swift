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

    // P1-3: 앱 종료 시 DockMonitor 리소스 해제
    func applicationWillTerminate(_ notification: Notification) {
        dockMonitor?.stop()
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("[DockPeek] 접근성 권한이 필요합니다.")
            // 시스템 권한 요청 다이얼로그가 자동으로 표시됨 (prompt: true)
        }
        // 화면 녹화 권한은 ScreenCaptureKit 첫 사용 시 자동 요청됨
    }

    // P1-4: CGEventTap 생성 실패 시 사용자에게 안내
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "접근성 권한이 필요합니다"
        alert.informativeText = "DockPeek가 Dock 이벤트를 감지하려면 접근성 권한이 필요합니다.\n\n시스템 설정 → 개인 정보 보호 및 보안 → 손쉬운 사용에서 DockPeek를 허용한 후 앱을 재시작해 주세요."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "나중에")

        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }

        // 상태바 아이콘을 경고 아이콘으로 변경
        statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "DockPeek — 권한 필요")
        statusItem?.button?.toolTip = "DockPeek: 접근성 권한이 필요합니다"
    }

    // MARK: - Core

    @MainActor
    private func startMonitoring() {
        previewController = PreviewPanelController()

        dockMonitor = DockMonitor()
        dockMonitor?.onAppHovered = { [weak self] bundleID, app in
            Task { @MainActor in self?.handleHover(bundleID: bundleID, app: app) }
        }
        dockMonitor?.onHoverEnded = { [weak self] in
            Task { @MainActor in self?.previewController?.hide() }
        }
        dockMonitor?.onPermissionError = { [weak self] in
            Task { @MainActor in self?.showPermissionAlert() }
        }
        dockMonitor?.start()
    }

    @MainActor
    private func handleHover(bundleID: String?, app: NSRunningApplication?) {
        guard let app = app else {
            previewController?.hide()
            return
        }
        let windows = WindowEnumerator.windows(for: app)
        // P1-3: 윈도우가 없으면 기존 패널도 숨김
        guard !windows.isEmpty else {
            previewController?.hide()
            return
        }

        previewController?.show(for: app, windows: windows)
    }
}
