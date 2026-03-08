import Cocoa

/// 특정 윈도우를 최전면으로 가져오는 유틸리티
enum WindowActivator {
    /// 앱을 활성화하고 특정 윈도우를 맨 앞으로 이동
    static func activate(window: WindowInfo, app: NSRunningApplication) {
        // 1. 앱 활성화
        app.activate(options: [.activateIgnoringOtherApps])

        // 2. AXUIElement로 특정 윈도우 포커스
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            raiseWindow(windowID: window.id, pid: app.processIdentifier)
        }
    }

    private static func raiseWindow(windowID: CGWindowID, pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for axWindow in windows {
            var idValue: CGWindowID = 0
            // _AXUIElementGetWindow은 private API — 대신 위치/크기로 매칭
            // TODO: CGWindowID ↔ AXUIElement 매핑을 위해 private API(_AXUIElementGetWindow) 또는
            //       pid + 순서 기반 매핑 방식 검토 필요
            if matchesWindowID(axWindow, targetID: windowID) {
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, true as CFTypeRef)

                // Raise action
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                break
            }
        }

        _ = idValue // suppress warning
    }

    /// AXUIElement와 CGWindowID 매칭 (private API 없이)
    /// 실제 구현 시 _AXUIElementGetWindow 또는 frame 기반 매칭 사용
    private static func matchesWindowID(_ element: AXUIElement, targetID: CGWindowID) -> Bool {
        // TODO: 신뢰도 높은 매핑 구현
        // Option A: dlsym으로 _AXUIElementGetWindow 심볼 로드 (private)
        // Option B: 윈도우 frame으로 근사 매칭
        return false
    }
}
