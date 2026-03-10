import Cocoa
import ApplicationServices

/// Dock 위의 마우스 움직임을 감지하여 호버 중인 앱을 알려주는 클래스.
///
/// 동작 원리:
/// 1. CGEventTap으로 전역 mouseMoved 이벤트를 수신
/// 2. 마우스가 Dock 영역에 들어오면 AXUIElement로 Dock 아이콘 목록을 탐색
/// 3. 아이콘의 AXFrame과 마우스 위치를 비교해 호버 중인 앱 식별
final class DockMonitor {
    var onAppHovered: ((String?, NSRunningApplication?) -> Void)?
    var onHoverEnded: (() -> Void)?
    var onPermissionError: (() -> Void)?
    /// 마우스 포인터(CG 좌표)가 미리보기 패널 위에 있으면 true를 반환하는 콜백.
    /// 패널 위에 있는 동안은 hoverEnd 타이머를 시작하지 않는다.
    var isMouseOverPanel: ((CGPoint) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
        setupEventTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
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

    // MARK: - CGEventTap 설정

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DockMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleMouseMoved(event.location)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap = eventTap else {
            print("[DockMonitor] CGEventTap 생성 실패 — 접근성 권한을 확인하세요.")
            DispatchQueue.main.async { [weak self] in
                self?.onPermissionError?()
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - 마우스 이벤트 처리

    private func handleMouseMoved(_ point: CGPoint) {
        // AXUIElement 좌표계는 CG 좌표계(좌상단 원점, y 아래로)와 동일하다.
        // 마우스 이벤트도 CG 좌표이므로 변환 없이 직접 비교한다.
        guard let hoveredApp = findHoveredDockApp(at: point) else {
            if isMouseOverPanel?(point) == true {
                // 패널 위에 있는 동안은 진행 중인 hide 타이머를 취소한다.
                // 취소하지 않으면 Dock → 패널 이동 중 시작된 0.2s 타이머가 패널을 숨긴다.
                isHoveringPanel = true
                cancelHoverTimer()
                return
            }
            // isHoveringPanel 리셋은 scheduleHoverEnd 내부에서 수행한다.
            // 여기서 false로 설정하면 scheduleHoverEnd의 guard 조건을 통과하지 못해
            // 패널이 사라지지 않는 버그가 발생한다.
            scheduleHoverEnd()
            return
        }
        isHoveringPanel = false

        let bundleID = hoveredApp.bundleIdentifier ?? ""
        if bundleID == lastHoveredBundleID { return }

        cancelHoverTimer()
        lastHoveredBundleID = bundleID

        // AppSettings.shared는 @MainActor 격리이므로 CGEventTap 콜백(메인 런루프)에서
        // 직접 접근하지 않고, 동일 UserDefaults 키를 통해 값을 읽는다.
        // 키 이름은 AppSettings.Keys.hoverDelay를 공유해 문자열 불일치를 방지한다.
        let delay = UserDefaults.standard.double(forKey: AppSettings.Keys.hoverDelay)
        let hoverDelay = delay > 0 ? delay : AppSettings.Defaults.hoverDelay
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            self?.onAppHovered?(bundleID, hoveredApp)
        }
    }

    private func scheduleHoverEnd() {
        guard lastHoveredBundleID != nil || isHoveringPanel else { return }
        isHoveringPanel = false   // guard 통과 후 리셋
        cancelHoverTimer()
        lastHoveredBundleID = nil

        // 약간의 딜레이 후 패널 숨김 (빠른 이동 시 깜빡임 방지)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.onHoverEnded?()
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
    /// 번들 ID 추출은 DockAXHelper.bundleID(of:)에 위임한다.
    private func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        guard let bundleID = DockAXHelper.bundleID(of: item) else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
    }
}
