#!/bin/bash
set -euo pipefail

# repro-qemu.sh — control test: same slow NFS but QEMU+sshfs instead of VZ+virtiofs.
# If this PASSES while repro-internal.sh --slow FAILS, the bug is in VZ+virtiofs.

PROFILE="zombie-qemu"
NUM_CONTAINERS=5
KILL_TIMEOUT=15
NFS_MOUNT="/tmp/zombie-nfs-mount"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[qemu-repro]${NC} $*"; }
warn() { echo -e "${YELLOW}[qemu-repro]${NC} $*"; }
fail() { echo -e "${RED}[qemu-repro]${NC} $*"; }

cleanup() {
  log "Cleaning up..."
  docker context use colima 2>/dev/null || true
  colima stop --profile "$PROFILE" 2>/dev/null || true
  colima delete --profile "$PROFILE" --force 2>/dev/null || true
  if mount | grep -qF "$NFS_MOUNT"; then
    sudo -n umount -f "$NFS_MOUNT" 2>/dev/null || true
  fi
  rmdir "$NFS_MOUNT" 2>/dev/null || true
  log "Cleanup complete"
}
trap cleanup EXIT

# --- Check NFS proxy ---

docker context use colima >/dev/null 2>&1
if ! docker ps --filter name=zombie-nfs-delay --format '{{.State}}' 2>/dev/null | grep -q running; then
  fail "Slow proxy not running. Start with: NFS_DELAY_MS=1000 NFS_LOSS_PCT=15 docker compose --profile slow up -d"
  exit 1
fi
log "Using slow NFS proxy (port 2050)"
docker logs zombie-nfs-delay 2>&1 | grep 'Adding' | tail -1

# --- Mount NFS via slow proxy ---

log "Mounting NFS..."
mkdir -p "$NFS_MOUNT"
if ! mount | grep -qF "$NFS_MOUNT"; then
  sudo -n mount_nfs -o vers=4,tcp,resvport,port=2050,mountport=2050,soft,retrans=10,timeo=50 \
    "127.0.0.1:/" "$NFS_MOUNT" 2>/dev/null || \
  sudo -n mount_nfs -o vers=4,tcp,resvport,soft,retrans=10,timeo=50 \
    "127.0.0.1:/" "$NFS_MOUNT" 2>/dev/null || {
    fail "Could not mount NFS"; exit 1
  }
fi
log "NFS mounted"

# --- Start QEMU+sshfs profile ---

log "Starting colima QEMU+sshfs profile..."
colima start \
  --profile "$PROFILE" \
  --vm-type qemu \
  --mount-type sshfs \
  --cpu 2 \
  --memory 2 \
  --disk 10 \
  --mount "$NFS_MOUNT:w"

docker context use "colima-$PROFILE"

log "Pulling alpine..."
docker pull alpine:latest >/dev/null 2>&1

log "Mount info inside QEMU VM:"
docker run --rm -v "$NFS_MOUNT:/data" alpine sh -c \
  'cat /proc/mounts | grep data; echo ---; cat /proc/version' 2>&1 | while read -r line; do
  log "  $line"
done

# --- Containers ---

for i in $(seq 1 "$NUM_CONTAINERS"); do
  docker rm -f "zombie-$i" >/dev/null 2>&1 || true
done

log "Starting $NUM_CONTAINERS containers..."
STARTED=0
for i in $(seq 1 "$NUM_CONTAINERS"); do
  if docker run -d --name "zombie-$i" -v "$NFS_MOUNT:/data" \
    alpine sh -c "
      while true; do
        echo tick-$i-\$(date +%s) >> /data/log-$i.txt 2>/dev/null
        ls /data/Media/Movies/ >/dev/null 2>&1 || true
        dd if=/dev/urandom of=/data/junk-$i bs=4k count=50 2>/dev/null
        sleep 0.1
      done
    " >/dev/null 2>&1; then
    STARTED=$((STARTED + 1))
  fi
done
log "$STARTED/$NUM_CONTAINERS containers started"

log "Letting degraded NFS I/O churn for 20s..."
sleep 20

# --- Kill ---

log "Killing all (timeout ${KILL_TIMEOUT}s each)..."
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
    D=$((KILL_END - KILL_START))
    [ "$D" -gt 3 ] && { warn "SLOW KILL: $name took ${D}s"; SLOW_COUNT=$((SLOW_COUNT + 1)); }
  fi
done

END_TIME=$(date +%s)
TOTAL=$((END_TIME - START_TIME))

echo ""
echo "================================="
echo "QEMU+sshfs control test"
echo "Versions:"
COLIMA_VER="$(colima version 2>&1 || true)"
echo "$COLIMA_VER" | head -2
limactl --version 2>&1 || true
echo "================================="

if [ "$ZOMBIE_COUNT" -gt 0 ]; then
  fail "FAIL: $ZOMBIE_COUNT/$NUM_CONTAINERS zombie containers"
  fail "Total kill time: ${TOTAL}s"
  exit 1
elif [ "$SLOW_COUNT" -gt 0 ]; then
  warn "WARN: $SLOW_COUNT/$NUM_CONTAINERS slow kills (>3s)"
  warn "Total kill time: ${TOTAL}s"
  exit 2
else
  log "PASS: All $NUM_CONTAINERS containers killed cleanly in ${TOTAL}s"
  exit 0
fi
