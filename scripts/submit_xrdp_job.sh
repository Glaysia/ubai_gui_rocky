#!/usr/bin/env bash
set -euo pipefail

env_file="${1:-config/session.env}"
if [ ! -f "$env_file" ]; then
  echo "[ERROR] env file not found: $env_file" >&2
  echo "Usage: $0 config/session.env" >&2
  exit 2
fi

abs_env_file="$(readlink -f "$env_file")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# shellcheck disable=SC1090
source "$abs_env_file"

sbatch_args=()
[ -n "${UABI_SLURM_PARTITION:-}" ] && sbatch_args+=(--partition="$UABI_SLURM_PARTITION")
[ -n "${UABI_SLURM_TIME:-}" ] && sbatch_args+=(--time="$UABI_SLURM_TIME")
[ -n "${UABI_SLURM_CPUS_PER_TASK:-}" ] && sbatch_args+=(--cpus-per-task="$UABI_SLURM_CPUS_PER_TASK")
[ -n "${UABI_SLURM_MEM:-}" ] && sbatch_args+=(--mem="$UABI_SLURM_MEM")
[ -n "${UABI_SLURM_GPUS:-}" ] && sbatch_args+=(--gres="gpu:${UABI_SLURM_GPUS}")

mkdir -p "$repo_root/logs"

echo "[INFO] Submitting XRDP job with env: $abs_env_file"
sbatch "${sbatch_args[@]}" \
  --export=ALL,UABI_ENV_FILE="$abs_env_file",UABI_REPO_ROOT="$repo_root" \
  "$repo_root/slurm/uabi_cst_xrdp.sbatch"
