# Velo for macOS

Run [Velo](https://github.com/elitan/velo) (PostgreSQL database branching using ZFS snapshots) on macOS via Colima.

Since macOS doesn't support ZFS natively, this project sets up Velo inside a Linux VM using Colima, with a transparent wrapper so you can use `velo` commands directly from your Mac.

## Quick Start

```bash
# Install dependencies
brew install colima qemu

# Clone and run setup
git clone https://github.com/clement-tourriere/velo-for-mac.git
cd velo-for-mac
./colima-velo-setup.sh

# Install the wrapper
sudo install -m 0755 velo-wrapper.sh /usr/local/bin/velo

# Verify installation
velo doctor
```

## Prerequisites

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- Colima and QEMU: `brew install colima qemu`

## Usage
- Create a project:
  ```bash
  velo project create demo
  ```
- Create a branch:
  ```bash
  velo branch create demo/feature-x
  ```
- Check status and connection string:
  ```bash
  velo status
  ```
- Connect from macOS using the shown `localhost:<port>`.

## Docker note (inside VM)
The setup script installs Docker via Ubuntu packages (`docker.io`). If you already ran the official Docker install script and got a “held packages” error, this is expected on Ubuntu 24.04 inside Colima.

## Customization
All settings can be overridden by environment variables when running `colima-velo-setup.sh`:

- `VELO_PROFILE` (default: `velo`)
- `VELO_CPU` (default: `2`)
- `VELO_MEMORY` (default: `4` GB)
- `VELO_DISK_GB` (default: `40` GB)
- `VELO_POOL_NAME` (default: `velopool`)
- `VELO_POOL_IMG` (default: `/var/lib/velo/zpool.img`)
- `VELO_POOL_SIZE` (default: `30G`)
- `VELO_VM_TYPE` (default: `qemu` - required for ZFS kernel modules)
- `VELO_COLIMA_BIN` (default: `colima`)

Example:
```bash
VELO_CPU=4 VELO_MEMORY=8 VELO_DISK_GB=60 VELO_POOL_SIZE=50G ./colima-velo-setup.sh
```

## Troubleshooting
- If you get "container name already in use" errors, clean up orphaned resources:
  ```bash
  velo cleanup
  ```
- If you hit `qemu-x86_64: Could not open '/lib64/ld-linux-x86-64.so.2'`, make sure QEMU is installed:
  ```bash
  brew install qemu
  ```
- If ZFS fails to load, delete and recreate the profile:
  ```bash
  colima delete --profile velo
  ./colima-velo-setup.sh
  ```
- If `localhost:<port>` is not reachable, verify Colima is running:
  ```bash
  colima status --profile velo
  ```

## Updating Velo

To update velo to the latest version:

```bash
./velo-update.sh
```

Or specify a version:

```bash
./velo-update.sh v1.1.0
```

## Uninstall

To completely remove Velo:

```bash
# Remove the Colima VM (includes all data, ZFS pool, and velo inside)
colima delete --profile velo

# Remove the macOS wrapper script
sudo rm -f /usr/local/bin/velo
```

That's it - no other files are created on macOS.
