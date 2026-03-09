# SmoothPeek Phase 2 — QA Review Report

**Date:** 2026-03-09
**Reviewer:** SmoothPeek QA Specialist
**Scope:** Phase 2 changes (P2-PRE, P2-6, P2-5, P2-1, P2-3, P2-4)
**Commits reviewed:** `1e686d4` → `916cdae`
**Verdict:** PASS WITH CONDITIONS

---

## Executive Summary

Phase 2 successfully delivers minimized window support, fade animations, shared AX utilities, SCShareableContent caching, and a preferences panel. The structural quality is noticeably higher than Phase 1: code duplication has been eliminated, concurrency annotations are consistent, and error handling is defensive throughout. Six issues were found, none of them critical. The two highest-severity issues (ISSUE-P2-01, ISSUE-P2-02) are a UI dimension desync and a `didSet` trap that can silently drop settings changes; both must be fixed before Phase 3 begins. The remaining four are low-to-medium severity.

---

## Phase 1 QA Follow-up

All required Phase 1 fixes were applied correctly in commit `1e686d4`:

| Phase 1 Item | Status |
|---|---|
| ISSUE-01: `NSScreen.main` → primary screen for Y-flip | FIXED — `NSScreen.screens.first` used in `matchesWindow` |
| ISSUE-02: title fallback logic clarification | FIXED — detailed invariant comment added |
| ISSUE-03: wrong screen in `positionPanel` | FIXED — `dockScreen()` returns `NSScreen.screens.first` |
| ISSUE-04: auto-hide Dock zero-height | FIXED — `max(visible.minY, minDockSize)` applied |
| ISSUE-05: coordinate space comment | FIXED — `DockAXHelper` doc comment documents NS coordinate space |
| ISSUE-06: icon update before `runModal()` | FIXED — icon change moved before `alert.runModal()` |
| INFO: ThumbnailGenerator comment macOS 13+ | FIXED — now reads macOS 14+ |
| INFO: `as! AXValue` force-casts | FIXED — `CFGetTypeID()` guard applied across all sites |

---

## Findings by Change Area

### P2-PRE · Residual QA Fixes

**Files:** `AppDelegate.swift`, `WindowActivator.swift`, `ThumbnailGenerator.swift`

All three items are correctly applied. The status bar icon is now updated before `alert.runModal()` (line 99), the title fallback invariant is documented with an explicit comment explaining `target.title` is never empty, and the file header comment now correctly reads macOS 14+. No new issues.

---

### P2-6 · DockAXHelper Extraction

**File:** `Sources/SmoothPeek/Core/DockAXHelper.swift`

The extraction is clean. `axFrame(of:)`, `bundleID(of:)`, and `dockIconElement(for:in:)` are factored out with no behavior change. Both `DockMonitor` and `PreviewPanelController` now delegate to the shared implementation. The `CFGetTypeID()` guards are consistent. The coordinate-system documentation in the header comment is thorough.

#### ISSUE-P2-01 · SEVERITY: MEDIUM — `DockAXHelper` comment mischaracterizes AX coordinate system for Dock icons

**File:** `Sources/SmoothPeek/Core/DockAXHelper.swift`, lines 14–18

```swift
/// - DockMonitor에서는 마우스 이벤트(CG 좌표계)와 비교하는데,
///   Dock 아이콘의 AX position은 실제로 CG 좌표계와 동일하게 동작한다.
///   (Dock은 화면 하단에 위치하므로 좌상단 원점 기준의 y값이 바닥 근처의 양수값임)
```

This comment is factually incorrect. AX position is in NS coordinates (bottom-left origin, Y increases upward). The Dock icon's AX `y` value is not `(screenHeight - dockHeight)` in CG terms — it is the NS y coordinate measured from the bottom of the screen, which happens to be a small positive number (e.g., 0–80 px) because the Dock sits near the bottom edge. This is numerically close to the CG y value for that same point (which would be `screenHeight - dockHeight`, e.g., 1080 - 70 = 1010 px on a 1080p screen). They are only "coincidentally similar" for the specific case of a bottom-positioned Dock of typical size, but they are not equal, and the comment saying "AX position은 실제로 CG 좌표계와 동일하게 동작한다" will mislead future maintainers.

