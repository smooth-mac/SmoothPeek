# =============================================================================
# SmoothPeek — Makefile
# =============================================================================
#
# 타겟 목록:
#   make build         — swift build -c release (실행 파일만)
#   make icons         — SVG → PNG/ICNS 아이콘 생성 (librsvg 필요)
#   make bundle        — .app 번들 생성 (서명 없음)
#   make sign          — 번들 빌드 + 코드서명 (DEVELOPER_ID_APP 필요)
#   make dmg           — 번들 빌드 + DMG 패키징 (서명 있으면 서명 포함)
#   make release       — 서명 + 공증 + 스테이플 + DMG (전체 파이프라인)
#   make clean         — 빌드 아티팩트 제거 (.build, dist)
#   make verify        — 서명/공증 상태 검사
#   make run           — 디버그 빌드 후 즉시 실행
#   make help          — 이 도움말 출력
#
# 서명/공증 환경 변수:
#   DEVELOPER_ID_APP   Developer ID Application 인증서 이름
#   NOTARY_PROFILE     xcrun notarytool keychain profile 이름 (권장)
#   APPLE_ID           Apple ID 이메일 (keychain profile 미사용 시)
#   APPLE_TEAM_ID      Apple 팀 ID    (keychain profile 미사용 시)
#   APP_PASSWORD       앱 전용 암호   (keychain profile 미사용 시)
#
# 예시:
#   make dmg DEVELOPER_ID_APP="Developer ID Application: Juho Lee (XXXXXXXXXX)"
#   make release DEVELOPER_ID_APP="..." NOTARY_PROFILE="SmoothPeek-Notary"
# =============================================================================

# --------------------------------------------------------------------------
# 기본 설정 — 필요하면 환경 변수로 오버라이드 가능
# --------------------------------------------------------------------------
APP_NAME        := SmoothPeek
PROJECT_ROOT    := $(shell pwd)
SCRIPTS_DIR     := $(PROJECT_ROOT)/scripts
DIST_DIR        := $(PROJECT_ROOT)/dist

# Developer ID — 환경 변수에서 가져오거나 빈 값 허용
DEVELOPER_ID_APP ?=
NOTARY_PROFILE   ?=
APPLE_ID         ?=
APPLE_TEAM_ID    ?=
APP_PASSWORD     ?=
NOTARIZE         ?= 0

# Xcode 프로젝트 관련 설정
XCODE_PROJECT   := $(PROJECT_ROOT)/SmoothPeek.xcodeproj
XCODE_SCHEME    := SmoothPeek
TEAM_ID         := W9U59XWU3W
ARCHIVE_PATH    := $(PROJECT_ROOT)/dist/SmoothPeek.xcarchive
EXPORT_PATH     := $(PROJECT_ROOT)/dist/mas-export

# --------------------------------------------------------------------------
# PHONY 선언
# --------------------------------------------------------------------------
.PHONY: all build icons bundle sign dmg release clean verify run help \
        xcode-gen xcode-build xcode-archive xcode-export xcode-sandbox-verify xcode-clean

# --------------------------------------------------------------------------
# 기본 타겟
# --------------------------------------------------------------------------
all: build

# --------------------------------------------------------------------------
# build — swift build -c release
# --------------------------------------------------------------------------
build:
	@echo ""
	@echo "==> Building release binary..."
	swift build -c release
	@echo ""
	@echo "    Binary: $(PROJECT_ROOT)/.build/release/$(APP_NAME)"

# --------------------------------------------------------------------------
# icons — SVG → PNG/ICNS (librsvg 필요)
# --------------------------------------------------------------------------
icons:
	@echo ""
	@echo "==> Building icons..."
	bash "$(SCRIPTS_DIR)/build_icons.sh"

# --------------------------------------------------------------------------
# bundle — .app 번들 생성 (서명 없음, 빠른 개발 테스트용)
# --------------------------------------------------------------------------
bundle:
	@echo ""
	@echo "==> Assembling unsigned .app bundle..."
	bash "$(SCRIPTS_DIR)/build_release.sh"

