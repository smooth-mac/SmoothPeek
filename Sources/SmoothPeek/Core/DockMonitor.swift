import Cocoa
import ApplicationServices

/// Dock 위의 마우스 움직임을 감지하여 호버 중인 앱을 알려주는 클래스.
///
/// 동작 원리:
/// 1. NSEvent.addGlobalMonitorForEvents(.mouseMoved)으로 전역 마우스 이벤트 수신
///    (App Store 샌드박스 호환; Input Monitoring 권한 불필요)
/// 2. 마우스가 Dock 영역에 들어오면 AXUIElement로 Dock 아이콘 목록을 탐색
/// 3. 아이콘의 AXFrame과 마우스 위치를 비교해 호버 중인 앱 식별
///
/// ## 좌표계 변환
/// NSEvent.mouseLocation은 NS 좌표계(좌하단 원점, y 위로 증가)를 반환한다.
/// DockAXHelper.axFrame 및 isMouseOverPanel 콜백은 CG 좌표계(좌상단 원점, y 아래로 증가)를
/// 기대하므로, primaryScreenHeight - nsY 변환을 통해 CG 좌표로 통일한다.
@MainActor
final class DockMonitor {
    var onAppHovered: ((String?, NSRunningApplication?) -> Void)?
    var onHoverEnded: (() -> Void)?
    var onPermissionError: (() -> Void)?
    /// 마우스 포인터(CG 좌표)가 미리보기 패널 위에 있으면 true를 반환하는 콜백.
    /// 패널 위에 있는 동안은 hoverEnd 타이머를 시작하지 않는다.
    var isMouseOverPanel: ((CGPoint) -> Bool)?

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    private var dockPID: pid_t?
    private var dockAXElement: AXUIElement?

    private var lastHoveredBundleID: String?
    private var hoverTimer: Timer?
    // 마우스가 미리보기 패널 위에 있는 동안 true.
    // Dock → 패널 이동 중 lastHoveredBundleID 가 nil 로 초기화된 뒤에도
    // 패널 밖으로 나가면 hide 가 정상 스케줄되도록 보조 플래그로 사용한다.
    private var isHoveringPanel = false

    // MARK: - Lifecycle

    func start() {
        findDock()
        setupMouseMonitor()
    }

    func stop() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    // MARK: - Dock 찾기

    private func findDock() {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else {
            print("[DockMonitor] Dock 프로세스를 찾을 수 없습니다.")
            return
        }
        dockPID = dock.processIdentifier
        dockAXElement = AXUIElementCreateApplication(dock.processIdentifier)
    }

    // MARK: - NSEvent 전역 모니터 설정
    //
    // NSEvent.addGlobalMonitorForEvents는 App Store 샌드박스에서 허용된다.
    // CGEventTap (.cghidEventTap)은 Input Monitoring 권한을 요구하며 샌드박스와 충돌한다.

    private func setupMouseMonitor() {
        // AXUIElement 접근 가능 여부 확인 — 불가 시 권한 오류 콜백 발생
        guard AXIsProcessTrusted() else {
            print("[DockMonitor] 접근성 권한 없음 — AX 기반 Dock 호버 감지 불가.")
            onPermissionError?()
            return
        }

        // 글로벌 모니터: 다른 앱(Dock 포함) 위에서의 마우스 이동 감지
        // NSEvent.mouseLocation을 항상 사용한다.
        // (event.locationInWindow은 이벤트 수신 앱 창의 로컬 좌표이므로 화면 좌표가 아님)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved(Self.nsToCG(NSEvent.mouseLocation))
        }

        // 로컬 모니터: SmoothPeek 자신의 패널 위에서의 마우스 이동 감지
        // addGlobalMonitorForEvents는 자신의 앱 창에서 발생한 이벤트를 수신하지 않으므로
        // 패널 위에서도 handleMouseMoved가 호출되어 isMouseOverPanel 체크가 이루어진다.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(Self.nsToCG(NSEvent.mouseLocation))
            return event
        }

        if mouseMonitor == nil {
            print("[DockMonitor] NSEvent 전역 모니터 등록 실패 — 접근성 권한을 확인하세요.")
            onPermissionError?()
        }
    }

    // MARK: - 좌표 변환

    /// NS 좌표계(좌하단 원점) → CG 좌표계(좌상단 원점) 변환.
    ///
    /// primary screen(NSScreen.screens.first, origin == .zero)의 높이를 기준으로 사용한다.
    /// 보조 모니터의 좌표는 primary screen 높이 기준 상대값으로 처리된다.
    private static func nsToCG(_ nsPoint: NSPoint) -> CGPoint {
        let screenHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                        ?? NSScreen.main?.frame.height ?? 0
        return CGPoint(x: nsPoint.x, y: screenHeight - nsPoint.y)
    }

    // MARK: - 마우스 이벤트 처리

    private func handleMouseMoved(_ point: CGPoint) {
        // point는 CG 좌표계(좌상단 원점).
        // DockAXHelper.axFrame(of:)도 CG 좌표계와 동일하게 동작하므로 직접 비교한다.
        guard let hoveredApp = findHoveredDockApp(at: point) else {
            if isMouseOverPanel?(point) == true {
                // 패널 위에 있는 동안은 진행 중인 hide 타이머를 취소한다.
                isHoveringPanel = true
                cancelHoverTimer()
                return
            }
            scheduleHoverEnd()
            return
        }
        isHoveringPanel = false

        let bundleID = hoveredApp.bundleIdentifier ?? ""
        if bundleID == lastHoveredBundleID { return }

        cancelHoverTimer()
        lastHoveredBundleID = bundleID

        // AppSettings.shared는 @MainActor 격리이므로 동일 UserDefaults 키를 통해 값을 읽는다.
        let delay = UserDefaults.standard.double(forKey: AppSettings.Keys.hoverDelay)
        let hoverDelay = delay > 0 ? delay : AppSettings.Defaults.hoverDelay
        // Timer는 main RunLoop에서 실행되므로 MainActor.assumeIsolated로 격리 보장
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onAppHovered?(bundleID, hoveredApp) }
        }
    }

    private func scheduleHoverEnd() {
        guard lastHoveredBundleID != nil || isHoveringPanel else { return }
        isHoveringPanel = false
        cancelHoverTimer()
        lastHoveredBundleID = nil

        // 약간의 딜레이 후 패널 숨김 (빠른 이동 시 깜빡임 방지)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onHoverEnded?() }
        }
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// 창 클릭 등으로 미리보기가 닫힌 후, 같은 앱 아이콘 위에 마우스가 그대로 있어도
    /// 다음 hover 이벤트에서 패널이 다시 표시되도록 상태를 초기화한다.
    func resetLastHovered() {
        cancelHoverTimer()
        lastHoveredBundleID = nil
    }

    // MARK: - Dock 아이콘 탐색

    /// Dock의 AXUIElement를 탐색해 마우스 위치에 해당하는 앱을 반환
    /// - Parameter point: CG 좌표계(좌상단 원점)의 마우스 위치
    private func findHoveredDockApp(at point: CGPoint) -> NSRunningApplication? {
        guard let dockElement = dockAXElement else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == kAXListRole as String else { continue }

            var itemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                  let items = itemsRef as? [AXUIElement] else { continue }

            for item in items {
                guard let frame = DockAXHelper.axFrame(of: item),
                      frame.contains(point) else { continue }

                return runningApp(for: item)
            }
        }
        return nil
    }

    /// AXUIElement의 URL 속성에서 번들 ID를 추출해 실행 중인 앱 반환.
    private func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        guard let bundleID = DockAXHelper.bundleID(of: item) else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
    }
}
