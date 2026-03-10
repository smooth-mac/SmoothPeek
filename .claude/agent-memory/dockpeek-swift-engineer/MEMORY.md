# DockPeek Swift Engineer — Persistent Memory

## Project Structure
- Project renamed DockPeek → SmoothPeek (refactor commit 3af0e7f)
- App/Core/UI layer architecture via Swift Package Manager
- Minimum deployment: macOS 13 (Ventura); macOS 14+ branches use SCScreenshotManager
- Key source root: `Sources/SmoothPeek/`
- Bundle ID: com.juholee.SmoothPeek; version 1.0.0

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
- No App Sandbox (CGEventTap requires it disabled); entitlements at `SmoothPeek.entitlements` in project root

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

## PreviewPanelController: Fade Animation (P2-3)
- `isFadingOut: Bool` flag tracks ongoing fade-out; `show()` resets it + sets `alphaValue = 0` to interrupt.
- `NSAnimationContext.runAnimationGroup` completionHandler is treated as a `Sendable` closure — wrap
  `@MainActor` property access with `Task { @MainActor in ... }` inside the handler.
- `NSPanel` has no `.layer` property (it's `NSWindow`, not `NSView`); never call `panel.layer?.removeAllAnimations()`.
- `makePanel()` sets initial `alphaValue = 0` so the panel is invisible before the first fade-in.
- `hide()` guards on `panel.isVisible` to skip animation when panel is already hidden.

## WindowThumbnailView: Dynamic Thumbnail Size (P2-QA)
- `WindowThumbnailCard` and `PreviewPanelView` use `@ObservedObject private var settings = AppSettings.shared`.
- `thumbSize` is a computed property (`CGSize(width: settings.thumbnailWidth, height: settings.thumbnailHeight)`),
  NOT a stored `let` — so it reflects settings changes live.
- `.task(id: thumbSize)` ensures thumbnail is re-captured when size changes.
- `LazyVGrid` column width also uses `settings.thumbnailWidth` (not hardcoded 200).
- `ThumbnailGenerator.thumbnail(for:size:)` returns `nil` immediately for minimized windows;
  the card never enters the loading state for them.

## AppSettings (P2-4 / P2-QA)
- `@MainActor final class AppSettings: ObservableObject` singleton at `Sources/SmoothPeek/App/AppSettings.swift`.
- `@AppStorage` keys: `hoverDelay` (0.4s), `thumbnailWidth` (200), `thumbnailHeight` (130), `launchAtLogin` (false).
- `Keys` enum is **internal** (not private) so DockMonitor can reference `AppSettings.Keys.hoverDelay`.
- `launchAtLogin.didSet` → `applyLaunchAtLogin`: on register() failure, rolls back `launchAtLogin = false`
  and sets `lastLaunchAtLoginError: String?`; on success or unregister, error is nil.
- `DockMonitor` reads hoverDelay via `UserDefaults.standard.double(forKey: AppSettings.Keys.hoverDelay)`
  and falls back to `AppSettings.Defaults.hoverDelay` — avoids `@MainActor` crossing.
- `PreviewPanelController.preferredSize` reads `AppSettings.shared.thumbnailWidth/Height` directly
  (both are `@MainActor` and `preferredSize` is called from `@MainActor` context — safe).

## SettingsView (P2-4 / P2-QA)
- SwiftUI Form at `Sources/SmoothPeek/UI/SettingsView.swift`; `LabeledSlider` (private) combines Slider + TextField.
- Uses `@ObservedObject` (NOT `@StateObject`) — singleton is owned externally, view does not own it.
- macOS 13 constraint: `onChange(of:)` must use **single-argument** closure `{ newValue in }`.
- `loginSection` shows a red error Text below the Toggle when `settings.lastLaunchAtLoginError != nil`.
- Settings window opened via `AppDelegate.openSettings()`: `NSApp.activate(ignoringOtherApps: true)`
  is required because the app runs as `.accessory` policy (no Dock icon = no auto-focus).
- Window is kept in `settingsWindow: NSWindow?` (isReleasedWhenClosed = false) for single-instance reuse.
- `openSettings()` checks `settingsWindow != nil` (not `isVisible`) — handles minimized state via
  `isMiniaturized` check + `deminiaturize(nil)` before `makeKeyAndOrderFront`.

## ThumbnailGenerator: SCKit Cache Invalidation (P2-QA)
- When `captureWithSCKit` cannot find a windowID in cached `SCShareableContent`, it sets
  `cachedShareableContent = nil` and `shareableContentTimestamp = nil` before CGWindow fallback.
- This ensures the next call triggers a fresh `SCShareableContent` fetch, recovering SCKit quality
  for newly opened windows without waiting for the 2.5s TTL to expire.
