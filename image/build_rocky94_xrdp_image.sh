#!/usr/bin/env bash
set -euo pipefail

: "${UBAI_BASE_IMAGE:=docker://rockylinux/rockylinux:9.4}"
: "${UBAI_IMAGE:=$HOME/runtime/enroot/ubai-cst-rocky94-xrdp.sqsh}"
: "${UBAI_ENROOT_NAME:=ubai-cst-rocky94-xrdp-build}"
: "${UBAI_BUILD_WORKDIR:=$HOME/runtime/enroot/build-ubai-cst-rocky94}"
: "${UBAI_BUILD_INCLUDE_CST_DEPS:=0}"
export UBAI_BUILD_INCLUDE_CST_DEPS

if [ "$UBAI_BASE_IMAGE" = "docker://rockylinux:9.4" ]; then
  echo "[INFO] Rewriting legacy Rocky image reference to docker://rockylinux/rockylinux:9.4"
  UBAI_BASE_IMAGE="docker://rockylinux/rockylinux:9.4"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

mkdir -p "$(dirname "$UBAI_IMAGE")" "$UBAI_BUILD_WORKDIR"

echo "[INFO] Base image: $UBAI_BASE_IMAGE"
echo "[INFO] Target image: $UBAI_IMAGE"
echo "[INFO] Build workdir: $UBAI_BUILD_WORKDIR"

base_sqsh="$UBAI_BUILD_WORKDIR/base.sqsh"

if [ -f "$base_sqsh" ]; then
  echo "[OK] Reusing cached base image: $base_sqsh"
else
  echo "[INFO] Importing OCI image with enroot..."
  enroot import -o "$base_sqsh" "$UBAI_BASE_IMAGE"
fi

echo "[INFO] Creating writable enroot container: $UBAI_ENROOT_NAME"
enroot remove -f "$UBAI_ENROOT_NAME" >/dev/null 2>&1 || true
enroot create -n "$UBAI_ENROOT_NAME" "$base_sqsh"

install_script="$UBAI_BUILD_WORKDIR/install_inside_container.sh"
cat > "$install_script" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Rocky release:"
cat /etc/rocky-release || true

sed -ri \
  -e 's|^mirrorlist=|#mirrorlist=|g' \
  -e 's|^#?baseurl=http://dl.rockylinux.org/\$contentdir/\$releasever/|baseurl=https://dl.rockylinux.org/vault/rocky/9.4/|g' \
  /etc/yum.repos.d/rocky*.repo

dnf_base=(
  dnf -y
  --allowerasing
  --setopt=install_weak_deps=False
  --setopt=metadata_timer_sync=0
  --setopt=max_parallel_downloads=10
  --setopt=ip_resolve=4
  --setopt=timeout=30
  --setopt=retries=1
)

: "${UBAI_DNF_TIMEOUT_SECONDS:=1200}"
: "${UBAI_DNF_ATTEMPTS:=2}"

