# SmoothPeek Phase 1 — QA Review Report

**Date:** 2026-03-09
**Reviewer:** SmoothPeek QA Specialist
**Scope:** Phase 1 changes (P1-1 through P1-4 + ThumbnailGenerator fix)
**Verdict:** PASS WITH CONDITIONS

---

## Executive Summary

Phase 1 delivers meaningful improvements over the prior always-false `matchesWindowID()` stub and the hardcoded dock height. The overall structure is sound. However, five bugs of varying severity were found that must be resolved before Phase 2 begins. Two of them (ISSUE-01, ISSUE-02) are correctness defects that will produce wrong behavior in supported configurations; the rest are lower-severity but still notable.

---

## Findings by Change Area

### P1-1 · WindowActivator — AX ↔ CG Coordinate Conversion

**File:** `Sources/SmoothPeek/Core/WindowActivator.swift`

#### ISSUE-01 · SEVERITY: HIGH — Wrong screen used for coordinate conversion on multi-display setups

**Lines 46–47:**
```swift
let screenHeight = NSScreen.main?.frame.height ?? 0
let cgY = screenHeight - axPos.y - axSize.height
```

`NSScreen.main` is the screen that currently contains the key window or menu bar, not necessarily the screen where the target window lives. On a two-display setup where the user has a window on a secondary monitor, `NSScreen.main` will return the wrong height, making every dimension calculation incorrect by the difference in screen heights.

The AX position for a window on any screen is given in a global NS coordinate space anchored to the bottom-left corner of the _primary_ screen (the one that holds the menu bar, `NSScreen.screens[0]`). The correct constant to use for the Y flip is `NSScreen.screens.first?.frame.height`, or equivalently the height of the screen whose origin is `(0, 0)`.

**Test case:** Open a window on a secondary monitor that is physically above the primary monitor. The AX y-coordinate will be negative in NS space. Using `NSScreen.main?.frame.height` when the key window is on the primary screen will produce a CG y that is off by the primary screen height, and `matchesWindow` will never match.

**Fix required:** Replace `NSScreen.main?.frame.height` with the height of the primary (origin-anchor) screen, typically `NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.main?.frame.height ?? 0`.

---

#### ISSUE-02 · SEVERITY: MEDIUM — Title fallback silently passes when both titles are empty string

**Lines 59–61:**
```swift
if let axTitle = titleRef as? String, !axTitle.isEmpty, !target.title.isEmpty {
    return axTitle == target.title
}
return true
```

The guard condition requires _both_ titles to be non-empty to perform the title comparison. If `target.title` is an empty string (which happens in `WindowEnumerator` for windows that have no `kCGWindowName`—the code falls back to `app.localizedName`, not empty string, but `kCGWindowName` can be absent on some windows) and `axTitle` is also empty, the condition short-circuits and returns `true` without any title check.

More concretely: if two windows of the same size both have no AX title (e.g., utility panels in some apps), the first one in the AX list will always win. This is an edge case but can produce wrong activation in apps like Xcode that have many panels.

Additionally, `WindowEnumerator` uses `app.localizedName ?? "Unknown"` as the title fallback, so `target.title` will never actually be empty—it will be the app name. This means the code path `!target.title.isEmpty` is always true, but `!axTitle.isEmpty` may be false, causing the block to be skipped and returning `true` anyway. The logic works by accident here, but it's fragile and confusing.

**Fix required:** Document the invariant that `target.title` is never empty, or restructure the condition to be explicit: skip title comparison only when the AX element has no title (`axTitle` is nil or empty), not when either side is empty.

---

#### Observation · force-cast `as! AXValue` on lines 42–43 and 167–168

**Lines 42–43 (WindowActivator), 167–168 (DockMonitor):**
```swift
AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)
```

The `as!` force-cast will crash at runtime if the AX attribute returns an unexpected type. The `guard` above only checks that `AXUIElementCopyAttributeValue` succeeds; it does not guarantee the returned `CFTypeRef` is an `AXValue`. While this is unlikely with standard AX attributes, a misbehaving or sandboxed app could return a different type. The same pattern appears identically in `DockMonitor.axFrame(of:)` and `PreviewPanelController.findDockIconCenter(for:)`.

