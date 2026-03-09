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

    private enum Keys {
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
    /// 실패해도 앱 크래시 없이 에러 로그만 출력한다.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("[AppSettings] launchAtLogin 변경 실패: \(error.localizedDescription)")
        }
    }
}
