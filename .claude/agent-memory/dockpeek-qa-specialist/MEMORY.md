# DockPeek QA Specialist — Persistent Memory

## Project Structure
- Swift Package Manager project, minimum deployment: macOS 13 (Package.swift line 6)
- Swift 6.2.4 compiler used (as of 2026-03-09)
- Source root: `Sources/DockPeek/` with subdirs `App/`, `Core/`, `UI/`
- Key files: AppDelegate, DockMonitor, DockAXHelper, WindowEnumerator, WindowActivator, ThumbnailGenerator, PreviewPanelController, WindowThumbnailView, AppSettings, SettingsView
- Docs in `docs/`: QA_PHASE1.md, QA_PHASE2.md, PHASE2_PLAN.md, PROJECT_PLAN.md

## Architecture Patterns
- `DockMonitor`: CGEventTap on main run loop — NOT @MainActor; callbacks fire on main thread via Timer
- `ThumbnailGenerator`: @MainActor singleton; async thumbnail generation with two-level cache (thumbnail TTL=0.5s, SCShareableContent TTL=2.5s)
- `PreviewPanelController`: @MainActor; NSAnimationContext fade animations with `isFadingOut` guard flag
- `AppSettings`: @MainActor ObservableObject singleton backed by @AppStorage; hoverDelay also read directly from UserDefaults in DockMonitor to avoid @MainActor isolation
- `DockAXHelper`: stateless enum with static helpers for AX frame extraction, bundle ID lookup, dock icon traversal

## Coordinate System — Critical Notes
- AX API position: NS coordinates (bottom-left origin, Y increases upward)
- CGWindowList frame: CG coordinates (top-left origin, Y increases downward)
- Mouse events (CGEventTap): CG coordinates
- For Y-flip: `cgY = NSScreen.screens.first?.frame.height - axPos.y - height` (MUST use primary screen, not NSScreen.main)
- DockAXHelper.axFrame returns NS coordinates — used directly in setFrameOrigin (correct)
- Dock icon AX frame vs CGEvent mouse: compared directly without coordinate transform — known approximation, works in typical cases but mathematically incorrect

## Known Recurring Issues
- Hardcoded dimensions: Panel sizing (PreviewPanelController.preferredSize) and card rendering (WindowThumbnailCard.thumbSize) now both read from AppSettings — resolved in b632eee.
- @StateObject with singleton: FIXED in b632eee — SettingsView now uses @ObservedObject correctly.
- Settings window minimized state: FIXED in b632eee — AppDelegate.openSettings() checks isMiniaturized.
- SMAppService silent failure: FIXED in b632eee — AppSettings.applyLaunchAtLogin rolls back launchAtLogin=false and sets lastLaunchAtLoginError; SettingsView displays the error in red.
- Panel persistence (new): isMouseOverPanel callback added in 7bddcbf. MEDIUM WARNING: containsMouse(at:) calls panel.isVisible and NSScreen.screens on the CGEventTap thread (main run loop thread) — but PreviewPanelController is @MainActor, so this is safe only because CGEventTap fires on the main run loop. Document this implicit assumption.
- lastHoveredBundleID nil-state edge case: When mouse moves from non-Dock area directly onto panel with no prior hover, scheduleHoverEnd is never called — correct behavior. Confirmed no race condition.
- applyLaunchAtLogin didSet re-entrancy: setting launchAtLogin=false inside didSet triggers didSet again (unregister path). The unregister call will succeed (already unregistered) or is a no-op, so no infinite loop risk. MEDIUM: not guarded by a flag.

## Performance Baselines
- SCShareableContent query: 50–200ms on macOS 14+ with many open windows (hence 2.5s TTL cache)
- Thumbnail cache: FIFO eviction at 50 entries; O(n) removeFirst() — fine at 50 but document for future
- WindowEnumerator makes 2 CGWindowList queries when minimized window support enabled — main thread, fine under ~50 windows

## Phase History
- Phase 1: AX↔CG coordinate fixes, panel positioning, permission UX — all PASSED after fixes
- Phase 2: Minimized window support, fade animation, DockAXHelper refactor, SCShareableContent cache, preferences panel — PASS WITH CONDITIONS (4 required fixes before Phase 3)
- Phase 2 fixes (b632eee): All 4 Phase 2 required fixes confirmed resolved.
- Commit 7bddcbf (panel persistence): PASS WITH CONDITIONS — 2 medium warnings (thread context implicit assumption, didSet re-entrancy in applyLaunchAtLogin).

## Links to Detail Files
- See `patterns.md` for detailed coding conventions
