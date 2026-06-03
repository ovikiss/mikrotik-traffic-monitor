#!/usr/bin/env bash
set -euo pipefail

ROUTER="${1:-admin@192.168.88.1}"
PLATFORM="${2:-linux/arm/v7}"
IMAGE="ghcr.io/ovikiss/mikrotik-traffic-monitor:latest"
RSC_LOCAL="mikrotik/install.rsc"
RSC_REMOTE="install-traffic-monitor.rsc"

if [[ ! -f "$RSC_LOCAL" ]]; then
  echo "Missing $RSC_LOCAL"
  exit 1
fi

echo "Logging in to GHCR using gh token"
gh auth token | docker login ghcr.io -u ovikiss --password-stdin >/dev/null

echo "Building and pushing $IMAGE for $PLATFORM"
docker buildx build \
  --platform "$PLATFORM" \
  -t "$IMAGE" \
  --push \
  .

echo "Uploading install script to $ROUTER:$RSC_REMOTE"
scp "$RSC_LOCAL" "$ROUTER:$RSC_REMOTE"

echo "Importing script on router"
ssh "$ROUTER" "/import file-name=$RSC_REMOTE"

echo "Cleaning up uploaded script"
ssh "$ROUTER" "/file remove [find where name=\"$RSC_REMOTE\"]" || true

echo "Done. Open: http://192.168.88.1:8088/"
