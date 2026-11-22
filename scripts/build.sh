#!/usr/bin/env bash
# Builds one of the image's two releases (README.md), Debian 13 (trixie) or Ubuntu 26.04 (resolute),
# on a Linux host -- Debian 13 or Ubuntu 24.04, arm64 or amd64 -- as a user with passwordless sudo,
# which Armbian's compile.sh relaunches itself with. CI runs it on GitHub's ubuntu-24.04-arm runner;
# on a Mac, run it in an OrbStack Linux machine (README.md).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
    echo "Usage: $(basename "$0") --release <trixie|resolute> --work-dir <dir> --out <dir>"
    echo
    echo "Fetches the head of armbian/build's ARMBIAN_BUILD_BRANCH (versions.env) into"
    echo "<work-dir>/armbian-build, copies userpatches/ and versions.env into it, builds the release"
    echo "(trixie: Debian 13, resolute: Ubuntu 26.04), and puts <name>.img.xz and <name>.img.xz.sha in"
    echo "<out>, with <name>.img.xz.distro (the distro's version) and <name>.img.xz.armbian (the"
    echo "Armbian commit), one line each."
    echo
    echo "<work-dir> must be on a case-sensitive filesystem: if Armbian has to build the kernel, its"
    echo "tree has file names that differ only by case. Reusing it reuses Armbian's caches."
    echo
    echo "Example:"
    echo "  $(basename "$0") --release resolute --work-dir ~/rk1-work --out out"
    exit 1
}

RELEASE=""
WORK=""
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) RELEASE="${2:-}"; shift 2 ;;
        --work-dir) WORK="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done
[[ "$RELEASE" =~ ^(trixie|resolute)$ && -n "$WORK" && -n "$OUT" ]] || usage

for tool in git rsync sha256sum sudo; do
    command -v "$tool" >/dev/null || { echo "Error: $tool not found in PATH"; exit 1; }
done

# shellcheck source=SCRIPTDIR/../versions.env
source "$REPO_DIR/versions.env"

mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd -P)"
OUT="$(cd "$OUT" && pwd -P)"
SRC="$WORK/armbian-build"

# The branch's head, resolved once, so that the build and <name>.img.xz.armbian name one commit.
echo "Resolving armbian/build $ARMBIAN_BUILD_BRANCH..."
ARMBIAN_COMMIT="$(git ls-remote "$ARMBIAN_BUILD_REPO" "refs/heads/$ARMBIAN_BUILD_BRANCH" | awk '{print $1}')"
if [[ ! "$ARMBIAN_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: no single branch $ARMBIAN_BUILD_BRANCH in $ARMBIAN_BUILD_REPO"
    exit 1
fi

# A depth-1 fetch of that commit, only when it is not already there; the build needs no
# history, and a repeat fetch downloads the whole tree again.
echo "Checking out armbian/build $ARMBIAN_COMMIT..."
if [[ ! -d "$SRC/.git" ]]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$ARMBIAN_BUILD_REPO"
fi
if ! git -C "$SRC" cat-file -e "$ARMBIAN_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch -q --depth 1 origin "$ARMBIAN_COMMIT"
fi
git -C "$SRC" checkout -q --detach "$ARMBIAN_COMMIT"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$ARMBIAN_COMMIT" ]]

# The build reads a copy of userpatches/ in the checkout, Armbian's default USERPATCHES_PATH.
# Armbian can be pointed at another directory, but it creates templates and a directory skeleton
# in the one it uses (lib/functions/cli/utils-cli.sh), and the copy also gets versions.env, so this
# repo's userpatches/ stays as git has it. A compile.sh started with sudo, rather than relaunching
# itself through sudo as below, leaves userpatches/ owned by root, and rsync runs as this user.
[[ ! -e "$SRC/userpatches" ]] || sudo chown -R "$(id -u):$(id -g)" "$SRC/userpatches"
rsync -a --delete "$REPO_DIR/userpatches/" "$SRC/userpatches/"
cp "$REPO_DIR/versions.env" "$SRC/userpatches/overlay/versions.env"
# Left by an earlier run; the copy-out below needs exactly one image, and this build's distro line.
sudo rm -f "$SRC"/output/images/*.img* "$SRC/output/distro.txt"

# PREFER_DOCKER on the command line: Armbian decides between Docker and sudo before it reads
# config-rk1.conf, and on a host with Docker it would otherwise build in a container.
echo "Building the $RELEASE image..."
(cd "$SRC" && ./compile.sh build rk1 RELEASE="$RELEASE" PREFER_DOCKER=no)

shopt -s nullglob
imgs=("$SRC"/output/images/*.img.xz)
if [[ ${#imgs[@]} -ne 1 ]]; then
    echo "Error: expected exactly one output/images/*.img.xz, found: ${imgs[*]}"
    exit 1
fi
NAME="$(basename "${imgs[0]}")"
if [[ ! "$NAME" =~ ^[A-Za-z0-9._+-]+\.img\.xz$ || "$NAME" != *"_${RELEASE}_vendor_"* ]]; then
    echo "Error: unexpected image file name for $RELEASE: $NAME"
    exit 1
fi
# Written by the distro-version hook in config-rk1.conf.
if [[ ! -s "$SRC/output/distro.txt" ]]; then
    echo "Error: the build wrote no output/distro.txt"
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
cp "$SRC/output/distro.txt" "$OUT/$NAME.distro"
printf '%s\n' "$ARMBIAN_COMMIT" > "$OUT/$NAME.armbian"
sudo rm -f "$SRC"/output/images/*.img* "$SRC/output/distro.txt"

echo
echo "Image: $OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f 1))"
echo "Distro: $(cat "$OUT/$NAME.distro")"
echo "Armbian: $ARMBIAN_BUILD_BRANCH at $ARMBIAN_COMMIT"
