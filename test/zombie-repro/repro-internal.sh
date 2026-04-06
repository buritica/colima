#!/bin/bash
set -euo pipefail

# repro-internal.sh — reproduce zombie containers using VM-internal NFS mount
#
# Instead of mounting NFS on the macOS host (which needs sudo and has
# portmap issues), this script:
#   1. Starts an NFS server in a container on crowntail's default colima
#   2. Creates a VZ+virtiofs test colima profile
#   3. Inside the test VM, mounts NFS from the host network (the default
#      colima VM's IP) directly
#   4. Starts containers that bind-mount the NFS path via virtiofs
#   5. Tries to kill them
#
# The key insight: the test VM uses virtiofs for its host mounts, and one
# of those host mounts is itself backed by NFS. This replicates halfmoon's
# exact topology: macOS host → NFS mount → virtiofs → container bind mount.

PROFILE="zombie-test"
NUM_CONTAINERS=5
KILL_TIMEOUT=15
NFS_MOUNT="/tmp/zombie-nfs-mount"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[repro]${NC} $*"; }
warn() { echo -e "${YELLOW}[repro]${NC} $*"; }
fail() { echo -e "${RED}[repro]${NC} $*"; }

cleanup() {
  log "Cleaning up..."

  # Switch back to default context
  docker context use colima 2>/dev/null || true

  # Stop test profile
  colima stop --profile "$PROFILE" 2>/dev/null || true
  colima delete --profile "$PROFILE" --force 2>/dev/null || true

  # Unmount NFS if mounted
  if mount | grep -qF "$NFS_MOUNT"; then
    sudo umount -f "$NFS_MOUNT" 2>/dev/null || true
  fi
  rmdir "$NFS_MOUNT" 2>/dev/null || true

  log "Cleanup complete"
}

# --- Check NFS server ---

log "Checking NFS server..."
docker context use colima >/dev/null 2>&1

if ! docker ps --filter name=zombie-nfs --format '{{.State}}' 2>/dev/null | grep -q running; then
  fail "NFS server not running. Run: cd test/zombie-repro && docker compose up -d"
  exit 1
fi

# Get the colima VM's IP (reachable from inside VZ test profile via host network)
COLIMA_IP=$(colima list --json 2>/dev/null | grep -o '"address":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$COLIMA_IP" ]; then
  # Fallback: try to get it from colima status
  COLIMA_IP="192.168.106.2"
  warn "Could not detect colima IP, using default $COLIMA_IP"
fi
log "Default colima VM IP: $COLIMA_IP (NFS server reachable here)"

# --- Mount NFS on macOS host ---
# We DO need the host mount so virtiofs can see it.
# The VZ profile's virtiofs exposes the host filesystem — if the host has
# an NFS mount, the VZ guest sees it through virtiofs (same as halfmoon).

log "Mounting NFS on host at $NFS_MOUNT..."
mkdir -p "$NFS_MOUNT"

if mount | grep -qF "$NFS_MOUNT"; then
  warn "Already mounted, reusing"
else
  # NFSv4 pseudoroot — the itsthenetwork/nfs-server-alpine exports at /
  if ! sudo mount_nfs -o vers=4,tcp,resvport "127.0.0.1:/" "$NFS_MOUNT" 2>/dev/null; then
    # Try v3 with portmap
    if ! sudo mount_nfs -o vers=3,tcp,resvport "127.0.0.1:/export" "$NFS_MOUNT" 2>/dev/null; then
      fail "Could not mount NFS. Try manually:"
      fail "  sudo mount_nfs -o vers=4,tcp,resvport 127.0.0.1:/ $NFS_MOUNT"
      exit 1
    fi
  fi
fi

log "NFS mounted. Contents:"
ls "$NFS_MOUNT/" 2>&1 | head -5

# --- Start VZ+virtiofs profile ---

log "Starting colima profile '$PROFILE' with VZ+virtiofs..."
trap cleanup EXIT

colima start \
  --profile "$PROFILE" \
  --vm-type vz \
  --mount-type virtiofs \
  --cpu 2 \
  --memory 2 \
  --disk 10 \
  --mount "$NFS_MOUNT:w"

docker context use "colima-$PROFILE"

# --- Start containers ---

log "Starting $NUM_CONTAINERS containers doing I/O on NFS-backed virtiofs..."
for i in $(seq 1 "$NUM_CONTAINERS"); do
  docker run -d \
    --name "zombie-$i" \
    -v "$NFS_MOUNT:/data" \
    alpine sh -c "
      while true; do
        # Write to the NFS-backed mount
        echo tick-$i-\$(date +%s) >> /data/log-$i.txt 2>/dev/null
        # Stat restricted dirs (triggers permission-denied NFS RPCs)
        ls /data/Media/Movies/ >/dev/null 2>&1 || true
        ls /data/Media/TV/ >/dev/null 2>&1 || true
        # Heavy write
        dd if=/dev/urandom of=/data/junk-$i bs=4k count=50 2>/dev/null
        sleep 0.1
      done
    " >/dev/null 2>&1
done

sleep 10  # let I/O build up

RUNNING=$(docker ps --filter name=zombie- --format '{{.Names}}' | wc -l | tr -d ' ')
log "$RUNNING containers running, letting them churn for 10s..."

# --- Kill ---

log "Killing all containers (timeout ${KILL_TIMEOUT}s each)..."
ZOMBIE_COUNT=0
SLOW_COUNT=0
START_TIME=$(date +%s)

for name in $(docker ps --filter name=zombie- --format '{{.Names}}'); do
  KILL_START=$(date +%s)
  if ! timeout "$KILL_TIMEOUT" docker kill "$name" >/dev/null 2>&1; then
    fail "ZOMBIE: $name could not be killed within ${KILL_TIMEOUT}s"
    ZOMBIE_COUNT=$((ZOMBIE_COUNT + 1))
  else
    KILL_END=$(date +%s)
    KILL_DURATION=$((KILL_END - KILL_START))
    if [ "$KILL_DURATION" -gt 3 ]; then
      warn "SLOW KILL: $name took ${KILL_DURATION}s"
      SLOW_COUNT=$((SLOW_COUNT + 1))
    fi
  fi
done

END_TIME=$(date +%s)
TOTAL=$((END_TIME - START_TIME))

# --- Report ---

echo ""
echo "================================="
echo "Versions:"
# Avoid pipefail + SIGPIPE: capture full output then trim
COLIMA_VER="$(colima version 2>&1 || true)"
echo "$COLIMA_VER" | head -2
limactl --version 2>&1 || true
echo "================================="

if [ "$ZOMBIE_COUNT" -gt 0 ]; then
  fail "FAIL: $ZOMBIE_COUNT/$NUM_CONTAINERS zombie containers"
  fail "Total kill time: ${TOTAL}s"
  exit 1
elif [ "$SLOW_COUNT" -gt 0 ]; then
  warn "WARN: $SLOW_COUNT/$NUM_CONTAINERS slow kills (>3s). Zombies are likely under heavier load."
  warn "Total kill time: ${TOTAL}s"
  exit 2
else
  log "PASS: All $NUM_CONTAINERS containers killed cleanly in ${TOTAL}s"
  exit 0
fi
