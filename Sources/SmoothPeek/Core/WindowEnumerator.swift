import Cocoa

/// 특정 앱의 윈도우 목록을 가져오는 유틸리티
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    /// 다른 Mission Control 스페이스에 있는 윈도우.
    /// true이면 현재 스페이스에 표시되지 않으며 썸네일 카드에 배지로 표시된다.
    let isOnAnotherSpace: Bool
    let pid: pid_t
}

#if !MAS_BUILD
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
#endif

enum WindowEnumerator {
    /// 앱의 윈도우 목록을 반환한다.
    ///
    /// 수집 우선순위:
    /// 1. 현재 스페이스의 온스크린 윈도우 (`isMinimized: false`, `isOnAnotherSpace: false`)
    /// 2. `showMinimizedWindows` 설정이 true이면 최소화 윈도우 포함 (`isMinimized: true`)
    /// 3. Direct 빌드에서만: 다른 스페이스의 윈도우 (`isOnAnotherSpace: true`)
    ///    AX kAXWindowsAttribute로 모든 AX 윈도우를 열거하고 _AXUIElementGetWindow(private API)로
    ///    CGWindowID를 추출한 뒤, CGWindowList에 없는(오프스크린·비최소화) ID를 다른 스페이스로 분류한다.
    ///
    /// 반환 목록은 CGWindowID 오름차순(창 생성 순서)으로 정렬된다.
    ///
    /// CGWindowList 쿼리와 AX 쿼리를 `Task.detached`(userInitiated)로 메인 스레드 밖에서 실행한다.
    /// `DockAXHelper.axFrameInCGCoordinates`가 `NSScreen.screens`를 참조하므로
    /// primary screen 높이를 메인 스레드에서 미리 캡처하여 detached task에 값으로 전달한다.
    @MainActor
    static func windows(for app: NSRunningApplication) async -> [WindowInfo] {
        // NSScreen은 메인 스레드 전용 — detached task 진입 전에 캡처한다.
        let primaryScreenHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?
            .frame.height
            ?? NSScreen.main?.frame.height
            ?? 0

        return await Task.detached(priority: .userInitiated) {
            WindowEnumerator.collectWindows(
                for: app,
                primaryScreenHeight: primaryScreenHeight
            )
        }.value
    }

    // MARK: - 동기 수집 (Task.detached 내부 전용)

    /// 실제 윈도우 수집 로직. `Task.detached` 클로저에서만 호출된다.
    ///
    /// - Parameters:
    ///   - app: 대상 앱
    ///   - primaryScreenHeight: 좌표 변환에 사용할 primary screen 높이 (메인 스레드에서 미리 캡처)
    private static func collectWindows(
        for app: NSRunningApplication,
        primaryScreenHeight: CGFloat
    ) -> [WindowInfo] {
        let pid = app.processIdentifier

        let onScreenWindows = collectVisibleWindows(pid: pid, app: app)

        // showMinimizedWindows 설정을 UserDefaults에서 직접 읽어 @MainActor 경계를 넘지 않는다.
        // AppSettings.Keys.showMinimizedWindows 상수를 사용하여 키 일관성을 유지한다.
        let includeMinimized = UserDefaults.standard.object(forKey: AppSettings.Keys.showMinimizedWindows)
            .flatMap { $0 as? Bool }
            ?? AppSettings.Defaults.showMinimizedWindows

        // `.excludeDesktopElements` 단독 쿼리: 온스크린 + 오프스크린을 모두 가져온다.
        // kCGWindowIsOnscreen == false인 항목은 최소화 윈도우 또는 다른 스페이스 윈도우이다.
        let allWindowsDict = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID)
            as? [[CFString: Any]] ?? []

        // 온스크린 윈도우 ID 집합 — 중복 제거에 사용
        let onScreenIDs = Set(onScreenWindows.map(\.id))

        var minimizedWindows: [WindowInfo] = []
        if includeMinimized {
            // CGWindowList에 kCGWindowIsOnscreen == false로 노출되는 윈도우 중
            // 현재 스페이스의 온스크린 윈도우가 아닌 것을 최소화 후보로 수집한다.
            // (다른 스페이스 윈도우는 CGWindowList에 노출되지 않으므로 여기서는 최소화 윈도우만 해당)
            let offScreenCGIDs: Set<CGWindowID> = Set(
                allWindowsDict.compactMap { dict -> CGWindowID? in
                    guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                          windowPID == pid,
                          let windowID = dict[kCGWindowNumber] as? CGWindowID,
                          let layer = dict[kCGWindowLayer] as? Int,
                          layer == 0,
                          let isOnScreen = dict[kCGWindowIsOnscreen] as? Bool,
                          !isOnScreen
                    else { return nil }
                    return windowID
                }
            )

            minimizedWindows = allWindowsDict.compactMap { dict -> WindowInfo? in
                guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                      windowPID == pid,
                      let windowID = dict[kCGWindowNumber] as? CGWindowID,
                      offScreenCGIDs.contains(windowID),
                      !onScreenIDs.contains(windowID)
                else { return nil }

                return makeWindowInfo(from: dict, id: windowID, app: app, pid: pid,
                                      isMinimized: true, isOnAnotherSpace: false)
            }
        }

        // 다른 스페이스 윈도우 수집 (Direct 빌드 전용 — private API 사용)
        let otherSpaceWindows = collectOtherSpaceWindows(
            app: app,
            pid: pid,
            knownIDs: onScreenIDs.union(Set(minimizedWindows.map(\.id))),
            allWindowsDict: allWindowsDict,
            primaryScreenHeight: primaryScreenHeight
        )

