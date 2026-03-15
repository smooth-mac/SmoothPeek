#!/usr/bin/env bash
# =============================================================================
# SmoothPeek — Icon Build Script
# =============================================================================
# Converts SVG master assets to PNG exports and builds AppIcon.icns
#
# Requirements:
#   - rsvg-convert (librsvg): brew install librsvg
#   - sips (built-in macOS)
#   - iconutil (built-in macOS)
#
# Usage:
#   chmod +x scripts/build_icons.sh
#   ./scripts/build_icons.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$PROJECT_ROOT/Sources/SmoothPeek/Resources"
OUTPUT="$PROJECT_ROOT/Sources/SmoothPeek/Resources"
ICONSET_DIR="$OUTPUT/AppIcon.iconset"

echo "[SmoothPeek] Starting icon build..."
echo "  Project root: $PROJECT_ROOT"
echo "  Resources:    $RESOURCES"

# -----------------------------------------------------------------------------
# 0. Verify dependencies
# -----------------------------------------------------------------------------
if ! command -v rsvg-convert &>/dev/null; then
    echo ""
    echo "ERROR: rsvg-convert not found."
    echo "  Install with: brew install librsvg"
    echo ""
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. Generate App Icon PNG at all required macOS iconset sizes
#    macOS iconset requires: 16, 32, 64, 128, 256, 512, 1024 (both @1x and @2x)
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] Generating App Icon PNG sizes from SVG..."

mkdir -p "$ICONSET_DIR"

SVG_APPICON="$RESOURCES/AppIcon.svg"

declare -a SIZES=(16 32 64 128 256 512 1024)

for SIZE in "${SIZES[@]}"; do
    echo "      Rendering ${SIZE}x${SIZE}..."
    rsvg-convert \
        --width="$SIZE" \
        --height="$SIZE" \
        --keep-aspect-ratio \
        --output="$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" \
        "$SVG_APPICON"
done

# macOS iconset naming convention requires specific filenames
# icon_SIZExSIZE.png  (@1x)
# icon_SIZExSIZE@2x.png  (@2x = SIZE*2 rendered at SIZE*2, named as SIZE)

# Rename to proper iconset format
echo "      Renaming to macOS iconset convention..."
mv "$ICONSET_DIR/icon_16x16.png"   "$ICONSET_DIR/icon_16x16.png"     # 16@1x
cp "$ICONSET_DIR/icon_32x32.png"   "$ICONSET_DIR/icon_16x16@2x.png"  # 16@2x
mv "$ICONSET_DIR/icon_32x32.png"   "$ICONSET_DIR/icon_32x32.png"     # 32@1x
cp "$ICONSET_DIR/icon_64x64.png"   "$ICONSET_DIR/icon_32x32@2x.png"  # 32@2x
mv "$ICONSET_DIR/icon_64x64.png"   "$ICONSET_DIR/icon_64x64.png"     # (not standard but harmless)
mv "$ICONSET_DIR/icon_128x128.png" "$ICONSET_DIR/icon_128x128.png"   # 128@1x
cp "$ICONSET_DIR/icon_256x256.png" "$ICONSET_DIR/icon_128x128@2x.png" # 128@2x
mv "$ICONSET_DIR/icon_256x256.png" "$ICONSET_DIR/icon_256x256.png"   # 256@1x
cp "$ICONSET_DIR/icon_512x512.png" "$ICONSET_DIR/icon_256x256@2x.png" # 256@2x
mv "$ICONSET_DIR/icon_512x512.png" "$ICONSET_DIR/icon_512x512.png"   # 512@1x
cp "$ICONSET_DIR/icon_1024x1024.png" "$ICONSET_DIR/icon_512x512@2x.png" # 512@2x
mv "$ICONSET_DIR/icon_1024x1024.png" "$ICONSET_DIR/icon_1024x1024.png"  # 1024 (App Store)

echo "      Iconset contents:"
ls -la "$ICONSET_DIR/"

# -----------------------------------------------------------------------------
# 2. Build AppIcon.icns from iconset
# -----------------------------------------------------------------------------
echo ""
echo "[2/4] Building AppIcon.icns with iconutil..."

ICNS_OUTPUT="$OUTPUT/AppIcon.icns"
iconutil --convert icns --output "$ICNS_OUTPUT" "$ICONSET_DIR"

echo "      Created: $ICNS_OUTPUT"
ls -lh "$ICNS_OUTPUT"

# -----------------------------------------------------------------------------
# 3. Generate Status Bar icons (template PNGs for NSStatusItem)
#    Template images must be black with alpha channel.
#    NSImage(named:) with isTemplate = true handles dark/light adaptation.
# -----------------------------------------------------------------------------
echo ""
echo "[3/4] Generating Status Bar Icon PNGs..."

SVG_STATUSBAR="$RESOURCES/StatusBarIcon.svg"

# @1x: 18x18 (standard density)
rsvg-convert \
    --width=18 \
    --height=18 \
    --keep-aspect-ratio \
    --output="$OUTPUT/StatusBarIcon_18.png" \
    "$SVG_STATUSBAR"

# @2x: 36x36 (Retina density)
rsvg-convert \
    --width=36 \
    --height=36 \
    --keep-aspect-ratio \
    --output="$OUTPUT/StatusBarIcon_36.png" \
    "$SVG_STATUSBAR"

echo "      Created: StatusBarIcon_18.png (18x18 @1x)"
echo "      Created: StatusBarIcon_36.png (36x36 @2x)"

# Also create the standard naming for asset catalogs
cp "$OUTPUT/StatusBarIcon_18.png" "$OUTPUT/statusbar_icon.png"
cp "$OUTPUT/StatusBarIcon_36.png" "$OUTPUT/statusbar_icon@2x.png"

# -----------------------------------------------------------------------------
# 4. Generate GitHub README banner (1200x630)
#    Uses the AppIcon SVG scaled and composited. We create a banner SVG first,
#    then rasterize. (Banner SVG is generated separately: READMEBanner.svg)
# -----------------------------------------------------------------------------
echo ""
echo "[4/4] Generating GitHub README Banner (1200x630)..."

BANNER_SVG="$RESOURCES/READMEBanner.svg"
if [ -f "$BANNER_SVG" ]; then
    rsvg-convert \
        --width=1200 \
        --height=630 \
        --keep-aspect-ratio \
        --output="$OUTPUT/README_banner.png" \
        "$BANNER_SVG"
    echo "      Created: README_banner.png (1200x630)"
else
    echo "      Skipping: READMEBanner.svg not found (run after creating it)"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  SmoothPeek Icon Build Complete"
echo "============================================================"
echo ""
echo "  Output files:"
echo "    $OUTPUT/AppIcon.icns          — Main app icon"
echo "    $OUTPUT/statusbar_icon.png    — Status bar @1x"
echo "    $OUTPUT/statusbar_icon@2x.png — Status bar @2x (Retina)"
echo "    $OUTPUT/README_banner.png     — GitHub social preview"
echo "    $ICONSET_DIR/               — All PNG sizes"
echo ""
echo "  Next steps:"
echo "    1. In Xcode: drag AppIcon.icns into AppIcon.xcassets"
echo "    2. Update AppDelegate.swift to use NSImage(named: 'statusbar_icon')"
echo "       and set .isTemplate = true"
echo "    3. Upload README_banner.png to docs/ and reference in README.md"
echo ""
