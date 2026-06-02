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

exec "$repo_root/image/build_rocky94_xrdp_image.sh"
