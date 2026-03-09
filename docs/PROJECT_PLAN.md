# SmoothPeek 프로젝트 플랜

> 작성일: 2026-03-09
> 기준 소스: `Sources/SmoothPeek/` (App 2개, Core 4개, UI 2개 파일)

---

## 1. 프로젝트 개요

SmoothPeek는 macOS Dock 아이콘에 마우스를 올렸을 때 Windows 작업 표시줄 스타일의 윈도우 미리보기 패널을 띄워주는 메뉴바 유틸리티 앱이다.

### 핵심 동작 흐름 (현재 구현 기준)

```
마우스 이동
 → CGEventTap (전역 이벤트 감청, 접근성 권한 필요)
 → DockMonitor: AXUIElement로 Dock 아이콘 탐색, bundleID 식별, 0.4초 딜레이
 → WindowEnumerator: CGWindowListCopyWindowInfo로 앱 윈도우 목록 수집
 → ThumbnailGenerator: ScreenCaptureKit(macOS 13+) 또는 CGWindowList fallback으로 캡처
 → PreviewPanelController: NSPanel(HUD, floating) 위에 SwiftUI 패널 표시
 → (클릭 시) WindowActivator: 앱 활성화 + AXUIElement로 윈도우 포커스 시도
```

### 기술 스택

| 항목 | 선택 |
|------|------|
| 언어 | Swift 5.9 |
| 빌드 시스템 | Swift Package Manager (`swift-tools-version: 5.9`) |
| 최소 지원 OS | macOS 13 Ventura |
| UI 프레임워크 | SwiftUI (썸네일 뷰) + AppKit (NSPanel, NSStatusItem) |
| 캡처 API | ScreenCaptureKit (주) / CGWindowList (fallback) |
| 접근성 API | AXUIElement, CGEventTap |
| 앱 형태 | 메뉴바 앱 (`.accessory` activation policy, Dock 아이콘 없음) |

---

## 2. 현재 상태 분석

### 2-1. App 레이어

#### `SmoothPeekApp.swift` — 완성도: 완료
- `@main` 진입점. `NSApplicationDelegateAdaptor`로 `AppDelegate` 연결.
- `Settings { EmptyView() }` Scene만 존재 — 별도 윈도우 없음. 의도한 구조.

#### `AppDelegate.swift` — 완성도: 기본 완료 / 기능 확장 여지 큼
- 상태바 아이콘(`macwindow.on.rectangle`) 설정 완료.
- 메뉴는 "SmoothPeek 실행 중" + 종료만 존재 — 환경설정 진입점 없음.
- `checkPermissions()`: 접근성 권한 요청(`kAXTrustedCheckOptionPrompt`)은 구현됨. 화면 녹화 권한은 ScreenCaptureKit 첫 사용 시 OS가 자동 요청하는 방식에 의존 — 명시적 사전 안내 없음.
- `handleHover()`: 윈도우가 0개이면 패널을 숨기지 않고 그냥 `return`함. 이전 패널이 남아있을 수 있음 (잠재적 버그).

---

### 2-2. Core 레이어

#### `DockMonitor.swift` — 완성도: 핵심 로직 완료 / 엣지케이스 미처리
- CGEventTap `.cghidEventTap` + `.listenOnly` 방식으로 전역 마우스 이벤트 수신. 구조 안정적.
- 좌표계 변환 구현: CG 좌표(좌상단 원점) → NS 좌표(좌하단 원점). `NSScreen.main?.frame.height` 사용 — 다중 모니터 환경에서 주 화면이 아닌 Dock 위치 처리는 미검증.
- 호버 딜레이: 0.4초(`hoverDelay`), 호버 종료 딜레이: 0.2초. 상수로 분리되어 있으나 사용자 설정 불가.
- `findHoveredDockApp()`: Dock AXElement의 `kAXListRole` 자식만 탐색 — 트래시, 구분선, 폴더 등 비앱 요소에 대한 처리 없음.
- `runningApp(for:)`: `kAXURLAttribute`에서 번들 경로를 추출해 번들 ID를 얻는 방식. 실행 중이 아닌 앱(Dock에 고정만 된 앱)은 `NSWorkspace.shared.runningApplications`에서 매칭 실패 → `nil` 반환. 실행 중이 아닌 앱에 대한 별도 처리 없음.
- `stop()` 메서드 구현됨 — 호출하는 곳은 현재 없음 (앱 종료 시 리소스 해제 누락 가능성).

