# SmoothPeek Phase 3 — 출시 준비 계획서

> 작성일: 2026-03-10
> 기준 커밋: Phase 2 QA 이슈 수정 완료 상태
> Phase 3 목표: 품질 완성 + 다중 스페이스 지원 + 배포 준비

---

## 1. Phase 3 개요

### 목표

Phase 3는 SmoothPeek를 **실사용자에게 배포 가능한 상태**로 끌어올리는 단계다.
Phase 1·2에서 확립된 안정적인 아키텍처 위에서, 세 가지 방향으로 완성도를 높인다.

| 방향 | 내용 |
|------|------|
| 기능 완성 | 다중 스페이스 윈도우 지원 (Phase 2 이연 항목) |
| 기술 부채 해소 | 좌표계 정확성, 코드 중복, 메인 스레드 블로킹 |
| 배포 준비 | 서명, 공증, 자동 업데이트, 앱 아이콘 |

### 범위 외 항목

다음 사항은 Phase 3 범위에 포함하지 않는다:

- App Store 제출 (CGEventTap과 샌드박스 비호환 — 섹션 6에서 상세 분석)
- 신규 핵심 기능 추가 (스크린샷, 파일 미리보기 등)
- 유료화 / 인앱 결제 구조

---

## 2. 선행 조건 (Phase 3 착수 전 필수)

Phase 2 미커밋 수정사항(6개 파일)이 커밋되어 있어야 한다.
다음 항목이 모두 코드에 반영된 상태로 Phase 3를 시작한다.

| 항목 | 파일 | 비고 |
|------|------|------|
| ISSUE-P2-04 수정 | WindowThumbnailView.swift | thumbSize AppSettings 연동 |
| ISSUE-P2-02 수정 | ThumbnailGenerator.swift | SCShareableContent 미스 시 캐시 무효화 |
| ISSUE-P2-05 수정 | AppSettings.swift | lastLaunchAtLoginError UI 표시 |
| ISSUE-P2-06 수정 | AppDelegate.swift | isMiniaturized 체크 |
| INFO 수정 | SettingsView.swift | @StateObject → @ObservedObject |

---

## 3. 작업 목록 (우선순위 순)

### P3-1. 다중 스페이스 윈도우 지원 [Phase 2 이연, 기능]

**우선순위:** 높음
**복잡도:** 높음 (macOS API 제약 상당함)
**담당 에이전트:** swift-engineer

#### 배경

현재 `WindowEnumerator`는 `.optionOnScreenOnly`와 `.excludeDesktopElements` 두 쿼리로 윈도우를 수집하지만, **다른 스페이스(데스크탑)에 있는 윈도우는 두 쿼리 모두에서 누락된다.**

`CGWindowListCopyWindowInfo(.excludeDesktopElements, ...)` 쿼리는 이론상 모든 스페이스의 윈도우를 반환해야 하지만, macOS에서 현재 스페이스가 아닌 윈도우는 `kCGWindowIsOnscreen == false`로 표시되면서 `CGWindowLayer` 정보가 유지되므로 `layer == 0` 필터로 수집 가능하다.

그러나 다른 스페이스 윈도우를 실제로 가져오려면 추가적인 판별 로직이 필요하다:
- 최소화 윈도우와 "다른 스페이스 윈도우" 모두 `isOnscreen == false`
- 두 종류를 구분하는 공식 API가 없음 (Accessibility 프로퍼티로 간접 판별 가능)

#### 구현 방향

**방법 A: AXUIElement 기반 스페이스 판별 (권장)**

1. 앱의 `kAXWindowsAttribute`로 모든 AX 윈도우를 열거한다.
2. 각 AX 윈도우에서 `_AXUIElementGetWindow`로 CGWindowID를 추출한다.
3. CGWindowList에서 해당 ID가 `isOnscreen == false`이고 `isMinimized (kAXMinimizedAttribute) == false`이면 다른 스페이스 윈도우로 분류한다.
4. `WindowInfo`에 `isOnAnotherSpace: Bool` 필드를 추가한다.

**방법 B: CGWindowListCopyWindowInfo 단독 쿼리 확장**

- `CGWindowListCopyWindowInfo(.excludeDesktopElements)` 결과에서 `isOnscreen == false`인 항목을 AX로 교차 검증해 최소화 여부를 확인한다.
- AX 접근성 권한이 있으면 정확, 없으면 오분류 위험.

**권장:** 방법 A. `_AXUIElementGetWindow`는 이미 `WindowActivator`에서 사용 중이므로 별도 위험 없이 재사용 가능하다.

