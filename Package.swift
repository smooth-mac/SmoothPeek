// swift-tools-version: 5.9
import PackageDescription

// MARK: - 빌드 변형 플래그
//
// App Store 빌드:    swift build -Xswiftc -DMAS_BUILD
// Direct 배포 빌드:  swift build (기본값, MAS_BUILD 미정의)
//
// MAS_BUILD 활성 시:
//   - CGEventTap 대신 NSEvent 전역 모니터 사용 (Input Monitoring 권한 불필요)
//   - CGWindowListCreateImage 제거 (SCKit only)
//   - _AXUIElementGetWindow Private API 없음 (이미 제거됨)

let package = Package(
    name: "SmoothPeek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SmoothPeek",
            path: "Sources/SmoothPeek",
            exclude: [
                // Info.plist은 SPM executableTarget의 resources에 넣을 수 없다.
                // build_release.sh가 .app 번들 조립 시 Contents/ 에 직접 복사한다.
                "Info.plist",
                // SVG 원본 파일 — 런타임에 불필요; build_icons.sh가 PNG로 변환한다.
                "Resources/AppIcon.svg",
                "Resources/StatusBarIcon.svg",
                "Resources/READMEBanner.svg",
            ],
            resources: [
                // Assets.xcassets는 .process로 처리 — actool을 통해 컴파일된
                // Assets.car 파일로 변환되어 번들 Resources/ 에 포함된다.
                // PNG 파일이 있어야 actool이 실제 Assets.car를 생성한다.
                // PNG가 없는 경우 build_release.sh의 actool 직접 호출 경로가 대응한다.
                .process("Resources/Assets.xcassets"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
