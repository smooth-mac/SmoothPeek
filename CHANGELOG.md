# Changelog

All notable changes to SmoothPeek will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v1.0.0] - 2026-03-10

### Added
- Dock icon hover detection via CGEventTap-based mouse monitoring (DockMonitor)
- App window preview panel displaying live thumbnails on Dock hover
- ScreenCaptureKit-based thumbnail capture with CGWindow API fallback (ThumbnailGenerator)
- SwiftUI thumbnail card UI with per-window title and app icon (WindowThumbnailView)
- Window activation on thumbnail click using AXUIElement and private `_AXUIElementGetWindow` API (WindowActivator)
- Minimized window support — minimized windows are included in the preview panel (P2-1)
- Fade in/out animation for the preview panel on show/hide (P2-3)
- Preferences panel with UserDefaults-backed settings: hover delay, thumbnail size, launch at login (P2-4)
- DockAXHelper module to centralize Accessibility API traversal and eliminate duplication
- ThumbnailGenerator SCShareableContent caching and thumbnail cache size cap for improved performance

### Changed
- Project renamed from DockPeek to SmoothPeek (all source files, Package.swift, bundle identifiers updated)
- Window thumbnail cards preserve the native window aspect ratio — no letterboxing
- Preview panel remains visible when the mouse moves from the Dock icon onto the panel itself
- Window activation order corrected: target window is raised via AX before app is brought to front, ensuring correct z-order
- `matchesWindow` coordinate comparison fixed: removed incorrect Y-flip — Accessibility API uses Core Graphics coordinates, not flipped AppKit coordinates
- Phase 2 QA stabilization: resolved panel stability regressions, window matching failures, and thumbnail sizing issues (P2-02, P2-04, P2-05, P2-06)

### Fixed
- Phase 1 QA issues resolved: AX URL type handling, mouse coordinate system alignment, and remaining stabilization recommendations
- Incorrect Y-axis flip in window matching logic that caused wrong windows to activate
- Window z-order regression where the wrong window appeared in front after activation
- Preview panel dismissing prematurely when mouse hovered over it
- Thumbnail cards stretching or letterboxing instead of preserving window aspect ratio

---

## [Unreleased]

_No unreleased changes at this time._

---

<!-- Version Links -->
[v1.0.0]: https://github.com/juholee/SmoothPeek/releases/tag/v1.0.0
[Unreleased]: https://github.com/juholee/SmoothPeek/compare/v1.0.0...HEAD
