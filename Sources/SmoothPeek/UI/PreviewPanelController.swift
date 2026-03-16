import Cocoa
import SwiftUI

/// Dock 위에 떠 있는 미리보기 패널을 관리하는 컨트롤러
@MainActor
final class PreviewPanelController {
    private var panel: NSPanel?
    private var currentApp: NSRunningApplication?

    // fade out 애니메이션이 진행 중임을 나타내는 플래그
    // show()가 들어오면 이 플래그를 보고 진행 중인 fade out을 취소한다
    private var isFadingOut = false

    /// 미리보기에서 창을 선택했을 때 호출되는 콜백.
    /// AppDelegate에서 DockMonitor 상태 리셋에 사용한다.
    var onWindowSelected: (() -> Void)?

    // MARK: - Animation Constants

    private enum Animation {
        static let fadeInDuration: TimeInterval = 0.15
        static let fadeOutDuration: TimeInterval = 0.10
    }

    // MARK: - Show

    func show(for app: NSRunningApplication, windows: [WindowInfo]) {
        if currentApp?.processIdentifier == app.processIdentifier, panel?.isVisible == true {
            return // 같은 앱 — 패널 유지
        }
        currentApp = app

        let rootView = PreviewPanelView(app: app, windows: windows) { [weak self] window in
            self?.hide()
            self?.onWindowSelected?()
            WindowActivator.activate(window: window, app: app)
        }

        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }

        // fade out 진행 중이면 즉시 중단하고 alphaValue를 0으로 초기화한 뒤 fade in 시작
        // NSAnimationContext 기반 애니메이션은 isFadingOut 플래그 리셋만으로 중단 처리한다
        if isFadingOut {
            isFadingOut = false
            panel.alphaValue = 0
        }

        let host = NSHostingController(rootView: rootView)
        let size = preferredSize(for: windows)
        host.view.frame = CGRect(origin: .zero, size: size)

        // NSHostingController는 기본적으로 SwiftUI intrinsic size로 패널을 자동 리사이즈한다.
        // 이 리사이즈는 positionPanel 이후에 발생해 Y가 틀어지는 원인이 된다.
        // sizingOptions = [] 로 자동 리사이즈를 완전 차단한다 (macOS 13+ API, 최소 배포 14).
        host.sizingOptions = []

        panel.contentViewController = host
        panel.setContentSize(size)

        // alphaValue를 0으로 리셋한 뒤 orderFront — 이후 easeOut fade in
        panel.alphaValue = 0
        panel.orderFront(nil)

        // orderFront 이후 포지셔닝: orderFront 시점에 SwiftUI 레이아웃이 완료되므로
        // 이 시점의 panel.frame.size가 실제 최종 크기에 가장 근접하다.
        positionPanel(panel, near: app)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Animation.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Hit Test

    /// 마우스 포인터가 현재 패널 위에 있는지 확인한다.
    ///
    /// CGEvent 좌표(좌상단 원점)를 NS 좌표(좌하단 원점)로 변환한 뒤
    /// NSPanel.frame과 비교한다. primary screen의 높이를 Y 축 기준으로 사용한다.
    func containsMouse(at cgPoint: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        let screenHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                        ?? NSScreen.main?.frame.height ?? 0
        let nsPoint = NSPoint(x: cgPoint.x, y: screenHeight - cgPoint.y)
        return panel.frame.contains(nsPoint)
    }

    // MARK: - Hide