**Recommendation (pre-Phase 2):** Replace with `guard let axVal = posRef as? AXValue else { return false }` pattern. Not crashing in production is more important than the marginal gain in conciseness.

---

### P1-2 · PreviewPanelController — Panel Positioning & DockEdge Detection

**File:** `Sources/SmoothPeek/UI/PreviewPanelController.swift`

#### ISSUE-03 · SEVERITY: MEDIUM — `positionPanel` uses `NSScreen.main`, not the screen containing the Dock icon

**Line 102:**
```swift
guard let screen = NSScreen.main else { return }
```

`NSScreen.main` is the screen with the current key window, which is not guaranteed to be the screen hosting the Dock. On a dual-monitor setup where the Dock is on the secondary screen (users can drag the Dock to any screen by moving the mouse to its edge), `dockEdge(on:)` will measure the wrong screen's `visibleFrame` and misplace the panel. The Dock is always on the screen specified by `NSScreen.main` only in the default single-monitor case.

The correct approach is to query which screen contains the Dock using `NSScreen.screens` and checking which one has the largest `visibleFrame` delta at the bottom (or the known edge), or by using the AX-derived Dock icon position to identify its hosting screen.

**Test case:** Move the Dock to the secondary monitor by moving the cursor to its bottom edge. Hover an icon. The panel will appear on the primary monitor at a wrong y-offset.

---

#### ISSUE-04 · SEVERITY: LOW — Auto-hide Dock not handled; `visibleFrame` delta is 0 or near-0

**Lines 91–97 (`dockEdge`):**
```swift
if visible.minX > 4 {
    return .left(width: visible.minX)
} else if frame.maxX - visible.maxX > 4 {
    return .right(width: frame.maxX - visible.maxX)
} else {
    return .bottom(height: visible.minY)
}
```

When the Dock is set to auto-hide, `NSScreen.visibleFrame` does not reserve space for it—the visible frame is equal to the full frame (modulo the menu bar). `visible.minY` will be 0, `dockHeight` will be 0, and the panel will be placed at `y = 0 + 8 = 8px`, flush with the bottom of the screen, potentially behind the auto-hiding Dock itself when it appears.

The threshold of `4` points is also fragile: Apple does not document a minimum Dock width/height, and a very small Dock (minimum icon size) may produce a `visibleFrame` delta smaller than 4, causing misdetection (e.g., a tiny left Dock being reported as a bottom Dock).

**Recommendation:** After the standard `visibleFrame` check returns a height of 0 for `bottom`, apply a hard-coded minimum panel offset (e.g., 4px above the screen bottom) or detect auto-hide via `com.apple.dock autohide` defaults and use a separate constant.

---

#### ISSUE-05 · SEVERITY: LOW — `findDockIconCenter` returns NS coordinates; `positionPanel` uses them as NS coordinates for `setFrameOrigin`, but coordinate system mismatch is possible

**Lines 170, 130:**
```swift
return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
// ...
panel.setFrameOrigin(NSPoint(x: x, y: y))
```

`findDockIconCenter` reads AX position/size (which are in NS coordinates, bottom-left origin) and returns a `CGPoint` without conversion. This value is then used directly in `positionPanel` as the NS-coordinate center. For the bottom-Dock case, this is used only for `x` (horizontal centering), which is correct since X is the same in both coordinate systems. For left/right Dock cases, the `y` value is used directly for vertical positioning. Since AX coordinates are in NS space and `setFrameOrigin` also accepts NS coordinates, this is actually consistent—but it is not documented in comments and could easily be broken by a future developer who assumes CG coordinates. The lack of an explicit comment about coordinate space here is a latent bug risk.

**Recommendation:** Add a comment stating that the returned CGPoint is in NS (AppKit) screen coordinates, matching `setFrameOrigin`.

---

### P1-3 · Bug Fixes — `hide()` on Empty Windows, `applicationWillTerminate`

**File:** `Sources/SmoothPeek/App/AppDelegate.swift`

