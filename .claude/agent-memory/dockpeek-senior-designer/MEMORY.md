# SmoothPeek Senior Designer — Persistent Memory

## Project Identity
- App: SmoothPeek (formerly DockPeek) — macOS Dock window preview utility
- Current phase: Phase 3 (distribution prep)
- Project root: /Users/juholee/SmoothPeek
- Package type: SPM executableTarget (no .xcodeproj yet)

## Brand Colors (established Phase 3)
- Background deep navy: #1C2B4A
- Background indigo: #2D2066
- Background dark violet: #1A0E3B
- Primary accent violet: #7B5CF5
- Light accent / selected: #A78BFA
- Glass white (highlights): rgba(255,255,255,0.22) → rgba(255,255,255,0.06)
- Titlebar dark: #3C4A6A (blue-dark), #3B2A6E (violet-dark), #264040 (teal-dark)

## Icon Design System (Phase 3, P3-7)
- App icon concept: "Dock 위에 떠오르는 창 미리보기" — three window thumbnails in a
  frosted glass panel, floating above a Dock bar with one icon highlighted/hovered
- macOS Big Sur design language: rounded square (rx=225/1024px), gradient bg, glass panels
- Status bar icon: monochrome template image — three window cards + dock bar motif,
  stroke-only, 18x18@1x / 36x36@2x
- README banner: 1200x630, left=icon, right=typography (SF Pro family)

## Key Asset Paths
- Master SVG (app icon): Sources/SmoothPeek/Resources/AppIcon.svg
- Master SVG (status bar): Sources/SmoothPeek/Resources/StatusBarIcon.svg
- Master SVG (README banner): Sources/SmoothPeek/Resources/READMEBanner.svg
- Asset catalog: Sources/SmoothPeek/Resources/Assets.xcassets/
- Build script: scripts/build_icons.sh (requires: brew install librsvg)

## Icon Build Pipeline
- Tool: rsvg-convert (librsvg) for SVG→PNG, iconutil for PNG→.icns
- Iconset sizes: 16, 32, 64, 128, 256, 512, 1024 (all generated from single SVG)
- Status bar naming: statusbar_icon.png (@1x) + statusbar_icon@2x.png (@2x)
- NSImage.isTemplate = true required for menu bar adaptation

## AppDelegate Status Bar Integration Note
- Current (temp): NSImage(systemSymbolName: "macwindow.on.rectangle")
- Target: NSImage(named: "StatusBarIcon") from Assets.xcassets with isTemplate=true
- See: Sources/SmoothPeek/App/AppDelegate.swift, setupStatusBar()

## Design Tool Preferences for SmoothPeek
- Midjourney: best for macOS utility aesthetic moodboards
- SVG programmatic: preferred for icons (infinite scale, version control friendly)
- rsvg-convert + iconutil: macOS native pipeline, no Xcode required for PNG/icns

## Links
- Detailed icon design notes: icon-design.md (create if needed)
