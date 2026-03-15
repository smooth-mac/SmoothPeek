# SmoothPeek PM — Persistent Memory

Last updated: 2026-03-10

## 프로젝트 현재 상태

- **현재 단계**: Phase 3 계획 완료 (docs/PHASE3_PLAN.md), Phase 3 착수 대기 중
- **최신 커밋**: Phase 2 QA 이슈 수정 포함 6개 소스 파일 미커밋 상태 (커밋 필요)
- **배포 방식 확정**: Direct Distribution (GitHub Releases + DMG). App Store 불가 (CGEventTap 샌드박스 비호환)

## 완료된 마일스톤

- Phase 1 전체 완료 (P1-1~P1-4 + QA 이슈 HIGH/MEDIUM 전부 수정)
- Phase 2 전체 완료 (P2-PRE, P2-6, P2-5, P2-1, P2-3, P2-4)
- QA_PHASE2.md 작성 완료 (docs/QA_PHASE2.md)
- 프로젝트 리네임: DockPeek → SmoothPeek
- Phase 3 계획서 작성 완료 (docs/PHASE3_PLAN.md — 2026-03-10)

## Phase 3 작업 목록

| ID | 작업 | 우선순위 | 복잡도 |
|----|------|----------|--------|
| P3-1 | 다중 스페이스 윈도우 지원 (Phase 2 이연) | 높음 | 높음 |
| P3-2 | WindowEnumerator 백그라운드 실행 | 높음 | 중간 |
| P3-3 | DockAXHelper 좌표계 정확성 수정 | 중간 | 중간 |
| P3-4 | AppSettings.Keys 접근성 개선 | 낮음 | 낮음 |
| P3-5 | 앱 서명 및 공증 설정 | 높음 | 중간 |
| P3-6 | Sparkle 자동 업데이트 통합 | 중간 | 중간 |
| P3-7 | 앱 아이콘 및 시각 자산 | 중간 | 낮음 |
| P3-8 | 종합 QA 테스트 (macOS 13/14/15) | 높음 | 낮음 |
| P3-9 | 버전 관리 / 릴리스 태깅 v1.0.0 | 중간 | 낮음 |

Phase 3A(기능: P3-3, P3-4, P3-1, P3-2) → Phase 3B(배포: P3-7, P3-5, P3-6, P3-9) → Phase 3C(QA/출시: P3-8)

## Phase 2 미커밋 수정 현황

| 이슈 | 심각도 | 상태 |
|------|--------|------|
| ISSUE-P2-01 | MEDIUM | 미수정 (P3-3에서 처리 — 좌표계 proper 변환) |
| ISSUE-P2-02 | MEDIUM | 수정 완료 (미커밋 — SCShareableContent 미스 시 캐시 무효화) |
| ISSUE-P2-03 | LOW | INFO — 50개 상한선에서 O(n) 무시 가능 |
| ISSUE-P2-04 | HIGH | 수정 완료 (미커밋 — thumbSize AppSettings 연동) |
| ISSUE-P2-05 | MEDIUM | 수정 완료 (미커밋 — lastLaunchAtLoginError UI 표시) |
| ISSUE-P2-06 | LOW | 수정 완료 (미커밋 — isMiniaturized 체크 추가) |
| INFO: @StateObject | INFO | 수정 완료 → @ObservedObject 변경 |
| INFO: hoverDelay 키 중복 | INFO | P3-4에서 처리 |

## 핵심 아키텍처 결정사항

- Dock은 항상 primary screen (NSScreen.screens.first)에 위치 — NSScreen.main 사용 금지
- AX 좌표계: AX position은 NS 좌표(좌하단 원점). Dock hit-test는 현재 근사 비교 중 (P3-3에서 proper 변환 예정)
- WindowActivator: _AXUIElementGetWindow 비공개 API로 CGWindowID 직접 매칭 (1순위) + frame+title (2순위 fallback)
- ThumbnailGenerator: SCScreenshotManager macOS 14+ 전용, SCShareableContent 2.5초 TTL 캐싱 + 미스 시 즉시 무효화
- PreviewPanel: .canJoinAllSpaces + .stationary 유지 (스페이스 전환 시 패널 유지)
- WindowEnumerator: 두 쿼리 방식 (onScreenOnly + 전체에서 isMinimized 필터) + CGWindowID 오름차순 정렬
- 배포: Direct Distribution (GitHub Releases + DMG + Sparkle). App Store 불가 판정

## 주요 파일 경로

- Sources/SmoothPeek/App/AppDelegate.swift
- Sources/SmoothPeek/App/SmoothPeekApp.swift
- Sources/SmoothPeek/App/AppSettings.swift
- Sources/SmoothPeek/Core/DockMonitor.swift
- Sources/SmoothPeek/Core/DockAXHelper.swift
- Sources/SmoothPeek/Core/WindowEnumerator.swift
- Sources/SmoothPeek/Core/ThumbnailGenerator.swift
- Sources/SmoothPeek/Core/WindowActivator.swift
- Sources/SmoothPeek/UI/PreviewPanelController.swift
- Sources/SmoothPeek/UI/WindowThumbnailView.swift
- Sources/SmoothPeek/UI/SettingsView.swift
- docs/PROJECT_PLAN.md / docs/QA_PHASE1.md / docs/PHASE2_PLAN.md / docs/QA_PHASE2.md / docs/PHASE3_PLAN.md

## 사용자 선호 및 결정사항

- 언어: 한국어로 소통
- WindowActivator: CGWindowID 직접 매칭(_AXUIElementGetWindow) + frame+title fallback 확정
- 환경설정 패널: 완료 (호버딜레이, 썸네일크기, 로그인시자동실행 포함)
- 다중 스페이스 윈도우 지원: Phase 3 P3-1에서 구현
- 배포 방식: Direct Distribution 확정 (App Store 불가 판정)

## 알려진 패턴 및 주의사항

- `as! AXValue` force-cast는 CFGetTypeID() 사전 확인 후 사용 — 안전하다는 주석 필수
- WindowEnumerator의 kCGWindowName은 화면 녹화 권한 없으면 nil 반환 — title이 앱 이름 fallback됨
- _AXUIElementGetWindow는 비공개 API이나 macOS 10.10+에서 안정적으로 사용 가능 (Direct Distribution에서만 허용)
- @AppStorage + didSet 조합: Swift 싱글톤에서는 동작하나 @ObservedObject로 사용해야 함
- NSAnimationContext completion handler는 main thread 보장 없음 → Task { @MainActor } 래핑 필수
- preferredSize(for:)와 WindowThumbnailCard.thumbSize는 동일한 로직으로 동기화 필수 (desync 시 패널 크기 틀어짐)
- P3-1 구현 시: isOnscreen==false인 윈도우를 최소화 vs 다른 스페이스로 구분하려면 AX kAXMinimizedAttribute 교차 확인 필요
- P3-2 구현 시: CGWindowList 쿼리는 백그라운드 가능, AX 쿼리는 메인 스레드 권장 — 분리 설계 필요
