# DockPeek PM — Persistent Memory

Last updated: 2026-03-09

## 프로젝트 현재 상태

- **현재 단계**: Phase 2 착수 (Phase 1 완전 완료)
- **최신 커밋**: adbe04f (fix: correct AX URL type handling and mouse coordinate system)
- **계획 문서**: docs/PHASE2_PLAN.md (작성 완료)

## 완료된 마일스톤

- Phase 1 전체 완료 (P1-1~P1-4 + QA 이슈 HIGH/MEDIUM 전부 수정)
- QA 리포트: docs/QA_PHASE1.md

## Phase 2 작업 순서 (확정)

```
P2-PRE → P2-6 → P2-5 → [P2-1 || P2-3] → P2-2 → P2-4
```

- P2-PRE: 잔여 QA 수정 3건 (ISSUE-02, ISSUE-06, 주석) — swift-engineer
- P2-6: DockAXHelper 추출 (DockMonitor + PreviewPanelController 중복 AX 코드) — swift-engineer
- P2-5: ThumbnailGenerator 성능 개선 (SCShareableContent 캐싱 TTL 2초, 캐시 상한 50개)
- P2-1: 최소화 윈도우 지원 (P2-3과 병렬 가능)
- P2-3: 패널 fade in/out 애니메이션 (P2-1과 병렬 가능)
- P2-2: 다중 스페이스 윈도우 지원
- P2-4: 환경설정 패널 (UserDefaults, SMAppService는 P3로 이연)

## 핵심 아키텍처 결정사항

- Dock은 항상 primary screen (NSScreen.screens.first)에 위치 — NSScreen.main 사용 금지
- AX 좌표계: CG 좌표(좌상단 원점), Y-flip 시 primaryScreen.frame.height 사용
- WindowActivator: frame+title 근사 매칭 방식 확정 (private API 사용 안 함)
- ThumbnailGenerator: SCScreenshotManager는 macOS 14+ 전용 (#available(macOS 14.0, *))
- PreviewPanel: .canJoinAllSpaces + .stationary 유지 (스페이스 전환 시 패널 유지)

## 주요 파일 경로

- Sources/DockPeek/App/AppDelegate.swift
- Sources/DockPeek/App/DockPeekApp.swift
- Sources/DockPeek/Core/DockMonitor.swift
- Sources/DockPeek/Core/WindowEnumerator.swift
- Sources/DockPeek/Core/ThumbnailGenerator.swift
- Sources/DockPeek/Core/WindowActivator.swift
- Sources/DockPeek/UI/PreviewPanelController.swift
- Sources/DockPeek/UI/WindowThumbnailView.swift
- docs/PROJECT_PLAN.md
- docs/QA_PHASE1.md
- docs/PHASE2_PLAN.md

## 사용자 선호 및 결정사항

- 언어: 한국어로 소통
- 배포 방식: 아직 미결정 (PROJECT_PLAN.md Q2 미확인)
- WindowActivator: frame+title 근사 매칭 (Option B) 사용 확정
- 최소화/다중스페이스 표시: 모두 표시 방향으로 Phase 2에 포함

## 미결 사항 (사용자 확인 필요)

- Q2: 배포 방식 (Direct Distribution vs App Store 대안)
- SMAppService 자동 실행: P2-4 환경설정 패널에서 제외 여부

## 알려진 패턴 및 주의사항

- `as! AXValue` force-cast는 CFGetTypeID() 사전 확인 후 사용 — 안전하다는 주석 필수
- WindowEnumerator의 kCGWindowName은 화면 녹화 권한 없으면 nil 반환 — title이 앱 이름 fallback됨
- SCShareableContent는 매 캡처마다 재호출 중 (P2-5에서 캐싱 예정)
