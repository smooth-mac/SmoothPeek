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

private struct AXWindowInfo {
    let frame: CGRect
    let title: String
}

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
        // collectOtherSpaceWindows의 cgWindowMap 구성 및 knownIDs 필터링에 사용한다.
        let allWindowsDict = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID)
            as? [[CFString: Any]] ?? []

        // 온스크린 윈도우 ID 집합 — 중복 제거에 사용
        let onScreenIDs = Set(onScreenWindows.map(\.id))

        // *** 핵심 수정: AX 기반 최소화 창 수집 ***
        //
        // 이전 구현의 문제점:
        // `offScreenCGIDs`에 layer==0이면서 onScreenIDs에 없는 모든 창을 포함시켰으나,
        // 이 범위에는 실제 최소화 창 외에도 다음이 포함된다:
        //   - 숨겨진 앱(Cmd+H)의 창
        //   - 크기가 0인 내부 창
        //   - 시스템 내부 보조 창
        // 이로 인해 "최소화 창"이 아님에도 isMinimized: true로 잘못 분류되는 유령 창이 생성됐다.
        //
        // 수정: AX `kAXMinimizedAttribute == true`를 최소화 판별의 단일 진실 기준으로 사용.
        // CGWindowList ID는 보조 용도(knownIDs 구성, WindowInfo 생성)로만 활용한다.
        //
        // AX로 확인된 최소화 창 ID 집합 (knownIDs 구성 및 other-space 오분류 방지에 사용)
        let axMinimizedIDs: Set<CGWindowID> = collectAXMinimizedIDs(pid: pid)

        var minimizedWindows: [WindowInfo] = []
        if includeMinimized && !axMinimizedIDs.isEmpty {
            // CGWindowList dict를 ID→dict로 인덱싱해 O(1) 조회
            let cgWindowMap: [CGWindowID: [CFString: Any]] = Dictionary(
                uniqueKeysWithValues: allWindowsDict.compactMap { dict -> (CGWindowID, [CFString: Any])? in
                    guard let wid = dict[kCGWindowNumber] as? CGWindowID else { return nil }
                    return (wid, dict)
                }
            )

            for wid in axMinimizedIDs {
                let dict = cgWindowMap[wid]
                let title = dict?[kCGWindowName] as? String ?? app.localizedName ?? "Unknown"
                // 최소화 창은 bounds가 없거나 0이므로 frame은 .zero로 설정 (썸네일 캡처 대상 아님)
                let frame: CGRect
                if let boundsDict = dict?[kCGWindowBounds] as? [String: CGFloat],
                   let w = boundsDict["Width"], let h = boundsDict["Height"], w > 0, h > 0 {
                    frame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0, width: w, height: h)
                } else {
                    frame = .zero
                }
                minimizedWindows.append(WindowInfo(
                    id: wid,
                    title: title,
                    frame: frame,
                    isMinimized: true,
                    isOnAnotherSpace: false,
                    pid: pid
                ))
            }
        }

        // knownIDs: 온스크린 + AX 최소화 창 ID
        // AX 최소화 창을 포함시켜 collectOtherSpaceWindows에서 최소화 창이 other-space로
        // 잘못 분류되지 않도록 한다. (includeMinimized 설정과 무관하게 항상 포함)
        let knownIDs = onScreenIDs.union(axMinimizedIDs)

        // 다른 스페이스 윈도우 수집 (Direct 빌드 전용 — private API 사용)
        let otherSpaceWindows = collectOtherSpaceWindows(
            app: app,
            pid: pid,
            knownIDs: knownIDs,
            allWindowsDict: allWindowsDict,
            primaryScreenHeight: primaryScreenHeight
        )

        // AX API로 창 제목을 보강한다.
        // App Sandbox(MAS) 환경에서 kCGWindowName은 항상 nil → 앱 이름으로 폴백되므로
        // AX kAXTitleAttribute로 실제 제목을 덮어써야 한다.
        // 최소화 창은 AX position이 없어 frame 매칭 불가이므로 enrichTitlesFromAX 내부에서 건너뛴다.
        // 다른 스페이스 창은 makeOtherSpaceWindowInfo에서 이미 AX title을 읽으므로 보강 대상에서 제외한다.
        let enrichedOnScreen = enrichTitlesFromAX(windows: onScreenWindows, pid: pid)
        let enrichedMinimized = enrichTitlesFromMinimizedAX(windows: minimizedWindows, pid: pid)

        let allWindows = enrichedOnScreen + enrichedMinimized + otherSpaceWindows
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

    // MARK: - AX Title Enrichment

    /// CGWindowList에서 얻은 창 목록의 제목을 AX API로 보강한다.
    ///
    /// App Sandbox 환경(MAS 빌드)에서 kCGWindowName은 nil을 반환하므로
    /// 모든 창 제목이 앱 이름으로 폴백된다. AX API는 접근성 권한이 있으면
    /// 실제 창 제목을 반환하므로, frame 기반 매칭으로 각 창의 제목을 교체한다.
    ///
    /// 최소화 창은 AX position이 존재하지 않아 frame 매칭 불가 — 기존 제목 유지.
    private static func enrichTitlesFromAX(windows: [WindowInfo], pid: pid_t) -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return windows }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement], !axWindows.isEmpty else {
            return windows
        }

        // AX 창마다 (frame, title) 추출 — position이 없으면 skip
        let axInfo: [AXWindowInfo] = axWindows.compactMap { axWindow in
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
                  let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }

            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)   // safe: type ID checked
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)  // safe: type ID checked

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            return AXWindowInfo(frame: CGRect(origin: pos, size: size), title: title)
        }

        let tolerance: CGFloat = 4
        var enriched: [WindowInfo] = []
        enriched.reserveCapacity(windows.count)
        for window in windows {
            enriched.append(Self.applyAXTitle(to: window, axInfo: axInfo, tolerance: tolerance))
        }
        return enriched
    }

    /// AX API로 프로세스의 실제 최소화 창 CGWindowID 집합을 반환한다.
    ///
    /// `kAXMinimizedAttribute == true`인 AX 창에서 `_AXUIElementGetWindow`(Direct 빌드) 또는
    /// CGWindowList 역매칭(MAS 빌드)으로 ID를 추출한다.
    ///
    /// AX 권한이 없거나 최소화 창이 없으면 빈 집합을 반환한다.
    private static func collectAXMinimizedIDs(pid: pid_t) -> Set<CGWindowID> {
        guard AXIsProcessTrusted() else { return [] }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return [] }

        var result: Set<CGWindowID> = []
        for axWindow in axWindows {
            // 최소화 여부 확인
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let isMinimized = minimizedRef as? Bool, isMinimized else { continue }

#if MAS_BUILD
            // MAS 빌드: private API 없음 — 제목+순서 기반으로 CGWindowList ID를 역매칭한다.
            // CGWindowList에서 같은 pid의 오프스크린(layer==0) 창 목록과
            // AX 최소화 창 목록을 순서대로 매칭한다.
            // 정확한 1:1 매칭이 보장되지 않으므로 이 경로는 best-effort다.
            // → 실제 ID 대신 AX 창 개수만큼 placeholder를 쌓으면 안 됨.
            // 실제 MAS 환경 최소화 지원은 enrichTitlesFromMinimizedAX 에서 처리.
            break
#else
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &wid) == .success, wid != 0 {
                result.insert(wid)
            }