        let allWindows = onScreenWindows + minimizedWindows + otherSpaceWindows
        return allWindows.sorted { $0.id < $1.id }
    }

    // MARK: - 다른 스페이스 윈도우 수집

    /// 현재 스페이스에 없는(다른 Mission Control 스페이스의) 윈도우를 수집.
    ///
    /// AX kAXWindowsAttribute로 앱의 모든 AX 윈도우를 열거하고,
    /// `_AXUIElementGetWindow`(private API)로 CGWindowID를 추출한 뒤
    /// 이미 알려진 ID(`knownIDs`)에 없는 것을 다른 스페이스 윈도우로 분류한다.
    ///
    /// MAS 빌드에서는 private API 사용 불가로 항상 빈 배열을 반환한다.
    private static func collectOtherSpaceWindows(
        app: NSRunningApplication,
        pid: pid_t,
        knownIDs: Set<CGWindowID>,
        allWindowsDict: [[CFString: Any]],
        primaryScreenHeight: CGFloat
    ) -> [WindowInfo] {
#if MAS_BUILD
        return []
#else
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return [] }

        // CGWindowList 전체 딕셔너리를 ID → dict 맵으로 인덱싱 (프레임·타이틀 조회 성능)
        let cgWindowMap: [CGWindowID: [CFString: Any]] = Dictionary(
            uniqueKeysWithValues: allWindowsDict.compactMap { dict -> (CGWindowID, [CFString: Any])? in
                guard let wid = dict[kCGWindowNumber] as? CGWindowID else { return nil }
                return (wid, dict)
            }
        )

        var result: [WindowInfo] = []
        for axWindow in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &wid) == .success else { continue }
            // 이미 온스크린 또는 최소화 윈도우로 수집된 ID는 건너뜀
            guard !knownIDs.contains(wid) else { continue }
            // 최소화 여부를 AX로 확인 — 최소화 윈도우는 collectOtherSpaceWindows에서 제외
            // (최소화는 별도 경로로 처리되므로)
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let isMinimized = minimizedRef as? Bool, isMinimized {
                continue
            }

            let info = makeOtherSpaceWindowInfo(
                axWindow: axWindow,
                windowID: wid,
                app: app,
                pid: pid,
                cgWindowDict: cgWindowMap[wid],
                primaryScreenHeight: primaryScreenHeight
            )
            result.append(info)
        }
        return result
#endif
    }

    // MARK: - Private Helpers

    /// 온스크린 윈도우만 수집하는 헬퍼 (Pass 1 전용).
    private static func collectVisibleWindows(
        pid: pid_t,
        app: NSRunningApplication
    ) -> [WindowInfo] {
        let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []

        return infoList.compactMap { dict -> WindowInfo? in
            guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                  windowPID == pid,
                  let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let layer = dict[kCGWindowLayer] as? Int,
                  layer == 0
            else { return nil }

            return makeWindowInfo(from: dict, id: windowID, app: app, pid: pid,
                                  isMinimized: false, isOnAnotherSpace: false)
        }
    }

    private static func makeWindowInfo(
        from dict: [CFString: Any],
        id: CGWindowID,
        app: NSRunningApplication,
        pid: pid_t,
        isMinimized: Bool,
        isOnAnotherSpace: Bool
    ) -> WindowInfo {
        let title = dict[kCGWindowName] as? String ?? app.localizedName ?? "Unknown"
        let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat] ?? [:]
        let frame = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        return WindowInfo(
            id: id,
            title: title,
            frame: frame,
            isMinimized: isMinimized,
            isOnAnotherSpace: isOnAnotherSpace,
            pid: pid
        )
    }

    /// 다른 스페이스 윈도우의 WindowInfo를 AX 속성에서 생성.
    ///
    /// CGWindowList에 노출되지 않으므로 타이틀·프레임을 AX API에서 직접 읽는다.
    /// AX position은 NS 좌표계이므로 `primaryScreenHeight`를 이용해 CG 좌표계로 변환한다.
    /// `NSScreen.screens`는 메인 스레드 전용이므로 호출자가 미리 캡처한 높이를 파라미터로 받는다.
    private static func makeOtherSpaceWindowInfo(
        axWindow: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        pid: pid_t,
        cgWindowDict: [CFString: Any]?,
        primaryScreenHeight: CGFloat
    ) -> WindowInfo {
        // 타이틀: CGWindowList dict 우선, 없으면 AX kAXTitleAttribute
        let title: String
        if let cgTitle = cgWindowDict?[kCGWindowName] as? String, !cgTitle.isEmpty {
            title = cgTitle
        } else {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            title = (titleRef as? String) ?? app.localizedName ?? "Unknown"
        }

        // 프레임: AX position(NS 좌표) → CG 좌표 변환
        // DockAXHelper.axFrameInCGCoordinates는 NSScreen을 참조하므로 직접 인라인 변환한다.
        let frame: CGRect
        if let nsFrame = DockAXHelper.axFrame(of: axWindow) {
            // NS → CG: cgY = screenHeight - nsY - frameHeight
            let cgY = primaryScreenHeight - nsFrame.origin.y - nsFrame.size.height
            frame = CGRect(x: nsFrame.origin.x, y: cgY,
                           width: nsFrame.size.width, height: nsFrame.size.height)
        } else if let boundsDict = cgWindowDict?[kCGWindowBounds] as? [String: CGFloat] {
            frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
        } else {
            frame = .zero
        }

        return WindowInfo(
            id: windowID,
            title: title,
            frame: frame,
            isMinimized: false,
            isOnAnotherSpace: true,
            pid: pid
        )
    }
}
