# DockPeek Phase 2 — 기능 확장 계획서

**작성일:** 2026-03-09
**작성자:** DockPeek PM
**기준 커밋:** adbe04f (fix: correct AX URL type handling and mouse coordinate system)
**목표:** 사용성 및 코드 완성도 향상

---

## 1. Phase 1 완료 상태 확인

### 완료된 Phase 1 작업
- P1-1: WindowActivator frame+title 기반 AX 매칭 구현 (특정 윈도우 포커스 동작)
- P1-2: PreviewPanel 위치 계산 개선 (Dock 방향 동적 감지, primary screen 기준)
- P1-3: 엣지케이스 버그 수정 (빈 윈도우 시 패널 hide, applicationWillTerminate stop())
- P1-4: 권한 안내 UX (CGEventTap 실패 시 Alert + 상태바 경고 아이콘)
- ThumbnailGenerator macOS 14+ 가용성 수정 (SCScreenshotManager 분기)
- AX URL 타입 처리 수정 (CFURL 타입 체크)
- ISSUE-01: NSScreen.main → NSScreen.screens.first (primary screen Y-flip 수정)
- ISSUE-03: positionPanel에서 dockScreen() 사용 (보조 모니터 올바른 화면 기준)
- ISSUE-04: auto-hide Dock 최솟값 보장 (minDockSize = 4)

### Phase 2 전 권장 잔여 수정 (QA_PHASE1.md 기준)
이 항목들은 Phase 2 첫 스프린트에 포함하여 처리한다.

| 항목 | 파일 | 내용 | 담당 |
|------|------|------|------|
| ISSUE-02 | WindowActivator.swift:69 | title fallback 로직 주석 명확화 | swift-engineer |
| ISSUE-06 | AppDelegate.swift:64-71 | showPermissionAlert에서 아이콘 변경을 runModal() 이전으로 이동 | swift-engineer |
| INFO | ThumbnailGenerator.swift:6 | 헤더 주석 "macOS 13+" → "macOS 14+" | swift-engineer |

---

## 2. Phase 2 작업 목록 및 우선순위

### 우선순위 결정 기준
1. **의존성**: 다른 작업의 선행 조건이 되는 작업 우선
2. **리스크 감소**: 코드 중복·구조 문제를 먼저 해결해 후속 작업의 안전성 확보
3. **사용자 체감 가치**: 실사용 시 체감 가능한 개선 우선
4. **복잡도**: 독립적인 단순 작업은 병렬 진행 가능

### 확정된 Phase 2 작업 순서

```
[P2-PRE] 잔여 QA 수정 (ISSUE-02, ISSUE-06, 주석)
    ↓
[P2-6] DockAXHelper 추출 (DockMonitor + PreviewPanelController 중복 AX 코드)
    ↓
[P2-5] ThumbnailGenerator 성능 개선 (SCShareableContent 캐싱, 캐시 상한선)
    ↓         ↓
[P2-1]      [P2-3]    ← 서로 독립적, 병렬 진행 가능
최소화       패널 fade
윈도우       in/out
지원         애니메이션
    ↓         ↓
[P2-2] 다중 스페이스 윈도우 지원
    ↓
[P2-4] 환경설정 패널 (UserDefaults)
```

---

## 3. 작업 상세 명세

### P2-PRE: 잔여 QA 수정 (선행 필수)
**담당**: swift-engineer
**예상 소요**: 30분 이내
**파일**: AppDelegate.swift, WindowActivator.swift, ThumbnailGenerator.swift

**작업 내용**:
1. `AppDelegate.showPermissionAlert()` — `statusItem?.button?.image = ...` 를 `alert.runModal()` 호출 이전으로 이동
2. `WindowActivator.matchesWindow()` — title fallback 로직에 인라인 주석 보강 (target.title이 비어있지 않음을 보장하는 이유 명시)
3. `ThumbnailGenerator` 파일 헤더 주석 6번 줄 `macOS 13+` → `macOS 14+` 수정

**완료 기준**: 세 파일 각각 수정 후 빌드 성공

---

### P2-6: DockAXHelper 공통 유틸 추출
**담당**: swift-engineer
**예상 소요**: 2-3시간
**신규 파일**: `Sources/DockPeek/Core/DockAXHelper.swift`
**수정 파일**: DockMonitor.swift, PreviewPanelController.swift

