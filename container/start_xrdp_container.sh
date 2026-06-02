#!/usr/bin/env bash
set -euo pipefail

: "${UABI_XRDP_USER:=cstuser}"
: "${UABI_XRDP_PASSWORD:=CHANGE_ME_LONG_PASSWORD}"
: "${UABI_XRDP_PORT_IN_CONTAINER:=3389}"

log_dir="${UABI_CONTAINER_LOG_DIR:-/work/logs}"
ready_file="${UABI_CONTAINER_READY_FILE:-/work/xrdp.ready}"

mkdir -p "$log_dir" /run/xrdp /var/run/xrdp /var/log/xrdp /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix || true

echo "[INFO] Container release:"
cat /etc/rocky-release || true

echo "[INFO] Preparing xrdp user: $UABI_XRDP_USER"
if ! id "$UABI_XRDP_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$UABI_XRDP_USER"
fi
echo "${UABI_XRDP_USER}:${UABI_XRDP_PASSWORD}" | chpasswd

if [ ! -f /etc/pam.d/xrdp-sesman ]; then
  cat > /etc/pam.d/xrdp-sesman <<'EOF'
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
EOF
fi

user_home="$(getent passwd "$UABI_XRDP_USER" | cut -d: -f6)"
mkdir -p "$user_home"
cat > "$user_home/.Xclients" <<'EOF'
#!/usr/bin/env bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
chmod +x "$user_home/.Xclients"
chown "$UABI_XRDP_USER:$UABI_XRDP_USER" "$user_home/.Xclients"

if [ -f /etc/xrdp/xrdp.ini ]; then
  cp -f /etc/xrdp/xrdp.ini "/etc/xrdp/xrdp.ini.uabi.bak.$(date +%s)" || true
  python3 - <<PY
from pathlib import Path
p = Path("/etc/xrdp/xrdp.ini")
s = p.read_text(errors="ignore")
lines = []
changed = False
for line in s.splitlines():
    if line.strip().startswith("port="):
        lines.append("port=${UABI_XRDP_PORT_IN_CONTAINER}")
        changed = True
    else:
        lines.append(line)
if not changed:
    lines.insert(0, "port=${UABI_XRDP_PORT_IN_CONTAINER}")
p.write_text("\n".join(lines) + "\n")
PY
fi

if command -v xrdp-keygen >/dev/null 2>&1; then
  xrdp-keygen xrdp auto >/dev/null 2>&1 || true
fi

echo "[INFO] OpenGL diagnostic:"
if command -v glxinfo >/dev/null 2>&1; then
  glxinfo 2>/dev/null | grep -E "OpenGL vendor|OpenGL renderer|OpenGL version" || true
else
  echo "[WARN] glxinfo not found"
fi

echo "[INFO] Starting xrdp-sesman..."
/usr/sbin/xrdp-sesman --nodaemon >"$log_dir/xrdp-sesman.stdout" 2>"$log_dir/xrdp-sesman.stderr" &
sesman_pid=$!

sleep 1
if ! kill -0 "$sesman_pid" >/dev/null 2>&1; then
  echo "[ERROR] xrdp-sesman exited early" >&2
  cat "$log_dir/xrdp-sesman.stderr" >&2 || true
  exit 1
fi

echo "[INFO] Starting xrdp on port $UABI_XRDP_PORT_IN_CONTAINER..."
/usr/sbin/xrdp --nodaemon >"$log_dir/xrdp.stdout" 2>"$log_dir/xrdp.stderr" &
xrdp_pid=$!

for i in $(seq 1 60); do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${UABI_XRDP_PORT_IN_CONTAINER}$"; then
    echo "[OK] xrdp is listening on ${UABI_XRDP_PORT_IN_CONTAINER}"
    touch "$ready_file"
    break
  fi
  if ! kill -0 "$xrdp_pid" >/dev/null 2>&1; then
    echo "[ERROR] xrdp exited early" >&2
    cat "$log_dir/xrdp.stderr" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -f "$ready_file" ]; then
  echo "[ERROR] xrdp did not become ready" >&2
  cat "$log_dir/xrdp.stderr" >&2 || true
  exit 1
fi

_term() {
  echo "[INFO] Stopping xrdp..."
  kill "$xrdp_pid" "$sesman_pid" >/dev/null 2>&1 || true
  wait "$xrdp_pid" "$sesman_pid" >/dev/null 2>&1 || true
}
trap _term TERM INT EXIT

while kill -0 "$xrdp_pid" >/dev/null 2>&1 && kill -0 "$sesman_pid" >/dev/null 2>&1; do
  sleep 10
done

echo "[ERROR] xrdp or sesman died" >&2
exit 1
