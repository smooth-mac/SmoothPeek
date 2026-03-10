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
        return (onScreenWindows + deduplicatedMinimized).sorted { $0.id < $1.id }
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
