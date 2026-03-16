#!/usr/bin/env bash
# =============================================================================
# SmoothPeek — Release Build & Distribution Pipeline
# =============================================================================
#
# 수행 단계:
#   1. swift build -c release  → 실행 파일
#   2. .app 번들 구조 생성      → Contents/{MacOS, Resources, Info.plist, icns}
#   3. codesign                → Developer ID Application (hardened runtime)
#   4. (옵션) notarytool submit → Apple 공증
#   5. (옵션) stapler staple   → 공증 티켓 스테이플
#   6. hdiutil create          → DMG 패키징
#
# 환경 변수 (모두 선택적 — 미설정 시 코드서명/공증 건너뜀):
#   DEVELOPER_ID_APP   Developer ID Application 인증서 이름
#                      예) "Developer ID Application: Juho Lee (XXXXXXXXXX)"
#   NOTARIZE           "1" 로 설정하면 공증 수행
#   APPLE_ID           공증용 Apple ID 이메일
#   APPLE_TEAM_ID      Apple 팀 ID (10자리)
#   APP_PASSWORD       앱 전용 암호 (App-Specific Password)
#                      또는 keychain profile: NOTARY_PROFILE 로 지정 가능
#   NOTARY_PROFILE     notarytool --keychain-profile 값 (keychain에 저장된 경우)
#
# 사용 예:
#   # 서명 없이 번들 + DMG만 생성 (테스트용)
#   ./scripts/build_release.sh
#
#   # 서명 + DMG
#   DEVELOPER_ID_APP="Developer ID Application: Juho Lee (XXXXXXXXXX)" \
#     ./scripts/build_release.sh
#
#   # 서명 + 공증 + DMG (keychain profile 방식)
#   DEVELOPER_ID_APP="Developer ID Application: Juho Lee (XXXXXXXXXX)" \
#     NOTARIZE=1 \
#     NOTARY_PROFILE="SmoothPeek-Notary" \
#     ./scripts/build_release.sh
#
#   # 서명 + 공증 + DMG (Apple ID/암호 직접 입력 방식)
#   DEVELOPER_ID_APP="Developer ID Application: Juho Lee (XXXXXXXXXX)" \
#     NOTARIZE=1 \
#     APPLE_ID="you@example.com" \
#     APPLE_TEAM_ID="XXXXXXXXXX" \
#     APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#     ./scripts/build_release.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 경로 / 설정
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="SmoothPeek"
EXECUTABLE="$APP_NAME"

# Info.plist에서 버전 및 번들 ID 읽기 (단일 소스 of truth)
INFO_PLIST="$PROJECT_ROOT/Sources/SmoothPeek/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "1.0.0")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || echo "com.smoothmac.smoothpeek")"

ENTITLEMENTS="$PROJECT_ROOT/SmoothPeek.entitlements"
RESOURCES_SRC="$PROJECT_ROOT/Sources/SmoothPeek/Resources"
ICONS_SRC="$RESOURCES_SRC/AppIcon.icns"

# 빌드 출력 경로
BUILD_DIR="$PROJECT_ROOT/.build/release"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${APP_VERSION}.dmg"
DMG_STAGING="$DIST_DIR/dmg_staging"

# 코드서명 환경 변수 (미설정 허용)
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

# -----------------------------------------------------------------------------
# 헬퍼 함수
# -----------------------------------------------------------------------------
log_step() { echo ""; echo "==> $1"; }
log_info() { echo "    $1"; }
log_ok()   { echo "    [OK] $1"; }
log_warn() { echo "    [WARN] $1"; }