The actual reason the mouse hit-test in `DockMonitor.findHoveredDockApp` works is that the CGEventTap `event.location` and `CGWindowListCopyWindowInfo` both use CG coordinates, while Dock AX position uses NS coordinates — and on macOS, for the primary screen, the numeric CG y for a point near the bottom of the screen is `screenHeight - nsY`. For a 1080px screen with a 70px Dock, the Dock's CG y ≈ 1080 - 70 = 1010 and AX y ≈ 0–70. These are not the same, which means the hit-test `frame.contains(point)` is comparing AX-coordinate frames with CG-coordinate mouse positions. On a standard single-display setup this still works because the user's mouse is physically in the Dock region and the numbers happen to be close enough for most practical icon sizes (the Dock AX frame height of 70+ px provides enough tolerance), but it is not mathematically correct and will produce incorrect results at extreme icon sizes, non-standard DPI, or with a top-positioned Dock.

**Impact:** Incorrect code comment concealing a latent hit-test inaccuracy. On non-standard Dock configurations (large icons, top Dock, high-DPI secondary display), hover detection may activate the wrong app or fail to activate.

**Recommendation:** Rewrite the comment to accurately describe the coordinate system and document that Dock icon detection uses AX coordinates directly compared against CGEvent mouse coordinates — noting this is a known approximation that works within the typical Dock height range but is not guaranteed for all configurations. A proper fix in Phase 3 would transform either the AX frame to CG coordinates or the mouse point to NS coordinates before comparison.

---

### P2-5 · ThumbnailGenerator — SCShareableContent Caching + Cache Size Limit

**File:** `Sources/SmoothPeek/Core/ThumbnailGenerator.swift`

The FIFO eviction logic is correct. The `cacheInsertionOrder` array tracks insertion order independently of map updates (line 67: only appended for new entries, not on TTL-refresh of existing entries). The `Any?` boxing workaround for `@available` stored properties is a valid Swift pattern and is correctly commented. The TTL values (0.5s thumbnail, 2.5s shareable content) are reasonable.

#### ISSUE-P2-02 · SEVERITY: MEDIUM — Stale `SCShareableContent` cache causes silent miss-and-fallback on new windows

**File:** `Sources/SmoothPeek/Core/ThumbnailGenerator.swift`, lines 83–93

```swift
@available(macOS 14.0, *)
private func shareableContent() async throws -> SCShareableContent {
    if let timestamp = shareableContentTimestamp,
       Date().timeIntervalSince(timestamp) < shareableContentTTL,
       let cached = cachedShareableContent as? SCShareableContent {
        return cached
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    ...
}
```

When a new window opens within the 2.5-second TTL window, `shareableContent()` returns the stale cached content. The caller (`captureWithSCKit`) then fails to find the new window ID in `content.windows` (line 101) and silently falls back to `captureWithCGWindow`. This degradation is invisible to the user for the first 2.5 seconds after any new window is opened, during which they will see lower-quality CGWindow thumbnails instead of SCKit thumbnails.

The Phase 2 plan risk log acknowledged this ("캡처 실패 시 즉시 재조회 fallback 추가") but the implementation did not include the retry. The fallback to `captureWithCGWindow` ensures no crash, but the quality regression is invisible.

**Impact:** For 2.5 seconds after any window opens, its thumbnail is captured at lower quality via CGWindow fallback. On macOS 14+ with Screen Recording permission this is a perceptible quality difference.

**Recommendation:** When `content.windows.first(where: { $0.windowID == windowID })` returns `nil`, invalidate the content cache (`cachedShareableContent = nil; shareableContentTimestamp = nil`) before falling back to CGWindow. This ensures the next hover refreshes the content and restores SCKit quality immediately rather than waiting for TTL expiry.

---

#### ISSUE-P2-03 · SEVERITY: LOW — `cacheInsertionOrder.removeFirst()` is O(n) on Array

**File:** `Sources/SmoothPeek/Core/ThumbnailGenerator.swift`, lines 69–73

```swift
if cacheInsertionOrder.count >= cacheMaxCount,
   let oldest = cacheInsertionOrder.first {
    cache.removeValue(forKey: oldest)
    cacheInsertionOrder.removeFirst()
}
```