#### `WindowEnumerator.swift` — 완성도: 기본 완료 / 제약 명확
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` 사용.
- `layer == 0` 필터로 일반 앱 윈도우만 수집 — 미니멀하고 명확한 기준.
- **최소화된 윈도우는 `onScreenOnly` 옵션 때문에 목록에서 제외됨** — README에 TODO로 기재됨.
- **다른 스페이스의 윈도우도 제외됨** — Mission Control 연동 미지원.
- `WindowInfo.isOnScreen`은 항상 `true`로 고정 — 실질적으로 사용되지 않는 필드.

#### `ThumbnailGenerator.swift` — 완성도: 구조 완료 / 성능 튜닝 필요
- `@MainActor` 싱글톤. `async` 인터페이스로 호출측과 깔끔하게 분리.
- 캐시 TTL 0.5초로 동일 윈도우 반복 요청 차단. 캐시는 메모리 딕셔너리 — 앱 종료 전까지 누적될 수 있음 (상한선 없음).
- macOS 13+ 분기: `SCScreenshotManager.captureImage` 사용. Retina 대응(`size * 2`) 구현됨.
- SCKit 실패 시 `CGWindowListCreateImage` fallback 내장. 안전하지만 SCKit 실패 원인 진단 로그가 단순(`print`).
- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` 호출 — 매 캡처마다 전체 콘텐츠 목록을 재요청함. 성능 개선 여지 있음.

#### `WindowActivator.swift` — 완성도: 미완성 (핵심 기능 불동작)
- `activate(options: [.activateIgnoringOtherApps])` 로 앱 전체 활성화는 동작.
- **`matchesWindowID(_:targetID:)` 함수가 항상 `false`를 반환** — 특정 윈도우 포커스 기능이 실제로는 동작하지 않음.
- 코드 내 주석에 두 가지 해결 방향이 명시됨:
  - Option A: `dlsym`으로 `_AXUIElementGetWindow` private symbol 로드
  - Option B: 윈도우 frame 기반 근사 매칭
- `_ = idValue` 구문으로 컴파일러 경고 억제 — 임시 코드 흔적.

---

### 2-3. UI 레이어

#### `PreviewPanelController.swift` — 완성도: 기본 완료 / 위치 계산 하드코딩
- `NSPanel(styleMask: [.nonactivatingPanel, .hudWindow, .borderless])` — 패널이 포커스를 가져가지 않는 올바른 설정.
- `collectionBehavior: [.canJoinAllSpaces, .stationary]` — 스페이스 전환 시에도 패널 유지.
- `preferredSize(windowCount:)`: 열 최대 4개, 썸네일 200×130, 패딩 12px로 하드코딩. 1열 기준 212px 폭, 4열 기준 848px 폭.
- `positionPanel()`: **Dock 높이를 70px로 하드코딩**. 실제 Dock 크기, 확대 효과, 좌/우 Dock 방향 미대응.
- `findDockIconCenter()`: `PreviewPanelController` 내에서 Dock AXUIElement를 직접 재탐색 — `DockMonitor`에서 이미 수행한 탐색과 중복. 로직 중복.
- 같은 앱 재호버 시 패널 유지 로직 있음 (`processIdentifier` 비교).

#### `WindowThumbnailView.swift` — 완성도: UI 완료 / 세부 polish 필요
- `PreviewPanelView`: 앱 아이콘 + 앱 이름 헤더 + `LazyVGrid` 썸네일 그리드.
- `WindowThumbnailCard`: hover 시 `accentColor` 테두리 + `scaleEffect(1.03)` 애니메이션(`spring`). 자연스러운 피드백.
- 배경: `.ultraThinMaterial` + 흰색 테두리 0.15 opacity — macOS 네이티브 느낌.
- 썸네일 로딩 중 `ProgressView` 표시.
- **패널 fade in/out 애니메이션 없음** — `orderFront` / `orderOut` 직접 호출.
- **다크/라이트 모드 대응**: `.ultraThinMaterial`은 자동 대응. 텍스트 색상은 `.white`로 하드코딩 — 라이트 모드에서 가독성 저하 가능.
- SwiftUI Preview용 더미 데이터 구현됨 (`PreviewPanelView_Previews`).

---

## 3. 로드맵

### Phase 1: 안정화 (목표: 실제 일상 사용 가능한 수준)

