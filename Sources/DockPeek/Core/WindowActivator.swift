import Cocoa

/// 특정 윈도우를 최전면으로 가져오는 유틸리티
enum WindowActivator {
    /// 앱을 활성화하고 특정 윈도우를 맨 앞으로 이동.
    /// 최소화 윈도우인 경우 복원 후 활성화한다.
    static func activate(window: WindowInfo, app: NSRunningApplication) {
        if window.isMinimized {
            restoreAndActivate(window: window, app: app)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                raiseWindow(window: window, pid: app.processIdentifier)
            }
        }
    }

    // MARK: - Minimized Window Restoration

    private static func restoreAndActivate(window: WindowInfo, app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            // AX 권한 없이 복원 불가 — 앱만 활성화
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }

        // 최소화 윈도우는 position/size 정보가 없으므로 title로만 매칭한다.
        // 동일 title 윈도우가 여러 개인 경우 첫 번째 최소화 상태 항목을 사용한다.
        for axWindow in axWindows {
            guard isMinimizedAXWindow(axWindow) else { continue }
            guard titleMatches(axWindow, target: window.title) else { continue }

            // kAXMinimizedAttribute = false 로 복원
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)

            // 복원 후 앱 활성화 + raise
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                app.activate(options: [.activateIgnoringOtherApps])
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
            return
        }

        // 매칭 실패 — 앱만 활성화
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func isMinimizedAXWindow(_ element: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
              let value = minimizedRef as? Bool else { return false }
        return value
    }

    private static func titleMatches(_ element: AXUIElement, target: String) -> Bool {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        guard let axTitle = titleRef as? String, !axTitle.isEmpty else {
            // 제목 없는 윈도우는 일단 매칭 허용 (첫 번째 최소화 윈도우가 선택됨)
            return true
        }
        return axTitle == target
    }

    // MARK: - On-Screen Window Raise

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
        //
        // [불변 조건] target.title은 WindowEnumerator에서
        //   kCGWindowName ?? app.localizedName 으로 채워지므로 실질적으로 비어있지 않다.
        //
        // [의도적 skip] axTitle이 비어있는 경우(무제목 창, 일부 유틸리티 패널 등)는
        //   title 비교를 건너뛰고 frame 매칭만으로 true를 반환한다.
        //   이는 무제목 창이 여러 개일 때 첫 번째 AX 순서 창을 선택하는 합리적 fallback이다.
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        if let axTitle = titleRef as? String, !axTitle.isEmpty {
            // target.title은 항상 비어있지 않으므로 axTitle만 검사하면 충분하다.
            return axTitle == target.title
        }

        // axTitle을 읽을 수 없거나 빈 문자열이면 frame 매칭 결과를 그대로 채택한다.
        return true
    }
}
