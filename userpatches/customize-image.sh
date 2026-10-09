#!/bin/bash
# Armbian's image-customization hook for the RK1 image (README.md). Armbian copies it into
# the image and runs it there as root (lib/functions/rootfs/customize.sh:24-34) with the arguments
#   RELEASE LINUXFAMILY BOARD BUILD_DESKTOP ARCH
# after its own packages are installed and before its apt repo is enabled: the release's own repos
# (Debian's or Ubuntu's) are reachable here, Armbian's are not. userpatches/overlay/ is bind-mounted
# read-only at /tmp/overlay. Any non-zero exit fails the build.
set -euo pipefail

RELEASE="$1"
BOARD="$3"
# Written for two targets on the RK1, Debian 13 (trixie) and Ubuntu 26.04 (resolute): the package
# names below exist in both; the release picks Jellyfin's repo.
case "$RELEASE" in
    trixie) JELLYFIN_DISTRO=debian ;;
    resolute) JELLYFIN_DISTRO=ubuntu ;;
    *) JELLYFIN_DISTRO="" ;;
esac
if [[ -z "$JELLYFIN_DISTRO" || "$BOARD" != turing-rk1 ]]; then
    echo "customize-image.sh: written for trixie or resolute on turing-rk1, called for $RELEASE on $BOARD" >&2
    exit 1
fi

OVERLAY=/tmp/overlay
# shellcheck source=SCRIPTDIR/../versions.env
source "$OVERLAY/versions.env"
export DEBIAN_FRONTEND=noninteractive

# Downloads land here and are deleted on exit, so none of them ships in the image. Readable by
# apt's _apt user, which fetches the local libmali deb.
WORK="$(mktemp -d)"
chmod 755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# fetch_verified URL SHA256 DEST: download, then fail unless the file matches its pin.
fetch_verified() {
    curl -fsSL --retry 3 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c -
}

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl clinfo vulkan-tools ocl-icd-libopencl1 libgomp1

# GPU: Mali G610 userspace (OpenCL 3.0, Vulkan 1.4, GLES 3.2), DDK g29p1 to match the vendor
# kernel's kbase driver. It installs the OpenCL and Vulkan ICD files clinfo and vulkaninfo read.
fetch_verified "$LIBMALI_URL" "$LIBMALI_SHA256" "$WORK/libmali.deb"
apt-get install -y --no-install-recommends "$WORK/libmali.deb"

# NPU: the RKNN and RKLLM runtimes, which Rockchip ships as bare .so files.
fetch_verified "$RKNNRT_URL" "$RKNNRT_SHA256" "$WORK/librknnrt.so"
fetch_verified "$RKLLMRT_URL" "$RKLLMRT_SHA256" "$WORK/librkllmrt.so"
install -m 0644 "$WORK/librknnrt.so" "$WORK/librkllmrt.so" /usr/lib/
ldconfig

# RKNN Toolkit Lite2's newest wheel is cp312 and both releases' python3 is newer (trixie 3.13,
# resolute 3.14), so uv installs CPython 3.12 into /opt/python and a venv on it at
# /opt/rknn-lite2. Dependencies come from the hash-locked rknn-requirements.txt, wheels only; the
# toolkit wheel is checked against its pin.
# Bytecode is compiled now because the venv is root-owned and its users can't write __pycache__.
fetch_verified "$UV_URL" "$UV_SHA256" "$WORK/uv.tar.gz"
tar -xzf "$WORK/uv.tar.gz" -C "$WORK"
install -m 0755 "$WORK/uv-aarch64-unknown-linux-gnu/uv" /usr/local/bin/uv
export UV_PYTHON_INSTALL_DIR=/opt/python UV_MANAGED_PYTHON=1 UV_NO_CACHE=1 UV_COMPILE_BYTECODE=1
uv python install --no-bin 3.12
uv venv --python 3.12 /opt/rknn-lite2
uv pip install --python /opt/rknn-lite2/bin/python --require-hashes --only-binary :all: \
    -r "$OVERLAY/rknn-requirements.txt"
WHEEL="$WORK/${RKNN_LITE_WHEEL_URL##*/}"
fetch_verified "$RKNN_LITE_WHEEL_URL" "$RKNN_LITE_WHEEL_SHA256" "$WHEEL"
uv pip install --python /opt/rknn-lite2/bin/python --no-deps "$WHEEL"

# Video: jellyfin-ffmpeg8, which bundles its own MPP and RGA, from Jellyfin's repo. The pin file
# lets nothing else come from there.
install -d -m 0755 /etc/apt/keyrings
fetch_verified "$JELLYFIN_KEY_URL" "$JELLYFIN_KEY_SHA256" /etc/apt/keyrings/jellyfin.asc
chmod 0644 /etc/apt/keyrings/jellyfin.asc
cat > /etc/apt/sources.list.d/jellyfin.sources <<EOF
Types: deb
URIs: https://repo.jellyfin.org/$JELLYFIN_DISTRO
Suites: $RELEASE
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/jellyfin.asc
EOF
install -m 0644 "$OVERLAY/jellyfin.pref" /etc/apt/preferences.d/jellyfin
apt-get update
apt-get install -y --no-install-recommends "jellyfin-ffmpeg8=$JELLYFIN_FFMPEG_VERSION-$RELEASE"

# Device permissions: the GPU (Armbian's own rule from packages/bsp/rk3399, which its RK3588
# family no longer installs: rockchip-rk3588.conf makes family_tweaks_bsp a no-op), and MPP, RGA
# and the DMA heaps (Jellyfin's rules).
install -m 0644 "$OVERLAY/50-mali.rules" /etc/udev/rules.d/
install -m 0644 "$OVERLAY/99-rk-device-permissions.rules" /etc/udev/rules.d/

# First boot is cloud-init (config-rk1.conf). Its networking is off, so Armbian's DHCP stays the only
# network config. The directory comes with the cloud-init package; without it this fails the build.
install -m 0644 "$OVERLAY/99-network-config-disabled.cfg" /etc/cloud/cloud.cfg.d/

apt-get clean