#### WindowThumbnailView 변경

- 다른 스페이스 윈도우 카드에 "다른 스페이스" 배지 표시
- 클릭 시 해당 스페이스로 전환 후 윈도우 활성화 (`NSWorkspace.shared.open` + AX raise)

#### 기대 효과

- Safari, Xcode 등 다중 스페이스 사용자의 핵심 요구 충족
- Mission Control과 유사한 전체 윈도우 가시성 제공

#### 주요 리스크

- macOS 버전마다 다른 스페이스 윈도우 열거 동작이 다를 수 있음
- AX 권한 없을 때 스페이스 판별 불가 → 최소화 윈도우와 혼동될 수 있음
- 스페이스 전환 + 윈도우 포커스의 타이밍 처리 (asyncAfter 조정 필요)

---

### P3-2. WindowEnumerator 백그라운드 실행 [성능, 기술 부채]

**우선순위:** 높음
**복잡도:** 중간
**담당 에이전트:** swift-engineer

#### 배경

현재 `AppDelegate.handleHover()`는 `@MainActor`에서 직접 `WindowEnumerator.windows(for:)`를 호출한다.

```swift
// AppDelegate.swift line 150
let windows = WindowEnumerator.windows(for: app)  // 메인 스레드 차단
```

`WindowEnumerator`는 내부적으로 `CGWindowListCopyWindowInfo`를 두 번 호출한다:
- `.optionOnScreenOnly` 쿼리
- `.excludeDesktopElements` 전체 쿼리

100개 이상의 윈도우가 열려 있는 환경에서 두 번째 쿼리는 **5~20ms 수준의 메인 스레드 블로킹**을 유발할 수 있다. Phase 3에서 다중 스페이스 지원(P3-1)까지 추가되면 세 번째 AX 쿼리가 더해져 블로킹이 심화된다.

#### 구현 방향

`WindowEnumerator.windows(for:)`를 `async` 함수로 전환한다.

```swift
// 변경 전
static func windows(for app: NSRunningApplication) -> [WindowInfo]

// 변경 후
static func windows(for app: NSRunningApplication) async -> [WindowInfo]
```

내부에서 `await Task.detached(priority: .userInitiated) { ... }.value`로 CGWindowList 쿼리를 백그라운드 스레드에서 실행한다.

`AppDelegate.handleHover()`는 이미 `@MainActor`이므로 `await` 호출만 추가하면 된다.

#### 주의사항

- `CGWindowListCopyWindowInfo`는 스레드 안전하지만 문서화되지 않음 — `Task.detached`로 실행 시 주의
- AX 쿼리(`AXUIElementCopyAttributeValue`)는 메인 스레드에서 호출해야 하는 경우가 있으므로 P3-1과 조율 필요
- 결과 반환 전에 사용자가 다른 아이콘으로 이동했다면 결과를 버려야 함 (취소 처리)

#### 기대 효과

- 메인 스레드 블로킹 제거 → UI 반응성 향상
- 향후 프리페치(미리 로드) 구조로 확장 가능

---

### P3-3. DockAXHelper 좌표계 정확성 수정 [기술 부채]

**우선순위:** 중간
**복잡도:** 중간
**담당 에이전트:** swift-engineer

#### 배경 (ISSUE-P2-01 계속)

`DockAXHelper.axFrame(of:)`가 반환하는 좌표는 **AX 좌표계(NS 좌표, 좌하단 원점)**다.
그런데 `DockMonitor.findHoveredDockApp()`은 이 프레임을 **CG 좌표계(좌상단 원점)**의 마우스 위치와 직접 비교한다.

```swift
// DockMonitor.swift line 178
guard let frame = DockAXHelper.axFrame(of: item),
      frame.contains(point) else { continue }  // AX 좌표 vs CG 좌표 직접 비교
```

이것이 현재 동작하는 이유: Dock이 화면 하단에 위치할 때, Dock 아이콘의 AX y값(NS 좌표계에서 아래서부터의 높이, 예: 0~80px)과 CG y값(위에서부터의 거리, 예: 1000~1080px on 1080p)은 **전혀 다른 숫자**다. 그러나 hit-test가 우연히 동작하는 이유는, Dock 아이콘 frame의 높이(60~100px 수준)가 충분히 커서 마우스 CG y값(예: 1060)이 AX frame(예: y=0, height=80의 range 0~80) 바깥에 있어도, AX 탐색에서 "이 item에 해당하는 마우스인가"를 판별하기 전에 bundle URL로 앱을 먼저 식별하기 때문이다.

