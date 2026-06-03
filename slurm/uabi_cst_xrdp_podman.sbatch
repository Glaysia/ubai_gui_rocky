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
: "${UABI_PODMAN_IMAGE:=localhost/uabi-cst-rocky94-xrdp:latest}"
: "${UABI_XRDP_PORT_IN_CONTAINER:=3389}"
: "${UABI_REVERSE_LOCAL_PORT_ON_WINDOWS:=9999}"
: "${UABI_REVERSE_BIND_HOST:=127.0.0.1}"
: "${UABI_REVERSE_SSH_TARGET:?UABI_REVERSE_SSH_TARGET is required}"
: "${UABI_REVERSE_SSH_PORT:=22}"
: "${UABI_SSH_STRICT_HOST_KEY_CHECKING:=accept-new}"
: "${UABI_PODMAN_IMAGE_ARCHIVE:=$HOME/runtime/podman/uabi-cst-rocky94-xrdp.tar}"
: "${UABI_PODMAN_RUNTIME:=runc}"
: "${UABI_CONTAINERS_POLICY_JSON:=$UABI_REPO_ROOT/config/containers-policy.json}"

strip_trailing_cr() {
  local name="$1"
  if [ -n "${!name+x}" ]; then
    printf -v "$name" "%s" "${!name%$'\r'}"
  fi
}

for env_name in \
  UABI_REPO_ROOT \
  UABI_PODMAN_IMAGE \
  UABI_PODMAN_IMAGE_ARCHIVE \
  UABI_PODMAN_RUNTIME \
  UABI_CONTAINERS_POLICY_JSON \
  UABI_XRDP_USER \
  UABI_XRDP_PASSWORD \
  UABI_XRDP_PORT_IN_CONTAINER \
  UABI_REVERSE_LOCAL_PORT_ON_WINDOWS \
  UABI_REVERSE_BIND_HOST \
  UABI_REVERSE_SSH_TARGET \
  UABI_REVERSE_SSH_PORT \
  UABI_SSH_STRICT_HOST_KEY_CHECKING \
  UABI_SSH_IDENTITY_FILE; do
  strip_trailing_cr "$env_name"
done

export PATH="$HOME/.local/userbin:$PATH"

job_id="${SLURM_JOB_ID:-manual}"
job_root="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/uabi-cst-xrdp-${job_id}"
mkdir -p "$job_root/logs"
export XDG_RUNTIME_DIR="$job_root/xdg-runtime"
export XDG_CONFIG_HOME="$job_root/xdg-config"
podman_runroot="$job_root/podman-runroot"
podman_graphroot="$job_root/podman-root"
podman_tmpdir="$job_root/podman-tmp"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/containers" "$podman_runroot" "$podman_graphroot" "$podman_tmpdir"
chmod 700 "$XDG_RUNTIME_DIR"

if [ -f "$UABI_CONTAINERS_POLICY_JSON" ]; then
  cp "$UABI_CONTAINERS_POLICY_JSON" "$XDG_CONFIG_HOME/containers/policy.json"
  mkdir -p "$HOME/.config/containers"
  cp "$UABI_CONTAINERS_POLICY_JSON" "$HOME/.config/containers/policy.json"
fi

echo "[INFO] Job root: $job_root"
echo "[INFO] Node: $(hostname)"
echo "[INFO] Podman image: $UABI_PODMAN_IMAGE"
echo "[INFO] Reverse target: $UABI_REVERSE_SSH_TARGET"

container_name="uabi-cst-xrdp-${job_id}"
podman_cmd=(
  podman
  --events-backend=file
  --root "$podman_graphroot"
  --runtime "$UABI_PODMAN_RUNTIME"
  --runroot "$podman_runroot"
  --storage-driver overlay
  --storage-opt ignore_chown_errors=true
  --tmpdir "$podman_tmpdir"
)

