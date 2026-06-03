#!/usr/bin/env bash
set -euo pipefail

: "${UABI_XRDP_USER:=user}"
: "${UABI_XRDP_PASSWORD:=1q2w3e}"
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
chmod 755 "$user_home" "$user_home/.Xclients" || true
if ! chown "$UABI_XRDP_USER:$UABI_XRDP_USER" "$user_home/.Xclients" 2>/dev/null; then
  echo "[WARN] Could not chown $user_home/.Xclients; continuing for rootless podman"
fi

if [ ! -f /etc/xrdp/xrdp.ini ]; then
  cat > /etc/xrdp/xrdp.ini <<'EOF'
[Globals]
ini_version=1
fork=false
port=3389
use_vsock=false
tcp_nodelay=true
tcp_keepalive=true
security_layer=negotiate
crypt_level=high
allow_channels=true
allow_multimon=true
bitmap_cache=true
bitmap_compression=true
max_bpp=32
new_cursors=true
runtime_user=
runtime_group=

[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=20
EOF
fi

cp -f /etc/xrdp/xrdp.ini "/etc/xrdp/xrdp.ini.uabi.bak.$(date +%s)" || true
python3 - <<PY
from pathlib import Path
p = Path("/etc/xrdp/xrdp.ini")
s = p.read_text(errors="ignore")
lines = []
changed = False
runtime_user_changed = False
runtime_group_changed = False
fork_changed = False
section = ""
for line in s.splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped.lower()
    if section == "[globals]" and stripped.startswith("port="):
        lines.append("port=${UABI_XRDP_PORT_IN_CONTAINER}")
        changed = True
    elif section == "[globals]" and stripped.startswith("runtime_user="):
        lines.append("runtime_user=")
        runtime_user_changed = True
    elif section == "[globals]" and stripped.startswith("runtime_group="):
        lines.append("runtime_group=")
        runtime_group_changed = True
    elif section == "[globals]" and stripped.startswith("fork="):
        lines.append("fork=false")
        fork_changed = True
    else:
        lines.append(line)
if not changed or not runtime_user_changed or not runtime_group_changed or not fork_changed:
    inserted = False
    for idx, line in enumerate(lines):
        if line.strip().lower() == "[globals]":
            insert_at = idx + 1
            if not changed:
                lines.insert(insert_at, "port=${UABI_XRDP_PORT_IN_CONTAINER}")
                insert_at += 1
            if not runtime_user_changed:
                lines.insert(insert_at, "runtime_user=")
                insert_at += 1
            if not runtime_group_changed:
                lines.insert(insert_at, "runtime_group=")
                insert_at += 1
            if not fork_changed:
                lines.insert(insert_at, "fork=false")
            inserted = True
            break
    if not inserted:
        prefix = []
        if not changed:
            prefix.append("port=${UABI_XRDP_PORT_IN_CONTAINER}")
        if not runtime_user_changed:
            prefix.append("runtime_user=")
        if not runtime_group_changed:
            prefix.append("runtime_group=")
        if not fork_changed:
            prefix.append("fork=false")
        lines = prefix + lines
p.write_text("\n".join(lines) + "\n")
PY

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
  cat "$log_dir/xrdp-sesman.stdout" >&2 || true
  cat "$log_dir/xrdp-sesman.stderr" >&2 || true
  exit 1
fi

echo "[INFO] Starting xrdp on port $UABI_XRDP_PORT_IN_CONTAINER..."
/usr/sbin/xrdp >"$log_dir/xrdp.stdout" 2>"$log_dir/xrdp.stderr" &
xrdp_pid=$!

for i in $(seq 1 60); do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${UABI_XRDP_PORT_IN_CONTAINER}$"; then
    echo "[OK] xrdp is listening on ${UABI_XRDP_PORT_IN_CONTAINER}"
    touch "$ready_file"
    break
  fi
  sleep 1
done

if [ ! -f "$ready_file" ]; then
  echo "[ERROR] xrdp did not become ready" >&2
  cat "$log_dir/xrdp.stdout" >&2 || true
  cat "$log_dir/xrdp.stderr" >&2 || true
  for f in /var/log/xrdp*.log; do
    [ -f "$f" ] || continue
    echo "----- $f -----" >&2
    tail -n 120 "$f" >&2 || true
  done
  exit 1
fi

_term() {
  echo "[INFO] Stopping xrdp..."
  kill "$xrdp_pid" "$sesman_pid" >/dev/null 2>&1 || true
  pkill -x xrdp >/dev/null 2>&1 || true
  wait "$xrdp_pid" "$sesman_pid" >/dev/null 2>&1 || true
}
trap _term TERM INT EXIT

while kill -0 "$sesman_pid" >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${UABI_XRDP_PORT_IN_CONTAINER}$"; do
  sleep 10
done

echo "[ERROR] xrdp or sesman died" >&2
exit 1
