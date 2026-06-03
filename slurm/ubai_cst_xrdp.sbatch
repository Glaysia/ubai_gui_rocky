#!/usr/bin/env bash
#SBATCH --job-name=ubai-cst-xrdp
#SBATCH --output=logs/ubai-cst-xrdp-%j.out
#SBATCH --error=logs/ubai-cst-xrdp-%j.err

set -euo pipefail

if [ -z "${UBAI_ENV_FILE:-}" ] || [ ! -f "$UBAI_ENV_FILE" ]; then
  echo "[ERROR] UBAI_ENV_FILE is missing or not found: ${UBAI_ENV_FILE:-}" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$UBAI_ENV_FILE"

: "${UBAI_REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${UBAI_IMAGE:?UBAI_IMAGE is required}"
: "${UBAI_XRDP_PORT_IN_CONTAINER:=3389}"
: "${UBAI_CONTAINER_SSH_PORT:=9922}"
: "${UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS:=9999}"
: "${UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS:=9922}"
: "${UBAI_REVERSE_BIND_HOST:=127.0.0.1}"
: "${UBAI_REVERSE_SSH_TARGET:?UBAI_REVERSE_SSH_TARGET is required}"
: "${UBAI_REVERSE_SSH_PORT:=22}"
: "${UBAI_SSH_STRICT_HOST_KEY_CHECKING:=accept-new}"
: "${UBAI_KEEP_CONTAINER_AFTER_EXIT:=0}"
: "${UBAI_CONTAINER_ROOT_HOME:=$HOME/runtime/container-root-home}"

case "$UBAI_CONTAINER_ROOT_HOME" in
  "~")
    UBAI_CONTAINER_ROOT_HOME="$HOME"
    ;;
  "~/"*)
    UBAI_CONTAINER_ROOT_HOME="$HOME/${UBAI_CONTAINER_ROOT_HOME#~/}"
    ;;
esac

job_id="${SLURM_JOB_ID:-manual}"
job_root="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/ubai-cst-xrdp-${job_id}"
mkdir -p "$job_root/logs"
mkdir -p "$UBAI_CONTAINER_ROOT_HOME"
chmod 700 "$UBAI_CONTAINER_ROOT_HOME" >/dev/null 2>&1 || true

if [ -e "$HOME/container-home" ] && [ ! -L "$HOME/container-home" ]; then
  echo "[WARN] $HOME/container-home already exists and is not a symlink; leaving it unchanged."
else
  ln -sfn "$UBAI_CONTAINER_ROOT_HOME" "$HOME/container-home"
fi

echo "[INFO] Job root: $job_root"
echo "[INFO] Node: $(hostname)"
echo "[INFO] Image: $UBAI_IMAGE"
echo "[INFO] Reverse target: $UBAI_REVERSE_SSH_TARGET"
echo "[INFO] Container /root home: $UBAI_CONTAINER_ROOT_HOME"
echo "[INFO] Host shortcut: $HOME/container-home"

tcp_ready() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  timeout 3 bash -lc ":</dev/tcp/$host/$port" >/dev/null 2>&1
}

dump_container_logs() {
  echo "--- container.stdout"
  cat "$job_root/logs/container.stdout" 2>/dev/null || true
  echo "--- container.stderr"
  cat "$job_root/logs/container.stderr" 2>/dev/null || true
  echo "--- xrdp.stdout"
  cat "$job_root/logs/xrdp.stdout" 2>/dev/null || true
  echo "--- xrdp.stderr"
  cat "$job_root/logs/xrdp.stderr" 2>/dev/null || true
  echo "--- xrdp-sesman.stdout"
  cat "$job_root/logs/xrdp-sesman.stdout" 2>/dev/null || true
  echo "--- xrdp-sesman.stderr"
  cat "$job_root/logs/xrdp-sesman.stderr" 2>/dev/null || true
  echo "--- sshd.stderr"
  cat "$job_root/logs/sshd.stderr" 2>/dev/null || true
}

if ! command -v enroot >/dev/null 2>&1; then
  echo "[ERROR] enroot not found on compute node: $(hostname)" >&2
  exit 1
fi

if [ ! -f "$UBAI_IMAGE" ]; then
  echo "[ERROR] enroot image not found: $UBAI_IMAGE" >&2
  echo "[INFO] Build the image before submitting the XRDP job." >&2
  exit 1
fi

container_name="ubai-cst-xrdp-${job_id}"
enroot_base="$job_root/enroot"
mkdir -p "$enroot_base"/{runtime,cache,data,tmp}