실제로는 `frame.contains(point)`가 올바르게 동작하는 경우보다 **버그에 의해 우연히 통과되는 경우가 더 많을 수 있다.** 정확한 수정이 필요하다.

#### 구현 방향

`DockAXHelper.axFrame(of:)`의 반환값에 대해 두 가지 변환 함수를 제공한다:

```swift
// CG 좌표계로 변환 (DockMonitor용 — 마우스 이벤트와 비교)
static func axFrameInCGCoordinates(of element: AXUIElement, screen: NSScreen) -> CGRect?

// NS 좌표계 그대로 (PreviewPanelController용 — setFrameOrigin에 직접 사용)
static func axFrame(of element: AXUIElement) -> CGRect?  // 기존 유지
```

변환 공식:
```
cgY = screenHeight - axNSY - axHeight
```

여기서 `screenHeight`는 primary screen(`NSScreen.screens.first`)의 `frame.height`를 사용한다.

#### 기대 효과

- 대형 아이콘, 상단 Dock, 고해상도 보조 디스플레이 환경에서 정확한 호버 감지
- 좌표계 혼용에 의한 잠재 버그 제거

---

### P3-4. AppSettings.Keys 접근성 개선 [기술 부채]

**우선순위:** 낮음
**복잡도:** 낮음
**담당 에이전트:** swift-engineer

#### 배경

`DockMonitor`에서 `hoverDelay` 키를 문자열 리터럴로 직접 읽고 있다.

```swift
// DockMonitor.swift line 125
let delay = UserDefaults.standard.double(forKey: AppSettings.Keys.hoverDelay)
```

이미 Phase 2 수정에서 `AppSettings.Keys.hoverDelay`를 직접 참조하도록 개선되었으나, `Keys` 열거형 자체가 `internal` 스코프로 선언되어 있는지 재확인이 필요하다. 현재 코드는 올바르게 동작하나 문서화가 불충분하다.

#### 구현 방향

- `AppSettings.Keys` 열거형에 각 키에 대한 문서 주석 추가
- `DockMonitor`에서 `AppSettings.Keys.hoverDelay` 참조 유지 (이미 올바름)
- `Defaults.hoverDelay` fallback 값도 `AppSettings.Defaults`에서 가져오도록 통일

---

### P3-5. 앱 서명 및 공증 설정 [배포 준비]

**우선순위:** 높음 (배포 전 필수)
**복잡도:** 중간
**담당 에이전트:** swift-engineer + appstore-manager

#### 배경

현재 SmoothPeek는 SPM CLI 빌드로만 실행 가능하다. 일반 사용자에게 배포하려면:
1. Developer ID Application 서명
2. Apple 공증(Notarization)
3. `.entitlements` 파일 구성

이 세 가지가 반드시 필요하다.

#### 구현 방향

**entitlements 설정**

```xml
<!-- SmoothPeek.entitlements -->
<key>com.apple.security.app-sandbox</key>
<false/>  <!-- CGEventTap 사용으로 샌드박스 불가 -->

<key>com.apple.security.automation.apple-events</key>
<true/>   <!-- AX API 사용 -->
```

화면 녹화 권한은 entitlement가 아닌 TCC(Transparency Consent Control)로 OS가 런타임에 요청한다. `NSScreenCaptureUsageDescription` 키를 `Info.plist`에 추가한다.

**빌드 및 공증 흐름**

1. Xcode 프로젝트 또는 SPM + xcodebuild로 `.app` 번들 생성
2. `codesign --deep --force --options=runtime --sign "Developer ID Application: ..."` 적용
3. `xcrun notarytool submit` → Apple 서버 공증
4. `xcrun stapler staple` → 공증 결과 앱 번들에 스테이플
5. `hdiutil create`로 DMG 패키지 생성

**주의사항**

- SPM `.executableTarget`은 `.app` 번들을 직접 생성하지 않는다. `xcodebuild`를 사용하거나 `swift build` 결과물에 수동으로 `Info.plist`와 `Contents/MacOS/` 구조를 만들어야 한다.
- macOS 13 최소 지원 유지 시 `@available(macOS 14.0, *)` 분기는 유지된다.

---

### P3-6. 자동 업데이트 (Sparkle 통합) [배포 준비]

**우선순위:** 중간
**복잡도:** 중간
**담당 에이전트:** swift-engineer

#### 배경

