#!/usr/bin/env bash
set -euo pipefail

: "${UABI_BASE_IMAGE:=docker://rockylinux:9.4}"
: "${UABI_IMAGE:=$HOME/runtime/enroot/uabi-cst-rocky94-xrdp.sqsh}"
: "${UABI_ENROOT_NAME:=uabi-cst-rocky94-xrdp-build}"
: "${UABI_BUILD_WORKDIR:=$HOME/runtime/enroot/build-uabi-cst-rocky94}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

mkdir -p "$(dirname "$UABI_IMAGE")" "$UABI_BUILD_WORKDIR"

echo "[INFO] Base image: $UABI_BASE_IMAGE"
echo "[INFO] Target image: $UABI_IMAGE"
echo "[INFO] Build workdir: $UABI_BUILD_WORKDIR"

rm -rf "$UABI_BUILD_WORKDIR"
mkdir -p "$UABI_BUILD_WORKDIR"

base_sqsh="$UABI_BUILD_WORKDIR/base.sqsh"

echo "[INFO] Importing OCI image with enroot..."
enroot import -o "$base_sqsh" "$UABI_BASE_IMAGE"

echo "[INFO] Creating writable enroot container: $UABI_ENROOT_NAME"
enroot remove -f "$UABI_ENROOT_NAME" >/dev/null 2>&1 || true
enroot create -n "$UABI_ENROOT_NAME" "$base_sqsh"

install_script="$UABI_BUILD_WORKDIR/install_inside_container.sh"
cat > "$install_script" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Rocky release:"
cat /etc/rocky-release || true

sed -ri \
  -e 's|^mirrorlist=|#mirrorlist=|g' \
  -e 's|^#?baseurl=http://dl.rockylinux.org/\$contentdir/\$releasever/|baseurl=https://dl.rockylinux.org/vault/rocky/9.4/|g' \
  /etc/yum.repos.d/rocky*.repo

dnf -y install dnf-plugins-core epel-release
dnf config-manager --set-enabled crb || true

dnf -y install \
  bash coreutils findutils procps-ng which tar gzip bzip2 xz unzip zip \
  hostname iproute iputils net-tools lsof less vim nano sudo shadow-utils \
  openssh-clients ca-certificates curl wget rsync git python3

dnf -y groupinstall "Xfce" || true

dnf -y install \
  xrdp \
  tigervnc-server \
  xorgxrdp \
  xorg-x11-server-Xorg \
  xorg-x11-server-Xvfb \
  xorg-x11-xauth \
  xorg-x11-utils \
  xorg-x11-apps \
  xterm \
  dbus-x11 \
  mesa-libGL \
  mesa-libGLU \
  mesa-dri-drivers \
  libglvnd \
  libglvnd-glx \
  libglvnd-egl \
  libX11 \
  libXext \
  libXrender \
  libXt \
  libXi \
  libXrandr \
  libXcursor \
  libXinerama \
  libXcomposite \
  libXdamage \
  libXfixes \
  libxcb \
  libxkbcommon \
  libxkbcommon-x11 \
  fontconfig \
  dejavu-sans-fonts \
  google-noto-sans-cjk-fonts \
  glibc-langpack-en \
  glibc-langpack-ko \
  gtk2 \
  gtk3 \
  nss \
  nspr \
  alsa-lib \
  pulseaudio-libs \
  libXScrnSaver \
  at-spi2-atk \
  at-spi2-core \
  cups-libs \
  libdrm \
  libxshmfence \
  vulkan-loader \
  psmisc \
  htop \
  strace \
  file \
  redhat-lsb-core || true

dnf -y install \
  libnsl \
  libnsl2 \
  libaio \
  numactl-libs \
  openmotif \
  motif \
  libpng \
  libjpeg-turbo \
  libtiff \
  expat \
  freetype \
  zlib \
  bzip2-libs \
  xz-libs \
  libuuid \
  libselinux \
  libxcrypt-compat || true

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

cat > /usr/local/bin/uabi-cst-shell <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Rocky: $(cat /etc/rocky-release 2>/dev/null || true)"
echo "DISPLAY=${DISPLAY:-}"
echo "Try: glxinfo | grep -E 'OpenGL vendor|OpenGL renderer|OpenGL version'"
echo "Set CST launcher path in /usr/local/bin/uabi-start-cst if needed."
exec "${SHELL:-/bin/bash}"
EOF
chmod +x /usr/local/bin/uabi-cst-shell

cat > /usr/local/bin/uabi-start-cst <<'EOF'
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
echo "[ERROR] CST launcher not found. Edit /usr/local/bin/uabi-start-cst." >&2
exit 127
EOF
chmod +x /usr/local/bin/uabi-start-cst

dnf clean all
rm -rf /var/cache/dnf /tmp/*
EOS

chmod +x "$install_script"

echo "[INFO] Installing packages inside enroot container..."
enroot start --root --rw \
  --mount "$install_script:/tmp/install_inside_container.sh" \
  "$UABI_ENROOT_NAME" /bin/bash /tmp/install_inside_container.sh

echo "[INFO] Running CST placeholder hook..."
enroot start --root --rw \
  --mount "$repo_root/image/install_cst_placeholder.sh:/tmp/install_cst_placeholder.sh" \
  "$UABI_ENROOT_NAME" /bin/bash /tmp/install_cst_placeholder.sh || true

echo "[INFO] Exporting final sqsh..."
rm -f "$UABI_IMAGE"
enroot export -o "$UABI_IMAGE" "$UABI_ENROOT_NAME"

echo "[INFO] Validating final image..."
enroot start --root --rw "$UABI_ENROOT_NAME" /bin/bash -lc '
set -e
cat /etc/rocky-release
grep -q "Rocky Linux release 9.4" /etc/rocky-release
command -v xrdp
command -v xrdp-sesman
command -v startxfce4 || true
command -v glxinfo || true
'

echo "[INFO] Cleaning build container..."
enroot remove -f "$UABI_ENROOT_NAME" >/dev/null 2>&1 || true

echo "[OK] Built image: $UABI_IMAGE"
