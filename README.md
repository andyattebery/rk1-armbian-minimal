# Turing RK1 image: Debian 13 or Ubuntu 26.04 on Rockchip's vendor kernel

A flashable eMMC image for the Turing RK1 (RK3588), built with the Armbian build framework: Debian 13
trixie or Ubuntu 26.04 resolute on Rockchip's vendor kernel, the only kernel that runs the NPU's full
RKNN/RKLLM stack, MPP video and the Mali GPU's proprietary userspace (libmali). Each release carries
two images, one per distro, and either goes on any node; first boot is cloud-init, from a seed
written into the image before flashing. GitHub Actions builds both and publishes each build as one
release.

## What the image holds

| Part | What | From |
|---|---|---|
| Kernel, DTB | 6.1.172 `vendor-rk35xx` (rkr7.2), `rk3588-turing-rk1.dtb` | armbian/linux-rockchip `44bbd021`, built by Armbian |
| Bootloader | U-Boot v2026.07 with the RK3588 SCMI clock fix, at 32 KiB on the eMMC | Armbian |
| Userspace | Debian 13 trixie or Ubuntu 26.04 resolute, Armbian minimal CLI | Debian or Ubuntu, Armbian |
| GPU | `libmali-valhall-g610-g29p1` 1.10-1: OpenCL 3.0, Vulkan 1.4 (the device reports 1.4.305), GLES 3.2 | ginkage/libmali-rockchip |
| NPU | `/usr/lib/librknnrt.so` 2.3.2, `/usr/lib/librkllmrt.so` 1.3.1; RKNN Toolkit Lite2 in the venv `/opt/rknn-lite2` (CPython 3.12: the toolkit's newest wheel is cp312, and both distros' Python is newer) | airockchip, PyPI, uv |
| Video | `jellyfin-ffmpeg8` 8.1.3-1 (rkmpp codecs, rkrga filters) in `/usr/lib/jellyfin-ffmpeg/` | repo.jellyfin.org |
| 2.5 GbE | `r8169` with the RTL8125 firmware, for a Realtek RTL8125 card in the Turing Pi 2's mini-PCIe slot | the kernel, armbian-firmware |
| Access | cloud-init (NoCloud), from the `user-data` and `meta-data` in the FAT `armbi_boot` partition. Unseeded: root/1234, until changed | Armbian's `cloud-init` extension |

## Files

| Path | What it is |
|---|---|
| `versions.env` | Every pin: the Armbian commit, the kernel commit, and each download's URL and SHA-256. |
| `userpatches/config-rk1.conf` | The Armbian build config: board, branch, the `cloud-init` extension and the setting that keeps cloud-init's SSH host keys, the kernel-pin hook, the distro-version hook, `.img.xz` output. The release comes from `build.sh`. |
| `userpatches/customize-image.sh` | Runs in the image chroot: GPU, NPU and video; turns cloud-init's networking off. |
| `userpatches/overlay/` | Files `customize-image.sh` installs: the apt pin for Jellyfin's repo, the udev rules for the GPU (`50-mali.rules`) and for MPP, RGA and the DMA heaps (Jellyfin's), `rknn-requirements.txt`, the hash-locked RKNN Lite2 dependencies, and `99-network-config-disabled.cfg`, which turns cloud-init's networking off. |
| `userpatches/rknn-requirements.in` | What that lock is compiled from. |
| `scripts/build.sh` | The build of one release, on a Linux host: `--release trixie` or `--release resolute`. CI and local builds both run it. Prints its usage with `-h`. |
| `.github/workflows/build.yml` | The CI build of both releases, and the release that carries them. |
| `licenses/` | The vendor licences attached to every release. |
| `mise.toml` | `uv`, which compiles the RKNN lock. |

## Flashing a node