`Array.removeFirst()` is O(n) because it shifts all remaining elements. With `cacheMaxCount = 50` this is a constant-bounded operation (at most 49 element shifts), so the practical impact at this scale is negligible. However, it is worth noting for Phase 3 if the cache limit is increased significantly. Using a `Deque` (Swift Collections package) or a simple index pointer would make this O(1).

**Impact:** Negligible at the current 50-item limit. Informational for future scalability.

**Recommendation:** Document the O(n) characteristic with a comment. Consider `Deque` or a ring-buffer approach if the cache limit increases to hundreds of entries in Phase 3.

---

### P2-1 · Minimized Window Support

**Files:** `Sources/SmoothPeek/Core/WindowEnumerator.swift`, `Sources/SmoothPeek/Core/WindowActivator.swift`, `Sources/SmoothPeek/UI/WindowThumbnailView.swift`

#### ISSUE-P2-04 · SEVERITY: HIGH — `WindowThumbnailCard.thumbSize` is hardcoded to 200×120, ignoring `AppSettings`

**File:** `Sources/SmoothPeek/UI/WindowThumbnailView.swift`, line 60

```swift
private let thumbSize = CGSize(width: 200, height: 120)
```

`PreviewPanelController.preferredSize(windowCount:)` correctly reads `AppSettings.shared.thumbnailWidth` and `AppSettings.shared.thumbnailHeight` to size the panel (lines 117–118). However, `WindowThumbnailCard` uses a hardcoded `thumbSize` of `200×120` for all rendering: the thumbnail image frame (line 68, 72, 78), the clip shape (line 73, 80), and the `ThumbnailGenerator` capture size (line 110).

The default `AppSettings` thumbnail height is `130` px, not `120` px (defined in `AppSettings.Defaults.thumbnailHeight = 130`). This means even with default settings, the panel height is calculated for 130px thumbnails but the rendered thumbnail images are clipped to 120px — producing a 10px blank strip at the bottom of each card slot. When the user adjusts thumbnail size in the preferences panel, the outer panel resizes but the actual thumbnail images remain 200×120.

Additionally, `PreviewPanelView`'s `LazyVGrid` columns use a hardcoded `GridItem(.fixed(200))` (line 28), which will also diverge from the user's configured width.

**Root cause:** `WindowThumbnailCard` was not updated to read `AppSettings` during the P2-4 integration. `PreviewPanelController` and `WindowThumbnailView` are in separate files with no shared sizing contract.

**Impact:** The thumbnail size preference has no visual effect on card rendering. The panel outer shell resizes but the inner thumbnails stay at 200×120. This makes the settings UI appear broken: adjusting the slider produces no visible change to thumbnail appearance.

**Recommendation:** `WindowThumbnailCard` and `PreviewPanelView` must read `AppSettings.shared.thumbnailWidth` / `thumbnailHeight` dynamically (via `@StateObject` or `@ObservedObject`) rather than using a hardcoded constant. The `GridItem(.fixed(200))` in `PreviewPanelView` must also be parameterized.

---

The minimized window enumeration logic is otherwise sound:
- The two-query approach (on-screen + all-windows filtered for `isOnScreen == false`) correctly separates minimized windows from on-screen windows.
- Deduplication via `Set<CGWindowID>` is correct.
- The `layer == 0` filter correctly excludes system UI elements from the minimized set.
- `ThumbnailGenerator.thumbnail(for:)` early-returns `nil` for minimized windows (line 37), correctly delegating display to `MinimizedPlaceholder`.

The minimized window restoration in `WindowActivator.restoreAndActivate` is structurally correct:
- AX `kAXMinimizedAttribute` check correctly identifies the target window.
- Title-only matching is the right strategy since minimized windows lack position/size.
- The 0.1s `asyncAfter` before `activate + raise` is reasonable to allow the unminimize animation to complete.
- The fallback to `app.activate` when AX permission is unavailable is correct.

One edge case in `restoreAndActivate`: if the same app has two minimized windows with identical titles, the first one in the AX window list order wins. This is the same "first match" policy used in Phase 1's `matchesWindow` for on-screen windows and is documented in the comment on line 32. Acceptable.

---

### P2-3 · Panel Fade In/Out Animation

**File:** `Sources/SmoothPeek/UI/PreviewPanelController.swift`