The `hide()` call for empty `windows` (lines 101–104) and `applicationWillTerminate` cleanup (lines 18–20) are both straightforward and correct. No issues found.

---

### P1-4 · Permission UX — `onPermissionError` Callback and Alert

**File:** `Sources/SmoothPeek/App/AppDelegate.swift`, `Sources/SmoothPeek/Core/DockMonitor.swift`

#### ISSUE-06 · SEVERITY: LOW — `showPermissionAlert()` modifies the status bar icon after `runModal()` returns, but `runModal()` blocks the main thread

**Lines 64–71:**
```swift
if alert.runModal() == .alertFirstButtonReturn {
    NSWorkspace.shared.open(url)
}
// 상태바 아이콘을 경고 아이콘으로 변경
statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", ...)
```

`NSAlert.runModal()` blocks the main thread until the user dismisses the alert. Status bar icon update at line 70 occurs only after the user clicks a button. This means:

1. The icon does not turn into the warning triangle while the alert is visible, only after the user dismisses it. This is a minor UX inversion—ideally the icon would change before or simultaneously with the alert to provide persistent context.
2. If the user clicks "Open System Settings", the URL is opened and then the icon changes. The sequence is correct but the delay between opening settings and the icon updating may be imperceptible.

This is not a crash or data-corruption bug, but it contradicts the natural expectation that the icon reflects current state (no permission) immediately.

**Recommendation:** Move `statusItem?.button?.image = ...` to before `alert.runModal()` so the icon reflects the error state before the modal appears.

---

#### Observation · `Task { @MainActor in }` wrapping inside already-`@MainActor` callbacks

**Lines 82–89:**
```swift
dockMonitor?.onAppHovered = { [weak self] bundleID, app in
    Task { @MainActor in self?.handleHover(bundleID: bundleID, app: app) }
}
dockMonitor?.onHoverEnded = { [weak self] in
    Task { @MainActor in self?.previewController?.hide() }
}
dockMonitor?.onPermissionError = { [weak self] in
    Task { @MainActor in self?.showPermissionAlert() }
}
```

`startMonitoring()` is already marked `@MainActor`. The closures assigned to `dockMonitor` callbacks are called from `DockMonitor`, which executes them on whatever thread calls them. In `DockMonitor`, `onPermissionError` is dispatched with `DispatchQueue.main.async` (line 78–80), making it safe. However, `onAppHovered` and `onHoverEnded` are called from the `hoverTimer` and `scheduleHoverEnd` Timer callbacks (lines 107–109, 118–119), which fire on the main run loop and therefore already on the main thread.

The `Task { @MainActor in }` wrappers are thus redundant but not harmful—they simply schedule a new task on the main actor's executor rather than calling directly. There is no race condition here because both paths serialize through the main thread. The code is safe.

**Recommendation (non-blocking):** For clarity, the callbacks could call the methods directly (since Timers always fire on the scheduling thread, which is main here), but the current pattern is a reasonable defensive practice.

---

### ThumbnailGenerator — `SCScreenshotManager` Availability Fix

**File:** `Sources/SmoothPeek/Core/ThumbnailGenerator.swift`

The correction from `macOS 13` to `macOS 14.0` at lines 29 and 47 is correct. `SCScreenshotManager` was introduced in macOS 14.0 (Sonoma). The comment at line 6 still says `macOS 13+` and should be updated to `macOS 14+` for accuracy.

**Line 6 (comment):**
```swift
/// - macOS 13+: ScreenCaptureKit (SCScreenshotManager) 사용 — 고품질, 권한 필요
```
Should read `macOS 14+`.

---

### WindowEnumerator — Ancillary Observation

**File:** `Sources/SmoothPeek/Core/WindowEnumerator.swift`

`kCGWindowName` can be absent (not just empty) for some windows, and `dict[kCGWindowName] as? String` returns `nil` in that case, correctly falling back to `app.localizedName`. However, because `kCGWindowName` requires the Screen Recording permission on macOS 14+, it may return `nil` for all windows until permission is granted. In that scenario every window's title becomes the app name, which would make the title-based disambiguation in `matchesWindow` useless (all titles match, since every `WindowInfo.title` is the same app name). This is a cascading effect of the permission model, not a Phase 1 bug per se, but worth noting for Phase 2 testing.