**배경**: 현재 `DockMonitor.axFrame(of:)` 와 `PreviewPanelController.findDockIconCenter(for:)` 가 거의 동일한 AX 탐색 코드를 반복한다. DockMonitor의 `findHoveredDockApp()` 와 PreviewPanelController의 `findDockIconCenter()` 도 Dock AXUIElement → children → list → items 순회 패턴이 중복된다.

**작업 내용**:
```swift
// DockAXHelper.swift (신규)
enum DockAXHelper {
    /// Dock AXUIElement에서 AXFrame을 추출 (CG 좌표계)
    static func axFrame(of element: AXUIElement) -> CGRect?

    /// Dock에서 특정 앱 아이콘의 AXUIElement 반환
    static func dockIconElement(for bundleID: String, in dockElement: AXUIElement) -> AXUIElement?

    /// AXUIElement의 URL 속성에서 bundleID 추출
    static func bundleID(of element: AXUIElement) -> String?
}
```

**완료 기준**:
- `DockAXHelper.swift` 파일 신규 생성
- `DockMonitor.axFrame(of:)` → `DockAXHelper.axFrame(of:)` 위임
- `PreviewPanelController.findDockIconCenter()` AX 탐색 부분 → `DockAXHelper` 활용
- 빌드 성공, 기존 동작 유지

---

### P2-5: ThumbnailGenerator 성능 개선
**담당**: swift-engineer
**예상 소요**: 2시간
**수정 파일**: Sources/DockPeek/Core/ThumbnailGenerator.swift

**배경**: 현재 매 캡처 시마다 `SCShareableContent.excludingDesktopWindows(...)` 를 호출해 전체 윈도우 목록을 재조회한다. 캐시도 상한선이 없어 장시간 실행 시 메모리 무제한 증가 가능성이 있다.

**작업 내용**:
1. `SCShareableContent` 결과 캐싱
   - 별도 `contentCache` 프로퍼티에 저장
   - TTL: 2초 (빈번한 재조회 방지)
   - 앱 전환 시 또는 명시적 무효화 시 갱신
2. 썸네일 캐시 상한선 도입
   - 최대 50개 항목 유지
   - 초과 시 가장 오래된 항목 제거 (FIFO 또는 LRU)
3. 선택적: 백그라운드 prefetch 검토 (복잡도 높을 경우 P3로 이연)

**완료 기준**:
- `SCShareableContent` 매 호출이 2초 TTL 캐시로 대체됨
- 캐시 항목 수 50개 초과 시 자동 정리
- 기존 썸네일 캡처 품질 동일

---

### P2-1: 최소화 윈도우 지원
**담당**: swift-engineer
**예상 소요**: 3-4시간
**수정 파일**: WindowEnumerator.swift, WindowThumbnailView.swift, WindowActivator.swift

**배경**: `CGWindowListCopyWindowInfo([.optionOnScreenOnly, ...])` 옵션 때문에 최소화된 윈도우가 수집되지 않는다.

**작업 내용**:
1. `WindowEnumerator`: `optionOnScreenOnly` 제거, `isMinimized` 플래그 추가
   ```swift
   struct WindowInfo {
       // 기존 필드 유지
       let isMinimized: Bool  // 신규
   }
   ```
2. `WindowThumbnailCard`: 최소화 윈도우는 앱 아이콘 + "최소화됨" 레이블 표시 (썸네일 없음)
3. `WindowActivator`: 최소화 윈도우 클릭 시 AX `kAXRaiseAction` 또는 `NSApplication.unhide` 시도
   - 감지 방법: AXUIElement에서 `kAXMinimizedAttribute` 확인

**완료 기준**:
- 최소화된 윈도우가 미리보기 패널에 표시됨
- 최소화 윈도우 클릭 시 윈도우가 복원됨
- 일반 윈도우 동작 영향 없음

---

### P2-3: 패널 Fade In/Out 애니메이션
**담당**: swift-engineer
**예상 소요**: 1-2시간
**수정 파일**: Sources/DockPeek/UI/PreviewPanelController.swift

**배경**: 현재 `orderFront` / `orderOut` 직접 호출로 패널이 즉시 나타났다 사라진다. 애니메이션이 없어 시각적으로 거칠다.

