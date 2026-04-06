#!/bin/bash
set -euo pipefail

# repro.sh — reproduce the zombie-container bug with VZ+virtiofs+NFS
#
# Prerequisites:
#   1. Running NFS server: docker compose up -d (in this directory)
#   2. macOS with Apple Silicon (VZ requires arm64)
#   3. colima and lima installed (any version — this is what we're testing)
#
# What this does:
#   1. Mounts the dockerized NFS share on the host
#   2. Creates a colima profile with VZ+virtiofs backed by the NFS mount
#   3. Starts containers that do I/O on the NFS-backed virtiofs mount
#   4. Tries to kill them and measures whether zombies occur
#   5. Reports pass/fail

PROFILE="zombie-test"
NFS_HOST="127.0.0.1"
NFS_MOUNT_DIR="/tmp/zombie-nfs-mount"
NUM_CONTAINERS=5
KILL_TIMEOUT=15  # seconds — if any container takes longer, it's a zombie

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[repro]${NC} $*"; }
warn() { echo -e "${YELLOW}[repro]${NC} $*"; }
fail() { echo -e "${RED}[repro]${NC} $*"; }

cleanup() {
  log "Cleaning up..."
  docker context use colima 2>/dev/null || true

  # Try to stop the test profile (might fail if already stopped)
  colima stop --profile "$PROFILE" 2>/dev/null || true
  colima delete --profile "$PROFILE" --force 2>/dev/null || true

  # Unmount NFS
  if mount | grep -qF "$NFS_MOUNT_DIR"; then
    sudo umount -f "$NFS_MOUNT_DIR" 2>/dev/null || true
  fi
  rmdir "$NFS_MOUNT_DIR" 2>/dev/null || true

  log "Cleanup complete"
}
trap cleanup EXIT

# --- Preflight ---

log "Checking prerequisites..."

if ! docker compose ps --filter name=zombie-nfs --format '{{.State}}' 2>/dev/null | grep -q running; then
  fail "NFS server not running. Run: docker compose up -d"
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  fail "VZ+virtiofs requires Apple Silicon (arm64). This machine is $(uname -m)."
  exit 1
fi

# --- Mount NFS on host ---

log "Mounting NFS share from dockerized server..."
mkdir -p "$NFS_MOUNT_DIR"

if mount | grep -qF "$NFS_MOUNT_DIR"; then
  warn "Already mounted, reusing"
else
  # Mount the NFS export from the dockerized server.
  # The server runs inside crowntail's existing colima (QEMU), which maps
  # port 2049 to the host. We mount from localhost.
  sudo mount_nfs -o vers=3,tcp,resvport "$NFS_HOST:/export" "$NFS_MOUNT_DIR"
fi

# Verify the restrictive permissions came through
if ls "$NFS_MOUNT_DIR/Media/Movies/" >/dev/null 2>&1; then
  warn "Movies dir is accessible (root_squash may not be effective for your uid)"
  warn "This is still a valid test — D-state can happen on any NFS I/O"
fi

log "NFS mount ready at $NFS_MOUNT_DIR"

# --- Start VZ+virtiofs colima profile ---

log "Starting colima profile '$PROFILE' with VZ+virtiofs..."
colima start \
  --profile "$PROFILE" \
  --vm-type vz \
  --mount-type virtiofs \
  --cpu 2 \
  --memory 2 \
  --disk 10 \
  --mount "$NFS_MOUNT_DIR:w"

docker context use "colima-$PROFILE"

# --- Start containers doing NFS I/O ---

log "Starting $NUM_CONTAINERS containers writing to NFS-backed virtiofs mount..."
for i in $(seq 1 "$NUM_CONTAINERS"); do
  docker run -d \
    --name "zombie-$i" \
    -v "$NFS_MOUNT_DIR:/data" \
    alpine sh -c "
      while true; do
        # Mix of writes to writable parent and stat calls to restricted subdirs
        echo tick-$i-\$(date +%s) >> /data/log-$i.txt
        ls /data/Media/Movies/ >/dev/null 2>&1 || true
        ls /data/Media/TV/ >/dev/null 2>&1 || true
        dd if=/dev/urandom of=/data/junk-$i bs=4k count=10 2>/dev/null
      done
    " >/dev/null 2>&1
done

sleep 5  # let them churn

RUNNING=$(docker ps --filter name=zombie- --format '{{.Names}}' | wc -l | tr -d ' ')
log "$RUNNING containers running"

# --- Kill all containers and measure ---

log "Killing all containers (timeout ${KILL_TIMEOUT}s per container)..."
ZOMBIE_COUNT=0
START_TIME=$(date +%s)

for name in $(docker ps --filter name=zombie- --format '{{.Names}}'); do
  KILL_START=$(date +%s)
  if ! timeout "$KILL_TIMEOUT" docker kill "$name" >/dev/null 2>&1; then
    fail "ZOMBIE: $name could not be killed within ${KILL_TIMEOUT}s"
    ZOMBIE_COUNT=$((ZOMBIE_COUNT + 1))
  else
    KILL_END=$(date +%s)
    KILL_DURATION=$((KILL_END - KILL_START))
    if [ "$KILL_DURATION" -gt 5 ]; then
      warn "SLOW KILL: $name took ${KILL_DURATION}s (>5s is suspicious)"
    fi
  fi
done

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

# --- Report ---

echo ""
echo "================================="
if [ "$ZOMBIE_COUNT" -gt 0 ]; then
  fail "FAIL: $ZOMBIE_COUNT/$NUM_CONTAINERS containers became zombies"
  fail "Total kill time: ${TOTAL_DURATION}s"
  echo ""
  fail "Bug reproduced! Container processes in D-state on NFS-backed virtiofs."
  fail "Versions:"
  colima version 2>&1 | head -3
  limactl --version 2>&1
  exit 1
else
  log "PASS: All $NUM_CONTAINERS containers killed cleanly in ${TOTAL_DURATION}s"
  echo ""
  log "Bug NOT reproduced with this configuration."
  log "Versions:"
  colima version 2>&1 | head -3
  limactl --version 2>&1
  exit 0
fi
