#!/bin/bash
# Build only inside this repository. Never install or stop a running application.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/build/Notch Companion.app"
cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Notch Companion must be built on macOS with the Xcode command line tools." >&2
    exit 1
fi

ARCH_FLAGS=()
if [[ -n "${NOTCH_BUILD_ARCH:-}" ]]; then
    if [[ "$NOTCH_BUILD_ARCH" != "arm64" ]]; then
        echo "NOTCH_BUILD_ARCH supports only the Apple Silicon release target: arm64." >&2
        exit 1
    fi
    ARCH_FLAGS=(--arch arm64)
fi
xcrun swift build --configuration release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product NotchCompanion
BIN_PATH="$(xcrun swift build --configuration release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
if [[ ! -x "$BIN_PATH/NotchCompanion" ]]; then
    echo "The Swift build did not produce NotchCompanion." >&2
    exit 1
fi

# Assemble separately so a failed build never leaves a half-written app bundle.
mkdir -p "$PROJECT_ROOT/build"
STAGING_PATH="$(mktemp -d "$PROJECT_ROOT/build/.app-stage.XXXXXX")"
trap '[[ -d "$STAGING_PATH" ]] && rm -r -- "$STAGING_PATH"' EXIT
STAGED_APP="$STAGING_PATH/Notch Companion.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_PATH/NotchCompanion" "$STAGED_APP/Contents/MacOS/NotchCompanion"
# Release downloads must not expose local source paths from debug symbols.
/usr/bin/strip -S "$STAGED_APP/Contents/MacOS/NotchCompanion"
cp "$PROJECT_ROOT/app/Info.plist" "$STAGED_APP/Contents/Info.plist"
python3 "$PROJECT_ROOT/scripts/release.py" stamp "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/app/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# CompanionResources.bundle resolves the standard resource location in a
# signed app. SwiftPM's generated accessor alone assumes a bundle at app root,
# which codesign rejects as unsealed content.
RESOURCE_COUNT=0
for RESOURCE_BUNDLE in "$BIN_PATH"/*.bundle; do
    [[ -d "$RESOURCE_BUNDLE" ]] || continue
    ditto "$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done
if [[ "$RESOURCE_COUNT" -eq 0 ]]; then
    echo "Expected the SwiftPM resource bundle containing bridge and sounds." >&2
    exit 1
fi

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# A previous local build is disposable; source and user data remain untouched.
if [[ -d "$APP_PATH" ]]; then
    mv "$APP_PATH" "$STAGING_PATH/previous.app"
fi
mv "$STAGED_APP" "$APP_PATH"
echo "Built and ad-hoc signed: $APP_PATH"
echo "Launch: open \"$APP_PATH\""
