#!/usr/bin/env bash
set -euo pipefail

ROUTER="${1:-admin@192.168.88.1}"
PLATFORM="${2:-linux/arm/v7}"
IMAGE="ghcr.io/ovikiss/mikrotik-traffic-monitor:latest"
RSC_LOCAL="mikrotik/install.rsc"
RSC_REMOTE="install-traffic-monitor.rsc"
UI_SHARED_REV="$(git ls-remote https://github.com/ovikiss/mikrotik-ui-shared.git refs/heads/main | awk '{print $1}')"

cleanup_remote_files() {
  while IFS= read -r remote_file; do
    [[ -z "$remote_file" ]] && continue
    ssh "$ROUTER" "/file remove [find where name=\"$remote_file\"]" >/dev/null 2>&1 || true
  done < <(
    ssh "$ROUTER" ':foreach f in=[/file find] do={ :put [/file get $f name] }' 2>/dev/null \
      | grep -E '(^|/)install-[^/]+\.rsc$' || true
  )

  ssh "$ROUTER" "/file remove [find where name=\"$RSC_REMOTE\"]" >/dev/null 2>&1 || true
}

trap cleanup_remote_files EXIT

if [[ ! -f "$RSC_LOCAL" ]]; then
  echo "Missing $RSC_LOCAL"
  exit 1
fi

echo "Logging in to GHCR using gh token"
gh auth token | docker login ghcr.io -u ovikiss --password-stdin >/dev/null

echo "Building and pushing $IMAGE for $PLATFORM"
docker buildx build \
  --platform "$PLATFORM" \
  --build-arg "UI_SHARED_REV=$UI_SHARED_REV" \
  --provenance=false \
  --sbom=false \
  -t "$IMAGE" \
  --push \
  .

echo "Cleaning old install scripts on router"
cleanup_remote_files

echo "Uploading install script to $ROUTER:$RSC_REMOTE"
scp "$RSC_LOCAL" "$ROUTER:$RSC_REMOTE"

echo "Importing script on router"
ssh "$ROUTER" "/import file-name=$RSC_REMOTE"

echo "Cleaning up uploaded script and old install files"
cleanup_remote_files

echo "Done. Open: http://192.168.88.1:8088/"