#### P1-1. WindowActivator 완성 [블로커]
- `CGWindowID ↔ AXUIElement` 매핑 구현.
- 우선 frame 기반 근사 매칭(Option B)으로 구현 후, private API 방식(Option A) 검토.
- 현재 모든 클릭이 윈도우를 바꾸지 못하고 앱만 전면으로 올라오는 문제 해결.

#### P1-2. 패널 위치 계산 개선
- Dock 높이 70px 하드코딩 제거.
- `NSScreen.visibleFrame`과 Dock AXUIElement frame을 조합해 실제 Dock 크기 계산.
- 좌/우 Dock 배치 감지 및 패널 위치 조정.

#### P1-3. 엣지케이스 버그 수정
- `handleHover()`에서 `windows.isEmpty`일 때 기존 패널을 숨기지 않는 문제 수정.
- `AppDelegate.applicationWillTerminate`에서 `dockMonitor?.stop()` 호출.
- `WindowInfo.isOnScreen` 필드 실제 사용 또는 제거.

#### P1-4. 권한 안내 UX
- 앱 최초 실행 시 접근성 / 화면 녹화 권한 모두 사전 안내하는 온보딩 화면 또는 알림 추가.
- 권한 미부여 시 메뉴바 아이콘에 시각적 표시.

---

### Phase 2: 기능 확장 (목표: 사용성 및 완성도 향상)

#### P2-1. 최소화 윈도우 지원
- `CGWindowListCopyWindowInfo` 옵션에서 `optionOnScreenOnly` 제거 후 별도 필터링.
- 최소화 윈도우는 썸네일 대신 앱 아이콘 + "최소화됨" 표시.
- 클릭 시 `NSApplication.shared.deminimize` 또는 AX `kAXRaiseAction` 활용.

#### P2-2. 다중 스페이스 윈도우 지원
- `CGWindowListCopyWindowInfo` 옵션 조정으로 다른 스페이스 윈도우 수집.
- 스페이스 정보 표시 (선택적).

#### P2-3. 패널 애니메이션
- `NSPanel.animator().alphaValue` 또는 Core Animation으로 fade in/out 구현.
- `PreviewPanelController.show()` / `hide()` 에 애니메이션 추가.

#### P2-4. 환경설정 패널
- 메뉴바 메뉴에 "환경설정..." 항목 추가.
- 설정 항목 후보:
  - 호버 딜레이 (현재 0.4초 하드코딩)
  - 썸네일 크기
  - 패널 갱신 주기
  - 시작 시 자동 실행 (`SMAppService`)

#### P2-5. ThumbnailGenerator 성능 개선
- `SCShareableContent` 결과 캐싱 (일정 주기로만 재조회).
- 캐시 최대 항목 수 제한.
- 백그라운드 사전 로딩(prefetch) 검토.

#### P2-6. 코드 중복 제거
- `DockMonitor`와 `PreviewPanelController` 양쪽에 흩어진 Dock AXElement 탐색 로직을 단일 `DockAXHelper` 유틸로 추출.

---

### Phase 3: 출시 준비 (목표: App Store 또는 직접 배포)

#### P3-1. 앱 서명 및 공증 (Notarization)
- Developer ID 서명 설정.
- `SmoothPeek.entitlements` 최종 검토 (샌드박스 OFF 명시, 권한 키 확인).
- `xcrun notarytool` 공증 파이프라인 구성.

#### P3-2. 배포 방식 결정
- **직접 배포 (권장)**: CGEventTap은 App Sandbox와 호환 불가 → App Store 제출 불가능. DMG 또는 Homebrew Cask를 통한 직접 배포가 현실적.
- App Store 우회 방안 검토: 접근성 기반 대신 다른 이벤트 감지 방식으로 샌드박스 내 동작 가능 여부 조사.

#### P3-3. 자동 업데이트
- Sparkle 프레임워크 통합 (직접 배포 시).
- 업데이트 피드 및 릴리스 노트 관리 프로세스 수립.

#### P3-4. 품질 보증
- 주요 macOS 버전(13, 14, 15) 테스트.
- 다중 모니터 환경 테스트.
- 좌/우 Dock 배치 테스트.
- 고해상도(Retina) / 일반 해상도 혼합 환경 테스트.

#### P3-5. 앱 아이콘 및 스크린샷
- 정식 앱 아이콘 디자인 (현재 시스템 SF Symbol `macwindow.on.rectangle` 사용 중).
- 웹사이트 / GitHub Releases 페이지용 스크린샷.

---

## 4. 기술적 과제

