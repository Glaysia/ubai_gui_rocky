#!/usr/bin/env bash
#SBATCH --job-name=uabi-cst-xrdp
#SBATCH --output=logs/uabi-cst-xrdp-%j.out
#SBATCH --error=logs/uabi-cst-xrdp-%j.err

set -euo pipefail

if [ -z "${UABI_ENV_FILE:-}" ] || [ ! -f "$UABI_ENV_FILE" ]; then
  echo "[ERROR] UABI_ENV_FILE is missing or not found: ${UABI_ENV_FILE:-}" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$UABI_ENV_FILE"

: "${UABI_REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${UABI_IMAGE:?UABI_IMAGE is required}"
: "${UABI_XRDP_PORT_IN_CONTAINER:=3389}"
: "${UABI_CONTAINER_SSH_PORT:=9922}"
: "${UABI_REVERSE_LOCAL_PORT_ON_WINDOWS:=9999}"
: "${UABI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS:=9922}"
: "${UABI_REVERSE_BIND_HOST:=127.0.0.1}"
: "${UABI_REVERSE_SSH_TARGET:?UABI_REVERSE_SSH_TARGET is required}"
: "${UABI_REVERSE_SSH_PORT:=10022}"
: "${UABI_SSH_STRICT_HOST_KEY_CHECKING:=accept-new}"
: "${UABI_KEEP_CONTAINER_AFTER_EXIT:=0}"

job_id="${SLURM_JOB_ID:-manual}"
job_root="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/uabi-cst-xrdp-${job_id}"
mkdir -p "$job_root/logs"

echo "[INFO] Job root: $job_root"
echo "[INFO] Node: $(hostname)"
echo "[INFO] Image: $UABI_IMAGE"
echo "[INFO] Reverse target: $UABI_REVERSE_SSH_TARGET"

if ! command -v enroot >/dev/null 2>&1; then
  echo "[ERROR] enroot not found on compute node: $(hostname)" >&2
  exit 1
fi

if [ ! -f "$UABI_IMAGE" ]; then
  echo "[ERROR] enroot image not found: $UABI_IMAGE" >&2
  echo "[INFO] Build the image before submitting the XRDP job." >&2
  exit 1
fi

container_name="uabi-cst-xrdp-${job_id}"
enroot_base="$job_root/enroot"
mkdir -p "$enroot_base"/{runtime,cache,data,tmp}