1. Download the `_trixie_` (Debian 13) or `_resolute_` (Ubuntu 26.04) `.img.xz` and its `.sha` from
   a [release](https://github.com/andyattebery/rk1-armbian-minimal/releases).
2. Check them: `sha256sum -c <name>.img.xz.sha` (on macOS, `shasum -a 256 -c <name>.img.xz.sha`).
3. To give the node its own settings, write a cloud-init seed into the image now (First boot).
4. On a Turing Pi 2, write it to the node's eMMC through the BMC with Turing's `tpi`:
   ```sh
   tpi power off -n <node>
   tpi flash -n <node> -i <name>.img.xz --sha256 <hash from the .sha>
   tpi power on -n <node>
   ```
   The BMC decompresses `.xz` itself and checks the stream against the hash. A flash takes about
   7 minutes.

## First boot

cloud-init sets the node up, with its NoCloud data source. It reads `user-data` and `meta-data` from
the FAT partition labelled `armbi_boot`, partition 1, which is also `/boot`. It also makes the SSH
host keys. Armbian's first-login setup doesn't start by itself.

### With a cloud-init seed

Replace `user-data` and `meta-data` in that partition before flashing. mtools writes them into a
decompressed copy without mounting it:
```sh
xz -dc <name>.img.xz > seeded.img
fdisk -l seeded.img          # partition 1's start sector (Linux)
mcopy -D o -i seeded.img@@<start>S user-data ::user-data
mcopy -D o -i seeded.img@@<start>S meta-data ::meta-data
xz -T0 seeded.img            # writes seeded.img.xz
sha256sum seeded.img.xz      # the hash for tpi flash --sha256
```
Then flash `seeded.img.xz` with that hash. Compressing it again keeps the flash short, because the
BMC decompresses `.xz` itself.
- **`meta-data`** needs `instance-id` and `local-hostname`, the hostname. The image's own has neither:
  it says `instance_id`, which cloud-init doesn't read, so every unseeded node is instance `nocloud`.
- **`user-data`** is a `#cloud-config` file: users, SSH keys, time zone and so on. It doesn't change
  root, which keeps password `1234`. `runcmd: [[usermod, -p, "*", root]]` replaces it, leaving root
  with no password.
- **Networking** is Armbian's DHCP on every Ethernet port. cloud-init's is turned off, so a
  `network-config` there does nothing.

### Without a seed

Log in as root with password `1234`, over SSH or on the serial console, where root is logged in by
itself (`tpi uart -n <node> get` shows it). Change it with `passwd`; nothing forces the change.

Or start Armbian's first-login setup, which sets a new root password too, from a root shell on a
terminal:
```sh
touch /root/.not_logged_in_yet && bash /usr/lib/armbian/armbian-firstlogin
```
It:
- asks for a new root password and a shell (bash or zsh);
- creates a user, in `sudo`, `video` and `render`, so the GPU and NPU work for it;
- offers to set the time zone and locale from your location, which sends the node's public IP to
  ipinfo.io and ipwhois.app.

cloud-init still runs, on the image's defaults. The hostname becomes `armbian`, and it creates the
distro's default user (`ubuntu` or `debian`), locked, with no password or keys. The time zone is the
build host's (`Etc/UTC` from GitHub's runners).

## Building

`scripts/build.sh --release <trixie|resolute> --work-dir <dir> --out <dir>` builds one release on
Debian 13 or Ubuntu 24.04, arm64 or amd64, as a user with passwordless sudo. It:
1. fetches armbian/build at `ARMBIAN_BUILD_SHA` into `<work-dir>/armbian-build`;
2. copies `userpatches/` in;
3. runs `./compile.sh build rk1 RELEASE=<release> PREFER_DOCKER=no`;
4. writes `<name>.img.xz`, `<name>.img.xz.sha` and `<name>.img.xz.distro` (the distro's version, one
   line) to `<out>`.

The first run downloads Armbian's cached kernel, U-Boot and root filesystem, or builds them. Reusing
the work dir reuses those caches.

**In CI.** [.github/workflows/build.yml](.github/workflows/build.yml) runs it once per release, in
parallel, on GitHub's `ubuntu-24.04-arm` runner: arm64 like the image, so the root filesystem builds
without qemu.
- **When:** a push to `main` that changes `versions.env`, `userpatches/`, `scripts/`, `licenses/` or
  the workflow, or a manual run from the Actions tab.
- **What it publishes:** one release with both images, only when both built. It is named
  `Armbian <Armbian version>, kernel <kernel version> (build <run number>)` and tagged
  `<kernel version>-<run number>` (for example `6.1.172-1`). It carries each `.img.xz`, its `.sha` and the three licence texts, and
  its notes give each image's distro version and sha256.
- **Not Armbian's own GitHub Action.** Its `action.yml` merges the unpinned `armbian/os` userpatches
  into the build, versions the image from `armbian/ci`, and uploads build logs to Armbian's paste
  service. None of these can be turned off.

**Locally**, on a Linux host: `scripts/build.sh --release resolute --work-dir ~/rk1-work --out out`.
On a Mac, in an OrbStack Linux machine:
```sh
orb create -a arm64 debian:trixie armbian-build
orb -m armbian-build bash -c 'sudo apt-get update && sudo apt-get install -y ca-certificates git rsync'
orb -m armbian-build bash -c 'cd <this repo> && scripts/build.sh --release resolute --work-dir ~/rk1-work --out out'
```
The first two commands are needed once. The work dir has to be on the machine's own filesystem
(Traps).

## Updating

Debian or Ubuntu packages and `jellyfin-ffmpeg8` update with apt.

Every Armbian package (kernel, DTB, U-Boot, BSP) is held (`BSPFREEZE=yes`). apt.armbian.com's stable
kernel is 6.1.115, older than this one, and would replace it. Those packages change only by bumping
the pins in `versions.env` and the hook in `config-rk1.conf`, then flashing the new release. Move off
Armbian `main` to a stable branch once one carries rkr7.2.

