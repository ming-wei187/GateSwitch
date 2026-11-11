#!/bin/bash
# Build GateSwitch.app and zip it for a GitHub Release.
# Usage: ./package.sh [output.zip]
# The zip contains GateSwitch.app at the top level. Default path: build/GateSwitch.zip
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "package.sh must be run on macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$ROOT/build/GateSwitch.zip}"
STAGE="$(mktemp -d -t gateswitch-package)"
trap 'rm -rf "$STAGE"' EXIT

# build.sh stops a running GateSwitch, then ad-hoc signs the app.
"$ROOT/build.sh" "$STAGE/GateSwitch.app"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
ditto -c -k --keepParent "$STAGE/GateSwitch.app" "$OUT"
echo "Packaged $OUT"