### [고] WindowActivator의 CGWindowID ↔ AXUIElement 매핑 불가
- `matchesWindowID()` 함수가 항상 `false` 반환 — 이 한 가지 이유로 "윈도우 선택" 기능 전체가 동작하지 않음.
- `_AXUIElementGetWindow`는 private API로 App Store 심사 통과 불가 / 공증된 앱에서도 사용 불확실.
- **권장 접근**: 먼저 frame + title 기반 근사 매칭으로 실용적인 구현, 이후 신뢰도 측정.

### [고] Dock 위치 하드코딩
- `dockHeight: CGFloat = 70` 하드코딩. Dock 확대 효과, 작은 Dock 설정, 좌/우 배치 시 패널이 엉뚱한 위치에 표시됨.
- `NSScreen.main?.visibleFrame`과 Dock AXUIElement의 실제 frame을 사용해 동적 계산 필요.

### [중] AX 탐색 로직 중복
- `DockMonitor.findHoveredDockApp()` 와 `PreviewPanelController.findDockIconCenter()` 가 거의 동일한 AX 탐색 코드를 반복.
- Dock AXUIElement 탐색 결과를 `DockMonitor`가 콜백으로 전달하거나 공유 헬퍼로 추출해야 함.

### [중] CGEventTap 생성 실패 시 복구 없음
- `setupEventTap()` 실패 시 `print`만 하고 종료. 사용자는 앱이 왜 동작하지 않는지 알 수 없음.
- 실패 원인(접근성 권한 미부여)을 UI로 안내하고, 권한 부여 후 재시도하는 흐름 필요.

### [중] 다중 모니터 / 비주화면 Dock 미지원
- `NSScreen.main?.frame.height`로 좌표 변환 — Dock이 주 화면이 아닌 화면에 있을 경우 좌표 오차 발생.
- Dock이 있는 화면을 동적으로 감지해야 함.

### [저] ThumbnailGenerator 캐시 무제한 증가
- 캐시 딕셔너리에 상한선 없음. 오래 실행하면 메모리 누수 가능성.
- LRU 또는 최대 항목 수(예: 50개) 제한 추가 권장.

### [저] 앱 종료 시 EventTap 미해제
- `AppDelegate`에 `applicationWillTerminate` 없음 → `DockMonitor.stop()` 미호출.
- 영향은 미미하지만 깔끔한 리소스 해제를 위해 추가 필요.

---

## 5. 에이전트 역할 분담

### swift-engineer
**담당**: 모든 Swift 소스코드 구현 및 리팩터링

우선순위 작업:
1. `WindowActivator.matchesWindowID()` — frame + title 기반 매핑 구현 (Phase 1 블로커)
2. `PreviewPanelController.positionPanel()` — Dock 높이 동적 계산 (AXUIElement frame 활용)
3. `DockAXHelper` 유틸 추출 — DockMonitor / PreviewPanelController 중복 AX 탐색 코드 통합
4. `AppDelegate.applicationWillTerminate` 추가, `handleHover()` 빈 윈도우 시 hide 처리
5. Phase 2: 최소화 윈도우 지원, 패널 fade 애니메이션, 환경설정 패널
6. Phase 3: Sparkle 통합

### qa-specialist
**담당**: 테스트 계획 수립 및 품질 검증

우선순위 작업:
1. Phase 1 완료 후 핵심 시나리오 테스트 매트릭스 작성:
   - macOS 13 / 14 / 15 × 단일 모니터 / 다중 모니터
   - Dock 하단 / 좌측 / 우측 배치
   - Retina / 비-Retina 디스플레이
2. WindowActivator 매핑 정확도 검증 (다중 윈도우 앱에서 올바른 윈도우가 활성화되는지)
3. 권한 미부여 상태 앱 동작 검증
4. 메모리 누수 모니터링 (ThumbnailGenerator 캐시, CGEventTap 유지 시)
5. Phase 3: 배포 전 최종 회귀 테스트

### senior-designer
**담당**: UI/UX 디자인 및 시각적 완성도

우선순위 작업:
1. 공식 앱 아이콘 디자인 (현재 SF Symbol 임시 사용)
2. 패널 fade in/out 애니메이션 스펙 정의 (타이밍, 커브)
3. 라이트 모드 대응 개선 (현재 텍스트 `.white` 하드코딩으로 라이트 모드 가독성 문제)
4. 환경설정 패널 UI 설계
5. 썸네일 hover 상태 시각 피드백 검토 (현재 `scaleEffect(1.03)` + `accentColor` 테두리)
6. Phase 3: 웹사이트 / GitHub용 스크린샷, 데모 GIF 제작