직접 배포 앱이 자동 업데이트를 지원하지 않으면 사용자는 수동으로 새 버전을 다운로드해야 한다. Sparkle 2는 macOS 오픈소스 표준 자동 업데이트 프레임워크로, Developer ID 공증 앱과 함께 사용 가능하다.

#### 구현 방향

**Package.swift 의존성 추가**

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
],
targets: [
    .executableTarget(
        name: "SmoothPeek",
        dependencies: [
            .product(name: "Sparkle", package: "Sparkle")
        ],
        ...
    )
]
```

**AppDelegate 통합**

```swift
import Sparkle

private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
```

**상태바 메뉴에 업데이트 확인 항목 추가**

```swift
let updateItem = NSMenuItem(
    title: "업데이트 확인...",
    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
    keyEquivalent: ""
)
updateItem.target = updaterController
```

**appcast.xml 구성**

GitHub Releases와 연동하거나 별도 서버에 appcast.xml을 호스팅한다.

#### 기대 효과

- 사용자 이탈 없이 새 버전 배포 가능
- 보안 패치를 빠르게 전파

---

### P3-7. 앱 아이콘 및 시각 자산 [배포 준비]

**우선순위:** 중간
**복잡도:** 낮음 (디자인 리소스 필요)
**담당 에이전트:** senior-designer

#### 배경

현재 상태바 아이콘은 `macwindow.on.rectangle` SF Symbol을 임시로 사용하고 있다.
앱 배포를 위해서는 `.icns` 형식의 정식 아이콘이 필요하다.

#### 필요 자산

| 자산 | 규격 | 용도 |
|------|------|------|
| 앱 아이콘 | 1024×1024 PNG | macOS 앱 아이콘 (`AppIcon.icns`) |
| 상태바 아이콘 | 18×18 @1x, 36×36 @2x PNG | NSStatusItem 표시용 |
| GitHub README 배너 | 1200×630 | 소셜 미리보기 / README 상단 |
| 데모 스크린샷 | 1280×800 | GitHub Releases 및 웹페이지용 |

#### 디자인 방향 제안

- SmoothPeek의 정체성: "Dock 위에 떠오르는 창 미리보기"
- 아이콘 컨셉: 유리 효과(vibrancy) + 작은 창들이 배열된 형태
- macOS 빅 서 이후 디자인 언어: 둥근 모서리 정사각형, 그라데이션 배경

---

### P3-8. 다중 모니터 + 비표준 Dock 위치 종합 테스트 [QA]

**우선순위:** 높음 (배포 전 필수)
**복잡도:** 낮음 (테스트 실행)
**담당 에이전트:** qa-specialist

#### 테스트 매트릭스

| 구성 | 테스트 항목 |
|------|------------|
| macOS 13 Ventura | 기본 동작, CGWindow fallback 경로 |
| macOS 14 Sonoma | SCKit 경로, 권한 요청 UI |
| macOS 15 Sequoia | 최신 API 호환성 |
| Dock 하단 (기본) | 패널 위치, 아이콘 중앙 정렬 |
| Dock 왼쪽 | 패널 Dock 오른쪽 배치 |
| Dock 오른쪽 | 패널 Dock 왼쪽 배치 |
| Dock 자동 숨김 | minDockSize fallback 동작 |
| 단일 모니터 | 기준 동작 |
| 다중 모니터 (Dock 주 화면) | 패널 주 화면에 올바르게 표시 |
| Retina + 비-Retina 혼합 | 썸네일 해상도 |
| 대형 아이콘 (큰 Dock) | 좌표 정확성 (P3-3 수정 후) |
| 50+ 윈도우 열린 환경 | WindowEnumerator 성능 |
| 다중 스페이스 | P3-1 완료 후 |

#### Phase 3 전용 회귀 테스트

- P3-1: 다른 스페이스 윈도우가 패널에 표시되고 클릭 시 스페이스 전환 + 활성화
- P3-2: 백그라운드 열거 중 다른 앱으로 이동 시 결과 무시 (race condition)
- P3-3: 상단 Dock에서 호버 정확성
- P3-5: 공증된 앱이 Gatekeeper 경고 없이 실행

---

### P3-9. 버전 관리 및 릴리스 태깅 [배포 준비]

**우선순위:** 중간
**복잡도:** 낮음
**담당 에이전트:** version-manager

#### 버전 체계

```
0.1.0  Phase 1 완료
0.5.0  Phase 2 완료
1.0.0  Phase 3 완료 — 첫 공개 배포
```

#### 필요 작업

1. `Info.plist`에 `CFBundleShortVersionString`, `CFBundleVersion` 추가
2. `CHANGELOG.md` 작성 (Phase 1~3 주요 변경사항 정리)
3. GitHub Releases 페이지 구성
4. `v1.0.0` 태그 및 릴리스 노트 작성

---

## 4. 배포 방식 분석

### 4-1. App Store — 불가 판정

**결론: CGEventTap 사용으로 App Store 제출 불가**

| 항목 | 판단 |
|------|------|
| 샌드박스 요구 | 필수 (App Store 심사 규정) |
| CGEventTap 샌드박스 호환 | 불가. CGEventTap은 `com.apple.security.app-sandbox = false`를 요구 |
| 대안 존재 여부 | CGEventTap 없이 Dock 호버 감지는 현실적으로 불가능 |
| 우회 방법 | NSEvent.addGlobalMonitorForEvents를 사용해도 샌드박스 외부 이벤트 수신 불가 |

**추가 고려사항:**
- `_AXUIElementGetWindow` Private API 사용은 심사 거절 사유 (App Store 기준)
- Direct Distribution에서는 개발자 책임 하에 사용 가능

### 4-2. Direct Distribution (권장)

**GitHub Releases + Developer ID 공증 DMG 배포**

| 항목 | 세부 내용 |
|------|----------|
| 배포 형식 | `.dmg` (드래그 앤 드롭 설치) |
| 서명 | Developer ID Application 인증서 |
| 공증 | Apple Notarization (xcrun notarytool) |
| Gatekeeper | 공증 완료 시 경고 없이 실행 가능 |
| 자동 업데이트 | Sparkle 2 (P3-6) |
| 비용 | Apple Developer Program 연간 $99 |

**배포 흐름:**

```
swift build -c release
→ .app 번들 구성 (Info.plist, Contents/MacOS/)
→ codesign (Developer ID, hardened runtime)
→ xcrun notarytool submit
→ xcrun stapler staple
→ hdiutil create (DMG)
→ GitHub Releases 업로드
```

### 4-3. Homebrew Cask (보조 배포 채널)

GitHub Releases에 공증된 DMG가 준비되면 Homebrew Cask 등록도 가능하다.

```ruby
# homebrew-cask/smoothpeek.rb
cask "smoothpeek" do
  version "1.0.0"
  sha256 "..."
  url "https://github.com/.../SmoothPeek-#{version}.dmg"
  app "SmoothPeek.app"
