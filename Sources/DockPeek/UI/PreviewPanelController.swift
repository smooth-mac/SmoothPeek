import Cocoa
import SwiftUI

/// Dock 위에 떠 있는 미리보기 패널을 관리하는 컨트롤러
@MainActor
final class PreviewPanelController {
    private var panel: NSPanel?
    private var currentApp: NSRunningApplication?

    // MARK: - Show

    func show(for app: NSRunningApplication, windows: [WindowInfo]) {
        if currentApp?.processIdentifier == app.processIdentifier, panel?.isVisible == true {
            return // 같은 앱 — 패널 유지
        }
        currentApp = app

        let rootView = PreviewPanelView(app: app, windows: windows) { [weak self] window in
            self?.hide()
            WindowActivator.activate(window: window, app: app)
        }

        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }

        let host = NSHostingController(rootView: rootView)
        host.view.frame = CGRect(origin: .zero, size: preferredSize(windowCount: windows.count))

        panel.contentViewController = host
        panel.setContentSize(host.view.frame.size)
        positionPanel(panel, near: app)
        panel.orderFront(nil)
    }

    // MARK: - Hide

    func hide() {
        panel?.orderOut(nil)
        currentApp = nil
    }

    // MARK: - Panel Factory

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .hudWindow, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = false
        return panel
    }

    // MARK: - Layout

    private func preferredSize(windowCount: Int) -> CGSize {
        let thumbWidth: CGFloat = 200
        let thumbHeight: CGFloat = 130
        let padding: CGFloat = 12
        let columns = min(windowCount, 4)
        let rows = Int(ceil(Double(windowCount) / Double(columns)))

        let width = CGFloat(columns) * (thumbWidth + padding) + padding
        let height = CGFloat(rows) * (thumbHeight + padding) + padding + 40 // 앱 이름 헤더

        return CGSize(width: width, height: height)
    }

    // MARK: - Dock Position

    private enum DockEdge {
        case bottom(height: CGFloat)
        case left(width: CGFloat)
        case right(width: CGFloat)
    }

    /// Dock이 위치한 화면을 반환한다.
    ///
    /// Dock은 항상 primary screen(NSScreen.screens.first)에 위치한다.
    /// NSScreen.main은 현재 키 윈도우가 있는 화면으로 보조 모니터일 수 있으므로 사용하지 않는다.
    private func dockScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    /// NSScreen의 visibleFrame 차이를 이용해 Dock 위치와 크기를 계산한다.
    ///
    /// Auto-hide 상태에서는 visibleFrame 차이가 거의 0이 되므로
    /// 최솟값(minDockSize)을 보장해 패널이 Dock 트리거 영역 뒤에 가려지지 않도록 한다.
    private func dockEdge(on screen: NSScreen) -> DockEdge {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let minDockSize: CGFloat = 4 // auto-hide 트리거 영역 여유

        if visible.minX > 4 {
            return .left(width: max(visible.minX, minDockSize))
        } else if frame.maxX - visible.maxX > 4 {
            return .right(width: max(frame.maxX - visible.maxX, minDockSize))
        } else {
            // bottom dock (또는 auto-hide)
            return .bottom(height: max(visible.minY, minDockSize))
        }
    }

    /// 패널을 Dock 위 해당 앱 아이콘 근처에 배치
    private func positionPanel(_ panel: NSPanel, near app: NSRunningApplication) {
        // ISSUE-03 수정: primary screen(Dock이 있는 화면) 기준으로 계산
        guard let screen = dockScreen() else { return }
        let panelSize = panel.frame.size
        let edge = dockEdge(on: screen)
        let iconCenter = findDockIconCenter(for: app)

        let x: CGFloat
        let y: CGFloat

        switch edge {
        case .bottom(let dockHeight):
            let centerX = iconCenter?.x ?? screen.frame.midX
            x = (centerX - panelSize.width / 2)
                .clamped(to: 8...(screen.frame.maxX - panelSize.width - 8))
            y = dockHeight + 8

        case .left(let dockWidth):
            x = dockWidth + 8
            let centerY = iconCenter.map { $0.y - panelSize.height / 2 }
                ?? (screen.frame.midY - panelSize.height / 2)
            y = centerY.clamped(to: 8...(screen.frame.maxY - panelSize.height - 8))

        case .right(let dockWidth):
            x = screen.frame.maxX - dockWidth - panelSize.width - 8
            let centerY = iconCenter.map { $0.y - panelSize.height / 2 }
                ?? (screen.frame.midY - panelSize.height / 2)
            y = centerY.clamped(to: 8...(screen.frame.maxY - panelSize.height - 8))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Dock 아이콘의 화면 중앙 좌표를 AXUIElement로 추출.
    ///
    /// 반환값은 AX 좌표계 그대로이며 `setFrameOrigin`(NS 좌표계)에 직접 사용된다.
    /// AX position은 NS 좌표계와 동일 원점이므로 별도 변환이 불필요하다.
    private func findDockIconCenter(for app: NSRunningApplication) -> CGPoint? {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return nil }

        let bundleID = app.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return nil }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let iconElement = DockAXHelper.dockIconElement(for: bundleID, in: dockElement),
              let frame = DockAXHelper.axFrame(of: iconElement) else { return nil }

        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