**작업 내용**:
```swift
// show() 시: alpha 0 → 1, duration 0.15초, easeOut
panel.alphaValue = 0
panel.orderFront(nil)
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.15
    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
    panel.animator().alphaValue = 1
}

// hide() 시: alpha 1 → 0, duration 0.1초, easeIn, 완료 후 orderOut
NSAnimationContext.runAnimationGroup({ ctx in
    ctx.duration = 0.10
    panel.animator().alphaValue = 0
}, completionHandler: {
    panel.orderOut(nil)
    panel.alphaValue = 1 // 다음 show()를 위해 초기화
})
```

**완료 기준**:
- 패널 등장 시 부드러운 fade in (0.15초)
- 패널 소멸 시 부드러운 fade out (0.1초)
- 빠른 hover 시 애니메이션 중단 및 즉시 전환 처리

---

### P2-2: 다중 스페이스 윈도우 지원
**담당**: swift-engineer
**예상 소요**: 3-4시간
**수정 파일**: WindowEnumerator.swift, WindowThumbnailView.swift

**배경**: `optionOnScreenOnly`를 제거하면 다른 스페이스 윈도우도 수집 가능. 단, 다른 스페이스 윈도우는 썸네일 캡처가 불가능하므로 적절한 fallback UI가 필요하다.

**작업 내용**:
1. `WindowEnumerator`: `isOnCurrentSpace` 필드 실제 활용 또는 제거 결정 후 다른 스페이스 윈도우 수집
   ```swift
   struct WindowInfo {
       // 기존 필드
       let isOnCurrentSpace: Bool  // 기존 isOnScreen 대체
   }
   ```
2. `WindowThumbnailCard`: 다른 스페이스 윈도우는 "다른 스페이스" 레이블 + 앱 아이콘 표시
3. `WindowActivator`: 다른 스페이스 윈도우 클릭 시 해당 스페이스로 전환 시도
   - `NSWorkspace.shared.switchToDesktop(_:)` 또는 AX `kAXRaiseAction` 활용

**완료 기준**:
- 다른 스페이스의 윈도우가 패널에 표시됨 ("다른 스페이스" 표시와 함께)
- 해당 윈도우 클릭 시 스페이스 전환 또는 앱 전면 이동 동작

---

### P2-4: 환경설정 패널 (UserDefaults 기반)
**담당**: swift-engineer
**예상 소요**: 4-6시간
**신규 파일**: `Sources/DockPeek/UI/PreferencesView.swift`, `Sources/DockPeek/App/PreferencesManager.swift`
**수정 파일**: AppDelegate.swift, DockMonitor.swift, PreviewPanelController.swift

**배경**: 호버 딜레이(0.4초), 썸네일 크기(200×130), 패널 갱신 주기 등이 하드코딩되어 있다.

**작업 내용**:
1. `PreferencesManager` 생성
   - `@AppStorage` 또는 `UserDefaults` 기반
   - 설정 항목: 호버 딜레이, 썸네일 크기, 시작 시 자동 실행(`SMAppService`)
2. `PreferencesView` 생성 (SwiftUI)
   - `NSPanel` 또는 `NSWindow`로 표시
3. `AppDelegate.statusBarClicked()` 메뉴에 "환경설정..." 항목 추가
4. `DockMonitor.hoverDelay` → `PreferencesManager` 값 참조로 교체
5. `PreviewPanelController.preferredSize()` → `PreferencesManager` 썸네일 크기 참조

**완료 기준**:
- 메뉴바 메뉴에서 "환경설정..." 클릭 시 설정 패널 열림
- 호버 딜레이 변경 시 즉시 적용
- 앱 재시작 후에도 설정 유지 (UserDefaults 영속성)

---

## 4. 에이전트 할당 계획

| 작업 | 담당 에이전트 | 단계 | 병렬 가능 여부 |
|------|--------------|------|--------------|
| P2-PRE (QA 잔여 수정) | swift-engineer | 1 | 단독 |
| P2-6 (DockAXHelper 추출) | swift-engineer | 2 | 단독 (P2-PRE 완료 후) |
| P2-5 (ThumbnailGenerator 성능) | swift-engineer | 3 | P2-6 완료 후 |
| P2-1 (최소화 윈도우) | swift-engineer | 4 | P2-3과 병렬 가능 |
| P2-3 (Fade 애니메이션) | swift-engineer | 4 | P2-1과 병렬 가능 |
| P2-2 (다중 스페이스) | swift-engineer | 5 | P2-1 완료 후 |
| P2-4 (환경설정 패널) | swift-engineer | 6 | 최종 통합 |
| QA 검증 | qa-specialist | 각 단계 완료 후 | 단계별 |

