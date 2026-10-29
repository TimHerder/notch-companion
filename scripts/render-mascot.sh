#!/bin/bash
# Render a mascot's sprite sheets and face anchors with Blender (headless).
# Usage: scripts/render-mascot.sh <mote|fold|soot|all> [--preview done,wave] [--turnaround] [--eyes]
#                                  [--clips done] [--samples 64] [--anchors-only] [--resume]
# Writes Sources/NotchCompanion/Resources/Mascot/<id>-*.webp and <id>.json, and
# build/mascot/<id>/<id>.blend. Full renders queue behind one lock so they never
# share the GPU; previews and turnarounds run immediately.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
if [[ ! -x "$BLENDER" ]]; then
    echo "Blender not found at $BLENDER (set BLENDER=/path/to/Blender)." >&2
    exit 1
fi
CHARACTER="${1:-}"
shift || true
if [[ "$CHARACTER" == "all" ]]; then
    for id in mote fold soot; do "$0" "$id" "$@"; done
    exit 0
fi
SCRIPT="$PROJECT_ROOT/scripts/mascot/$CHARACTER.py"
if [[ -z "$CHARACTER" || ! -f "$SCRIPT" ]]; then
    echo "Usage: $0 <mote|fold|soot|all> [options]" >&2
    exit 1
fi
WORK="$PROJECT_ROOT/build/mascot/$CHARACTER"
mkdir -p "$WORK"
LOCK="$PROJECT_ROOT/build/mascot/.render-lock"
EXTRA=()
if [[ " $* " == *" --preview "* || " $* " == *" --turnaround "* || " $* " == *" --anchors-only "* ]]; then
    # A full render owns the GPU; sharing it ran Metal out of memory, so review renders use the CPU meanwhile.
    if [[ -d "$LOCK" ]]; then
        echo "A full render holds the GPU ($(cat "$LOCK/owner" 2>/dev/null || echo unknown)); rendering on the CPU."
        EXTRA=(--cpu)
    fi
else
    until mkdir "$LOCK" 2>/dev/null; do
        echo "Waiting for another mascot render ($(cat "$LOCK/owner" 2>/dev/null || echo unknown))…"
        sleep 30
    done
    echo "$CHARACTER" > "$LOCK/owner"
    trap 'rm -rf "$LOCK"' EXIT
fi
"$BLENDER" --background --factory-startup --python "$SCRIPT" -- \
    --work "$WORK" --save "$WORK/$CHARACTER.blend" "$@" ${EXTRA[@]+"${EXTRA[@]}"}