cleanup() {
  rc=$?
  echo "[INFO] cleanup rc=$rc"
  if [ -n "${tunnel_ctl:-}" ] && [ -S "$tunnel_ctl" ]; then
    ssh -S "$tunnel_ctl" -O exit "$UABI_REVERSE_SSH_TARGET" >/dev/null 2>&1 || true
  fi
  if [ -n "${container_pid:-}" ]; then
    kill "$container_pid" >/dev/null 2>&1 || true
    wait "$container_pid" >/dev/null 2>&1 || true
  fi
  if [ "${UABI_KEEP_CONTAINER_AFTER_EXIT}" != "1" ]; then
    ENROOT_RUNTIME_PATH="$enroot_base/runtime" ENROOT_CACHE_PATH="$enroot_base/cache" ENROOT_DATA_PATH="$enroot_base/data" ENROOT_TEMP_PATH="$enroot_base/tmp" \
      enroot remove -f "$container_name" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "[INFO] Creating enroot container..."
if ! ENROOT_RUNTIME_PATH="$enroot_base/runtime" ENROOT_CACHE_PATH="$enroot_base/cache" ENROOT_DATA_PATH="$enroot_base/data" ENROOT_TEMP_PATH="$enroot_base/tmp" \
  enroot create -n "$container_name" "$UABI_IMAGE" >"$job_root/logs/enroot.create.stdout" 2>"$job_root/logs/enroot.create.stderr"; then
  echo "[ERROR] enroot create failed" >&2
  echo "--- enroot.create.stdout" >&2
  cat "$job_root/logs/enroot.create.stdout" >&2 || true
  echo "--- enroot.create.stderr" >&2
  cat "$job_root/logs/enroot.create.stderr" >&2 || true
  exit 1
fi

mounts=(
  --mount "$UABI_REPO_ROOT/container/start_xrdp_container.sh:/usr/local/bin/start_xrdp_container.sh"
  --mount "$job_root:/work"
)

if [ -n "${UABI_EXTRA_MOUNTS:-}" ]; then
  IFS=',' read -r -a extra_mounts <<< "$UABI_EXTRA_MOUNTS"
  for m in "${extra_mounts[@]}"; do
    [ -n "$m" ] && mounts+=(--mount "$m")
  done
fi

echo "[INFO] Starting xrdp container..."
ENROOT_RUNTIME_PATH="$enroot_base/runtime" ENROOT_CACHE_PATH="$enroot_base/cache" ENROOT_DATA_PATH="$enroot_base/data" ENROOT_TEMP_PATH="$enroot_base/tmp" \
  enroot start --root --rw "${mounts[@]}" "$container_name" \
  /bin/bash /usr/local/bin/start_xrdp_container.sh \
  >"$job_root/logs/container.stdout" 2>"$job_root/logs/container.stderr" &
container_pid=$!

echo "[INFO] Waiting for xrdp readiness..."
for i in $(seq 1 120); do
  if [ -f "$job_root/xrdp.ready" ] && kill -0 "$container_pid" >/dev/null 2>&1; then
    echo "[OK] xrdp ready"
    break
  fi
  if ! kill -0 "$container_pid" >/dev/null 2>&1; then
    echo "[ERROR] container exited before ready" >&2
    cat "$job_root/logs/container.stdout" >&2 || true
    cat "$job_root/logs/container.stderr" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -f "$job_root/xrdp.ready" ]; then
  echo "[ERROR] xrdp readiness timeout" >&2
  cat "$job_root/logs/container.stdout" >&2 || true
  cat "$job_root/logs/container.stderr" >&2 || true
  exit 1
fi

echo "[INFO] Establishing SSH reverse tunnel..."
tunnel_ctl="$job_root/reverse_tunnel.ctl"

ssh_args=(
  -p "$UABI_REVERSE_SSH_PORT"
  -o "ExitOnForwardFailure=yes"
  -o "ServerAliveInterval=30"
  -o "ServerAliveCountMax=3"
  -o "StrictHostKeyChecking=$UABI_SSH_STRICT_HOST_KEY_CHECKING"
  -M
  -S "$tunnel_ctl"
  -fnNT
  -R "${UABI_REVERSE_BIND_HOST}:${UABI_REVERSE_LOCAL_PORT_ON_WINDOWS}:127.0.0.1:${UABI_XRDP_PORT_IN_CONTAINER}"
  -R "${UABI_REVERSE_BIND_HOST}:${UABI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS}:127.0.0.1:${UABI_CONTAINER_SSH_PORT}"
)

if [ -n "${UABI_SSH_IDENTITY_FILE:-}" ]; then
  ssh_args+=(-i "$UABI_SSH_IDENTITY_FILE")
fi

ssh "${ssh_args[@]}" "$UABI_REVERSE_SSH_TARGET"

echo "[OK] Reverse tunnel established."
echo "[INFO] On Windows, open mstsc.exe and connect to:"
echo "       127.0.0.1:${UABI_REVERSE_LOCAL_PORT_ON_WINDOWS}"
echo "[INFO] XRDP user: root"
echo "[INFO] VSCode Remote-SSH target:"
echo "       ssh://root@localhost:${UABI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS}"

while kill -0 "$container_pid" >/dev/null 2>&1; do
  if ! ssh -S "$tunnel_ctl" -O check "$UABI_REVERSE_SSH_TARGET" >/dev/null 2>&1; then
    echo "[ERROR] SSH reverse tunnel is not alive" >&2
    exit 1
  fi
  sleep 30
done

echo "[ERROR] container process ended" >&2
exit 1