The `isFadingOut` flag approach for canceling in-flight fade-outs is well-designed. The `NSAnimationContext` completion handler correctly dispatches to `@MainActor` via `Task { @MainActor [weak self] in }` to safely access the `isFadingOut` property. The `guard let self, self.isFadingOut` check prevents `orderOut` when `show()` has been called during the fade.

One subtle concern: `NSAnimationContext.runAnimationGroup` completion handlers are not documented to execute on the main thread. The `Task { @MainActor }` wrapper ensures safety here. The comment on lines 81–83 documents this reasoning explicitly. Good.

The animation constants (0.15s fade-in, 0.10s fade-out) are appropriate for the use case.

#### Observation · `panel` captured strongly in `hide()` completion handler

**File:** `Sources/SmoothPeek/UI/PreviewPanelController.swift`, line 89

```swift
} completionHandler: { [weak self] in
    Task { @MainActor [weak self] in
        ...
        panel.orderOut(nil)  // <-- panel is captured strongly
    }
}
```

`panel` is captured by the outer closure via the `guard let panel` at the top of `hide()`. The strong capture of `panel` extends its lifetime until the completion handler fires. Since `panel` is an `NSPanel` (a reference type), this is not a memory leak in the traditional sense, but it does mean the panel cannot be deallocated while a fade-out animation is in progress. Given that `panel` is also held strongly by `self.panel`, this creates no practical issue — but adding `[weak panel]` to the outer closure capture list would be cleaner and prevent any hypothetical double-release if the panel is ever nulled out mid-animation.

**Severity:** Low / informational.

---

### P2-4 · Preferences Panel

**Files:** `Sources/SmoothPeek/App/AppSettings.swift`, `Sources/SmoothPeek/UI/SettingsView.swift`, `Sources/SmoothPeek/App/AppDelegate.swift`

#### ISSUE-P2-05 · SEVERITY: MEDIUM — `@AppStorage` `didSet` does not fire reliably for property wrapper types in Swift; `launchAtLogin` side-effect may silently not execute

**File:** `Sources/SmoothPeek/App/AppSettings.swift`, lines 48–51

```swift
@AppStorage(Keys.launchAtLogin)
var launchAtLogin: Bool = Defaults.launchAtLogin {
    didSet { applyLaunchAtLogin(launchAtLogin) }
}
```

`@AppStorage` is a property wrapper that synthesizes a backing store in `UserDefaults`. In Swift, `didSet` on a property wrapper-backed property is invoked when the wrapper's `wrappedValue` setter is called from Swift code on the same actor. However, `didSet` is **not** called when `UserDefaults` is mutated externally (e.g., from another process, from `UserDefaults.standard.set(_, forKey:)` directly, or from `resetToDefaults()` if the wrapper setter is used internally). In practice, `resetToDefaults()` on line 64 calls `launchAtLogin = Defaults.launchAtLogin`, which does invoke the setter and triggers `didSet` — that part works correctly.

The specific risk here is that `@AppStorage` `didSet` is documented behavior in SwiftUI, and for `@MainActor`-isolated classes it generally works. However, there is a known Swift 5.7+ interaction where `didSet` on a `@MainActor` class's `@AppStorage` property may not fire during initialization or when set from non-Swift contexts. More critically, the implementation has a conceptual asymmetry: the UI toggle directly mutates `$settings.launchAtLogin` via `Toggle("로그인 시 자동 실행", isOn: $settings.launchAtLogin)`, which sets the underlying `UserDefaults` via `AppStorage`'s `projectedValue` binding. This setter path does invoke `didSet`, so the `SMAppService` call will execute. This is correct.

The real concern is resilience: if `applyLaunchAtLogin` throws (it catches internally) and the `SMAppService.register()` silently fails (e.g., the app is not signed, or the entitlement is missing for a CLI target built with SPM), the toggle will visually remain in the "on" state but login-item registration will not have occurred. There is no UI feedback to the user that the SMAppService call failed.

**Impact:** User toggles "Launch at Login", the toggle appears to succeed, but the system login item is not registered. No error is surfaced. The user discovers the app did not auto-launch after a reboot.

