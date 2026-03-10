import Cocoa

// kAXWindowIdentifierAttribute 조사 결과 (2026-03):
// AXWindowIdentifier(-25205, kAXErrorAttributeUnsupported)로 공개 SDK에서 지원되지 않음.
// _AXUIElementGetWindow Private API 없이 frame + title 비교로 창 매칭을 수행한다.
// 이 방식은 App Store 샌드박스 환경에서도 동작하며 Private API 심사 거부 위험이 없다.

/// 특정 윈도우를 최전면으로 가져오는 유틸리티
enum WindowActivator {
    /// 앱을 활성화하고 특정 윈도우를 맨 앞으로 이동.
    /// 최소화 윈도우인 경우 복원 후 활성화한다.
    static func activate(window: WindowInfo, app: NSRunningApplication) {
        if window.isMinimized {
            restoreAndActivate(window: window, app: app)
        } else {
            raiseWindow(window: window, pid: app.processIdentifier)
            app.activate()
            // Chrome/Electron 앱은 activate() 이후 자체 로직으로 마지막 활성 창을 최전면에 올린다.
            // 80ms 후 재-raise로 덮어쓴다.
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                raiseWindow(window: window, pid: pid)
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
            app.activate()
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
                app.activate()
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
            return
        }

        // 매칭 실패 — 앱만 활성화
        app.activate()
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
                // 앱 엘리먼트의 포커스 윈도우를 명시적으로 지정해
                // activate() 시 이 윈도우가 최전면으로 오도록 한다.
                AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, axWindow)
                break
            }
        }
    }

    /// AXUIElement와 WindowInfo 매칭.
    ///
    /// frame + title 비교 방식 사용.
    /// AX와 CGWindowList 모두 CG 좌표계(좌상단 원점)를 사용하므로 변환 없이 직접 비교한다.
    ///
    /// 동일 title·동일 frame 창(극히 드문 케이스)은 첫 번째 매칭 창을 선택하며,
    /// 이는 Private API 없는 환경에서의 최선이다.
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

        let axFrame = CGRect(x: axPos.x, y: axPos.y, width: axSize.width, height: axSize.height)

        let tolerance: CGFloat = 4
        guard abs(axFrame.origin.x - target.frame.origin.x) < tolerance,
              abs(axFrame.origin.y - target.frame.origin.y) < tolerance,
              abs(axFrame.size.width - target.frame.size.width) < tolerance,
              abs(axFrame.size.height - target.frame.size.height) < tolerance else { return false }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        if let axTitle = titleRef as? String, !axTitle.isEmpty {
            return axTitle == target.title
        }

        return true
    }
}
