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
VELO_VERSION="${VELO_VERSION:-latest}"
SKIP_CLEANUP="${VELO_SKIP_CLEANUP:-false}"

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

# Clean up stale velo containers from previous installations (e.g., in OrbStack/Docker Desktop)
# These can conflict with new containers created inside the Colima VM
if [ "$SKIP_CLEANUP" != "true" ]; then
  STALE_CONTAINERS=$(docker ps -a --filter "name=velo-" --format '{{.Names}}' 2>/dev/null || true)
  if [ -n "$STALE_CONTAINERS" ]; then
    echo "==> Cleaning up stale velo containers..."
    echo "$STALE_CONTAINERS" | xargs -r docker rm -f 2>/dev/null || true
  fi
fi

echo "==> Starting Colima VM (profile: $PROFILE)..."
"$COLIMA_BIN" start --profile "$PROFILE" \
  --runtime docker \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --disk "$DISK_GB" \
  --arch "$COLIMA_ARCH" \
  --vm-type "$VM_TYPE"

echo "==> Configuring VM and installing dependencies..."

# Clean up stale velo data from previous installations inside the VM
if [ "$SKIP_CLEANUP" != "true" ]; then
  "$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -c '
    # Clean up stale velo containers inside the VM
    STALE=$(docker ps -a --filter "name=velo-" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$STALE" ]; then
      echo "    Cleaning up stale velo containers..."
      echo "$STALE" | xargs -r docker rm -f 2>/dev/null || true
    fi
    # Clean up stale velo data directory
    if [ -d "$HOME/.velo" ]; then
      echo "    Cleaning up stale velo data..."
      sudo rm -rf "$HOME/.velo" 2>/dev/null || true
    fi
  ' 2>/dev/null || true
fi

"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -s -- "$POOL_NAME" "$POOL_IMG" "$POOL_SIZE" "$VELO_VERSION" <<'EOF'
set -euo pipefail
POOL_NAME="$1"
POOL_IMG="$2"
POOL_SIZE="$3"
VELO_VERSION="$4"

# Ubuntu 24.04+ has ZFS modules pre-built in the kernel - no DKMS needed!
# Bun compiles velo to a standalone binary - no Node.js needed at runtime!

# Kill any stale apt processes from previous interrupted runs
if pgrep -x apt >/dev/null 2>&1; then
  echo "    Killing stale apt process..."
  sudo pkill -9 apt 2>/dev/null || true
  sleep 1
fi
sudo rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true

echo "    Updating package lists..."
sudo apt update

# Minimal package list - only what's strictly needed
PACKAGES=(
  zfsutils-linux
  curl
  ca-certificates
  git
  unzip
)

# Add docker if not present
if ! command -v docker >/dev/null 2>&1; then
  PACKAGES+=(docker.io docker-compose-plugin)
fi

echo "    Installing packages..."
sudo DEBIAN_FRONTEND=noninteractive apt install -y --allow-change-held-packages "${PACKAGES[@]}"

echo "    Loading ZFS kernel module..."
if ! sudo modprobe zfs; then
  echo "Failed to load zfs kernel module. This often happens with Colima --vm-type=vz on Apple Silicon." >&2
  echo "Delete the profile and rerun with VELO_VM_TYPE=qemu." >&2
  exit 1
fi

echo "    Setting up ZFS pool..."
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
  echo "    Velo already installed in VM."
else
  echo "    Installing Bun and cloning Velo (in parallel)..."
  
  # Start bun install in background
  (curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1) &
  BUN_PID=$!
  
  # Clone velo repo in parallel
  if [ ! -d "$HOME/.velo-src" ]; then
    git clone --quiet https://github.com/elitan/velo.git "$HOME/.velo-src"
  fi
  
  # Wait for bun installation to complete
  wait $BUN_PID
  
  BUN_BIN="$HOME/.bun/bin/bun"
  if [ ! -x "$BUN_BIN" ]; then
    echo "Failed to install bun." >&2
    exit 1
  fi

  cd "$HOME/.velo-src"
  git fetch --tags --quiet
  
  # Resolve version
  if [ "$VELO_VERSION" = "latest" ]; then
    VELO_VERSION=$(git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "v1.0.0")
  fi
  
  echo "    Building Velo $VELO_VERSION..."
  git checkout "$VELO_VERSION" --quiet
  "$BUN_BIN" install --silent
  "$BUN_BIN" build --compile --minify --sourcemap src/index.ts --outfile dist/velo

  sudo install -m 0755 dist/velo /usr/local/bin/velo
fi

# Add user to docker group (will take effect after restart)
sudo usermod -aG docker "$(id -un)"
EOF

echo "==> Restarting VM to apply group membership..."
"$COLIMA_BIN" stop --profile "$PROFILE"
"$COLIMA_BIN" start --profile "$PROFILE"

echo "==> Running velo setup..."
"$COLIMA_BIN" ssh --profile "$PROFILE" -- velo setup

# Fix ownership issues created by velo setup
"$COLIMA_BIN" ssh --profile "$PROFILE" -- bash -c '
sudo chown -R $(id -un):$(id -gn) $HOME/.velo 2>/dev/null || true
sudo chown root:root /etc/sudoers.d/velo 2>/dev/null || true
sudo chmod 440 /etc/sudoers.d/velo 2>/dev/null || true
'

# Restart to apply velo group membership from velo setup
echo "==> Restarting VM to apply velo group membership..."
"$COLIMA_BIN" stop --profile "$PROFILE"
"$COLIMA_BIN" start --profile "$PROFILE"

echo ""
echo "==> Velo setup complete!"
echo "    Install wrapper with: sudo install -m 0755 velo-wrapper.sh /usr/local/bin/velo"