## Licences

The image redistributes four vendor binaries under three sets of terms. Every release attaches the
terms, which are also in `licenses/`:
- **libmali**, the Mali GPU userspace: Arm's End User Licence Agreement, which allows redistribution
  with a copy of the licence.
- **librkllmrt**, the RKLLM runtime: Rockchip's BSD-style licence, from airockchip/rknn-llm.
- **librknnrt and RKNN Toolkit Lite2**: Rockchip's copyright statement, from airockchip/rknn-toolkit2.

Everything else comes from Debian or Ubuntu, Armbian and Jellyfin (their copyright files are in the
image's `/usr/share/doc`), and from PyPI and Astral (the venv's packages, uv, and the CPython uv
installs), each under its own licence.

## Traps

- **The work dir must be case-sensitive.** If Armbian has to build the kernel, the tree has file
  names that differ only by case, which a case-insensitive filesystem (macOS APFS) cannot hold.
- **Native, not Docker.** `PREFER_DOCKER=no` goes on the command line, because Armbian decides
  between Docker and sudo before it reads `config-rk1.conf`. On a Mac, OrbStack's Docker engine can't
  run Armbian's Docker mode anyway: Armbian hands static loop devices only to Docker Desktop and
  Rancher, and on any other engine passes the Mac's nonexistent `/dev/loop*`.
- **userpatches must be inside the checkout.** On this Armbian commit `USERPATCHES_PATH` is
  read-only, set to `<checkout>/userpatches`, whatever the docs say. `build.sh` rsyncs `userpatches/`
  in on every run, so edit it here.
- **No `lib.config`.** Armbian `main` aborts a build that has `userpatches/lib.config`.
- **`customize-image.sh` runs without Armbian's apt repo.** Only the release's own repos (Debian's or
  Ubuntu's) are enabled at that point.
- **`/boot` is FAT:** the 512 MiB `armbi_boot` partition, which the `cloud-init` extension requires
  so NoCloud can read it. FAT holds no symlinks, so Armbian's kernel packages and its initramfs hook
  write plain files there instead.
- **cloud-init's networking is off.** The extension removes Armbian's `/etc/netplan/armbian-*`, but
  not its `10-dhcp-all-interfaces.yaml`, so cloud-init's network config would be a second one for
  the same ports. `overlay/99-network-config-disabled.cfg` turns cloud-init's off.
- **The image name has `-ci` after the kernel version** (`…_vendor_6.1.172-ci_minimal.img.xz`). The
  extension adds it; the workflow strips it for the release's tag and title.
- **SSH host keys come from cloud-init.** By default `armbian-firstrun` deletes and regenerates them
  on the first boot, after ssh has started. `OPENSSHD_REGENERATE_HOST_KEYS=false` in
  `config-rk1.conf` keeps cloud-init's.
- **Root's password must not be expired** (`chage -d 0 root`) to force a change. cron's PAM account
  check then refuses every root job ("Authentication token is no longer valid"), including Armbian's
  log truncation, until the password changes. Armbian leaves the same `chage` commented out
  (`lib/functions/rootfs/distro-agnostic.sh`).
- **`/etc/os-release` names Armbian.** Armbian's `base-files` rewrites it. The distro's own is
  `/usr/lib/os-release`, which the distro-version hook in `config-rk1.conf` reads.
- **Armbian's RK3588 family installs no GPU udev rule.** `rockchip64_common.inc` would install
  `50-mali.rules`, but `rockchip-rk3588.conf` replaces that function with a no-op, so `/dev/mali0`
  would be root-only. The overlay brings the rule.
- **libmali must match the kernel's GPU driver.** The vendor kernel's kbase is DDK g29p1, so the
  userspace is g29p1.
  - If OpenCL or Vulkan finds no device, the fallback is tsukumijima's g24p0 packages. kbase
    negotiates down to an older userspace, but every g24p0 report is on an older kbase (g25p0, rkr5.1).
  - ginkage deletes superseded releases, so a 404 at the libmali download means re-pinning to the
    current release.
- **No panthor.** The `panthor-gpu` overlay binds the GPU to panthor instead of kbase, and libmali
  needs kbase. This build sets no overlays.
- **`jellyfin-ffmpeg` is not on PATH.** It is `/usr/lib/jellyfin-ffmpeg/ffmpeg`. The RGA filters take
  hardware frames only: decode with
  `-init_hw_device rkmpp=rk -hwaccel rkmpp -hwaccel_output_format drm_prime` before `scale_rkrga`,
  or the filter fails with "Function not implemented".
- **`tpi uart get` is not a live stream.** Each call returns the BMC's whole buffer since the node
  powered on. Call it again to see newer lines.
