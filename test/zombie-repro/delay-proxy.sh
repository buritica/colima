#!/bin/sh
set -e

apk add --no-cache iproute2 socat >/dev/null 2>&1

DELAY="${NFS_DELAY_MS:-200}"
LOSS="${NFS_LOSS_PCT:-5}"
JITTER="${NFS_JITTER_MS:-100}"

echo "Adding ${DELAY}ms delay (±${JITTER}ms jitter), ${LOSS}% packet loss"
tc qdisc add dev eth0 root netem delay "${DELAY}ms" "${JITTER}ms" loss "${LOSS}%"

echo "Starting TCP proxy 0.0.0.0:2050 → zombie-nfs:2049"
exec socat TCP-LISTEN:2050,fork,reuseaddr TCP:zombie-nfs:2049
