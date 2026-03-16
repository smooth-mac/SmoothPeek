import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var dockMonitor: DockMonitor?
    private var previewController: PreviewPanelController?

    /// 환경설정 윈도우 — 단일 인스턴스를 유지해 재클릭 시 기존 윈도우를 활성화한다.
    private var settingsWindow: NSWindow?

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
            // Assets.xcassets의 StatusBarIcon 이미지셋을 로드한다.
            // PNG 빌드 전(SVG만 있는 경우) SF Symbol로 폴백한다.
            if let icon = NSImage(named: "StatusBarIcon") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                       accessibilityDescription: "SmoothPeek")
            }
            button.action = #selector(statusBarClicked)
            button.target = self
        }
    }

    @objc private func statusBarClicked() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "SmoothPeek 실행 중", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "환경설정...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettings() {
        // 기존 윈도우가 살아 있으면 앞으로 가져온다.
        // 최소화 상태인 경우 isVisible == false 이므로 isMiniaturized도 별도로 확인한다.
        if let existing = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = makeSettingsWindow()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings Window Factory

    private func makeSettingsWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "SmoothPeek 환경설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // SwiftUI가 높이를 lazily 계산하므로 창 크기를 명시적으로 설정해
        // 첫 오픈 시 창이 너무 작게 열리는 문제를 방지한다.
        let fittingSize = host.sizeThatFits(in: CGSize(width: 420, height: 10_000))
        window.setContentSize(CGSize(width: 420, height: max(fittingSize.height, 360)))
        window.center()
        return window
    }

    // MARK: - Permissions

    private func checkPermissions() {
        // 이미 신뢰된 경우 팝업 없이 즉시 반환
        guard !AXIsProcessTrusted() else { return }

        // 신뢰되지 않은 경우에만 시스템 TCC 팝업 표시 (prompt: true)
        // 팝업은 사용자가 시스템 설정에서 직접 허용할 수 있도록 안내한다.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        // 화면 녹화 권한은 ScreenCaptureKit 첫 사용 시 자동 요청됨
    }

    // 접근성 권한 오류 시 사용자에게 안내
    private func showPermissionAlert() {
        // 상태바 아이콘을 경고 아이콘으로 변경 — runModal() 이전에 수행해야
        // 모달이 떠 있는 동안에도 아이콘이 오류 상태를 반영한다.
        statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "SmoothPeek — 권한 필요")
        statusItem?.button?.toolTip = "SmoothPeek: 접근성 권한이 필요합니다"

        let alert = NSAlert()
        alert.messageText = "접근성 권한이 필요합니다"
        alert.informativeText = "SmoothPeek가 Dock 아이콘 감지 및 창 활성화 기능을 사용하려면 접근성 권한이 필요합니다.\n\n시스템 설정 → 개인 정보 보호 및 보안 → 손쉬운 사용에서 SmoothPeek를 허용한 후 앱을 재시작해 주세요."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "나중에")

        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
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
            Task { @MainActor in
                self?.showPermissionAlert()
                // 권한이 허용될 때까지 1초마다 재시도
                self?.waitForAccessibilityPermission()
            }
        }
        previewController?.onWindowSelected = { [weak self] in
            self?.dockMonitor?.resetLastHovered()
        }
        dockMonitor?.isMouseOverPanel = { [weak self] point in
            self?.previewController?.containsMouse(at: point) ?? false
        }
        dockMonitor?.start()
    }

    /// 접근성 권한이 허용될 때까지 1초마다 폴링하다가 허용되면 모니터를 자동 재시작.
    /// 사용자가 시스템 설정에서 토글을 켠 직후 앱 재시작 없이 동작하게 한다.
    @MainActor
    private func waitForAccessibilityPermission() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self.dockMonitor?.stop()
            self.dockMonitor?.start()
        }
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