cleanup() {
  rc=$?
  echo "[INFO] cleanup rc=$rc"
  if [ -n "${tunnel_ctl:-}" ] && [ -S "$tunnel_ctl" ]; then
    ssh -S "$tunnel_ctl" -O exit "$UBAI_REVERSE_SSH_TARGET" >/dev/null 2>&1 || true
  fi
  if [ -n "${container_pid:-}" ]; then
    kill "$container_pid" >/dev/null 2>&1 || true
    wait "$container_pid" >/dev/null 2>&1 || true
  fi
  if [ "${UBAI_KEEP_CONTAINER_AFTER_EXIT}" != "1" ]; then
    ENROOT_RUNTIME_PATH="$enroot_base/runtime" ENROOT_CACHE_PATH="$enroot_base/cache" ENROOT_DATA_PATH="$enroot_base/data" ENROOT_TEMP_PATH="$enroot_base/tmp" \
      enroot remove -f "$container_name" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "[INFO] Creating enroot container..."
if ! ENROOT_RUNTIME_PATH="$enroot_base/runtime" ENROOT_CACHE_PATH="$enroot_base/cache" ENROOT_DATA_PATH="$enroot_base/data" ENROOT_TEMP_PATH="$enroot_base/tmp" \
  enroot create -n "$container_name" "$UBAI_IMAGE" >"$job_root/logs/enroot.create.stdout" 2>"$job_root/logs/enroot.create.stderr"; then
  echo "[ERROR] enroot create failed" >&2
  echo "--- enroot.create.stdout" >&2
  cat "$job_root/logs/enroot.create.stdout" >&2 || true
  echo "--- enroot.create.stderr" >&2
  cat "$job_root/logs/enroot.create.stderr" >&2 || true
  exit 1
fi

mounts=(
  --mount "$UBAI_REPO_ROOT/container/start_xrdp_container.sh:/usr/local/bin/start_xrdp_container.sh"
  --mount "$job_root:/work"
  --mount "$UBAI_CONTAINER_ROOT_HOME:/root"
)

if [ -n "${UBAI_EXTRA_MOUNTS:-}" ]; then
  IFS=',' read -r -a extra_mounts <<< "$UBAI_EXTRA_MOUNTS"
  for m in "${extra_mounts[@]}"; do
    [ -n "$m" ] && mounts+=(--mount "$m")
  done
fi

container_env=(
  "UBAI_XRDP_PASSWORD=${UBAI_XRDP_PASSWORD:-1q2w3e}"
  "UBAI_XRDP_PORT_IN_CONTAINER=$UBAI_XRDP_PORT_IN_CONTAINER"
  "UBAI_CONTAINER_SSH_PORT=$UBAI_CONTAINER_SSH_PORT"
  "UBAI_CONTAINER_SSH_PUBLIC_KEY=${UBAI_CONTAINER_SSH_PUBLIC_KEY:-}"
  "UBAI_CONTAINER_LOG_DIR=/work/logs"
  "UBAI_CONTAINER_READY_FILE=/work/xrdp.ready"
)

echo "[INFO] Starting xrdp container..."
ENROOT_RUNTIME_PATH="$enroot_base/runtime" ENROOT_CACHE_PATH="$enroot_base/cache" ENROOT_DATA_PATH="$enroot_base/data" ENROOT_TEMP_PATH="$enroot_base/tmp" \
  enroot start --root --rw "${mounts[@]}" "$container_name" \
  /usr/bin/env "${container_env[@]}" /bin/bash /usr/local/bin/start_xrdp_container.sh \
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
  dump_container_logs >&2
  exit 1
fi

if ! tcp_ready 127.0.0.1 "$UBAI_XRDP_PORT_IN_CONTAINER"; then
  echo "[ERROR] container reported ready, but compute node cannot reach XRDP at 127.0.0.1:${UBAI_XRDP_PORT_IN_CONTAINER}" >&2
  dump_container_logs >&2
  exit 1
fi

if ! tcp_ready 127.0.0.1 "$UBAI_CONTAINER_SSH_PORT"; then
  echo "[ERROR] container reported ready, but compute node cannot reach SSH at 127.0.0.1:${UBAI_CONTAINER_SSH_PORT}" >&2
  dump_container_logs >&2
  exit 1
fi

echo "[OK] Compute node can reach container XRDP/SSH ports."

echo "[INFO] Establishing SSH reverse tunnel..."
tunnel_ctl="$job_root/reverse_tunnel.ctl"

ssh_args=(
  -p "$UBAI_REVERSE_SSH_PORT"
  -o "ExitOnForwardFailure=yes"
  -o "ServerAliveInterval=30"
  -o "ServerAliveCountMax=3"
  -o "StrictHostKeyChecking=$UBAI_SSH_STRICT_HOST_KEY_CHECKING"
  -M
  -S "$tunnel_ctl"
  -fnNT
  -R "${UBAI_REVERSE_BIND_HOST}:${UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS}:127.0.0.1:${UBAI_XRDP_PORT_IN_CONTAINER}"
  -R "${UBAI_REVERSE_BIND_HOST}:${UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS}:127.0.0.1:${UBAI_CONTAINER_SSH_PORT}"
)

if [ -n "${UBAI_SSH_IDENTITY_FILE:-}" ]; then
  ssh_args+=(-i "$UBAI_SSH_IDENTITY_FILE")
fi

ssh "${ssh_args[@]}" "$UBAI_REVERSE_SSH_TARGET"

echo "[OK] Reverse tunnel established."

if ! ssh -S "$tunnel_ctl" -p "$UBAI_REVERSE_SSH_PORT" "$UBAI_REVERSE_SSH_TARGET" \
  "nc -z 127.0.0.1 '$UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS' && nc -z 127.0.0.1 '$UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS'"; then
  echo "[ERROR] Reverse tunnel opened, but gate node cannot reach forwarded RDP/SSH ports." >&2
  dump_container_logs >&2
  exit 1
fi

echo "[OK] Gate node can reach forwarded RDP/SSH ports."
echo "[INFO] On Windows, open mstsc.exe and connect to:"
echo "       127.0.0.1:${UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS}"
echo "[INFO] XRDP user: root"
echo "[INFO] VSCode Remote-SSH target:"
echo "       ssh://root@localhost:${UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS}"

while kill -0 "$container_pid" >/dev/null 2>&1; do
  if ! ssh -S "$tunnel_ctl" -O check "$UBAI_REVERSE_SSH_TARGET" >/dev/null 2>&1; then
    echo "[ERROR] SSH reverse tunnel is not alive" >&2
    exit 1
  fi
  sleep 30
done

echo "[ERROR] container process ended" >&2
exit 1