---

## 5. 리스크 분석

| 리스크 | 심각도 | 내용 | 대응 방안 |
|--------|--------|------|----------|
| 최소화 윈도우 썸네일 캡처 불가 | 중 | 최소화 상태에서는 SCKit/CGWindow 모두 화면에 없어 캡처 불가 | 앱 아이콘 + "최소화됨" 레이블로 fallback UI 제공 |
| 다른 스페이스 윈도우 스위칭 API | 중 | NSWorkspace 스페이스 전환 API가 공개 API로 완전하지 않음 | kAXRaiseAction 우선 시도, 실패 시 앱 활성화만 수행 |
| 환경설정 패널 복잡도 | 중 | SMAppService 자동 실행 설정은 권한/entitlements 변경 필요 | 초기 버전에서는 자동 실행 항목 제외, P3에서 추가 |
| SCShareableContent 캐싱 부작용 | 저 | 2초 TTL 중 새 윈도우 열림 시 목록에 없어 캡처 실패 | 캡처 실패 시 즉시 재조회 fallback 추가 |
| DockAXHelper 리팩터링 중 회귀 | 저 | 중복 코드 제거 중 동작 차이 발생 가능 | 리팩터링 전후 동일 시나리오 수동 검증 필수 |

---

## 6. 마일스톤

| 마일스톤 | 포함 작업 | 목표 완료 |
|---------|---------|---------|
| M2-1: 코드 기반 정리 | P2-PRE, P2-6 | Phase 2 착수 후 Day 1 |
| M2-2: 성능 안정화 | P2-5 | Day 2 |
| M2-3: 핵심 기능 확장 | P2-1, P2-3 | Day 3-4 |
| M2-4: 스페이스 지원 | P2-2 | Day 5 |
| M2-5: 설정 패널 | P2-4 | Day 6-7 |
| M2-QA: Phase 2 QA | 전체 Phase 2 검증 | Day 8 |

---

## 7. swift-engineer 첫 번째 작업 지시서

### 작업: P2-PRE + P2-6 (코드 기반 정리 스프린트)

**목적**: Phase 2 기능 확장 전 코드 품질 기준선 확보

**작업 1 — P2-PRE: 잔여 QA 수정 (3개 항목)**

파일: `/Users/juholee/DockPeek/Sources/DockPeek/App/AppDelegate.swift`
- `showPermissionAlert()` 함수 (64-71번 줄): 상태바 아이콘 변경 코드(69-71번 줄)를 `alert.runModal()` 호출(64번 줄) 이전으로 이동

파일: `/Users/juholee/DockPeek/Sources/DockPeek/Core/WindowActivator.swift`
- `matchesWindow()` 함수 (64-73번 줄): title fallback 로직에 주석 보강
  - `target.title`이 `WindowEnumerator`에서 항상 앱 이름 이상의 값을 가짐을 명시
  - 두 타이틀 모두 비어있는 edge case에서 `return true`가 의도적임을 명시

파일: `/Users/juholee/DockPeek/Sources/DockPeek/Core/ThumbnailGenerator.swift`
- 6번 줄 주석: `macOS 13+` → `macOS 14+` 변경

**작업 2 — P2-6: DockAXHelper 추출**

신규 파일: `/Users/juholee/DockPeek/Sources/DockPeek/Core/DockAXHelper.swift`
- `DockMonitor.axFrame(of:)` 와 동일한 로직을 `DockAXHelper.axFrame(of:)` 정적 메서드로 추출
- Dock 아이콘 AX 탐색 공통 로직(URL → bundleID 매칭) 추출
- `DockMonitor.swift` 와 `PreviewPanelController.swift` 에서 중복 코드를 `DockAXHelper` 호출로 교체

**커밋 메시지 가이드라인**:
- P2-PRE 완료 시: `fix: apply remaining Phase 1 QA recommendations`
- P2-6 완료 시: `refactor: extract DockAXHelper to eliminate AX traversal duplication`

**완료 후 PM에게 보고 사항**:
- 변경된 파일 목록
- 빌드 성공 여부
- DockAXHelper에 추출된 함수 목록 및 시그니처

---

*이 문서는 Phase 2 진행 중 갱신됩니다. 최종 상태는 Phase 2 완료 후 QA 리포트(docs/QA_PHASE2.md)와 함께 확정됩니다.*