end
```

기술 요구사항은 Direct Distribution과 동일하다. 단, Cask PR이 승인되려면 프로젝트가 GitHub에서 일정 수준의 인지도를 갖추어야 한다.

### 4-4. 배포 방식 결정 권고

**P3 단계 권장 순서:**
1. Direct Distribution (GitHub Releases) 먼저 구현 및 검증
2. 안정화 후 Homebrew Cask 등록 검토
3. App Store 제출은 CGEventTap 의존성 제거 전에는 추진하지 않음

---

## 5. 작업 우선순위 요약

| 작업 | 우선순위 | 복잡도 | 의존성 |
|------|----------|--------|--------|
| P3-1 다중 스페이스 지원 | 높음 | 높음 | 없음 |
| P3-2 WindowEnumerator 백그라운드화 | 높음 | 중간 | P3-1과 조율 |
| P3-3 좌표계 정확성 수정 | 중간 | 중간 | 없음 |
| P3-4 AppSettings.Keys 정리 | 낮음 | 낮음 | 없음 |
| P3-5 서명 및 공증 | 높음 (배포 필수) | 중간 | P3-9 필요 |
| P3-6 Sparkle 자동 업데이트 | 중간 | 중간 | P3-5 완료 후 |
| P3-7 앱 아이콘 자산 | 중간 | 낮음 | 없음 |
| P3-8 종합 QA 테스트 | 높음 (배포 필수) | 낮음 | P3-1~P3-3 완료 후 |
| P3-9 버전 관리 / 릴리스 | 중간 | 낮음 | P3-5 완료 후 |

### 권장 진행 순서

```
Phase 3A (기능/안정화):
  P3-3 좌표계 수정 (빠른 수정, 기반 안정화)
  P3-4 Keys 정리 (빠른 수정)
  P3-1 다중 스페이스 지원 (핵심 기능)
  P3-2 WindowEnumerator 백그라운드화 (P3-1 완료 후)