#endif
        }

#if MAS_BUILD
        // MAS 빌드: CGWindowList에서 pid 소유의 오프스크린(layer==0) 창 중
        // kCGWindowIsOnscreen 키가 없거나 false인 것을 최소화 후보로 간주.
        // onScreenOnly 쿼리 결과와 비교해 실제 오프스크린 여부를 확인한다.
        let onScreenQuery = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        let onScreenSet = Set(onScreenQuery.compactMap { $0[kCGWindowNumber] as? CGWindowID })

        let allQuery = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID)
            as? [[CFString: Any]] ?? []

        // AX 최소화 창 개수만큼 CGWindowList 오프스크린 창과 순서 매칭
        let appElement2 = AXUIElementCreateApplication(pid)
        var windowsRef2: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement2, kAXWindowsAttribute as CFString, &windowsRef2) == .success,
              let axWindows2 = windowsRef2 as? [AXUIElement] else { return result }

        let axMinimizedCount = axWindows2.filter { axWin in
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &ref) == .success,
                  let flag = ref as? Bool else { return false }
            return flag
        }.count

        let candidateIDs = allQuery.compactMap { dict -> CGWindowID? in
            guard let p = dict[kCGWindowOwnerPID] as? pid_t, p == pid,
                  let wid = dict[kCGWindowNumber] as? CGWindowID,
                  let layer = dict[kCGWindowLayer] as? Int, layer == 0,
                  !onScreenSet.contains(wid) else { return nil }
            return wid
        }

        // 순서대로 axMinimizedCount개만 최소화 창으로 분류
        for i in 0..<min(axMinimizedCount, candidateIDs.count) {
            result.insert(candidateIDs[i])
        }
