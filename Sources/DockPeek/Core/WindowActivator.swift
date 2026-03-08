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

    /// AXUIElement와 WindowInfo를 frame + title 기반으로 매칭.
    ///
    /// 좌표 변환:
    /// - AX는 NS 좌표계(좌하단 원점, y 위로 증가)
    /// - CGWindowList는 CG 좌표계(좌상단 원점, y 아래로 증가)
    /// - 변환식: cgY = primaryScreenHeight - axY - height
    ///
    /// primaryScreenHeight는 반드시 NSScreen.screens.first를 사용해야 한다.
    /// NSScreen.main은 현재 포커스된 윈도우의 화면으로, 보조 모니터일 경우
    /// 높이가 달라져 Y 변환이 틀리게 된다.
    private static func matchesWindow(_ element: AXUIElement, target: WindowInfo) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return false }

        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &axPos)   // safe: type ID checked
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &axSize)  // safe: type ID checked

        // ISSUE-01 수정: primary screen 기준으로 Y-flip (보조 모니터 윈도우도 정확히 매칭)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgY = primaryHeight - axPos.y - axSize.height
        let axFrame = CGRect(x: axPos.x, y: cgY, width: axSize.width, height: axSize.height)

        let tolerance: CGFloat = 4
        guard abs(axFrame.origin.x - target.frame.origin.x) < tolerance,
              abs(axFrame.origin.y - target.frame.origin.y) < tolerance,
              abs(axFrame.size.width - target.frame.size.width) < tolerance,
              abs(axFrame.size.height - target.frame.size.height) < tolerance else { return false }

        // 동일 크기 윈도우가 여러 개일 때 title로 보조 검증.
        // target.title이 실제 창 제목이 아닌 fallback(앱 이름 등)일 수 있으므로
        // AX title이 available하고 target title이 비어있지 않을 때만 비교한다.
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        if let axTitle = titleRef as? String, !axTitle.isEmpty, !target.title.isEmpty {
            return axTitle == target.title
        }

        return true
    }
}