die() {
    echo ""
    echo "ERROR: $1" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# 0. 사전 검증
# -----------------------------------------------------------------------------
log_step "Verifying environment"

if [ ! -f "$ENTITLEMENTS" ]; then
    die "Entitlements file not found: $ENTITLEMENTS"
fi

# ICNS 파일 존재 여부 확인 (없으면 build_icons.sh 자동 실행 or placeholder)
if [ ! -f "$ICONS_SRC" ]; then
    log_warn "AppIcon.icns not found at $ICONS_SRC"
    if command -v rsvg-convert &>/dev/null; then
        log_info "rsvg-convert found — running build_icons.sh to generate icns..."
        bash "$SCRIPT_DIR/build_icons.sh"
    else
        log_warn "rsvg-convert not found (install with: brew install librsvg)"
        log_warn "Proceeding without AppIcon.icns — bundle will have no custom icon."
        ICONS_SRC=""
    fi
fi

log_ok "Environment check passed"
log_info "App:        $APP_NAME $APP_VERSION"
log_info "Bundle ID:  $BUNDLE_ID"
log_info "Project:    $PROJECT_ROOT"
log_info "Dist dir:   $DIST_DIR"
if [ -n "$DEVELOPER_ID_APP" ]; then
    log_info "Sign as:    $DEVELOPER_ID_APP"
else
    log_warn "DEVELOPER_ID_APP not set — binary will NOT be codesigned."
fi

# -----------------------------------------------------------------------------
# 1. Swift Release 빌드
# -----------------------------------------------------------------------------
log_step "[1/6] Building release binary"

cd "$PROJECT_ROOT"
swift build -c release

BINARY="$BUILD_DIR/$EXECUTABLE"
if [ ! -f "$BINARY" ]; then
    die "Build succeeded but binary not found at: $BINARY"
fi

log_ok "Binary built: $BINARY"
log_info "$(file "$BINARY")"

# -----------------------------------------------------------------------------
# 2. .app 번들 구조 생성
# -----------------------------------------------------------------------------
log_step "[2/6] Assembling .app bundle"

# 기존 dist 디렉토리 초기화
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# macOS .app 번들 표준 구조
#   SmoothPeek.app/
#     Contents/
#       Info.plist
#       MacOS/
#         SmoothPeek          ← 실행 파일
#       Resources/
#         AppIcon.icns
#         Assets.car          ← SPM이 actool로 컴파일한 에셋 카탈로그
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"

# 실행 파일 복사
cp "$BINARY" "$APP_MACOS/$EXECUTABLE"

# Info.plist 복사
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"

# PkgInfo 파일 (APPL 시그니처 — Finder가 번들 인식에 사용)
printf 'APPL????' > "$APP_CONTENTS/PkgInfo"

# AppIcon.icns 복사 (있는 경우)
if [ -n "$ICONS_SRC" ] && [ -f "$ICONS_SRC" ]; then
    cp "$ICONS_SRC" "$APP_RESOURCES/AppIcon.icns"
    log_ok "AppIcon.icns included"
else
    log_warn "AppIcon.icns not included in bundle"
fi

# Assets.xcassets → Assets.car 컴파일
# 전략:
#   1. SPM이 actool을 정상 호출해 생성한 Assets.car를 우선 탐색
#   2. 없으면 xcrun actool을 직접 호출해 번들용 Assets.car 생성
#   이 방식은 PNG 파일이 xcassets에 아직 없어 SPM이 actool을 건너뛰는 경우도 커버한다.

XCASSETS_SRC="$RESOURCES_SRC/Assets.xcassets"
ACTOOL_OUTDIR="$DIST_DIR/.actool_output"

# SPM 빌드 결과에서 Assets.car 탐색
ASSETS_CAR=""
for candidate in \
    "$PROJECT_ROOT/.build/release/SmoothPeek.build/Assets.car" \
    "$PROJECT_ROOT/.build/release/SmoothPeek_SmoothPeek.bundle/Assets.car"
do
    if [ -f "$candidate" ]; then
        ASSETS_CAR="$candidate"
        break
    fi
done

# 못 찾은 경우 find로 추가 탐색
if [ -z "$ASSETS_CAR" ]; then
    ASSETS_CAR="$(find "$PROJECT_ROOT/.build" -name "Assets.car" 2>/dev/null | head -1 || true)"
fi

if [ -n "$ASSETS_CAR" ] && [ -f "$ASSETS_CAR" ]; then
    cp "$ASSETS_CAR" "$APP_RESOURCES/Assets.car"
    log_ok "Assets.car included (SPM build): $ASSETS_CAR"
elif [ -d "$XCASSETS_SRC" ] && command -v xcrun &>/dev/null; then
    # SPM이 Assets.car를 생성하지 않은 경우 actool 직접 호출
    log_info "Assets.car not found in SPM output — compiling with actool directly..."
    mkdir -p "$ACTOOL_OUTDIR"

    xcrun actool \
        --output-format human-readable-text \
        --notices \
        --warnings \
        --platform macosx \
        --minimum-deployment-target 13.0 \
        --compile "$ACTOOL_OUTDIR" \
        "$XCASSETS_SRC" 2>&1 | while IFS= read -r line; do log_info "  actool: $line"; done

    if [ -f "$ACTOOL_OUTDIR/Assets.car" ]; then
        cp "$ACTOOL_OUTDIR/Assets.car" "$APP_RESOURCES/Assets.car"
        log_ok "Assets.car compiled with actool: $APP_RESOURCES/Assets.car"
    else
        log_warn "actool did not produce Assets.car (xcassets may have no image files yet)."
        log_warn "Run 'scripts/build_icons.sh' to generate PNG assets, then rebuild."
    fi

    rm -rf "$ACTOOL_OUTDIR"
else
    log_warn "Assets.xcassets not found and actool unavailable — NSImage(named:) will return nil at runtime."
fi

log_ok "App bundle assembled: $APP_BUNDLE"
log_info "Bundle structure:"
find "$APP_BUNDLE" -type f | sed "s|$DIST_DIR/||" | sort | while IFS= read -r line; do
    log_info "  $line"
done

# -----------------------------------------------------------------------------
# 3. 코드서명 (Developer ID Application)
# -----------------------------------------------------------------------------
log_step "[3/6] Code signing"

if [ -z "$DEVELOPER_ID_APP" ]; then
    # 서명 인증서 없는 경우에도 ad-hoc으로 번들 전체를 재서명한다.
    # 이유: swift build의 linker-signed adhoc 서명은 Info.plist를 코드 디렉토리에
    # 바인딩하지 않는다(Info.plist=not bound). 그 결과 macOS TCC 시스템이
    # CFBundleIdentifier 대신 실행파일 이름(SmoothPeek)으로 앱을 식별해
    # 시스템 설정에서 권한을 허용해도 AXIsProcessTrusted()가 false를 반환하는 버그가 생긴다.
    # --sign - (ad-hoc) + --force로 번들 서명을 교체하면 Info.plist가 바인딩되어
    # CFBundleIdentifier가 올바르게 인식된다.
    log_info "No DEVELOPER_ID_APP set — applying ad-hoc signature to bind Info.plist."
    codesign \
        --sign - \
        --force \
        --deep \
        "$APP_BUNDLE"
    log_ok "Ad-hoc signature applied (Info.plist bound, identifier: $BUNDLE_ID)"
    log_warn "Ad-hoc signed binary is for local development only — not for distribution."
    log_warn "To sign for distribution: export DEVELOPER_ID_APP=\"Developer ID Application: Name (TEAMID)\""
else
    # Hardened Runtime 활성화 (--options runtime) — 공증 필수 조건
    # entitlements 파일로 예외 허용 (sandbox=false, accessibility, screen-capture)
    codesign \
        --sign "$DEVELOPER_ID_APP" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        --force \
        --deep \
        "$APP_BUNDLE"

    log_ok "Code signed with: $DEVELOPER_ID_APP"

    # 서명 검증
    log_info "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | \
        while IFS= read -r line; do log_info "$line"; done
    log_ok "Signature verified"

    # Gatekeeper 사전 검증 (공증 전에도 서명 유효성 확인 가능)
    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 | \
        while IFS= read -r line; do log_info "  spctl: $line"; done || \
        log_warn "spctl assess failed (expected before notarization — not an error)"
fi

# -----------------------------------------------------------------------------
# 4. DMG 생성 (공증 전 — ZIP 제출용)
# -----------------------------------------------------------------------------
log_step "[4/6] Creating distribution DMG"

# 임시 스테이징 디렉토리 (DMG 내부 레이아웃 구성)
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# /Applications 심볼릭 링크 추가 (드래그 설치 UX)
ln -sf /Applications "$DMG_STAGING/Applications"

# DMG 볼륨 이름 / 크기 자동 계산 (앱 크기 × 1.3 + 최소 10MB)
APP_SIZE_KB=$(du -sk "$APP_BUNDLE" | awk '{print $1}')
DMG_SIZE_MB=$(( (APP_SIZE_KB * 13 / 10 / 1024) + 10 ))

log_info "App bundle size: ${APP_SIZE_KB} KB"
log_info "DMG allocation: ${DMG_SIZE_MB} MB"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -size "${DMG_SIZE_MB}m" \
    "$DMG_PATH"

# 스테이징 디렉토리 정리
rm -rf "$DMG_STAGING"

log_ok "DMG created: $DMG_PATH"
log_info "DMG size: $(du -sh "$DMG_PATH" | awk '{print $1}')"

# -----------------------------------------------------------------------------
# 5. 공증 (NOTARIZE=1 인 경우)
# -----------------------------------------------------------------------------
log_step "[5/6] Notarization"

if [ "$NOTARIZE" != "1" ]; then
    log_warn "Skipping notarization (set NOTARIZE=1 to enable)."
else
    if [ -z "$DEVELOPER_ID_APP" ]; then
        die "Cannot notarize without DEVELOPER_ID_APP being set."
    fi

    log_info "Submitting DMG to Apple notarization service..."

    # keychain profile 방식 (권장 — 자격증명을 환경변수에 노출하지 않음)
    if [ -n "$NOTARY_PROFILE" ]; then
        log_info "Using keychain profile: $NOTARY_PROFILE"
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
    elif [ -n "$APPLE_ID" ] && [ -n "$APPLE_TEAM_ID" ] && [ -n "$APP_PASSWORD" ]; then
        log_info "Using Apple ID: $APPLE_ID (team: $APPLE_TEAM_ID)"
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APP_PASSWORD" \
            --wait
    else
        die "Notarization requires either NOTARY_PROFILE or (APPLE_ID + APPLE_TEAM_ID + APP_PASSWORD)."
    fi

    log_ok "Notarization complete"

    # -----------------------------------------------------------------------------
    # 6. Staple (공증 티켓을 DMG에 부착)
    # -----------------------------------------------------------------------------
    log_step "[6/6] Stapling notarization ticket"

    xcrun stapler staple "$DMG_PATH"
    log_ok "Stapled: $DMG_PATH"

    # 최종 Gatekeeper 검증
    log_info "Running final Gatekeeper assessment..."
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" 2>&1 | \
        while IFS= read -r line; do log_info "  spctl: $line"; done
    log_ok "Gatekeeper assessment passed"
fi

# -----------------------------------------------------------------------------
# 완료 요약
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  SmoothPeek $APP_VERSION — Build Complete"
echo "============================================================"
echo ""
echo "  App bundle : $APP_BUNDLE"
echo "  DMG        : $DMG_PATH"
if [ -n "$DEVELOPER_ID_APP" ]; then
    echo "  Signed     : YES ($DEVELOPER_ID_APP)"
else
    echo "  Signed     : NO (unsigned — development only)"
fi
if [ "$NOTARIZE" = "1" ]; then
    echo "  Notarized  : YES"
    echo "  Stapled    : YES"
else
    echo "  Notarized  : NO"
fi
echo ""
echo "  Distribute:"
echo "    - Share $DMG_PATH"
echo "    - Users: mount DMG → drag SmoothPeek.app to /Applications"
echo ""
