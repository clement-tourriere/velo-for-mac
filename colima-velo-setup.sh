#!/usr/bin/env bash
set -euo pipefail

PROFILE="${VELO_PROFILE:-velo}"
CPU="${VELO_CPU:-2}"
MEMORY="${VELO_MEMORY:-4}"
DISK_GB="${VELO_DISK_GB:-40}"

POOL_NAME="${VELO_POOL_NAME:-velopool}"
POOL_IMG="${VELO_POOL_IMG:-/var/lib/velo/zpool.img}"
POOL_SIZE="${VELO_POOL_SIZE:-30G}"
COLIMA_BIN="${VELO_COLIMA_BIN:-colima}"

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  COLIMA_ARCH="aarch64"
else
  COLIMA_ARCH="x86_64"
fi

# QEMU is required for ZFS kernel module support (vz doesn't work)
VM_TYPE="${VELO_VM_TYPE:-qemu}"

if ! command -v "$COLIMA_BIN" >/dev/null 2>&1; then
  echo "colima not found. Install with: brew install colima" >&2
  exit 1
fi

"$COLIMA_BIN" start --profile "$PROFILE" \
  --runtime docker \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --disk "$DISK_GB" \
  --arch "$COLIMA_ARCH" \
  --vm-type "$VM_TYPE"

"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -s -- "$POOL_NAME" "$POOL_IMG" "$POOL_SIZE" <<'EOF'
set -euo pipefail
POOL_NAME="$1"
POOL_IMG="$2"
POOL_SIZE="$3"

sudo apt update

HEADER_PKG="linux-headers-$(uname -r)"
if ! apt-cache show "$HEADER_PKG" >/dev/null 2>&1; then
  echo "Kernel headers for $(uname -r) not available."
  echo "ZFS DKMS needs matching headers. Recreate the Colima profile with VELO_VM_TYPE=qemu." >&2
  exit 1
fi

sudo apt install -y zfsutils-linux zfs-dkms "$HEADER_PKG" curl ca-certificates gnupg zstd git unzip

NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
fi
if [ "$NODE_MAJOR" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt install -y nodejs
fi

if ! command -v docker >/dev/null 2>&1; then
  sudo apt install -y --allow-change-held-packages docker.io docker-compose-plugin
fi

if ! sudo modprobe zfs; then
  echo "Failed to load zfs kernel module. This often happens with Colima --vm-type=vz on Apple Silicon." >&2
  echo "Delete the profile and rerun with VELO_VM_TYPE=qemu." >&2
  exit 1
fi

sudo mkdir -p "$(dirname "$POOL_IMG")"

if ! sudo zpool list "$POOL_NAME" >/dev/null 2>&1; then
  # Clean up stale mountpoint from previous failed run
  if [ -d "/$POOL_NAME" ]; then
    sudo rm -rf "/$POOL_NAME"
  fi
  sudo truncate -s "$POOL_SIZE" "$POOL_IMG"
  sudo zpool create -f -o ashift=12 "$POOL_NAME" "$POOL_IMG"
fi

if [ -x /usr/local/bin/velo ]; then
  echo "Velo already installed in VM."
else
  curl -fsSL https://bun.sh/install | bash
  BUN_BIN="$HOME/.bun/bin/bun"
  if [ ! -x "$BUN_BIN" ]; then
    echo "Failed to install bun." >&2
    exit 1
  fi

  if [ ! -d "$HOME/.velo-src" ]; then
    git clone https://github.com/elitan/velo.git "$HOME/.velo-src"
  fi

  cd "$HOME/.velo-src"
  git fetch --tags
  git checkout "v1.0.0"
  "$BUN_BIN" install
  "$BUN_BIN" build --compile --minify --sourcemap src/index.ts --outfile dist/velo

  sudo install -m 0755 dist/velo /usr/local/bin/velo
fi

sudo usermod -aG docker "$(id -un)"
EOF

"$COLIMA_BIN" stop --profile "$PROFILE"
"$COLIMA_BIN" start --profile "$PROFILE"

"$COLIMA_BIN" ssh --profile "$PROFILE" -- velo setup

# Fix ownership issues created by velo setup (directory may not exist yet)
"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -c 'sudo chown -R $(id -un):$(id -gn) $HOME/.velo 2>/dev/null; true'
"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -c 'sudo chown root:root /etc/sudoers.d/velo 2>/dev/null; sudo chmod 440 /etc/sudoers.d/velo 2>/dev/null; true'

# Restart to apply velo group membership
"$COLIMA_BIN" stop --profile "$PROFILE"
"$COLIMA_BIN" start --profile "$PROFILE"

echo "Velo setup complete. Install wrapper with: sudo install -m 0755 velo-wrapper.sh /usr/local/bin/velo"