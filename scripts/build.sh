#!/usr/bin/env bash
# Builds the image (README.md) on a Linux host -- Debian 13 or Ubuntu 24.04, arm64 or amd64 -- as a
# user with passwordless sudo, which Armbian's compile.sh relaunches itself with. CI runs it on
# GitHub's ubuntu-24.04-arm runner; on a Mac, run it in an OrbStack Linux machine (README.md).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
    echo "Usage: $(basename "$0") --work-dir <dir> --out <dir>"
    echo
    echo "Fetches armbian/build at ARMBIAN_BUILD_SHA (versions.env) into <work-dir>/armbian-build,"
    echo "copies userpatches/ and versions.env into it, builds, and puts <name>.img.xz and"
    echo "<name>.img.xz.sha in <out>."
    echo
    echo "<work-dir> must be on a case-sensitive filesystem: if Armbian has to build the kernel, its"
    echo "tree has file names that differ only by case. Reusing it reuses Armbian's caches."
    echo
    echo "Example:"
    echo "  $(basename "$0") --work-dir ~/rk1-work --out out"
    exit 1
}

WORK=""
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir) WORK="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done
[[ -n "$WORK" && -n "$OUT" ]] || usage

for tool in git rsync sha256sum sudo; do
    command -v "$tool" >/dev/null || { echo "Error: $tool not found in PATH"; exit 1; }
done

# shellcheck source=SCRIPTDIR/../versions.env
source "$REPO_DIR/versions.env"

# The kernel pin is in two places: versions.env and the hook in config-rk1.conf.
if ! grep -qF "KERNELBRANCH='commit:$KERNEL_COMMIT'" "$REPO_DIR/userpatches/config-rk1.conf"; then
    echo "Error: userpatches/config-rk1.conf does not pin commit:$KERNEL_COMMIT (versions.env)"
    exit 1
fi

mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd -P)"
OUT="$(cd "$OUT" && pwd -P)"
SRC="$WORK/armbian-build"

# A depth-1 fetch of the pinned commit, only when it is not already there; the build needs no
# history, and a repeat fetch downloads the whole tree again.
echo "Checking out armbian/build $ARMBIAN_BUILD_SHA..."
if [[ ! -d "$SRC/.git" ]]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$ARMBIAN_BUILD_REPO"
fi
if ! git -C "$SRC" cat-file -e "$ARMBIAN_BUILD_SHA^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch -q --depth 1 origin "$ARMBIAN_BUILD_SHA"
fi
git -C "$SRC" checkout -q --detach "$ARMBIAN_BUILD_SHA"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$ARMBIAN_BUILD_SHA" ]]

# Armbian reads userpatches only from inside its checkout (entrypoint.sh declares USERPATCHES_PATH
# read-only). A compile.sh started with sudo, rather than relaunching itself through sudo as below,
# leaves userpatches/ owned by root, and rsync runs as this user.
[[ ! -e "$SRC/userpatches" ]] || sudo chown -R "$(id -u):$(id -g)" "$SRC/userpatches"
rsync -a --delete "$REPO_DIR/userpatches/" "$SRC/userpatches/"
cp "$REPO_DIR/versions.env" "$SRC/userpatches/overlay/versions.env"
# Left by an earlier run; the copy-out below needs exactly one image.
sudo rm -f "$SRC"/output/images/*.img*

# PREFER_DOCKER on the command line: Armbian decides between Docker and sudo before it reads
# config-rk1.conf, and on a host with Docker it would otherwise build in a container.
echo "Building the image..."
(cd "$SRC" && ./compile.sh build rk1 PREFER_DOCKER=no)

shopt -s nullglob
imgs=("$SRC"/output/images/*.img.xz)
if [[ ${#imgs[@]} -ne 1 ]]; then
    echo "Error: expected exactly one output/images/*.img.xz, found: ${imgs[*]}"
    exit 1
fi
NAME="$(basename "${imgs[0]}")"
if [[ ! "$NAME" =~ ^[A-Za-z0-9._+-]+\.img\.xz$ ]]; then
    echo "Error: unexpected image file name: $NAME"
    exit 1
fi

# Copied under a temporary name until it matches the hash Armbian wrote. The .sha is rewritten as
# "<hash>  <name>": Armbian writes one space, which GNU sha256sum -c accepts and macOS shasum -c
# rejects.
WANT="$(awk '{print $1}' "$SRC/output/images/$NAME.sha")"
cp "$SRC/output/images/$NAME" "$OUT/.$NAME.partial"
GOT="$(sha256sum "$OUT/.$NAME.partial" | awk '{print $1}')"
if [[ ! "$WANT" =~ ^[0-9a-f]{64}$ || "$GOT" != "$WANT" ]]; then
    rm -f "$OUT/.$NAME.partial"
    echo "Error: the copied image does not match Armbian's $NAME.sha"
    exit 1
fi
mv -f "$OUT/.$NAME.partial" "$OUT/$NAME"
printf '%s  %s\n' "$GOT" "$NAME" > "$OUT/$NAME.sha"
sudo rm -f "$SRC"/output/images/*.img*

echo
echo "Image: $OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f 1))"
