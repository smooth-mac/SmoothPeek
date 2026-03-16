import Cocoa

// 창 매칭 전략:
//
// Direct 배포 빌드 (기본, MAS_BUILD 미정의):
//   1순위: _AXUIElementGetWindow (CGWindowID 직접 매칭) — Chrome/Electron 멀티 윈도우 정확
//   2순위: frame + title fallback
//
// App Store 빌드 (-DMAS_BUILD 플래그):
//   1순위: frame + title 비교 (Private API 없음, App Store 심사 통과)
//   Chrome 멀티 윈도우 동일 크기인 경우 오매칭 가능성 있음 (MAS 환경의 트레이드오프)
//
// kAXWindowIdentifierAttribute 조사 결과 (2026-03):
//   -25205 (kAXErrorAttributeUnsupported) — 공개 SDK에서 지원되지 않음.

#if !MAS_BUILD
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
#endif

/// 특정 윈도우를 최전면으로 가져오는 유틸리티
enum WindowActivator {
    /// 앱을 활성화하고 특정 윈도우를 맨 앞으로 이동.
    ///
    /// - 최소화 윈도우: AX로 복원 후 활성화
    /// - 다른 스페이스 윈도우: raise → activate 순서로 호출하면 macOS가 해당 스페이스로 자동 전환
    /// - 일반 온스크린 윈도우: raise + activate + 80ms 재-raise(Chrome/Electron 대응)
    static func activate(window: WindowInfo, app: NSRunningApplication) {
        if window.isMinimized {
            restoreAndActivate(window: window, app: app)
        } else if window.isOnAnotherSpace {
            // 다른 스페이스 윈도우: kAXRaiseAction을 먼저 호출해 macOS에게 스페이스 전환을 유도하고
            // activate()로 앱을 포커스한다.
            raiseWindow(window: window, pid: app.processIdentifier)
            app.activate()
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
        let axTitle = (titleRef as? String) ?? ""

        // 양쪽 모두 제목이 있으면 정확히 비교한다.
        if !axTitle.isEmpty && !target.isEmpty {
            return axTitle == target
        }
        // 한쪽이라도 제목이 없으면 매칭 허용 — 첫 번째 최소화 창이 선택된다.
        return true
    }

    // MARK: - On-Screen Window Raise

    private static func raiseWindow(window: WindowInfo, pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        guard let axWindow = findAXWindow(in: axWindows, matching: window) else { return }
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, axWindow)
    }

    /// AXUIElement 배열에서 WindowInfo에 대응하는 항목을 찾는다.
    ///
    /// Direct 빌드: CGWindowID 직접 매칭 (1순위) → frame+title fallback (2순위)
    /// MAS 빌드: frame+title 매칭만 사용
    private static func findAXWindow(in axWindows: [AXUIElement], matching window: WindowInfo) -> AXUIElement? {
#if !MAS_BUILD
        // 1순위: CGWindowID 직접 매칭 — Chrome/Electron 동일 크기 창도 정확히 구분
        for axWindow in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &wid) == .success, wid == window.id {
                return axWindow
            }
        }
#endif
        // 2순위(Direct) / 1순위(MAS): frame + title 매칭
        return axWindows.first { matchesWindow($0, target: window) }
    }

    /// AXUIElement와 WindowInfo 매칭.
    ///
    /// frame + title 비교 방식 사용.
    /// AX position은 NS 좌표계(좌하단 원점), WindowInfo.frame은 CG 좌표계(좌상단 원점)이므로
    /// DockAXHelper.axFrameInCGCoordinates(of:)로 AX frame을 CG 좌표계로 변환한 뒤 비교한다.
    ///
    /// 동일 title·동일 frame 창(극히 드문 케이스)은 첫 번째 매칭 창을 선택하며,
    /// 이는 Private API 없는 환경에서의 최선이다.
    private static func matchesWindow(_ element: AXUIElement, target: WindowInfo) -> Bool {
        guard let axFrame = DockAXHelper.axFrameInCGCoordinates(of: element) else { return false }

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
