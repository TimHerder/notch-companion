#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"$PROJECT_ROOT/scripts/build-app.sh"
open "$PROJECT_ROOT/build/Notch Companion.app"