**Recommendation:** Propagate the SMAppService error state back to the UI. A simple approach is to add an `@Published var launchAtLoginError: String?` property to `AppSettings` and display it near the toggle in `SettingsView`. Alternatively, verify `SMAppService.mainApp.status` on view appearance to reconcile the toggle state with actual system state.

---

#### ISSUE-P2-06 · SEVERITY: LOW — Settings window re-open guard uses `isVisible`, not `isKeyWindow`; minimized settings window is not handled

**File:** `Sources/SmoothPeek/App/AppDelegate.swift`, lines 59–63

```swift
if let existing = settingsWindow, existing.isVisible {
    NSApp.activate(ignoringOtherApps: true)
    existing.makeKeyAndOrderFront(nil)
    return
}
```

If the user minimizes the settings window (the window has `miniaturizable` style mask, line 77), `isVisible` returns `false` for a minimized window in AppKit. When the user then clicks "環境설정..." again, the guard check fails and `makeSettingsWindow()` is called again, creating a second settings window. The old (minimized) window is orphaned — `settingsWindow` is overwritten with the new reference, and the minimized window persists in the Dock until the app quits.

**Test case:** Open settings window → minimize it → click "環境설정..." from the status bar menu → two settings windows exist simultaneously.

**Impact:** Multiple settings windows; the minimized one is unreachable and leaks for the session.

**Recommendation:** Use `existing.isVisible || existing.isMiniaturized` or simply `existing != nil` (relying on `isReleasedWhenClosed = false`). When a minimized window is detected, call `existing.deminiaturize(nil)` before `makeKeyAndOrderFront(nil)`.

---

#### Observation · `SettingsView` uses `@StateObject` with a singleton — technically incorrect lifecycle

**File:** `Sources/SmoothPeek/UI/SettingsView.swift`, line 10

```swift
@StateObject private var settings = AppSettings.shared
```

`@StateObject` is designed for objects whose lifecycle is owned by the view — SwiftUI creates the object on first render and destroys it when the view is removed from the hierarchy. Using it with a `static let shared` singleton means SwiftUI believes it owns `AppSettings.shared`, but the object is never actually destroyed because the singleton retains it. In practice this works correctly (the same instance is always returned, and `@StateObject` will not try to recreate it since `AppSettings.shared` always returns the same reference), but it is a misuse of the API and will generate a purple warning in Xcode about `@StateObject` initialization with a non-owned object in future Swift/SwiftUI versions.

**Recommendation:** Use `@ObservedObject` for externally-owned singletons. `@ObservedObject private var settings = AppSettings.shared` correctly expresses the intent that the view does not own the lifecycle.

---

### DockMonitor · `hoverDelay` via `UserDefaults.standard` direct read

**File:** `Sources/SmoothPeek/Core/DockMonitor.swift`, lines 104–107

```swift
// AppSettings.shared는 @MainActor 격리이므로 CGEventTap 콜백(메인 런루프)에서
// 직접 접근하지 않고, 같은 UserDefaults 키를 통해 값을 읽는다.
let delay = UserDefaults.standard.double(forKey: "hoverDelay")
let hoverDelay = delay > 0 ? delay : 0.4
```

The comment explains the rationale clearly. `UserDefaults.standard.double(forKey:)` is thread-safe and returns `0.0` when the key has never been set (not the `Defaults.hoverDelay` of `0.4`). The `delay > 0 ? delay : 0.4` guard correctly handles the "never set" case. The string literal `"hoverDelay"` duplicates `AppSettings.Keys.hoverDelay`, which is `private`. If the key name ever changes in `AppSettings`, this site must be updated manually.

**Recommendation (non-blocking):** Promote `AppSettings.Keys.hoverDelay` from `private` to `internal` or `fileprivate` and reference it from `DockMonitor`. Alternatively, add a `fileprivate(set) static let hoverDelayKey = Keys.hoverDelay` accessor. This prevents silent mismatch if the key is renamed. Not a blocking issue since the string is short and stable.

---

## Issue Priority Table

