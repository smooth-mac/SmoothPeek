# DockPeek QA Specialist — Persistent Memory

## Project Structure
- Project renamed DockPeek → SmoothPeek (commit 3af0e7f)
- Swift Package Manager project; Package.swift minimum deployment: macOS 14 (updated in App Store port)
- Source root: `Sources/SmoothPeek/` with subdirs `App/`, `Core/`, `UI/`
- Key files: AppDelegate, DockMonitor, DockAXHelper, WindowEnumerator, WindowActivator, ThumbnailGenerator, PreviewPanelController, WindowThumbnailView, AppSettings, SettingsView
- Docs in `docs/`: QA_PHASE1.md, QA_PHASE2.md, PHASE2_PLAN.md, PROJECT_PLAN.md, APPSTORE_REDESIGN_PLAN.md
- Build: `scripts/build_release.sh` + `Makefile`; App Store requires Xcode project (not SPM alone)

## Architecture Patterns
- `DockMonitor` (App Store port): NSEvent.addGlobalMonitorForEvents(.mouseMoved) — NOT CGEventTap
- `ThumbnailGenerator`: @MainActor singleton; SCKit-only (CGWindowListCreateImage removed); two-level cache (0.5s thumbnail TTL, 2.5s SCShareableContent TTL)
- `PreviewPanelController`: @MainActor; NSAnimationContext fade animations with `isFadingOut` guard flag
- `AppSettings`: @MainActor ObservableObject singleton backed by @AppStorage; hoverDelay also read directly from UserDefaults in DockMonitor to avoid @MainActor isolation
- `DockAXHelper`: stateless enum with static helpers for AX frame extraction, bundle ID lookup, dock icon traversal
- `WindowActivator`: frame+title matching only (no _AXUIElementGetWindow private API); tolerance 4pt

## Coordinate System — Critical Notes
- NSEvent.mouseLocation: NS coordinates (bottom-left origin, Y increases upward)
- AX API position: NS coordinates (bottom-left origin, Y increases upward)
- CGWindowList frame: CG coordinates (top-left origin, Y increases downward)
- nsToCG(): `cgY = primaryScreenHeight - nsPoint.y` using NSScreen.screens.first(where origin==.zero)
- containsMouse() in PreviewPanelController: performs inverse CG→NS before comparing to panel.frame
- CRITICAL BUG (commit 1237dca): DockMonitor line 81 uses event.locationInWindow (window-local, NOT screen) before NSEvent.mouseLocation fallback — causes wrong coordinates when mouse is over any app window

## Known Recurring Issues
- NSEvent locationInWindow bug (commit 1237dca): event.locationInWindow is window-local coord, not screen coord. Must use NSEvent.mouseLocation exclusively.
- com.apple.security.accessibility NOT allowed in Mac App Store: This entitlement is restricted and will cause automatic rejection. Current App Store port architecture is fundamentally incompatible with MAS policy.
- Entitlement not applied to debug/release SPM builds: .build/.../SmoothPeek-entitlement.plist only has get-task-allow; sandbox entitlements require codesign --entitlements or Xcode project.
- Info.plist LSMinimumSystemVersion mismatch: says 13.0 but SCKit-only ThumbnailGenerator requires macOS 14+; Package.swift correctly says .v14 but Info.plist not updated.
- SMAppService in App Store sandbox: needs LoginItems entitlement/helper app structure; current implementation will always fail in MAS builds.
- titleMatches() overbroad: empty-title AX windows return true unconditionally — first minimized window selected.
- applyLaunchAtLogin didSet re-entrancy: not guarded by flag but effectively harmless (confirmed).

## App Store Port Status (commit 1237dca → current main) — FAIL
- locationInWindow coordinate bug FIXED (now uses NSEvent.mouseLocation exclusively)
- Info.plist LSMinimumSystemVersion updated to 14.0 (matched to SCKit requirement)
- project.yml Xcode project added (SPM → XcodeGen); project.yml is source of truth
- CRITICAL REMAINING: (1) com.apple.security.accessibility still present in entitlements (MAS restricted), (2) project.yml Debug AND Release both set MAS_BUILD — private API path always disabled
- HIGH REMAINING: CGWindowListCopyWindowInfo sandboxed in App Sandbox (kCGWindowName not returned for other apps), DockAXHelper double-traversal per hover (findHoveredDockApp + findDockIconFrame both traverse AX tree), DockMonitor not @MainActor — NSEvent callback thread safety unconfirmed
- Architecture: XcodeGen (project.yml) generates Xcode project; SmoothPeek.entitlements applied at codesign time
- Verdict: MAS submission still blocked by accessibility entitlement policy — fundamental architecture reassessment required

## Performance Baselines
- SCShareableContent query: 50–200ms on macOS 14+ with many open windows (hence 2.5s TTL cache)
- Thumbnail cache: FIFO eviction at 50 entries; O(n) removeFirst() — fine at 50
- WindowEnumerator makes 2 CGWindowList queries when minimized window support enabled
- AX IPC cost: ~2 full Dock tree traversals per hover event (DockMonitor + PreviewPanelController) — ~20 AX IPC round trips for 10-app Dock

## Phase History
- Phase 1: AX↔CG coordinate fixes, panel positioning, permission UX — PASSED
- Phase 2: Minimized window support, fade animation, DockAXHelper refactor, SCShareableContent cache, preferences panel — PASS WITH CONDITIONS (all 4 required fixes resolved in b632eee)
- Commit 7bddcbf (panel persistence): PASS WITH CONDITIONS — 2 medium warnings
- Commit cf4c186 (Phase 2 QA fixes): resolved panel stability, window matching, sizing
- Commit 1237dca (App Store port): FAIL — 3 Critical, 3 High issues
- Full source review (2026-03-11): FAIL — 2 Critical, 4 High, 6 Medium, 4 Low

## Links to Detail Files
- See `patterns.md` for detailed coding conventions
