# DockPeek Swift Engineer — Persistent Memory

## Project Structure
- Project renamed DockPeek → SmoothPeek (refactor commit 3af0e7f)
- App/Core/UI layer architecture via Swift Package Manager
- Minimum deployment: **macOS 14 (Sonoma)** — upgraded from 13 for MAS porting
- Key source root: `Sources/SmoothPeek/`
- Bundle ID: com.juholee.SmoothPeek; version 1.0.0
- MAS build flag: `-Xswiftc -DMAS_BUILD` (defined in Package.swift comment; app sandbox ON)

## SPM executableTarget Resource Constraints (P3-5)
- **Info.plist cannot be in `resources:` array** — SPM rejects it with "forbidden as top-level resource".
  Solution: add to `exclude:` in Package.swift; build_release.sh copies it to Contents/ directly.
- **SVG files must be excluded** from the target to avoid "unhandled file" warnings.
  Add all .svg files in Resources/ to `exclude:` in Package.swift.
- **Assets.xcassets** with no PNG files: actool silently skips generating Assets.car.
  build_release.sh falls back to calling `xcrun actool` directly to produce Assets.car.
- SPM resource bundle for executableTarget is named `SmoothPeek_SmoothPeek.bundle` (not Assets.car).

## Distribution Pipeline (P3-5)
- `scripts/build_release.sh` — full pipeline: swift build → .app bundle → codesign → notarize → staple → DMG
- `Makefile` — convenience targets: make build / icons / bundle / sign / dmg / release / clean / verify / run
- `dist/` directory holds SmoothPeek.app and SmoothPeek-{version}.dmg after make dmg
- Signing: `DEVELOPER_ID_APP` env var; hardened runtime via `--options runtime --timestamp`
- Notarization: `NOTARIZE=1` + `NOTARY_PROFILE` (keychain, preferred) or `APPLE_ID`/`APPLE_TEAM_ID`/`APP_PASSWORD`
- **App Sandbox ON** (MAS requirement); entitlements at `SmoothPeek.entitlements` in project root
  - `com.apple.security.app-sandbox = true`
  - `com.apple.security.accessibility = true`
  - `com.apple.security.screen-capture = true`

## Known Swift Constraints (macOS/AppKit)
- **`@available` on stored properties is not allowed.** When a property type belongs to a newer SDK
  (e.g., `SCShareableContent`), use `Any?` boxing + a separate timestamp/flag, then cast with `as?`
  inside the `@available` guarded method. See `ThumbnailGenerator.swift` for the pattern.

## Established Patterns
- `ThumbnailGenerator`: `@MainActor` singleton; `Any?`-boxed `cachedShareableContent` (TTL 2.5s);
  FIFO thumbnail cache capped at 50 entries via parallel `cacheInsertionOrder: [CGWindowID]` array.
- Cache eviction helper extracted into `storeThumbnailInCache()` to keep `thumbnail(for:size:)` readable.

## WindowInfo Model
- Fields: `id: CGWindowID`, `title: String`, `frame: CGRect`, `isMinimized: Bool`, `pid: pid_t`
- `isOnScreen` was removed in P2-1 (never used outside the enumerator).
- `isMinimized` added in P2-1; used by ThumbnailGenerator (skip capture) and WindowThumbnailCard (badge UI).

## WindowEnumerator Strategy (P2-1)
- Two-pass CGWindowList query:
  1. `[.optionOnScreenOnly, .excludeDesktopElements]` -> normal visible windows (`isMinimized: false`)
  2. `.excludeDesktopElements` only -> filter `kCGWindowIsOnscreen == false && layer == 0` -> minimized windows
- Deduplicate by window ID (Set of on-screen IDs).
- Other-Space windows are also `isOnscreen == false` but CGWindowList typically does not expose them;
  cross-Space filtering is deferred to P2-2.

## WindowActivator: Minimized Window Restoration
- Minimized windows have no AX position/size, so frame-based `matchesWindow` fails for them.
- Separate path `restoreAndActivate`: iterate AX windows, check `kAXMinimizedAttribute == true`,
  match by title only, then set `kAXMinimizedAttribute = false` to restore.
- After 0.1s delay: `app.activate` + `kAXMainAttribute = true` + `kAXRaiseAction`.
- Fallback: if AX access unavailable, call `app.activate` only.

## PreviewPanelController: Fade Animation (P2-3 / P3-4)
- `isFadingOut: Bool` flag tracks ongoing fade-out; `show()` resets it + sets `alphaValue = 0` to interrupt.
- `NSAnimationContext.runAnimationGroup` completionHandler is treated as a `Sendable` closure — wrap
  `@MainActor` property access with `Task { @MainActor in ... }` inside the handler.
