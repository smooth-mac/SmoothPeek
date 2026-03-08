import Cocoa

/// 특정 앱의 윈도우 목록을 가져오는 유틸리티
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let pid: pid_t
}

enum WindowEnumerator {
    /// 앱의 가시적인 윈도우 목록을 반환
    static func windows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] ?? []

        return infoList.compactMap { dict -> WindowInfo? in
            guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                  windowPID == pid,
                  let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let layer = dict[kCGWindowLayer] as? Int,
                  layer == 0 // 일반 앱 레이어만
            else { return nil }

            let title = dict[kCGWindowName] as? String ?? app.localizedName ?? "Unknown"
            let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat] ?? [:]
            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            return WindowInfo(
                id: windowID,
                title: title,
                frame: frame,
                isOnScreen: true,
                pid: pid
            )
        }
    }
}
