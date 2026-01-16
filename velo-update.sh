#!/usr/bin/env bash
set -euo pipefail

PROFILE="${VELO_PROFILE:-velo}"
COLIMA_BIN="${VELO_COLIMA_BIN:-colima}"
VELO_VERSION="${1:-latest}"

if ! command -v "$COLIMA_BIN" >/dev/null 2>&1; then
  echo "colima not found. Install with: brew install colima" >&2
  exit 1
fi

if ! "$COLIMA_BIN" status --profile "$PROFILE" >/dev/null 2>&1; then
  echo "Colima profile '$PROFILE' is not running. Start it first." >&2
  exit 1
fi

echo "Updating velo to ${VELO_VERSION}..."

"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -s -- "$VELO_VERSION" <<'EOF'
set -euo pipefail
VELO_VERSION="$1"

cd "$HOME/.velo-src"
git fetch --tags

if [ "$VELO_VERSION" = "latest" ]; then
  VELO_VERSION=$(git describe --tags --abbrev=0 origin/main)
  echo "Latest version: $VELO_VERSION"
fi

git checkout "$VELO_VERSION"

BUN_BIN="$HOME/.bun/bin/bun"
"$BUN_BIN" install
"$BUN_BIN" build --compile --minify --sourcemap src/index.ts --outfile dist/velo

sudo install -m 0755 dist/velo /usr/local/bin/velo

echo "Velo updated to $VELO_VERSION"
velo --version
EOF
