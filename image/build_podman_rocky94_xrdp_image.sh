#!/usr/bin/env bash
set -euo pipefail

: "${UBAI_PODMAN_IMAGE:=localhost/ubai-cst-rocky94-xrdp:latest}"
: "${UBAI_PODMAN_IMAGE_ARCHIVE:=$HOME/runtime/podman/ubai-cst-rocky94-xrdp.tar}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

export PATH="$HOME/.local/userbin:$PATH"

if ! command -v podman >/dev/null 2>&1; then
  echo "[ERROR] podman not found and enroot is unavailable." >&2
  exit 127
fi

echo "[INFO] Building podman image: $UBAI_PODMAN_IMAGE"
podman build \
  -t "$UBAI_PODMAN_IMAGE" \
  -f "$repo_root/image/Containerfile.rocky94-xrdp" \
  "$repo_root"

echo "[INFO] Validating podman image..."
podman run --rm "$UBAI_PODMAN_IMAGE" /bin/bash -lc '
set -e
cat /etc/rocky-release
grep -q "Rocky Linux release 9.4" /etc/rocky-release
command -v xrdp
command -v xrdp-sesman
command -v sshd
command -v startxfce4 || true
command -v glxinfo || true
'

echo "[INFO] Saving podman image archive: $UBAI_PODMAN_IMAGE_ARCHIVE"
mkdir -p "$(dirname "$UBAI_PODMAN_IMAGE_ARCHIVE")"
tmp_archive="${UBAI_PODMAN_IMAGE_ARCHIVE}.tmp"
rm -f "$tmp_archive"
podman save -o "$tmp_archive" "$UBAI_PODMAN_IMAGE"
mv "$tmp_archive" "$UBAI_PODMAN_IMAGE_ARCHIVE"

echo "[OK] Built podman image: $UBAI_PODMAN_IMAGE"