Phase 3B (배포 준비):
  P3-7 앱 아이콘 (P3A와 병행 가능)
  P3-5 서명 / 공증 설정
  P3-6 Sparkle 통합
  P3-9 버전 관리 / CHANGELOG

Phase 3C (QA / 출시):
  P3-8 종합 QA 테스트
  GitHub Releases v1.0.0 업로드
```

---

## 6. 리스크 및 기술적 고려사항

### 리스크 목록

| 리스크 | 심각도 | 영향 | 완화 방안 |
|--------|--------|------|----------|
| P3-1: 다른 스페이스 윈도우 열거 macOS 버전별 동작 차이 | 높음 | 다중 스페이스 기능 미동작 | macOS 13/14/15 각각 실기기 테스트 필수 |
| P3-2: async 전환 중 결과 race condition | 중간 | 잘못된 앱의 패널 표시 | 작업 취소(Task cancellation) 처리 추가 |
| P3-3: 좌표계 수정 시 기존 Dock 감지 회귀 | 중간 | 호버 감지 불동작 | 단일 모니터 기본 구성에서 반드시 검증 |
| P3-5: SPM → .app 번들 변환 과정 복잡성 | 중간 | 빌드 파이프라인 구축 지연 | xcodebuild 사용 또는 Makefile 자동화 |
| P3-6: Sparkle 2 SPM 패키지 크기 | 낮음 | 앱 번들 크기 증가 (약 2MB) | 허용 가능 수준 |
| Private API (_AXUIElementGetWindow) OS 업데이트 시 깨짐 | 중간 | WindowActivator fallback 필요 | frame+title fallback 이미 구현됨 — 유지 |

### macOS API 제약 사항

**CGEventTap과 샌드박스:**
- `CGEvent.tapCreate(tap: .cghidEventTap, ...)` 호출은 `com.apple.security.app-sandbox = false` 필수
- App Sandbox 환경에서는 `CGEvent.tapCreate(tap: .cgSessionEventTap, ...)` 만 가능하지만 이는 동일 세션 이벤트만 감지하므로 Dock 이벤트 수신 불가

**ScreenCaptureKit 권한:**
- macOS 14+에서 `SCScreenshotManager`는 화면 녹화 권한 없이 일부 시나리오에서 동작하나 일반적으로 권한 요청이 필요
- 권한 거부 시 `captureWithCGWindow` fallback으로 자동 전환됨 (현재 구현 그대로)

**SMAppService:**
- SPM CLI 빌드에서는 `SMAppService.mainApp.register()`가 앱 서명이 없으면 실패할 수 있음
- 공증 완료 후 정식 테스트 필요

---

## 7. 에이전트 역할 배분

| 에이전트 | 담당 작업 |
|----------|----------|
| swift-engineer | P3-1, P3-2, P3-3, P3-4, P3-5 (빌드 파이프라인), P3-6 |
| qa-specialist | P3-8 (QA 테스트 매트릭스 실행 및 보고서 작성) |
| senior-designer | P3-7 (아이콘 및 시각 자산 제작) |
| appstore-manager | P3-5 (서명/공증 절차), P3-9 (릴리스 관리), Homebrew Cask 검토 |
| version-manager | P3-9 (버전 체계, CHANGELOG, Git 태그) |

---

## 8. 완료 기준 (Definition of Done)

Phase 3가 완료된 것으로 간주하려면 다음 항목이 모두 충족되어야 한다.

- [ ] 다중 스페이스 윈도우가 미리보기 패널에 표시되고 클릭 시 올바르게 활성화된다
- [ ] WindowEnumerator가 백그라운드에서 실행되어 메인 스레드를 차단하지 않는다
- [ ] DockAXHelper 좌표계가 정확하게 변환되어 비표준 Dock 구성에서도 호버 감지가 정확하다
- [ ] 공증된 .dmg 파일이 Gatekeeper 경고 없이 설치 및 실행된다
- [ ] Sparkle 자동 업데이트가 동작하고 appcast.xml이 호스팅된다
- [ ] 정식 앱 아이콘이 적용되어 있다
- [ ] macOS 13/14/15 및 Dock 하단/좌/우 구성에서 QA 테스트 PASS
- [ ] v1.0.0 Git 태그 및 GitHub Release가 생성되어 있다
- [ ] CHANGELOG.md가 작성되어 있다

---

*이 문서는 Phase 2 완료 시점(2026-03-10) 기준으로 작성되었습니다. 구현 진행 중 발견된 사항은 별도 QA_PHASE3.md에 기록합니다.*