# --------------------------------------------------------------------------
# sign — .app 번들 + 코드서명 (공증/DMG 없음)
# --------------------------------------------------------------------------
sign:
	@if [ -z "$(DEVELOPER_ID_APP)" ]; then \
		echo ""; \
		echo "ERROR: DEVELOPER_ID_APP is not set."; \
		echo "  Usage: make sign DEVELOPER_ID_APP=\"Developer ID Application: Name (TEAMID)\""; \
		echo ""; \
		exit 1; \
	fi
	@echo ""
	@echo "==> Building and signing..."
	DEVELOPER_ID_APP="$(DEVELOPER_ID_APP)" \
		bash "$(SCRIPTS_DIR)/build_release.sh"

# --------------------------------------------------------------------------
# dmg — 번들 + DMG 생성 (서명 있으면 서명 포함, 공증 없음)
# --------------------------------------------------------------------------
dmg:
	@echo ""
	@echo "==> Building DMG..."
	DEVELOPER_ID_APP="$(DEVELOPER_ID_APP)" \
		bash "$(SCRIPTS_DIR)/build_release.sh"
	@echo ""
	@echo "    DMG output: $(DIST_DIR)/"
	@ls -lh "$(DIST_DIR)"/*.dmg 2>/dev/null || true

# --------------------------------------------------------------------------
# release — 전체 파이프라인: 빌드 + 서명 + 공증 + 스테이플 + DMG
# --------------------------------------------------------------------------
release:
	@if [ -z "$(DEVELOPER_ID_APP)" ]; then \
		echo ""; \
		echo "ERROR: DEVELOPER_ID_APP is required for release."; \
		echo "  export DEVELOPER_ID_APP=\"Developer ID Application: Name (TEAMID)\""; \
		echo ""; \
		exit 1; \
	fi
	@if [ "$(NOTARIZE)" != "1" ]; then \
		echo ""; \
		echo "WARNING: NOTARIZE=1 not set — running without notarization."; \
		echo "  To notarize: make release NOTARIZE=1 NOTARY_PROFILE=<profile>"; \
		echo ""; \
	fi
	@echo ""
	@echo "==> Full release pipeline..."
	DEVELOPER_ID_APP="$(DEVELOPER_ID_APP)" \
	NOTARIZE="$(NOTARIZE)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	APPLE_ID="$(APPLE_ID)" \
	APPLE_TEAM_ID="$(APPLE_TEAM_ID)" \
	APP_PASSWORD="$(APP_PASSWORD)" \
		bash "$(SCRIPTS_DIR)/build_release.sh"

# --------------------------------------------------------------------------
# xcode-gen — project.yml → SmoothPeek.xcodeproj 재생성
# --------------------------------------------------------------------------
xcode-gen:
	@echo ""
	@echo "==> Regenerating Xcode project from project.yml..."
	xcodegen generate --spec "$(PROJECT_ROOT)/project.yml"
	@echo "    Created: $(XCODE_PROJECT)"

# --------------------------------------------------------------------------
# xcode-build — Xcode Debug 빌드 (서명 없음, 컴파일 검증용)
# --------------------------------------------------------------------------
xcode-build:
	@echo ""
	@echo "==> Xcode Debug build (unsigned, compile check)..."
	xcodebuild \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-configuration Debug \
		-destination "platform=macOS" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)|note:" | grep -v "^$$"

# --------------------------------------------------------------------------
# xcode-archive — MAS 제출용 Archive 생성 (Apple Development 인증서 필요)
#
# MAS 제출은 xcodebuild archive → xcodebuild -exportArchive 두 단계로 진행.
# 팀 ID: TEAM_ID 변수 (기본: W9U59XWU3W)
# --------------------------------------------------------------------------
xcode-archive:
	@echo ""
	@echo "==> Creating Xcode Archive for MAS submission..."
	@mkdir -p "$(PROJECT_ROOT)/dist"
	xcodebuild archive \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-configuration Release \
		-destination "generic/platform=macOS" \
		-archivePath "$(ARCHIVE_PATH)" \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		CODE_SIGN_STYLE=Automatic \
		2>&1 | grep -E "error:|warning:|ARCHIVE (SUCCEEDED|FAILED)|Archive" | grep -v "^$$"
	@echo ""
	@echo "    Archive: $(ARCHIVE_PATH)"
	@ls -la "$(ARCHIVE_PATH)" 2>/dev/null || echo "    WARNING: Archive not found"

# --------------------------------------------------------------------------
# xcode-export — Archive → MAS IPA/pkg 내보내기
#
# ExportOptions.plist가 필요합니다. scripts/ExportOptions.plist 를 참조하세요.
# --------------------------------------------------------------------------
xcode-export:
	@if [ ! -d "$(ARCHIVE_PATH)" ]; then \
		echo ""; \
		echo "ERROR: Archive not found at $(ARCHIVE_PATH)"; \
		echo "  Run 'make xcode-archive' first."; \
		echo ""; \
		exit 1; \
	fi
	@echo ""
	@echo "==> Exporting Archive for Mac App Store..."
	@mkdir -p "$(EXPORT_PATH)"
	xcodebuild -exportArchive \
		-archivePath "$(ARCHIVE_PATH)" \
		-exportPath "$(EXPORT_PATH)" \
		-exportOptionsPlist "$(PROJECT_ROOT)/scripts/ExportOptions.plist" \
		2>&1 | grep -E "error:|warning:|EXPORT (SUCCEEDED|FAILED)" | grep -v "^$$"
	@echo ""
	@echo "    Exported to: $(EXPORT_PATH)"
	@ls -la "$(EXPORT_PATH)/" 2>/dev/null || true

# --------------------------------------------------------------------------
# xcode-sandbox-verify — 빌드된 Debug .app의 sandbox/entitlement 적용 확인
# --------------------------------------------------------------------------
xcode-sandbox-verify:
	@echo ""
	@echo "==> Verifying Sandbox & Entitlements on Xcode Debug build..."
	@APP_PATH=$$(xcodebuild -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| grep " BUILT_PRODUCTS_DIR " | awk '{print $$3}'); \
	APP_BUNDLE="$$APP_PATH/SmoothPeek.app"; \
	BINARY="$$APP_BUNDLE/Contents/MacOS/SmoothPeek"; \
	if [ ! -f "$$BINARY" ]; then \
		echo "  ERROR: Binary not found. Run 'make xcode-build' first."; \
		exit 1; \
	fi; \
	echo ""; \
	echo "  App bundle: $$APP_BUNDLE"; \
	echo ""; \
	echo "  --- Code Signature ---"; \
	codesign -dvvv "$$APP_BUNDLE" 2>&1 | grep -E "Identifier|TeamID|Flags|Entitlements" || true; \
	echo ""; \
	echo "  --- Entitlements embedded in binary ---"; \
	codesign -d --entitlements - "$$APP_BUNDLE" 2>/dev/null \
		| xmllint --format - 2>/dev/null || codesign -d --entitlements - "$$APP_BUNDLE" 2>&1 || true; \
	echo ""

# --------------------------------------------------------------------------
# xcode-clean — Xcode DerivedData 및 Archive 정리
# --------------------------------------------------------------------------
xcode-clean:
	@echo ""
	@echo "==> Cleaning Xcode DerivedData..."
	rm -rf ~/Library/Developer/Xcode/DerivedData/SmoothPeek-*
	rm -rf "$(ARCHIVE_PATH)" "$(EXPORT_PATH)"
	@echo "    Done."

# --------------------------------------------------------------------------
# clean — 빌드 아티팩트 및 dist 폴더 삭제
# --------------------------------------------------------------------------
clean:
	@echo ""
	@echo "==> Cleaning build artifacts..."
	swift package clean
	rm -rf "$(DIST_DIR)"
	@echo "    Removed: .build/, dist/"

# --------------------------------------------------------------------------
# verify — 기존 번들/DMG의 서명 및 공증 상태 확인
# --------------------------------------------------------------------------
verify:
	@echo ""
	@echo "==> Verifying code signatures..."
	@APP_BUNDLE="$(DIST_DIR)/$(APP_NAME).app"; \
	DMG_PATH="$(DIST_DIR)/"*.dmg; \
	if [ -d "$$APP_BUNDLE" ]; then \
		echo ""; \
		echo "  .app bundle: $$APP_BUNDLE"; \
		codesign --verify --deep --strict --verbose=2 "$$APP_BUNDLE" 2>&1 | \
			sed 's/^/    /'; \
		echo ""; \
		echo "  spctl (app):"; \
		spctl --assess --type execute --verbose "$$APP_BUNDLE" 2>&1 | sed 's/^/    /' || true; \
	else \
		echo "  No .app bundle found at $$APP_BUNDLE"; \
		echo "  Run 'make dmg' first."; \
	fi
	@for dmg in $(DIST_DIR)/*.dmg; do \
		if [ -f "$$dmg" ]; then \
			echo ""; \
			echo "  DMG: $$dmg"; \
			xcrun stapler validate --verbose "$$dmg" 2>&1 | sed 's/^/    /' || true; \
			spctl --assess --type open --context context:primary-signature --verbose "$$dmg" 2>&1 | \
				sed 's/^/    /' || true; \
		fi; \
	done

# --------------------------------------------------------------------------
# run — 디버그 빌드 후 즉시 실행 (개발 중 빠른 확인용)
# --------------------------------------------------------------------------
run:
	@echo ""
	@echo "==> Building (debug) and running..."
	swift build
	"$(PROJECT_ROOT)/.build/debug/$(APP_NAME)"

# --------------------------------------------------------------------------
# help
# --------------------------------------------------------------------------
help:
	@echo ""
	@echo "SmoothPeek Build System"
	@echo ""
	@echo "Usage: make [target] [VAR=value ...]"
	@echo ""
	@echo "--- SPM 기반 타겟 (Direct / Developer ID 배포) ---"
	@echo "  build       swift build -c release (실행 파일만)"
	@echo "  icons       SVG → PNG/ICNS 아이콘 생성 (brew install librsvg 필요)"
	@echo "  bundle      .app 번들 생성 (서명 없음)"
	@echo "  sign        .app 번들 + 코드서명"
	@echo "  dmg         .app 번들 + DMG 패키징"
	@echo "  release     서명 + 공증 + 스테이플 + DMG (전체 파이프라인)"
	@echo "  verify      기존 번들/DMG 서명 상태 확인"
	@echo "  run         디버그 빌드 후 즉시 실행"
	@echo "  clean       빌드 아티팩트 제거 (.build, dist)"
	@echo ""
	@echo "--- Xcode 기반 타겟 (Mac App Store 제출) ---"
	@echo "  xcode-gen             project.yml → SmoothPeek.xcodeproj 재생성"
	@echo "  xcode-build           Xcode Debug 빌드 (서명 없음, 컴파일 검증)"
	@echo "  xcode-sandbox-verify  Debug 빌드의 sandbox/entitlement 적용 확인"
	@echo "  xcode-archive         MAS 제출용 Archive 생성 (.xcarchive)"
	@echo "  xcode-export          Archive → MAS .pkg 내보내기"
	@echo "  xcode-clean           Xcode DerivedData 및 Archive 정리"
	@echo ""
	@echo "Variables:"
	@echo "  DEVELOPER_ID_APP   \"Developer ID Application: Name (TEAMID)\""
	@echo "  TEAM_ID            Apple 팀 ID (10자리, 기본: W9U59XWU3W)"
	@echo "  NOTARIZE           1 로 설정하면 공증 수행"
	@echo "  NOTARY_PROFILE     xcrun notarytool keychain profile (권장)"
	@echo "  APPLE_ID           Apple ID 이메일"
	@echo "  APPLE_TEAM_ID      Apple 팀 ID (keychain profile 미사용 시)"
	@echo "  APP_PASSWORD       앱 전용 암호"
	@echo ""
	@echo "MAS 제출 순서:"
	@echo "  1. make xcode-gen           (최초 또는 project.yml 변경 시)"
	@echo "  2. make xcode-build         (컴파일 검증)"
	@echo "  3. make xcode-archive       (배포 Archive 생성)"
	@echo "  4. make xcode-export        (MAS .pkg 내보내기)"
	@echo "  5. Transporter 또는 Xcode Organizer로 App Store Connect에 업로드"
	@echo ""
	@echo "Examples:"
	@echo "  make xcode-build"
	@echo "  make xcode-archive TEAM_ID=W9U59XWU3W"
	@echo "  make dmg DEVELOPER_ID_APP=\"Developer ID Application: Juho Lee (W9U59XWU3W)\""
	@echo "  make release DEVELOPER_ID_APP=\"...\" NOTARIZE=1 NOTARY_PROFILE=\"SmoothPeek-Notary\""
	@echo ""