| # | Severity | File | Lines | Summary |
|---|----------|------|-------|---------|
| ISSUE-P2-01 | MEDIUM | DockAXHelper.swift | 14–18 | AX coordinate comment incorrectly states AX == CG for Dock icons |
| ISSUE-P2-02 | MEDIUM | ThumbnailGenerator.swift | 83–93 | Stale SCShareableContent cache causes silent SCKit→CGWindow fallback on new windows |
| ISSUE-P2-03 | LOW | ThumbnailGenerator.swift | 69–73 | `cacheInsertionOrder.removeFirst()` is O(n); fine at 50 items, note for future |
| ISSUE-P2-04 | HIGH | WindowThumbnailView.swift | 60 | `thumbSize` hardcoded 200×120; AppSettings thumbnail size changes have no effect on rendered cards |
| ISSUE-P2-05 | MEDIUM | AppSettings.swift | 48–51 | `SMAppService` failure is silently swallowed; no UI feedback when login-item registration fails |
| ISSUE-P2-06 | LOW | AppDelegate.swift | 59–63 | Minimized settings window not detected by `isVisible`; re-clicking creates a second window |
| — | INFO | SettingsView.swift | 10 | `@StateObject` used with singleton; should be `@ObservedObject` |
| — | INFO | DockMonitor.swift | 106 | Hard-coded `"hoverDelay"` string duplicates `AppSettings.Keys.hoverDelay` |
| — | INFO | PreviewPanelController.swift | 89 | `panel` captured strongly in fade-out completion handler; harmless but could be `[weak panel]` |

---

## Functional Test Results

| # | Test Case | Scenario | Expected | Result |
|---|-----------|----------|----------|--------|
| TC-01 | Minimized window enumeration | App with 1 on-screen + 1 minimized window | Both windows appear in panel | PASS (code trace) |
| TC-02 | Minimized window deduplication | Same window ID appears in both queries | Only appears once in result | PASS — `onScreenIDs` Set dedup is correct |
| TC-03 | Minimized window placeholder | Click on minimized window card | Placeholder shown, not thumbnail | PASS |
| TC-04 | Minimized window restore | Click minimized card | Window unminimized, app activated | PASS (code trace) |
| TC-05 | Minimized restore — AX permission missing | No accessibility permission | App activated only, no crash | PASS — fallback `app.activate` |
| TC-06 | Fade in on hover | Hover Dock icon | Panel fades in over 0.15s | PASS |
| TC-07 | Fade out on unhover | Move mouse off Dock | Panel fades out over 0.1s | PASS |
| TC-08 | Show interrupts fade-out | Hover different icon during fade-out | Old fade-out canceled, new panel fades in | PASS — `isFadingOut` flag correctly reset |
| TC-09 | Rapid hover between two icons | Mouse moves quickly | No orphaned panel | PASS |
| TC-10 | Settings window opens | Click "환경설정..." | Settings window appears | PASS |
| TC-11 | Settings window singleton | Click "환경설정..." twice | Same window focused | PASS |
| TC-12 | Settings window minimized then re-opened | Minimize settings, re-click menu | Second window created | FAIL — ISSUE-P2-06 |
| TC-13 | Hover delay preference applied | Change delay to 1.0s, hover icon | Panel appears after 1s | PASS — UserDefaults read each time |
| TC-14 | Thumbnail size preference applied | Change thumbnail width to 300px | Cards render at 300px wide | FAIL — ISSUE-P2-04 |
| TC-15 | Thumbnail cache — new window within TTL | Open window, hover app within 2.5s | Window thumbnail shown | FAIL — ISSUE-P2-02 (falls back to CGWindow quality) |
| TC-16 | Thumbnail cache FIFO eviction | 51 distinct window IDs captured | Oldest entry evicted | PASS — logic correct |
| TC-17 | SCShareableContent cache reuse | Two thumbnails within 2.5s of same content | Single `SCShareableContent` query | PASS |
| TC-18 | DockAXHelper extraction — DockMonitor | Hover Dock icon | Correct app identified | PASS — `DockAXHelper.axFrame` delegates correctly |
| TC-19 | DockAXHelper extraction — PreviewPanelController | Panel positioned near icon | Icon center correctly computed | PASS — `DockAXHelper.dockIconElement` + `axFrame` |
| TC-20 | `resetToDefaults()` | Click reset button | All sliders return to defaults | PASS — each setter triggers `@AppStorage` update |
| TC-21 | Launch at login toggle — SMAppService failure | App not signed / no entitlement | Toggle appears set but system does not register | FAIL — ISSUE-P2-05 (silent failure) |
| TC-22 | Thumbnail generator — macOS 13 path | macOS 13 device | `captureWithCGWindow` used | PASS |
| TC-23 | `clearCache()` | Called externally | Both thumbnail and SCShareableContent caches cleared | PASS |

