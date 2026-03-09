import SwiftUI
import ServiceManagement

/// 앱 전역 설정을 UserDefaults에 저장/로드하는 ObservableObject.
///
/// @AppStorage를 사용해 UserDefaults(standard)와 자동으로 동기화되며,
/// SwiftUI 뷰에서 @StateObject / @EnvironmentObject 로 관찰할 수 있다.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - Keys

    /// UserDefaults 키 상수. DockMonitor 등 비-MainActor 컨텍스트에서도 참조할 수 있도록 internal.
    enum Keys {
        static let hoverDelay      = "hoverDelay"
        static let thumbnailWidth  = "thumbnailWidth"
        static let thumbnailHeight = "thumbnailHeight"
        static let launchAtLogin   = "launchAtLogin"
    }

    // MARK: - Default Values

    enum Defaults {
        static let hoverDelay:      Double = 0.4
        static let thumbnailWidth:  Double = 200
        static let thumbnailHeight: Double = 130
        static let launchAtLogin:   Bool   = false
    }

    // MARK: - Settings

    /// 호버 인식 딜레이 (초), 범위 0.1~1.0
    @AppStorage(Keys.hoverDelay)
    var hoverDelay: Double = Defaults.hoverDelay

    /// 썸네일 너비 (px), 범위 100~400
    @AppStorage(Keys.thumbnailWidth)
    var thumbnailWidth: Double = Defaults.thumbnailWidth

    /// 썸네일 높이 (px), 범위 80~300
    @AppStorage(Keys.thumbnailHeight)
    var thumbnailHeight: Double = Defaults.thumbnailHeight

    /// 로그인 시 자동 실행 (SMAppService 연동)
    @AppStorage(Keys.launchAtLogin)
    var launchAtLogin: Bool = Defaults.launchAtLogin {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    /// launchAtLogin 등록/해제 실패 시 설정되는 에러 메시지.
    /// 다음 성공 시 또는 사용자가 토글을 다시 조작할 때 nil로 초기화된다.
    @Published var lastLaunchAtLoginError: String?

    // MARK: - Init

    private init() {}

    // MARK: - Reset

    /// 모든 설정을 기본값으로 초기화한다.
    func resetToDefaults() {
        hoverDelay      = Defaults.hoverDelay
        thumbnailWidth  = Defaults.thumbnailWidth
        thumbnailHeight = Defaults.thumbnailHeight
        launchAtLogin   = Defaults.launchAtLogin
    }

    // MARK: - SMAppService

    /// launchAtLogin 변경을 SMAppService에 반영한다.
    /// 등록 실패 시 `launchAtLogin`을 `false`로 롤백하고 `lastLaunchAtLoginError`에 메시지를 기록한다.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        // 이전 에러는 새 시도 시작과 동시에 초기화한다.
        lastLaunchAtLoginError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let message = error.localizedDescription
            print("[AppSettings] launchAtLogin 변경 실패: \(message)")
            if enabled {
                // 등록 실패 — UI가 ON으로 남지 않도록 롤백한다.
                // didSet 재진입 방지를 위해 @AppStorage 값을 직접 덮어쓴다.
                launchAtLogin = false
                lastLaunchAtLoginError = message
            }
        }
    }
}
