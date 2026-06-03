#!/usr/bin/env bash
set -euo pipefail

env_file="${1:-config/session.env}"
if [ ! -f "$env_file" ]; then
  echo "[ERROR] env file not found: $env_file" >&2
  echo "Usage: $0 config/session.env" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$env_file"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

backend="${UABI_IMAGE_BACKEND:-enroot}"
case "$backend" in
  auto)
    if command -v enroot >/dev/null 2>&1; then
      exec "$repo_root/image/build_rocky94_xrdp_image.sh"
    fi
    echo "[INFO] enroot is not available on this host; using podman image build backend." >&2
    exec "$repo_root/image/build_podman_rocky94_xrdp_image.sh"
    ;;
  enroot)
    if ! command -v enroot >/dev/null 2>&1; then
      echo "[ERROR] enroot not found on this host. Run the build on an enroot-capable compute node or set UABI_IMAGE_BACKEND=podman." >&2
      exit 127
    fi
    exec "$repo_root/image/build_rocky94_xrdp_image.sh"
    ;;
  podman)
    exec "$repo_root/image/build_podman_rocky94_xrdp_image.sh"
    ;;
  *)
    echo "[ERROR] Unsupported UABI_IMAGE_BACKEND: $backend" >&2
    echo "        Use auto, enroot, or podman." >&2
    exit 2
    ;;
esac
