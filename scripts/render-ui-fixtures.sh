#!/bin/bash
# Render actual native views with mock transport and temporary session storage.
# --theme refined|tahoe|instrument|all picks the expanded panel's design
# (default refined, into build/ui-review; others into build/ui-review-<theme>).
# `all` compiles once and renders every theme. Other arguments go to the renderer.
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
THEMES=(refined)
ARGS=()
while (($#)); do
    if [[ "$1" == --theme ]]; then
        [[ "${2:-}" == all ]] && THEMES=(refined tahoe instrument) || THEMES=("${2:?--theme needs a value}")
        shift 2
    else
        ARGS+=("$1"); shift
    fi
done
xcrun swift build --product NotchCompanion
BIN_PATH="$(xcrun swift build --show-bin-path)"
BUILD_PATH="$PROJECT_ROOT/build/ui-review"
mkdir -p "$BUILD_PATH"
SOURCES=()
for SOURCE in "$PROJECT_ROOT"/Sources/NotchCompanion/*.swift; do
    [[ "$SOURCE" == */Entry.swift ]] || SOURCES+=("$SOURCE")
done
RESOURCE_ACCESSOR="$BIN_PATH/NotchCompanion.build/DerivedSources/resource_bundle_accessor.swift"
if [[ ! -f "$RESOURCE_ACCESSOR" ]]; then
    # Swift 6.3's swiftbuild engine separates intermediates from products.
    RESOURCE_ACCESSOR="$PROJECT_ROOT/.build/out/Intermediates.noindex/NotchCompanion.build/Debug/NotchCompanion-p.build/DerivedSources/resource_bundle_accessor.swift"
fi
xcrun swiftc -parse-as-library -module-name NotchCompanion \
    "${SOURCES[@]}" "$RESOURCE_ACCESSOR" \
    "$PROJECT_ROOT/Tests/Fixtures/InterfacePreview.swift" -o "$BUILD_PATH/render"
ditto "$BIN_PATH/NotchCompanion_NotchCompanion.bundle" "$BUILD_PATH/NotchCompanion_NotchCompanion.bundle"
for THEME in "${THEMES[@]}"; do
    OUTPUT_PATH="$BUILD_PATH"
    [[ "$THEME" == refined ]] || OUTPUT_PATH="$BUILD_PATH-$THEME"
    mkdir -p "$OUTPUT_PATH"
    echo "Rendering $THEME into ${OUTPUT_PATH#"$PROJECT_ROOT"/}"
    "$BUILD_PATH/render" "$OUTPUT_PATH" --theme "$THEME" ${ARGS[@]+"${ARGS[@]}"}
done
