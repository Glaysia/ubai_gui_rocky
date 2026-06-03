#!/usr/bin/env bash
set -euo pipefail

: "${UABI_XRDP_PASSWORD:=1q2w3e}"
: "${UABI_XRDP_PORT_IN_CONTAINER:=3389}"
: "${UABI_CONTAINER_SSH_PORT:=9922}"
: "${UABI_CONTAINER_SSH_PUBLIC_KEY:=}"
xrdp_user="root"

log_dir="${UABI_CONTAINER_LOG_DIR:-/work/logs}"
ready_file="${UABI_CONTAINER_READY_FILE:-/work/xrdp.ready}"

mkdir -p "$log_dir" /run/xrdp /var/run/xrdp /var/log/xrdp /run/sshd /var/run/sshd /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix || true

echo "[INFO] Container release:"
cat /etc/rocky-release || true

echo "[INFO] Preparing xrdp user: $xrdp_user"
echo "${xrdp_user}:${UABI_XRDP_PASSWORD}" | chpasswd
usermod -s /bin/bash "$xrdp_user" >/dev/null 2>&1 || true

mkdir -p /root/.ssh
chmod 700 /root /root/.ssh
if [ -n "$UABI_CONTAINER_SSH_PUBLIC_KEY" ]; then
  printf '%s\n' "$UABI_CONTAINER_SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

cat > /etc/pam.d/xrdp-sesman <<'EOF'
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
EOF

mkdir -p /root
cat > /root/.Xclients <<'EOF'
#!/usr/bin/env bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
unset SESSION_MANAGER
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
if command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- startxfce4
fi
exec startxfce4
EOF
chmod 700 /root
chmod 755 /root/.Xclients
cp -f /root/.Xclients /root/.xsession

cat > /etc/xrdp/startwm.sh <<'EOF'
#!/usr/bin/env bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
unset SESSION_MANAGER
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
if command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- startxfce4
fi
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh

if [ ! -x /usr/sbin/sshd ] && command -v dnf >/dev/null 2>&1; then
  echo "[INFO] openssh-server missing; trying runtime install..."
  dnf -y install openssh-server >/dev/null 2>&1 || true
fi
if [ ! -x /usr/sbin/sshd ]; then
  echo "[ERROR] /usr/sbin/sshd not found. Rebuild the image with openssh-server." >&2
  exit 1
fi

ssh-keygen -A >/dev/null 2>&1 || true
sshd_options=(
  -D
  -e
  -o "Port=${UABI_CONTAINER_SSH_PORT}"
  -o "ListenAddress=127.0.0.1"
  -o "PermitRootLogin=yes"
  -o "PasswordAuthentication=yes"
  -o "PubkeyAuthentication=yes"
  -o "AuthorizedKeysFile=.ssh/authorized_keys"
  -o "UsePAM=yes"
  -o "X11Forwarding=yes"
  -o "AllowTcpForwarding=yes"
  -o "PermitTunnel=no"
)

echo "[INFO] Starting container sshd on 127.0.0.1:${UABI_CONTAINER_SSH_PORT}..."
/usr/sbin/sshd "${sshd_options[@]}" >"$log_dir/sshd.stdout" 2>"$log_dir/sshd.stderr" &
sshd_pid=$!

sleep 1
if ! kill -0 "$sshd_pid" >/dev/null 2>&1; then
  echo "[ERROR] sshd exited early" >&2
  cat "$log_dir/sshd.stdout" >&2 || true
  cat "$log_dir/sshd.stderr" >&2 || true
  exit 1
fi

cp -f /etc/xrdp/xrdp.ini "/etc/xrdp/xrdp.ini.uabi.bak.$(date +%s)" 2>/dev/null || true
cat > /etc/xrdp/xrdp.ini <<EOF
[Globals]
ini_version=1
fork=false
port=${UABI_XRDP_PORT_IN_CONTAINER}
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

[Xvnc]
name=Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
delay_ms=2000
EOF

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
  xrdp_ready=0
  sshd_ready=0
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${UABI_XRDP_PORT_IN_CONTAINER}$" && xrdp_ready=1
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${UABI_CONTAINER_SSH_PORT}$" && sshd_ready=1
  if [ "$xrdp_ready" -eq 1 ] && [ "$sshd_ready" -eq 1 ]; then
    echo "[OK] xrdp is listening on ${UABI_XRDP_PORT_IN_CONTAINER}"
    echo "[OK] sshd is listening on ${UABI_CONTAINER_SSH_PORT}"
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
  echo "[INFO] Stopping xrdp/sshd..."
  kill "$xrdp_pid" "$sesman_pid" "$sshd_pid" >/dev/null 2>&1 || true
  pkill -x xrdp >/dev/null 2>&1 || true
  pkill -x sshd >/dev/null 2>&1 || true
  wait "$xrdp_pid" "$sesman_pid" "$sshd_pid" >/dev/null 2>&1 || true
}
trap _term TERM INT EXIT

while kill -0 "$sesman_pid" >/dev/null 2>&1 && kill -0 "$sshd_pid" >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${UABI_XRDP_PORT_IN_CONTAINER}$"; do
  sleep 10
done

echo "[ERROR] xrdp, sesman, or sshd died" >&2
exit 1
