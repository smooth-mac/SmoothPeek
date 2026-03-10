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

# --------------------------------------------------------------------------
# PHONY 선언
# --------------------------------------------------------------------------
.PHONY: all build icons bundle sign dmg release clean verify run help

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
	@echo "Targets:"
	@echo "  build       swift build -c release (실행 파일만)"
	@echo "  icons       SVG → PNG/ICNS 아이콘 생성 (brew install librsvg 필요)"
	@echo "  bundle      .app 번들 생성 (서명 없음)"
	@echo "  sign        .app 번들 + 코드서명"
	@echo "  dmg         .app 번들 + DMG 패키징"
	@echo "  release     서명 + 공증 + 스테이플 + DMG (전체 파이프라인)"
	@echo "  clean       빌드 아티팩트 제거 (.build, dist)"
	@echo "  verify      기존 번들/DMG 서명 상태 확인"
	@echo "  run         디버그 빌드 후 즉시 실행"
	@echo "  help        이 도움말 출력"
	@echo ""
	@echo "Variables:"
	@echo "  DEVELOPER_ID_APP   \"Developer ID Application: Name (TEAMID)\""
	@echo "  NOTARIZE           1 로 설정하면 공증 수행"
	@echo "  NOTARY_PROFILE     xcrun notarytool keychain profile (권장)"
	@echo "  APPLE_ID           Apple ID 이메일"
	@echo "  APPLE_TEAM_ID      Apple 팀 ID (10자리)"
	@echo "  APP_PASSWORD       앱 전용 암호"
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make dmg"
	@echo "  make dmg DEVELOPER_ID_APP=\"Developer ID Application: Juho Lee (XXXXXXXXXX)\""
	@echo "  make release DEVELOPER_ID_APP=\"...\" NOTARIZE=1 NOTARY_PROFILE=\"SmoothPeek-Notary\""
	@echo ""
