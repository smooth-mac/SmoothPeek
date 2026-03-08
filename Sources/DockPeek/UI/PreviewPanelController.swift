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

    /// NSScreen의 visibleFrame 차이를 이용해 Dock 위치와 크기를 계산한다.
    private func dockEdge(on screen: NSScreen) -> DockEdge {
        let frame = screen.frame
        let visible = screen.visibleFrame

        if visible.minX > 4 {
            return .left(width: visible.minX)
        } else if frame.maxX - visible.maxX > 4 {
            return .right(width: frame.maxX - visible.maxX)
        } else {
            return .bottom(height: visible.minY)
        }
    }

    /// 패널을 Dock 위 해당 앱 아이콘 근처에 배치
    private func positionPanel(_ panel: NSPanel, near app: NSRunningApplication) {
        guard let screen = NSScreen.main else { return }
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

    /// Dock 아이콘의 화면 중앙 좌표를 AXUIElement로 추출 (NS 좌표계)
    private func findDockIconCenter(for app: NSRunningApplication) -> CGPoint? {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return nil }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == kAXListRole as String else { continue }

            var itemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                  let items = itemsRef as? [AXUIElement] else { continue }

            for item in items {
                var urlRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef)
                guard let urlStr = urlRef as? String,
                      let url = URL(string: urlStr),
                      Bundle(url: url)?.bundleIdentifier == app.bundleIdentifier else { continue }

                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef) == .success,
                      AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef) == .success else { continue }

                var pos = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

                return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            }
        }
        return nil
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