    func hide() {
        guard let panel, panel.isVisible else {
            currentApp = nil
            return
        }

        currentApp = nil
        isFadingOut = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Animation.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // completionHandler는 Sendable 컨텍스트로 취급되므로
            // @MainActor 프로퍼티 접근을 MainActor.run 안에서 수행한다
            Task { @MainActor [weak self] in
                guard let self, self.isFadingOut else {
                    // show()가 중간에 호출되어 플래그가 리셋된 경우 — orderOut 하지 않음
                    return
                }
                self.isFadingOut = false
                panel.orderOut(nil)
            }
        }
    }

    // MARK: - Panel Factory

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .hudWindow, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = false
        // fade in/out 애니메이션 시작점: 완전 투명 상태에서 시작
        panel.alphaValue = 0
        return panel
    }

    // MARK: - Layout

    /// 실제 SwiftUI 레이아웃을 반영한 패널 크기 계산.
    ///
    /// 레이아웃 구조:
    ///   PreviewPanelView
    ///     .padding(.top, 12)                          → 12pt
    ///     HStack(header)                              → 20pt  (아이콘 20×20 기준)
    ///     VStack spacing: 8                           →  8pt
    ///     LazyVGrid(spacing: 12)                      → rows * cardH + (rows-1)*12
    ///       WindowThumbnailCard: VStack(spacing:4)
    ///         ZStack .frame(thumbW, thumbH)           → thumbHeight (aspect-ratio fitted)
    ///         Text size:11                            → ~13pt
    ///       card height = thumbHeight + 4 + 13 = thumbHeight + 17
    ///     .padding([.horizontal, .bottom], 12)        → 12pt (bottom)
    ///
    ///   총 fixed 오버헤드 = 12 + 20 + 8 + 12 = 52pt
    ///   각 row 기여 = max(thumbHeight in row) + 17
    ///   row 간 gap = 12pt (LazyVGrid spacing)
    ///
    /// 창별 thumbHeight는 WindowThumbnailCard.thumbSize와 동일한 로직으로 계산해
    /// 실제 렌더 높이와 오차 없이 일치시킨다.
    private func preferredSize(for windows: [WindowInfo]) -> CGSize {
        let maxW   = CGFloat(AppSettings.shared.thumbnailWidth)
        let maxH   = CGFloat(AppSettings.shared.thumbnailHeight)
        let hPad: CGFloat  = 12   // grid horizontal/bottom padding
        let rGap: CGFloat  = 12   // LazyVGrid row spacing
        let cardExtra: CGFloat = 17  // VStack spacing(4) + Text height(~13)

        let columns = min(windows.count, 4)
        let rows    = Int(ceil(Double(windows.count) / Double(columns)))

        // 창별 실제 thumb 크기 (WindowThumbnailCard.thumbSize와 동일 로직)
        let thumbSizes: [CGSize] = windows.map { w in
            guard !w.isMinimized, w.frame.width > 0, w.frame.height > 0 else {
                return CGSize(width: maxW, height: maxH)
            }
            let scale = min(maxW / w.frame.width, maxH / w.frame.height)
            return CGSize(
                width:  max(1, (w.frame.width  * scale).rounded()),
                height: max(1, (w.frame.height * scale).rounded())
            )
        }

        // 실제 최대 thumb 너비 → PreviewPanelView의 colWidth와 동일한 값
        let colW = thumbSizes.map(\.width).max() ?? maxW

        // 행별 최대 thumb 높이 합산
        var gridH: CGFloat = hPad  // bottom padding
        for row in 0..<rows {
            let lo = row * columns
            let hi = min(lo + columns, thumbSizes.count)
            let rowThumbH = thumbSizes[lo..<hi].map(\.height).max() ?? maxH
            gridH += rowThumbH + cardExtra
            if row < rows - 1 { gridH += rGap }
        }

        // 고정 오버헤드: top(12) + header(20) + VStack spacing(8)
        let height = 40 + gridH
        let width  = CGFloat(columns) * (colW + hPad) + hPad
        return CGSize(width: width, height: height)
    }

    // MARK: - Dock Position

    private enum DockEdge {
        case bottom(height: CGFloat)
        case left(width: CGFloat)
        case right(width: CGFloat)
    }

    /// Dock이 위치한 화면을 반환한다.
    ///
    /// Dock은 항상 primary screen(NSScreen.screens.first)에 위치한다.
    /// NSScreen.main은 현재 키 윈도우가 있는 화면으로 보조 모니터일 수 있으므로 사용하지 않는다.
    private func dockScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    /// NSScreen의 visibleFrame 차이를 이용해 Dock 위치와 크기를 계산한다.
    ///
    /// Auto-hide 상태에서는 visibleFrame 차이가 거의 0이 되므로
    /// 최솟값(minDockSize)을 보장해 패널이 Dock 트리거 영역 뒤에 가려지지 않도록 한다.
    private func dockEdge(on screen: NSScreen) -> DockEdge {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let minDockSize: CGFloat = 4 // auto-hide 트리거 영역 여유

        if visible.minX > 4 {
            return .left(width: max(visible.minX, minDockSize))
        } else if frame.maxX - visible.maxX > 4 {
            return .right(width: max(frame.maxX - visible.maxX, minDockSize))
        } else {
            // bottom dock (또는 auto-hide)
            return .bottom(height: max(visible.minY, minDockSize))
        }
    }

    /// 패널을 Dock 위 해당 앱 아이콘 근처에 배치
    private func positionPanel(_ panel: NSPanel, near app: NSRunningApplication) {
        // ISSUE-03 수정: primary screen(Dock이 있는 화면) 기준으로 계산
        guard let screen = dockScreen() else { return }
        let panelSize = panel.frame.size
        let edge = dockEdge(on: screen)
        let iconFrame = findDockIconFrame(for: app)
        let gap: CGFloat = 12

        let x: CGFloat
        let y: CGFloat

        switch edge {
        case .bottom(let dockHeight):
            let centerX = iconFrame?.midX ?? screen.frame.midX
            x = (centerX - panelSize.width / 2)
                .clamped(to: 8...(screen.frame.maxX - panelSize.width - 8))
            // Dock magnification 중 AX 프레임을 읽으면 아이콘이 확대된 상태라
            // minY가 위로 올라가 패널 위치가 불안정해진다.
            // visibleFrame.minY(Dock 영역 경계)를 기준으로 사용해 항상 일정한 위치를 보장한다.
            y = dockHeight + gap

        case .left(let dockWidth):
            x = dockWidth + gap
            // iconFrame은 CG 좌표(좌상단 원점); setFrameOrigin은 NS 좌표(좌하단 원점) 필요.
            // NS_y = screen.frame.height - CG_y
            let centerY = iconFrame.map { screen.frame.height - $0.midY - panelSize.height / 2 }
                ?? (screen.frame.midY - panelSize.height / 2)
            y = centerY.clamped(to: 8...(screen.frame.maxY - panelSize.height - 8))

        case .right(let dockWidth):
            x = screen.frame.maxX - dockWidth - panelSize.width - gap
            let centerY = iconFrame.map { screen.frame.height - $0.midY - panelSize.height / 2 }
                ?? (screen.frame.midY - panelSize.height / 2)
            y = centerY.clamped(to: 8...(screen.frame.maxY - panelSize.height - 8))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Dock 아이콘의 AX 프레임(NS 좌표계)을 반환.
    ///
    /// - `midX`: 패널 수평 중앙 정렬에 사용
    /// - `maxY`: 패널 하단 Y 기준점 — Dock 영역 상단이 아닌 아이콘 상단 기준으로
    ///           패널을 위치시켜 앱마다 일정한 간격이 유지된다.
    private func findDockIconFrame(for app: NSRunningApplication) -> CGRect? {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return nil }

        let bundleID = app.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return nil }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let iconElement = DockAXHelper.dockIconElement(for: bundleID, in: dockElement) else { return nil }
        return DockAXHelper.axFrame(of: iconElement)
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