run_dnf() {
  echo "[INFO] dnf $*"
  local attempt rc
  for attempt in $(seq 1 "$UBAI_DNF_ATTEMPTS"); do
    if command -v timeout >/dev/null 2>&1; then
      timeout "$UBAI_DNF_TIMEOUT_SECONDS" "${dnf_base[@]}" "$@" && return 0
    else
      "${dnf_base[@]}" "$@" && return 0
    fi
    rc=$?
    echo "[WARN] dnf attempt $attempt/$UBAI_DNF_ATTEMPTS failed: rc=$rc" >&2
    if [ "$attempt" -lt "$UBAI_DNF_ATTEMPTS" ]; then
      rm -rf /var/cache/dnf/* || true
      sleep 5
    fi
  done
  return "$rc"
}

UBAI_DNF_TIMEOUT_SECONDS=240 run_dnf install dnf-plugins-core epel-release
dnf config-manager --set-enabled crb || true

run_dnf install \
  bash coreutils findutils procps-ng which tar gzip bzip2 xz unzip zip \
  hostname iproute iputils net-tools lsof less vim-minimal nano shadow-utils \
  openssh-clients openssh-server ca-certificates curl wget rsync git python3 \
  firefox \
  xrdp tigervnc-server xorgxrdp xorg-x11-xauth xorg-x11-utils xterm dbus-x11 \
  mesa-demos mesa-libGL mesa-dri-drivers fontconfig dejavu-sans-fonts \
  glibc-langpack-en glibc-langpack-ko psmisc htop file

run_dnf install \
  xfce4-session xfce4-panel xfdesktop xfwm4 xfce4-settings xfce4-terminal Thunar || {
  echo "[WARN] Minimal Xfce package install failed; trying Xfce groupinstall."
  run_dnf groupinstall "Xfce"
}

run_dnf install google-noto-sans-cjk-fonts || true

if [ "${UBAI_BUILD_INCLUDE_CST_DEPS:-0}" = "1" ]; then
  run_dnf install \
    libnsl libnsl2 libaio numactl-libs openmotif motif libpng libjpeg-turbo \
    libtiff expat freetype zlib bzip2-libs xz-libs libuuid libselinux \
    libxcrypt-compat gtk2 gtk3 nss nspr alsa-lib pulseaudio-libs cups-libs \
    libdrm libxshmfence vulkan-loader strace redhat-lsb-core || true
fi

mkdir -p /etc/xrdp /run/xrdp /var/run/xrdp /var/log/xrdp
if [ -x /usr/bin/xrdp-keygen ]; then
  xrdp-keygen xrdp auto >/dev/null 2>&1 || true
fi

cat > /etc/skel/.Xclients <<'EOF'
#!/usr/bin/env bash
exec startxfce4
EOF
chmod +x /etc/skel/.Xclients

if [ -f /etc/xrdp/startwm.sh ]; then
  cp -f /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.orig || true
  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/usr/bin/env bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
  chmod +x /etc/xrdp/startwm.sh
fi

cat > /usr/local/bin/ubai-cst-shell <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Rocky: $(cat /etc/rocky-release 2>/dev/null || true)"
echo "DISPLAY=${DISPLAY:-}"
echo "Try: glxinfo | grep -E 'OpenGL vendor|OpenGL renderer|OpenGL version'"
echo "Set CST launcher path in /usr/local/bin/ubai-start-cst if needed."
exec "${SHELL:-/bin/bash}"
EOF
chmod +x /usr/local/bin/ubai-cst-shell

cat > /usr/local/bin/ubai-start-cst <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CANDIDATES=(
  "/opt/cst/cst_design_environment"
  "/opt/cst/CST_Studio_Suite/cst_design_environment"
  "/usr/local/CST_Studio_Suite/cst_design_environment"
)
for path in "${CANDIDATES[@]}"; do
  if [ -x "$path" ]; then
    exec "$path" "$@"
  fi
done
echo "[ERROR] CST launcher not found. Edit /usr/local/bin/ubai-start-cst." >&2
exit 127
EOF
chmod +x /usr/local/bin/ubai-start-cst

dnf clean all || true
rm -rf /var/cache/dnf
find /tmp -mindepth 1 ! -name install_inside_container.sh -exec rm -rf {} + 2>/dev/null || true
EOS

chmod +x "$install_script"

echo "[INFO] Installing packages inside enroot container..."
enroot start --root --rw \
  --mount "$install_script:/tmp/install_inside_container.sh" \
  "$UBAI_ENROOT_NAME" /bin/bash /tmp/install_inside_container.sh

echo "[INFO] Running CST placeholder hook..."
enroot start --root --rw \
  --mount "$repo_root/image/install_cst_placeholder.sh:/tmp/install_cst_placeholder.sh" \
  "$UBAI_ENROOT_NAME" /bin/bash /tmp/install_cst_placeholder.sh || true

echo "[INFO] Exporting final sqsh..."
rm -f "$UBAI_IMAGE"
enroot export -o "$UBAI_IMAGE" "$UBAI_ENROOT_NAME"

echo "[INFO] Validating final image..."
enroot start --root --rw "$UBAI_ENROOT_NAME" /bin/bash -lc '
set -e
cat /etc/rocky-release
grep -q "Rocky Linux release 9.4" /etc/rocky-release
command -v xrdp
command -v xrdp-sesman
command -v sshd
command -v firefox
command -v startxfce4 || true
command -v glxinfo || true
'

echo "[INFO] Cleaning build container..."
enroot remove -f "$UBAI_ENROOT_NAME" >/dev/null 2>&1 || true

echo "[OK] Built image: $UBAI_IMAGE"