---

## Issue Priority Table

| # | Severity | File | Lines | Summary |
|---|----------|------|-------|---------|
| ISSUE-01 | HIGH | WindowActivator.swift | 46–47 | `NSScreen.main` used for AX→CG Y-flip; wrong on multi-display |
| ISSUE-02 | MEDIUM | WindowActivator.swift | 59–63 | Title fallback logic is fragile; passes silently when both titles empty |
| ISSUE-03 | MEDIUM | PreviewPanelController.swift | 102 | Panel positioned relative to wrong screen on multi-monitor setups |
| ISSUE-04 | LOW | PreviewPanelController.swift | 91–97, 115 | Auto-hide Dock returns `dockHeight = 0`; panel placed at bottom edge |
| ISSUE-05 | LOW | PreviewPanelController.swift | 170 | Dock icon center coordinate space undocumented; latent bug risk |
| ISSUE-06 | LOW | AppDelegate.swift | 64–71 | Status bar warning icon set after modal dismissal, not before |
| — | INFO | ThumbnailGenerator.swift | 6 | Comment still says macOS 13+, should be macOS 14+ |
| — | INFO | Multiple files | 42–43, 167–168 | `as! AXValue` force-casts; should be guarded |

---

## Test Cases Executed (Mentally)

| Test | Scenario | Expected | Actual (code trace) |
|------|----------|----------|---------------------|
| TC-01 | Single monitor, bottom Dock, normal window | AX→CG Y conversion correct | PASS |
| TC-02 | Dual monitor (secondary above primary), window on secondary | AX→CG Y correct | FAIL — ISSUE-01 |
| TC-03 | Two same-size windows, one titled, one untitled | Titled window matched via title | PASS (by accident via return true) |
| TC-04 | Two same-size windows, both untitled | First AX window wins | PASS (acceptable) |
| TC-05 | Two same-size windows, both titled differently | Correct window matched | PASS |
| TC-06 | Bottom Dock, normal size | Panel appears above Dock | PASS |
| TC-07 | Auto-hide Dock enabled | Panel appears 8px from bottom | FAIL — ISSUE-04 |
| TC-08 | Left Dock, secondary monitor | Panel positioned correctly | FAIL — ISSUE-03 |
| TC-09 | CGEventTap creation fails | Alert shown, icon changes | PASS (with UX note ISSUE-06) |
| TC-10 | App terminates | `dockMonitor.stop()` called | PASS |
| TC-11 | Hovering app with 0 windows | Panel hides | PASS |
| TC-12 | macOS 13 device | Falls back to CGWindow capture | PASS (after fix) |
| TC-13 | macOS 14+ device | Uses SCScreenshotManager | PASS (after fix) |

---

## Overall Verdict

**PASS WITH CONDITIONS**

Phase 1 is a solid structural improvement. The code is generally well-organized and the intent of each change is clear. Two issues (ISSUE-01, ISSUE-03) produce incorrect behavior on any multi-monitor setup and must be fixed before Phase 2, since Phase 2 likely builds more UI on top of the positioning infrastructure. ISSUE-02 is fragile but will not cause crashes. ISSUE-04 affects auto-hide users. ISSUE-05 and ISSUE-06 are low-risk cleanup items.

**Required fixes before Phase 2:**
1. ISSUE-01: Fix primary-screen anchor for AX→CG Y-flip in `WindowActivator`.
2. ISSUE-03: Identify the screen hosting the Dock correctly in `positionPanel`.
3. ISSUE-04: Handle auto-hide Dock (zero `visibleFrame` delta) with a minimum offset fallback.

**Recommended but non-blocking:**
4. ISSUE-02: Clarify title-fallback logic and add a comment.
5. ISSUE-06: Move status bar icon update before `runModal()`.
6. Replace `as! AXValue` force-casts with guarded casts across all files.
7. Fix `ThumbnailGenerator` header comment to say macOS 14+.