#endif

        return result
    }

    /// 최소화 윈도우의 제목을 AX API로 보강한다.
    ///
    /// 최소화 창은 AX position/size 속성이 없어 frame 매칭이 불가능하다.
    /// 대신 AX `kAXWindowsAttribute` 중 `kAXMinimizedAttribute == true`인 항목의
    /// `kAXTitleAttribute`를 사용하여, CGWindowList의 창 목록과 AX 최소화 창 목록을
    /// 순서 기반으로 1:1 매칭한다.
    ///
    /// 매칭 실패(AX 권한 없음, 목록 불일치 등) 시 원본 WindowInfo를 그대로 반환한다.
    private static func enrichTitlesFromMinimizedAX(windows: [WindowInfo], pid: pid_t) -> [WindowInfo] {
        guard !windows.isEmpty else { return windows }
        guard AXIsProcessTrusted() else { return windows }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement], !axWindows.isEmpty else {
            return windows
        }

        // AX 창 중 최소화된 것만 수집 (순서 유지)
        let axMinimizedTitles: [String] = axWindows.compactMap { axWindow in
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let isMinimized = minimizedRef as? Bool, isMinimized else { return nil }
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            return (titleRef as? String) ?? ""
        }

        // CGWindowList 최소화 창과 AX 최소화 창을 순서대로 1:1 매칭
        return windows.enumerated().map { (index, window) in
            guard index < axMinimizedTitles.count else { return window }
            let axTitle = axMinimizedTitles[index]
            guard !axTitle.isEmpty else { return window }
            return WindowInfo(
                id: window.id,
                title: axTitle,
                frame: window.frame,
                isMinimized: window.isMinimized,
                isOnAnotherSpace: window.isOnAnotherSpace,
                pid: window.pid
            )
        }
    }

    /// AX 창 정보를 사용해 단일 WindowInfo의 제목을 교체한다.
    /// frame 매칭 실패 또는 최소화 창이면 원본을 반환한다.
    private static func applyAXTitle(
        to window: WindowInfo,
        axInfo: [AXWindowInfo],
        tolerance: CGFloat
    ) -> WindowInfo {
        guard !window.isMinimized else { return window }

        var matchedTitle: String?
        for ax in axInfo {
            let dx = abs(ax.frame.origin.x - window.frame.origin.x)
            let dy = abs(ax.frame.origin.y - window.frame.origin.y)
            let dw = abs(ax.frame.size.width - window.frame.size.width)
            let dh = abs(ax.frame.size.height - window.frame.size.height)
            if dx < tolerance && dy < tolerance && dw < tolerance && dh < tolerance {
                matchedTitle = ax.title
                break
            }
        }

        guard let title = matchedTitle, !title.isEmpty else { return window }
        return WindowInfo(
            id: window.id,
            title: title,
            frame: window.frame,
            isMinimized: window.isMinimized,
            isOnAnotherSpace: window.isOnAnotherSpace,
            pid: window.pid
        )
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
