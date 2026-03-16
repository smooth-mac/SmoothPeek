/// SmoothPeek 자동 업데이트 매니저.
///
/// Direct 배포 빌드(`!MAS_BUILD`)에서만 Sparkle 프레임워크를 사용한다.
/// MAS 빌드에서는 App Store 자체 업데이트 메커니즘을 사용하므로 이 클래스는
/// 빈 stub으로만 존재한다.
///
/// ## Sparkle 연동 준비 단계
/// Sparkle SPM 패키지를 추가한 후 아래 절차를 따른다.
/// 1. `Package.swift` 또는 Xcode 프로젝트에 Sparkle 의존성 추가
/// 2. `Info.plist`에 `SUFeedURL` 키와 appcast URL 추가
/// 3. `#if !MAS_BUILD` 블록의 `// SPARKLE_TODO` 주석 부분을 실제 구현으로 교체:
///    ```swift
///    import Sparkle
///    private let updater = SPUStandardUpdaterController(
///        startingUpdater: true,
///        updaterDelegate: nil,
///        userDriverDelegate: nil
///    )
///    func checkForUpdates() {
///        updater.checkForUpdates(nil)
///    }
///    ```
@MainActor
final class UpdateManager {

    // MARK: - Shared Instance

    static let shared = UpdateManager()

    private init() {}

    // MARK: - Public API

    /// 업데이트를 확인한다.
    ///
    /// - Direct 빌드: Sparkle이 연동되면 업데이트 확인 다이얼로그를 표시한다.
    ///   현재는 Sparkle 패키지가 추가되지 않아 로그만 출력한다.
    /// - MAS 빌드: 아무 동작도 하지 않는다. App Store가 업데이트를 처리한다.
    func checkForUpdates() {
#if !MAS_BUILD
        checkForUpdatesDirect()
#endif
    }

    // MARK: - Private Implementation

#if !MAS_BUILD
    /// Sparkle을 통해 업데이트를 확인한다 (Direct 빌드 전용).
    ///
    /// Sparkle SPM 패키지가 추가되면 이 메서드를 실제 Sparkle 호출로 교체한다.
    /// - SeeAlso: ``UpdateManager`` 클래스 주석의 Sparkle 연동 준비 단계
    private func checkForUpdatesDirect() {
        // SPARKLE_TODO: Sparkle SPM 패키지 추가 후 아래 print를 실제 구현으로 교체한다.
        // import Sparkle 후 SPUStandardUpdaterController.checkForUpdates(nil) 호출.
        print("[SmoothPeek] 업데이트 확인 — Sparkle 패키지 연동 후 활성화 예정")
    }
#endif
}