---

## Performance Analysis

### SCShareableContent Caching (P2-5)
The 2.5s TTL effectively eliminates the most expensive repeated call. On macOS 14+ with many open windows, `SCShareableContent.excludingDesktopWindows` can take 50–200ms. Caching this for 2.5s means sequential thumbnail requests for multiple windows of the same app (common in the 4-column grid) share a single query. This is a meaningful improvement.

### Thumbnail Cache FIFO Eviction (P2-5)
The FIFO eviction is appropriate for a thumbnail cache since recently-viewed windows are more likely to be re-viewed. The 0.5s TTL is short enough that entries will frequently expire before the count reaches 50 in normal use, making the eviction logic rarely triggered but correctly implemented for pathological cases (50+ apps open simultaneously).

### `WindowEnumerator` Second CGWindowList Query (P2-1)
The minimized window support adds a second `CGWindowListCopyWindowInfo` call (the `allWindowsDict` query at line 33). This query uses `.excludeDesktopElements` without `.optionOnScreenOnly`, which is broader and may return more entries. On a machine with 100+ open windows, this could be measurably slower than the on-screen-only query. The two queries are sequential on the calling thread; if `WindowEnumerator.windows(for:)` is called on the main thread (as it is in `AppDelegate.handleHover`), both queries block the main thread.

**Recommendation:** This is low risk at typical window counts (under 30) but could become an issue for power users. Consider moving `WindowEnumerator.windows(for:)` to a background task in Phase 3 if frame-rate sensitivity becomes a concern.

### Animation Thread Safety
`NSAnimationContext.runAnimationGroup` and `panel.animator()` are main-thread operations. `PreviewPanelController` is `@MainActor`-isolated, so all calls are correctly dispatched. The `Task { @MainActor }` in the completion handler correctly re-enters the main actor. No threading concerns.

---

## Security Considerations

No new security surface introduced in Phase 2. The preferences panel does not request any new permissions. `SMAppService.mainApp` is a standard login-item registration API and does not require privileged entitlements beyond correct bundle setup. `UserDefaults.standard` access patterns are unchanged.

---

## Overall Verdict

**PASS WITH CONDITIONS**

Phase 2 is well-implemented and represents a significant improvement in code quality over Phase 1. The DockAXHelper extraction eliminates a real maintainability risk. The fade animations are correctly guarded against race conditions. The preferences architecture is clean.

---

## Required fixes before Phase 3

1. **ISSUE-P2-04 (HIGH):** Fix `WindowThumbnailCard.thumbSize` to read from `AppSettings`. Update `LazyVGrid` column width in `PreviewPanelView` accordingly. The thumbnail size preference currently has no visible effect — this is a P2-4 integration gap that makes the entire settings feature appear non-functional.

2. **ISSUE-P2-02 (MEDIUM):** When `captureWithSCKit` cannot find the target window in cached `SCShareableContent`, invalidate the content cache before the CGWindow fallback to ensure SCKit quality is restored on the next capture attempt.

3. **ISSUE-P2-05 (MEDIUM):** Surface `SMAppService` failure state in the UI. At minimum, read `SMAppService.mainApp.status` on settings view appearance to reconcile the toggle's visual state with the actual system state.

## Recommended but non-blocking

4. **ISSUE-P2-06 (LOW):** Handle minimized settings window in `openSettings()` using `isMiniaturized` check.
5. **ISSUE-P2-01 (MEDIUM):** Correct the `DockAXHelper` coordinate system comment. Add a note that mouse vs. AX frame comparison is an approximation. Plan a proper coordinate transform in Phase 3 for correctness on non-standard Dock configurations.
6. **INFO (SettingsView):** Replace `@StateObject` with `@ObservedObject` for the `AppSettings.shared` singleton reference.
7. **INFO (DockMonitor):** Expose `AppSettings.Keys.hoverDelay` (at least `internal`) to eliminate the duplicated string literal.
