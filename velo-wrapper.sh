#!/usr/bin/env bash
set -euo pipefail

PROFILE="${VELO_PROFILE:-velo}"
COLIMA_BIN="${VELO_COLIMA_BIN:-colima}"

if ! command -v "$COLIMA_BIN" >/dev/null 2>&1; then
  echo "colima not found. Install with: brew install colima" >&2
  exit 1
fi

# Fix .velo ownership (velo creates some files as root)
"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -c 'sudo chown -R $(id -un):$(id -gn) $HOME/.velo 2>/dev/null; true' 2>/dev/null

# Run velo, filtering colima's exit status noise
"$COLIMA_BIN" ssh --profile "$PROFILE" -- velo "$@" 2> >(grep -v 'level=fatal msg="exit status' >&2)
