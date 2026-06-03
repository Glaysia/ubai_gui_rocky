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
: "${UBAI_PODMAN_IMAGE:=localhost/ubai-cst-rocky94-xrdp:latest}"
: "${UBAI_XRDP_PORT_IN_CONTAINER:=3389}"
: "${UBAI_CONTAINER_SSH_PORT:=9922}"
: "${UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS:=9999}"
: "${UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS:=9922}"
: "${UBAI_REVERSE_BIND_HOST:=127.0.0.1}"
: "${UBAI_REVERSE_SSH_TARGET:?UBAI_REVERSE_SSH_TARGET is required}"
: "${UBAI_REVERSE_SSH_PORT:=22}"
: "${UBAI_SSH_STRICT_HOST_KEY_CHECKING:=accept-new}"
: "${UBAI_PODMAN_IMAGE_ARCHIVE:=$HOME/runtime/podman/ubai-cst-rocky94-xrdp.tar}"
: "${UBAI_PODMAN_RUNTIME:=runc}"
: "${UBAI_CONTAINERS_POLICY_JSON:=$UBAI_REPO_ROOT/config/containers-policy.json}"
: "${UBAI_CONTAINER_ROOT_HOME:=$HOME/runtime/container-root-home}"

strip_trailing_cr() {
  local name="$1"
  if [ -n "${!name+x}" ]; then
    printf -v "$name" "%s" "${!name%$'\r'}"
  fi
}

for env_name in \
  UBAI_REPO_ROOT \
  UBAI_PODMAN_IMAGE \
  UBAI_PODMAN_IMAGE_ARCHIVE \
  UBAI_PODMAN_RUNTIME \
  UBAI_CONTAINERS_POLICY_JSON \
  UBAI_XRDP_PASSWORD \
  UBAI_XRDP_PORT_IN_CONTAINER \
  UBAI_CONTAINER_SSH_PORT \
  UBAI_CONTAINER_SSH_PUBLIC_KEY \
  UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS \
  UBAI_REVERSE_LOCAL_SSH_PORT_ON_WINDOWS \
  UBAI_REVERSE_BIND_HOST \
  UBAI_REVERSE_SSH_TARGET \
  UBAI_REVERSE_SSH_PORT \
  UBAI_SSH_STRICT_HOST_KEY_CHECKING \
  UBAI_SSH_IDENTITY_FILE \
  UBAI_CONTAINER_ROOT_HOME; do
  strip_trailing_cr "$env_name"
done

case "$UBAI_CONTAINER_ROOT_HOME" in
  "~")
    UBAI_CONTAINER_ROOT_HOME="$HOME"
    ;;
  "~/"*)
    UBAI_CONTAINER_ROOT_HOME="$HOME/${UBAI_CONTAINER_ROOT_HOME#~/}"
    ;;
esac

export PATH="$HOME/.local/userbin:$PATH"

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
export XDG_RUNTIME_DIR="$job_root/xdg-runtime"
export XDG_CONFIG_HOME="$job_root/xdg-config"
podman_runroot="$job_root/podman-runroot"
podman_graphroot="$job_root/podman-root"
podman_tmpdir="$job_root/podman-tmp"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/containers" "$podman_runroot" "$podman_graphroot" "$podman_tmpdir"
chmod 700 "$XDG_RUNTIME_DIR"

if [ -f "$UBAI_CONTAINERS_POLICY_JSON" ]; then
  cp "$UBAI_CONTAINERS_POLICY_JSON" "$XDG_CONFIG_HOME/containers/policy.json"
  mkdir -p "$HOME/.config/containers"
  cp "$UBAI_CONTAINERS_POLICY_JSON" "$HOME/.config/containers/policy.json"
fi

echo "[INFO] Job root: $job_root"
echo "[INFO] Node: $(hostname)"
echo "[INFO] Podman image: $UBAI_PODMAN_IMAGE"
echo "[INFO] Reverse target: $UBAI_REVERSE_SSH_TARGET"
echo "[INFO] Container /root home: $UBAI_CONTAINER_ROOT_HOME"
echo "[INFO] Host shortcut: $HOME/container-home"

container_name="ubai-cst-xrdp-${job_id}"
podman_cmd=(
  podman
  --events-backend=file
  --root "$podman_graphroot"
  --runtime "$UBAI_PODMAN_RUNTIME"
  --runroot "$podman_runroot"
  --storage-driver overlay
  --storage-opt ignore_chown_errors=true
  --tmpdir "$podman_tmpdir"
)

cleanup() {
  rc=$?
  echo "[INFO] cleanup rc=$rc"
  if [ -n "${tunnel_ctl:-}" ] && [ -S "$tunnel_ctl" ]; then
    ssh -S "$tunnel_ctl" -O exit "$UBAI_REVERSE_SSH_TARGET" >/dev/null 2>&1 || true
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

if [ -f "$UBAI_PODMAN_IMAGE_ARCHIVE" ]; then
  echo "[INFO] Loading podman image archive: $UBAI_PODMAN_IMAGE_ARCHIVE"
  "${podman_cmd[@]}" load -i "$UBAI_PODMAN_IMAGE_ARCHIVE"
elif ! "${podman_cmd[@]}" image exists "$UBAI_PODMAN_IMAGE"; then
  echo "[ERROR] podman image not found in isolated job storage: $UBAI_PODMAN_IMAGE" >&2
  echo "[ERROR] expected archive: $UBAI_PODMAN_IMAGE_ARCHIVE" >&2
  exit 1
fi

podman_args=(
  run
  --name "$container_name"
  --network host
  --tmpfs /run
  --tmpfs /tmp
  -e "UBAI_XRDP_PASSWORD=${UBAI_XRDP_PASSWORD:-1q2w3e}"
  -e "UBAI_XRDP_PORT_IN_CONTAINER=$UBAI_XRDP_PORT_IN_CONTAINER"
  -e "UBAI_CONTAINER_SSH_PORT=$UBAI_CONTAINER_SSH_PORT"
  -e "UBAI_CONTAINER_SSH_PUBLIC_KEY=${UBAI_CONTAINER_SSH_PUBLIC_KEY:-}"
  -e "UBAI_CONTAINER_LOG_DIR=/work/logs"
  -e "UBAI_CONTAINER_READY_FILE=/work/xrdp.ready"
  -v "$UBAI_REPO_ROOT/container/start_xrdp_container.sh:/usr/local/bin/start_xrdp_container.sh:ro"
  -v "$job_root:/work"
  -v "$UBAI_CONTAINER_ROOT_HOME:/root"
)

if [ -n "${UBAI_EXTRA_MOUNTS:-}" ]; then
  IFS=',' read -r -a extra_mounts <<< "$UBAI_EXTRA_MOUNTS"
  for m in "${extra_mounts[@]}"; do
    [ -n "$m" ] && podman_args+=(-v "$m")
  done
fi

echo "[INFO] Starting podman xrdp container..."
"${podman_cmd[@]}" "${podman_args[@]}" "$UBAI_PODMAN_IMAGE" /bin/bash /usr/local/bin/start_xrdp_container.sh \
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
echo "[INFO] In relay mode, keep Windows local forward open:"
echo "       ssh -N -L 9999:127.0.0.1:${UBAI_REVERSE_LOCAL_PORT_ON_WINDOWS} ${UBAI_REVERSE_SSH_TARGET}"
echo "[INFO] Then open mstsc.exe -> 127.0.0.1:9999"
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
