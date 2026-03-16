import Cocoa

/// 특정 앱의 윈도우 목록을 가져오는 유틸리티
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let pid: pid_t
}

enum WindowEnumerator {
    /// 앱의 윈도우 목록을 반환한다 (화면에 표시된 윈도우 + 최소화 윈도우 포함).
    ///
    /// - 화면에 표시된 윈도우: `.optionOnScreenOnly` + `.excludeDesktopElements` 쿼리로 수집
    /// - 최소화 윈도우: `.excludeDesktopElements` 단독 쿼리에서 `kCGWindowIsOnscreen == false` 인 항목으로 수집
    /// - 두 결과를 합산해 중복 ID를 제거한 뒤 반환한다.
    static func windows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier

        let onScreenWindows = collectWindows(
            pid: pid,
            app: app,
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            isMinimized: false
        )

        // `.excludeDesktopElements` 단독 쿼리: 온스크린 + 오프스크린을 모두 가져온다.
        // 여기서 kCGWindowIsOnscreen == false인 항목만 최소화 윈도우로 취급한다.
        // 다른 Space의 윈도우도 isOnscreen == false로 올 수 있으나,
        // 현재 macOS는 CGWindowList에서 다른 Space 윈도우를 기본 제공하지 않으므로
        // 추가적인 Space 필터는 P2-2에서 별도 처리한다.
        let allWindowsDict = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID)
            as? [[CFString: Any]] ?? []

        let minimizedWindows = allWindowsDict.compactMap { dict -> WindowInfo? in
            guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                  windowPID == pid,
                  let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let layer = dict[kCGWindowLayer] as? Int,
                  layer == 0,
                  let isOnScreen = dict[kCGWindowIsOnscreen] as? Bool,
                  !isOnScreen
            else { return nil }

            return makeWindowInfo(from: dict, id: windowID, app: app, pid: pid, isMinimized: true)
        }

        // 온스크린 윈도우 ID 집합으로 중복 제거
        let onScreenIDs = Set(onScreenWindows.map(\.id))
        let deduplicatedMinimized = minimizedWindows.filter { !onScreenIDs.contains($0.id) }

        // CGWindowID는 창 생성 순서대로 할당된다.
        // z-order 대신 생성 순서(오름차순)로 정렬해 클릭 후에도 창 위치가 바뀌지 않도록 한다.
        let sorted = (onScreenWindows + deduplicatedMinimized).sorted { $0.id < $1.id }

        // App Sandbox에서 kCGWindowName이 nil을 반환하므로 AX API로 실제 창 제목을 보강한다.
        return enrichTitlesFromAX(windows: sorted, pid: pid)
    }

    // MARK: - Private Helpers

    private static func collectWindows(
        pid: pid_t,
        app: NSRunningApplication,
        options: CGWindowListOption,
        isMinimized: Bool
    ) -> [WindowInfo] {
        let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] ?? []

        return infoList.compactMap { dict -> WindowInfo? in
            guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                  windowPID == pid,
                  let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let layer = dict[kCGWindowLayer] as? Int,
                  layer == 0
            else { return nil }

            return makeWindowInfo(from: dict, id: windowID, app: app, pid: pid, isMinimized: isMinimized)
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
        struct AXWindowInfo { let frame: CGRect; let title: String }
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
        return windows.map { window in
            // 최소화 창은 AX frame이 없으므로 frame 매칭 불가
            guard !window.isMinimized else { return window }

            guard let match = axInfo.first(where: { ax in
                abs(ax.frame.origin.x - window.frame.origin.x) < tolerance &&
                abs(ax.frame.origin.y - window.frame.origin.y) < tolerance &&
                abs(ax.frame.size.width  - window.frame.size.width)  < tolerance &&
                abs(ax.frame.size.height - window.frame.size.height) < tolerance
            }), !match.title.isEmpty else { return window }

            return WindowInfo(
                id: window.id,
                title: match.title,
                frame: window.frame,
                isMinimized: window.isMinimized,
                pid: window.pid
            )
        }
    }

    private static func makeWindowInfo(
        from dict: [CFString: Any],
        id: CGWindowID,
        app: NSRunningApplication,
        pid: pid_t,
        isMinimized: Bool
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
            pid: pid
        )
    }
}
