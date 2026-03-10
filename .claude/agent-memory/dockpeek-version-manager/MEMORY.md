# DockPeek / SmoothPeek Version Manager Memory

## Project Identity
- Original name: DockPeek (renamed to SmoothPeek in commit 3af0e7f, 2026-03-10)
- Working directory: /Users/juholee/SmoothPeek
- Bundle ID: com.juholee.SmoothPeek
- Platform: macOS 13+, Swift Package (Package.swift, no Xcode project file)
- Source layout: Sources/SmoothPeek/{App,Core,UI}/

## Current Version History
- v1.0.0 — 2026-03-10 — First public release (Phase 1 + Phase 2 complete)
  - CFBundleShortVersionString: 1.0.0 | CFBundleVersion: 1

## Key Files
- /Users/juholee/SmoothPeek/CHANGELOG.md          — version changelog (created P3-9)
- /Users/juholee/SmoothPeek/Sources/SmoothPeek/Info.plist — bundle version metadata (created P3-9)
- /Users/juholee/SmoothPeek/Package.swift          — Swift PM manifest
- /Users/juholee/SmoothPeek/SmoothPeek.entitlements

## Source Files (as of v1.0.0)
App/: AppDelegate.swift, AppSettings.swift, SmoothPeekApp.swift
Core/: DockAXHelper.swift, DockMonitor.swift, ThumbnailGenerator.swift, WindowActivator.swift, WindowEnumerator.swift
UI/: PreviewPanelController.swift, SettingsView.swift, WindowThumbnailView.swift

## Release Conventions
- Version prefix: v (e.g., v1.0.0)
- CFBundleVersion increments by 1 per release (integer build number)
- CHANGELOG format: Keep a Changelog (https://keepachangelog.com/en/1.0.0/)
- All changelog and version files: English only (international distribution)

## Development Phase Mapping
- Phase 1 (2026-03-09): Initial implementation — CGEventTap hover, ScreenCaptureKit thumbnails, AX window activation, QA fixes
- Phase 2 (2026-03-09–10): Minimized windows, fade animation, preferences panel, DockAXHelper refactor, rename to SmoothPeek, QA fixes
- v1.0.0 marks the completion of Phase 1 + Phase 2

## Notes
- Project uses LSUIElement=true (menu bar / agent app, no Dock icon for itself)
- Requires Accessibility + Screen Recording entitlements
- No Xcode project — Swift Package Manager only