- `NSPanel` has no `.layer` property (it's `NSWindow`, not `NSView`); never call `panel.layer?.removeAllAnimations()`.
- `makePanel()` sets initial `alphaValue = 0` so the panel is invisible before the first fade-in.
- `hide()` guards on `panel.isVisible` to skip animation when panel is already hidden.
- Animation gated on `AppSettings.shared.animationEnabled`: when false, `show()` sets `alphaValue = 1` directly
  and `hide()` calls `panel.orderOut(nil)` immediately (no NSAnimationContext, `isFadingOut` stays false).

## WindowThumbnailView: Dynamic Thumbnail Size (P2-QA)
- `WindowThumbnailCard` and `PreviewPanelView` use `@ObservedObject private var settings = AppSettings.shared`.
- `thumbSize` is a computed property (`CGSize(width: settings.thumbnailWidth, height: settings.thumbnailHeight)`),
  NOT a stored `let` — so it reflects settings changes live.
- `.task(id: thumbSize)` ensures thumbnail is re-captured when size changes.
- `LazyVGrid` column width also uses `settings.thumbnailWidth` (not hardcoded 200).
- `ThumbnailGenerator.thumbnail(for:size:)` returns `nil` immediately for minimized windows;
  the card never enters the loading state for them.

## AppSettings (P2-4 / P2-QA / P3-4)
- `@MainActor final class AppSettings: ObservableObject` singleton at `Sources/SmoothPeek/App/AppSettings.swift`.
- `@AppStorage` keys: `hoverDelay` (0.4s), `thumbnailWidth` (200), `thumbnailHeight` (130), `launchAtLogin` (false),
  `animationEnabled` (true), `showMinimizedWindows` (true), `panelToggleKey` ("").
- All keys documented with `///` doc comments in `Keys` enum; `Defaults` enum mirrors every key.
- `Keys` enum is **internal** (not private) so non-MainActor contexts can reference keys.
- `launchAtLogin.didSet` → `applyLaunchAtLogin`: on register() failure, rolls back `launchAtLogin = false`
  and sets `lastLaunchAtLoginError: String?`; on success or unregister, error is nil.
- Non-MainActor contexts (DockMonitor, WindowEnumerator) read settings via
  `UserDefaults.standard.object(forKey: AppSettings.Keys.xxx).flatMap { $0 as? T } ?? AppSettings.Defaults.xxx`
  pattern — avoids `@MainActor` crossing with a safe optional cast fallback.
- `PreviewPanelController` reads `AppSettings.shared.*` directly (both are `@MainActor`).

## SettingsView (P2-4 / P2-QA / P3-4)
- SwiftUI Form at `Sources/SmoothPeek/UI/SettingsView.swift`; `LabeledSlider` (private) combines Slider + TextField.
- Sections: hoverSection, thumbnailSection, behaviorSection, shortcutSection, loginSection, updateSection, resetSection.
- `behaviorSection`: animationEnabled + showMinimizedWindows toggles.
- `shortcutSection`: `KeyRecorderField` (NSViewRepresentable) — click to record, Delete to clear, Escape to cancel.
  `KeyCaptureNSView` is a public NSView subclass (needed by NSViewRepresentable); `KeyRecorderField` is private struct.
- `updateSection`: "업데이트 확인" button with `// TODO: Sparkle integration (P3-6)` stub (no `#if DEBUG` guard).
- `LabeledSlider` Slider has `.accessibilityLabel(label)` + `.accessibilityValue("\(value) \(unit)")`.
- Uses `@ObservedObject` (NOT `@StateObject`) — singleton is owned externally, view does not own it.
- macOS 14+: `onChange(of:)` uses **two-parameter** closure `{ _, newValue in }`.
- Settings window opened via `AppDelegate.openSettings()`: `NSApp.activate(ignoringOtherApps: true)` required.
- Window is kept in `settingsWindow: NSWindow?` (isReleasedWhenClosed = false) for single-instance reuse.

## ThumbnailGenerator: SCKit Only (MAS port)
- **CGWindowListCreateImage removed** — macOS 14+ / MAS requires SCKit only.
- Cache invalidation: when windowID not found in cached `SCShareableContent`, invalidate cache
  and call `captureWithSCKitRetry()` (1 retry with fresh fetch) instead of CGWindow fallback.
- `@available(macOS 14.0, *)` guards on `captureWithSCKit` removed — whole class is 14+ now.
- `cachedShareableContent: Any?` boxing pattern retained (stored property @available restriction).

## DockMonitor: NSEvent (MAS port)
- **CGEventTap completely removed** — replaced with `NSEvent.addGlobalMonitorForEvents(.mouseMoved)`.
- NSEvent monitor is MAS sandbox compatible; no Input Monitoring permission needed.
- **Coordinate conversion**: `NSEvent.mouseLocation` is NS coords (bottom-left origin).
  Convert to CG coords: `cgY = primaryScreenHeight - nsY` via `DockMonitor.nsToCG(_:)`.
- `AXIsProcessTrusted()` check in `setupMouseMonitor()` — fires `onPermissionError` if false.
- `stop()` calls `NSEvent.removeMonitor()` instead of `CGEvent.tapEnable(tap:enable:false)`.

## WindowActivator: Private API Removed (MAS port)
- `@_silgen_name("_AXUIElementGetWindow")` **removed** — Private API banned in MAS.
- **kAXWindowIdentifierAttribute investigation result**: not in public SDK (AXWindowIdentifier
  returns -25205 kAXErrorAttributeUnsupported at runtime). Cannot replace private API.
- frame + title comparison is now the sole matching strategy (was previously fallback).
- `app.activate(options: [.activateIgnoringOtherApps])` → `app.activate()` (deprecated macOS 14).

## SettingsView: macOS 14 API (MAS port)
- `onChange(of:)` updated to two-parameter form `{ _, newValue in }` (macOS 14+).
  (Previously single-argument form was used for macOS 13 compatibility.)
