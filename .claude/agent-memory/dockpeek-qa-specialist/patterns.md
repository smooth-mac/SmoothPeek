# DockPeek — Coding Patterns and Conventions

## Swift Concurrency Patterns
- Main-actor isolation via @MainActor on class declaration (PreviewPanelController, ThumbnailGenerator, AppSettings)
- DockMonitor is NOT @MainActor — it uses CGEventTap/Timer callbacks which fire on main run loop
- NSAnimationContext completion handlers are not guaranteed main thread — use `Task { @MainActor }` wrapper
- @AppStorage didSet fires reliably when setter is called from Swift code; does NOT fire on external UserDefaults changes
- Use @ObservedObject (not @StateObject) for externally-owned singletons in SwiftUI views

## AX API Patterns
- Always CFGetTypeID() check before as! AXValue cast — guard block, not force-cast inline
- kAXURL returns CFURL not String — check CFGetTypeID() == CFURLGetTypeID()
- AX frame for Dock icons: compare with CGEvent mouse position directly (approximation only)
- DockAXHelper.axFrame() returns NS coordinates (NOT CG coordinates)
- Primary screen for Y-flip: NSScreen.screens.first (not NSScreen.main)

## Cache Patterns
- ThumbnailGenerator: thumbnail TTL 0.5s, SCShareableContent TTL 2.5s
- When SCKit window lookup fails in cached content, invalidate content cache before CGWindow fallback
- FIFO eviction: cacheInsertionOrder: [CGWindowID] array tracks insertion order; removeFirst() O(n)

## Settings Architecture
- AppSettings.Keys: private enum — duplicate string in DockMonitor ("hoverDelay") is a known technical debt
- Thumbnail width default: 200px, height default: 130px (NOT 120px — this caused Phase 2 ISSUE-P2-04)
- WindowThumbnailCard.thumbSize must match AppSettings values — easy to desync

## Window Enumeration
- Minimized windows: .excludeDesktopElements query + kCGWindowIsOnscreen == false filter
- On-screen windows: [.optionOnScreenOnly, .excludeDesktopElements]
- Dedup by CGWindowID Set before merging results
- layer == 0 filter required to exclude system UI windows from both queries

## Settings Window
- isReleasedWhenClosed = false ensures window survives close
- isVisible returns false for minimized windows — must also check isMiniaturized
- NSWindow singleton pattern in AppDelegate: check existing.isVisible || existing.isMiniaturized