cleanup() {
  rc=$?
  echo "[INFO] cleanup rc=$rc"
  if [ -n "${tunnel_ctl:-}" ] && [ -S "$tunnel_ctl" ]; then
    ssh -S "$tunnel_ctl" -O exit "$UABI_REVERSE_SSH_TARGET" >/dev/null 2>&1 || true
  fi
  "${podman_cmd[@]}" rm -f "$container_name" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

dump_container_logs() {
  echo "[INFO] Container log dump:" >&2
  for f in "$job_root/logs"/*; do
    [ -f "$f" ] || continue
    echo "----- $f -----" >&2
    tail -n 200 "$f" >&2 || true
  done
}

"${podman_cmd[@]}" rm -f "$container_name" >/dev/null 2>&1 || true

if [ -f "$UABI_PODMAN_IMAGE_ARCHIVE" ]; then
  echo "[INFO] Loading podman image archive: $UABI_PODMAN_IMAGE_ARCHIVE"
  "${podman_cmd[@]}" load -i "$UABI_PODMAN_IMAGE_ARCHIVE"
elif ! "${podman_cmd[@]}" image exists "$UABI_PODMAN_IMAGE"; then
  echo "[ERROR] podman image not found in isolated job storage: $UABI_PODMAN_IMAGE" >&2
  echo "[ERROR] expected archive: $UABI_PODMAN_IMAGE_ARCHIVE" >&2
  exit 1
fi

podman_args=(
  run
  --name "$container_name"
  --network host
  --tmpfs /run
  --tmpfs /tmp
  -e "UABI_XRDP_USER=${UABI_XRDP_USER:-user}"
  -e "UABI_XRDP_PASSWORD=${UABI_XRDP_PASSWORD:-1q2w3e}"
  -e "UABI_XRDP_PORT_IN_CONTAINER=$UABI_XRDP_PORT_IN_CONTAINER"
  -e "UABI_CONTAINER_LOG_DIR=/work/logs"
  -e "UABI_CONTAINER_READY_FILE=/work/xrdp.ready"
  -v "$UABI_REPO_ROOT/container/start_xrdp_container.sh:/usr/local/bin/start_xrdp_container.sh:ro"
  -v "$job_root:/work"
)

if [ -n "${UABI_EXTRA_MOUNTS:-}" ]; then
  IFS=',' read -r -a extra_mounts <<< "$UABI_EXTRA_MOUNTS"
  for m in "${extra_mounts[@]}"; do
    [ -n "$m" ] && podman_args+=(-v "$m")
  done
fi

echo "[INFO] Starting podman xrdp container..."
"${podman_cmd[@]}" "${podman_args[@]}" "$UABI_PODMAN_IMAGE" /bin/bash /usr/local/bin/start_xrdp_container.sh \
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
    dump_container_logs
    exit 1
  fi
  sleep 1
done

if [ ! -f "$job_root/xrdp.ready" ]; then
  echo "[ERROR] xrdp readiness timeout" >&2
  dump_container_logs
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
)

if [ -n "${UABI_SSH_IDENTITY_FILE:-}" ]; then
  ssh_args+=(-i "$UABI_SSH_IDENTITY_FILE")
fi

ssh "${ssh_args[@]}" "$UABI_REVERSE_SSH_TARGET"

echo "[OK] Reverse tunnel established."
echo "[INFO] In relay mode, keep Windows local forward open:"
echo "       ssh -N -L 9999:127.0.0.1:${UABI_REVERSE_LOCAL_PORT_ON_WINDOWS} ${UABI_REVERSE_SSH_TARGET}"
echo "[INFO] Then open mstsc.exe -> 127.0.0.1:9999"
echo "[INFO] XRDP user: ${UABI_XRDP_USER:-user}"

while kill -0 "$container_pid" >/dev/null 2>&1; do
  if ! ssh -S "$tunnel_ctl" -O check "$UABI_REVERSE_SSH_TARGET" >/dev/null 2>&1; then
    echo "[ERROR] SSH reverse tunnel is not alive" >&2
    exit 1
  fi
  sleep 30
done

echo "[ERROR] container process ended" >&2
exit 1
