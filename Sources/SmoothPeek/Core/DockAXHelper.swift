import Cocoa
import ApplicationServices

/// Dock Accessibility API 공통 유틸리티.
///
/// DockMonitor와 PreviewPanelController 양쪽에서 공유하는
/// AXUIElement 탐색 및 속성 추출 로직을 제공한다.
///
/// ## 좌표계 주의사항
///
/// AX API의 position은 **CG 좌표계**(좌상단 원점, y 아래로 증가)를 사용한다.
/// CGWindowList의 frame과 동일한 좌표계이다.
///
/// `axFrame(of:)` — NS 좌표계 그대로 반환. NSPanel.setFrameOrigin 등 AppKit API에 사용.
/// `axFrameInCGCoordinates(of:)` — CG 좌표계로 변환 후 반환. CGWindowList·마우스 이벤트 비교에 사용.
enum DockAXHelper {

    // MARK: - Frame 추출

    /// AXUIElement의 position과 size 속성으로 frame을 구성해 반환.
    ///
    /// AX API는 position/size를 AXValue 타입으로 반환하므로
    /// `CFGetTypeID()` 검사 후 `AXValueGetValue()`로 안전하게 추출한다.
    ///
    /// AX API의 `kAXPositionAttribute`는 **CG 좌표계**(좌상단 원점, y 아래로 증가)를 반환한다.
    /// `setFrameOrigin` 등 AppKit NS 좌표계 API에 사용하려면 별도로 NS 좌표로 변환해야 한다.
    ///
    /// - Returns: CG 좌표계(좌상단 원점)의 CGRect. 실패 시 nil.
    static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)   // safe: type ID checked above
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)  // safe: type ID checked above

        return CGRect(origin: pos, size: size)
    }

    /// AXUIElement의 frame을 CG 좌표계(좌상단 원점, y 아래로 증가)로 반환.
    ///
    /// AX API의 `kAXPositionAttribute`는 이미 CG 좌표계를 사용하므로 추가 변환 없이 그대로 반환한다.
    /// (`axFrame(of:)`와 동일한 값. 호출 측 코드의 의도를 명확히 하기 위한 alias 역할)
    ///
    /// 마우스 이벤트 좌표(CG) 및 CGWindowList frame과 직접 비교할 때 사용한다.
    ///
    /// - Returns: CG 좌표계(좌상단 원점)의 CGRect. 실패 시 nil.
    static func axFrameInCGCoordinates(of element: AXUIElement) -> CGRect? {
        return axFrame(of: element)
    }

    // MARK: - Bundle ID 추출

    /// AXUIElement의 `kAXURLAttribute`에서 번들 ID를 추출.
    ///
    /// `kAXURL`은 String이 아닌 CFURL 타입으로 반환되므로
    /// `CFGetTypeID()` 검사 후 캐스팅해야 한다.
    ///
    /// - Returns: 번들 ID 문자열, URL 속성이 없거나 번들을 찾을 수 없으면 nil
    static func bundleID(of element: AXUIElement) -> String? {
        var urlRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef)

        guard let urlRef,
              CFGetTypeID(urlRef) == CFURLGetTypeID() else { return nil }

        let url = urlRef as! CFURL as URL  // safe: type ID checked above
        let id = Bundle(url: url)?.bundleIdentifier ?? ""
        return id.isEmpty ? nil : id
    }

    // MARK: - Dock 아이콘 탐색

    /// Dock AXUIElement에서 특정 bundleID를 가진 아이콘 항목을 반환.
    ///
    /// Dock의 AX 계층 구조:
    /// ```
    /// dockElement (Application)
    ///   └─ List (kAXListRole)
    ///        └─ item (kAXURLAttribute 로 앱 식별)
    /// ```
    ///
    /// - Parameters:
    ///   - bundleID: 찾으려는 앱의 번들 ID
    ///   - dockElement: Dock 프로세스의 최상위 AXUIElement
    /// - Returns: 해당 번들 ID의 Dock 아이콘 AXUIElement, 없으면 nil
    static func dockIconElement(for bundleID: String, in dockElement: AXUIElement) -> AXUIElement? {
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
                guard DockAXHelper.bundleID(of: item) == bundleID else { continue }
                return item
            }
        }
        return nil
    }
}
