# SmoothPeek

macOS에서 Dock 아이콘에 마우스를 올리면 Windows 작업 표시줄처럼 해당 앱의 윈도우 미리보기를 보여주는 유틸리티 앱.

---

## 작동 방식

```
마우스 이동
    │
    ▼
CGEventTap (전역 이벤트 감청)
    │
    ▼
Dock 영역 감지? ──NO──▶ 아무것도 안 함
    │
   YES
    ▼
AXUIElement로 Dock 아이콘 탐색
→ 호버 중인 앱 식별 (bundleID 기반)
    │
    ▼ (0.4초 딜레이 후)
WindowEnumerator
→ CGWindowList로 앱의 윈도우 목록 수집
    │
    ▼
ThumbnailGenerator
→ ScreenCaptureKit으로 윈도우 스크린샷
    │
    ▼
PreviewPanelController
→ NSPanel (HUD, floating) 위에 SwiftUI 뷰 표시
    │
    ▼ (클릭 시)
WindowActivator
→ 앱 활성화 + AXUIElement로 윈도우 포커스
```

---

## 프로젝트 구조

```
SmoothPeek/
├── Package.swift
├── SmoothPeek.entitlements          # 권한 설정
└── Sources/SmoothPeek/
    ├── App/
    │   ├── SmoothPeekApp.swift      # @main 진입점
    │   └── AppDelegate.swift      # 상태바 아이템, 컴포넌트 연결
    ├── Core/
    │   ├── DockMonitor.swift      # CGEventTap + AX API로 호버 감지
    │   ├── WindowEnumerator.swift # CGWindowList로 윈도우 목록
    │   ├── ThumbnailGenerator.swift # ScreenCaptureKit 캡처
    │   └── WindowActivator.swift  # 윈도우 활성화
    └── UI/
        ├── PreviewPanelController.swift # NSPanel 관리, 위치 계산
        └── WindowThumbnailView.swift    # SwiftUI 미리보기 UI
```

---

## 필요 권한

| 권한 | 목적 |
|------|------|
| **접근성 (Accessibility)** | CGEventTap 생성, Dock AXUIElement 탐색 |
| **화면 녹화 (Screen Recording)** | ScreenCaptureKit으로 윈도우 캡처 |

> **앱 샌드박스는 반드시 OFF** 해야 함 (CGEventTap이 샌드박스 환경에서 동작 불가)

---

## Xcode 설정 방법

1. Xcode에서 새 macOS App 프로젝트 생성
2. 소스 파일을 프로젝트에 추가
3. `Signing & Capabilities` 탭:
   - **App Sandbox** 체크 해제
   - **Accessibility** 추가
4. `SmoothPeek.entitlements` 연결
5. `Info.plist`에 추가:
   ```xml
   <key>NSAccessibilityUsageDescription</key>
   <string>Dock 아이콘 호버 감지에 필요합니다</string>
   <key>NSScreenCaptureUsageDescription</key>
   <string>윈도우 미리보기 생성에 필요합니다</string>
   ```

---

## 알려진 한계 및 TODO

### 핵심 미구현 사항

- [ ] **WindowActivator**: `CGWindowID ↔ AXUIElement` 매핑
  - Private API `_AXUIElementGetWindow` 사용 or frame 기반 근사 매칭 구현 필요
- [ ] **DockMonitor**: Dock 아이콘 위치를 AXUIElement 없이 탐색 시 fallback 처리
- [ ] **패널 위치**: 실제 Dock 크기/위치 동적 계산 (현재는 70px 하드코딩)
- [ ] **Dock 방향**: 좌/우 Dock 배치 대응

### 개선 사항

- [ ] 미리보기 패널 애니메이션 (fade in/out)
- [ ] 최소화된 윈도우 처리 (Dock에서 복원)
- [ ] 여러 스페이스(Mission Control)의 윈도우 표시
- [ ] 미리보기 갱신 주기 설정
- [ ] 다크/라이트 모드 자동 대응

---

## 주요 API 참고

| API | 용도 |
|-----|------|
| `CGEventTap` | 전역 마우스 이벤트 감청 |
| `AXUIElementCreateApplication` | 접근성 기반 UI 탐색 |
| `CGWindowListCopyWindowInfo` | 윈도우 메타데이터 수집 |
| `SCShareableContent` | ScreenCaptureKit 콘텐츠 목록 |
| `SCScreenshotManager.captureImage` | 윈도우 스크린샷 |
| `NSPanel` (hudWindow, floating) | 항상 위에 떠 있는 패널 |