### appstore-manager
**담당**: 배포 전략 및 출시 관리

우선순위 작업:
1. **배포 채널 확정**: CGEventTap의 App Sandbox 비호환 문제로 App Store 직접 제출 불가 여부 최종 판단 및 대안(Direct Distribution, Homebrew Cask) 선택.
2. Developer ID 인증서 및 공증(Notarization) 프로세스 준비.
3. `SmoothPeek.entitlements` 파일 내용 확인 및 배포용 최종 권한 설정.
4. GitHub Releases 페이지 구성, 릴리스 노트 템플릿 작성.
5. Phase 3: 사용자 피드백 채널(GitHub Issues 등) 운영 계획 수립.

### version-manager
**담당**: 버전 관리, 브랜치 전략, 릴리스 태깅

우선순위 작업:
1. 브랜치 전략 정의 (`main`, `develop`, feature 브랜치).
2. 버전 체계 수립: `MAJOR.MINOR.PATCH` — Phase 1 완료 = `0.1.0`, Phase 2 완료 = `0.5.0`, Phase 3 출시 = `1.0.0`.
3. `Package.swift`에 현재 버전 정보 없음 — `CFBundleShortVersionString` 관리 방식 결정.
4. Phase별 마일스톤 및 태그 관리.
5. CHANGELOG.md 유지 관리.

---

## 6. 확인 요청

진행 전 방향성 결정이 필요한 항목입니다. 각 항목에 대한 의견을 주시면 로드맵에 반영하겠습니다.

---

### Q1. WindowActivator 구현 방식
**현황**: `matchesWindowID()` 가 `false` 반환으로 특정 윈도우 포커스 불동작.
**옵션**:
- A) `_AXUIElementGetWindow` private API 사용 — 정확하지만 공증 실패 또는 OS 업데이트 시 깨질 위험
- B) frame + title 근사 매칭 — 안정적이지만 같은 크기의 윈도우가 여러 개일 때 오매칭 가능성

**→ 어떤 방식으로 진행할까요? 또는 두 방식을 모두 시도해보고 결과를 비교할까요?**

---

### Q2. App Store vs. 직접 배포
**현황**: CGEventTap은 App Sandbox와 호환 불가 → App Store 제출이 구조적으로 불가능.
**옵션**:
- A) Direct Distribution (GitHub Releases, 개발자 웹사이트) + Developer ID 공증
- B) Homebrew Cask 등록으로 설치 편의성 확보
- C) 앱 구조를 변경해 App Store 호환성 확보 (CGEventTap 대신 다른 방식 탐색 — 기능 제약 가능성)

**→ 배포 방식을 결정해주세요. 이 결정에 따라 entitlements 설정과 빌드 파이프라인이 달라집니다.**

---

### Q3. 다중 모니터 / 비주화면 Dock 지원 범위
**현황**: `NSScreen.main` 기준 좌표 사용. 주 화면이 아닌 곳에 Dock이 있으면 오동작.
**옵션**:
- A) Phase 1에서 즉시 수정 (다중 모니터 환경 사용자를 위해 필수)
- B) Phase 2로 미룸 (단일 모니터 환경 먼저 안정화 후 진행)

**→ 우선순위를 결정해주세요.**

---

### Q4. 최소화 윈도우 및 다른 스페이스 윈도우 표시 여부
**현황**: 현재 "화면에 보이는 현재 스페이스 윈도우"만 표시. 최소화 및 다른 스페이스 윈도우는 미표시.
**옵션**:
- A) 모두 표시 (Exposé/Mission Control 스타일 — 더 완성도 높으나 복잡도 증가)
- B) 최소화 윈도우만 추가 표시 (현실적인 중간 단계)
- C) 현행 유지 (현재 스페이스 온스크린 윈도우만)

**→ 제품 방향성을 알려주세요.**

---

### Q5. 환경설정 UI 구현 시점
**현황**: 현재 호버 딜레이(0.4초), 썸네일 크기(200×130) 등이 하드코딩.
**옵션**:
- A) Phase 1에서 기본 설정 저장(`UserDefaults`) 먼저 — UI는 Phase 2
- B) Phase 2에서 설정 저장과 UI를 함께 구현
- C) 출시 후 사용자 피드백 보고 우선순위 결정

**→ 어떤 시점을 원하시나요?**

---

*이 문서는 코드 분석 시점(2026-03-09) 기준입니다. 코드 변경 시 갱신이 필요합니다.*
