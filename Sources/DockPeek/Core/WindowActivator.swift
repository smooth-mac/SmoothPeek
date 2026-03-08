import Cocoa

/// 특정 윈도우를 최전면으로 가져오는 유틸리티
enum WindowActivator {
    /// 앱을 활성화하고 특정 윈도우를 맨 앞으로 이동
    static func activate(window: WindowInfo, app: NSRunningApplication) {
        app.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            raiseWindow(window: window, pid: app.processIdentifier)
        }
    }

    private static func raiseWindow(window: WindowInfo, pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        for axWindow in axWindows {
            if matchesWindow(axWindow, target: window) {
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                break
            }
        }
    }

    /// AXUIElement와 WindowInfo를 frame + title 기반으로 매칭
    ///
    /// AXUIElement는 NS 좌표계(좌하단 원점), CGWindowList는 CG 좌표계(좌상단 원점)이므로
    /// 비교 전 좌표 변환을 수행한다.
    private static func matchesWindow(_ element: AXUIElement, target: WindowInfo) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else { return false }

        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)

        // AX 좌표(NS, 좌하단 원점) → CG 좌표(좌상단 원점) 변환
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cgY = screenHeight - axPos.y - axSize.height
        let axFrame = CGRect(x: axPos.x, y: cgY, width: axSize.width, height: axSize.height)

        let tolerance: CGFloat = 4
        guard abs(axFrame.origin.x - target.frame.origin.x) < tolerance,
              abs(axFrame.origin.y - target.frame.origin.y) < tolerance,
              abs(axFrame.size.width - target.frame.size.width) < tolerance,
              abs(axFrame.size.height - target.frame.size.height) < tolerance else { return false }

        // 동일한 크기의 윈도우가 여러 개일 때 title로 보조 검증
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        if let axTitle = titleRef as? String, !axTitle.isEmpty, !target.title.isEmpty {
            return axTitle == target.title
        }

        return true
    }
}
