# stargate-kernel

Build a machine-optimized vanilla Linux kernel as Debian packages, from the
latest kernel.org release, in one command: trimmed to the hardware in front
of you, compiled for its exact CPU, with a few desktop-oriented defaults and
your own boot logo. Written for a TUXEDO InfinityBook
Pro AMD Gen10 (Ryzen AI 9 HX 370, `znver5`) running Debian 13, but every
machine-specific choice is an environment variable.

## What you get vs the stock Debian kernel

| Area | stargate | Debian |
| --- | --- | --- |
| CPU target | `-march=znver5` via `KCFLAGS` | generic x86-64 |
| Config | `localmodconfig` (only the modules this machine loads) + a `KEEP_MODULES` list for hot-plug hardware, VPNs, network filesystems, VMs and containers | everything as a module |
| Timer tick | `HZ=1000` | 250 |
| I/O scheduler | BFQ available | dropped by localmodconfig |
| TCP congestion control | BBR (default) | CUBIC |
| UBSAN | off | on |
| Boot logo | `logo/stargate-logo.png` via `CONFIG_LOGO_LINUX_CLUT224_FILE` (any image, converted at build time) | off |
| Scheduler | EEVDF, optional BORE patch (`ENABLE_BORE=1`) | EEVDF |
| Output | `linux-image-<ver>-stargate` and `linux-headers-<ver>-stargate` `.deb` via `bindeb-pkg` | — |

The script never touches the running kernel: the packages add a GRUB entry,
the old kernel stays as fallback.

## How it works, step by step

1. **Pick the release.** Reads `https://www.kernel.org/releases.json` and takes
   the latest `stable` entry (or `mainline`, the current `-rc`, with
   `CHANNEL=mainline`), including the tarball and signature URLs kernel.org
   publishes for it. If that exact version is already running or installed as
   `<ver>-stargate`, it stops here: nothing to do.
2. **Install build dependencies** that are missing (`build-essential`,
   `libssl-dev`, `libelf-dev`, `dwarves`, `debhelper`, `libdw-dev`, `ccache`,
   ImageMagick, ...), with `apt`.
3. **Download and verify.** The tarball goes to `~/build/`; a tarball already
   there is reused. Stable releases are checked against Greg Kroah-Hartman's
   PGP key (`647F...693E`, fetched on first run); `-rc` tarballs are unsigned
   upstream, so only HTTPS applies and the script says so.
4. **Optional BORE patch** (`ENABLE_BORE=1`): downloaded, dry-run applied, and
   skipped with a warning if it does not fit this version.
5. **Configure.** Starts from the running kernel's `/boot/config-$(uname -r)`,
   then `make localmodconfig` keeps only the modules currently loaded. That
   throws away everything not in use *at that moment* (a USB stick you did not
   plug in, WireGuard, NFS, the SD card reader, Bluetooth HID, IIO), so a fixed
   `KEEP_MODULES` list forces those back as `=m`. Then the tuning:
   `LOGO` with your image converted to a 224-color PPM, `HZ_1000`,
   `IOSCHED_BFQ`, `UBSAN` off, `TCP_CONG_BBR` + `DEFAULT_BBR`, and
   `make olddefconfig` to settle dependencies.
6. **Verify the config.** Every symbol requested above is grepped back from
   `.config`; a missing one aborts the build naming it. Kconfig silently drops
   unknown or dependency-less symbols, this is the only way to notice.
   `CONFIG_ONLY=1` ends here.
7. **Build.** `make -j$(nproc) bindeb-pkg` with `KCFLAGS=-march=znver5 -O2`
   (vanilla kernel.org has no per-microarchitecture Kconfig choice, that is a
   Debian-only patch), `LOCALVERSION=-stargate`, through `ccache`. Output:
   `linux-image-<ver>-stargate`, `linux-headers-<ver>-stargate` (plus the
   `-dbg` and `linux-libc-dev` packages `bindeb-pkg` always produces).
8. **Print the install commands** and the rollback instructions. Installing
   is your call; the script never runs `dpkg -i` itself.

## Usage

```sh
./build-optimized-kernel.sh              # latest stable; exits early if it is already installed/running
FORCE=1 ./build-optimized-kernel.sh      # rebuild the same version (after changing the script)
CHANNEL=mainline ./build-optimized-kernel.sh   # current -rc from git.kernel.org (unsigned tarball)
CONFIG_ONLY=1 ./build-optimized-kernel.sh      # stop once .config is ready, no compile
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `MARCH` | `znver5` | `-march` passed to the compiler (`gcc -march=native -Q --help=target` tells you yours) |
| `KERNEL_NAME` | `stargate` | `LOCALVERSION` suffix and package name |
| `CHANNEL` | `stable` | `stable` or `mainline` (-rc) |
| `KEEP_MODULES` | see script | Kconfig symbols forced to `=m` after `localmodconfig`; replaces the list, does not extend it |
| `LOGO_FILE` / `LOGO_SIZE` | `logo/stargate-logo.png` / `128` | boot logo; `LOGO_FILE=""` keeps Tux |
| `ENABLE_BORE` / `BORE_PATCH_URL` | `0` | apply the BORE scheduler patch, best-effort (skipped if it does not apply) |
| `BUILD_DIR` | `~/build` | tarball, source tree and packages |
| `JOBS` | `nproc` | parallel jobs |
| `KEEP_SOURCE` | `1` | `0` deletes the source tree after the build |
| `FORCE` / `CONFIG_ONLY` | `0` | see above |
| `INSTALL` | `ask` | `ask`, `yes` or `no`: whether to offer to install at the end |

Build dependencies are installed automatically with `apt` when missing.
A cold build takes ~8 minutes on 24 threads; rebuilds with a warm `ccache` 2–3.

## Install

When the build finishes the script asks **"Install <ver>-stargate now?"** and,
on `y`, installs the headers **first** and the image **second** (two separate
`dpkg -i`: the image's postinst triggers DKMS, which needs the matching headers
already configured or it silently builds nothing), then prints the DKMS status
and warns if any module is not `installed`. It picks the newest revision of each
package when `~/build` holds several.

| `INSTALL=` | Behaviour |
| --- | --- |
| `ask` (default) | asks when a terminal is attached; otherwise only prints the commands |
| `yes` | installs without asking |
| `no` | never asks, only prints the commands |

To do it by hand:

```sh
cd ~/build
sudo dpkg -i linux-headers-<ver>-stargate_*.deb
sudo dpkg -i linux-image-<ver>-stargate_*.deb
sudo dkms status | grep stargate      # every DKMS module should say "installed"
```

Roll back: pick the old kernel in GRUB, then
`sudo dpkg --purge linux-image-<ver>-stargate linux-headers-<ver>-stargate`.

## Runtime side: console palette and a single logo

`grub/90-console-stargate.cfg` is a `/etc/default/grub.d/` drop-in that sets a
Gentoo-inspired VT palette (`vt.default_{red,grn,blu}`) and
`fbcon=logo-count:1`, so fbcon draws one logo instead of one per CPU. Copy it
to `/etc/default/grub.d/` and run `update-grub`. Removing `quiet` from the
kernel command line (and Plymouth from the system) is what makes the logo and
the boot log visible at all.

## Things the script checks for you

`scripts/config` happily writes symbols that do not exist and `olddefconfig`
silently discards them. After configuring, the script verifies that every
requested option actually landed in `.config` and stops otherwise, naming the
symbol. That is how these were found the first time:

- BFQ is `IOSCHED_BFQ`, not `MQ_IOSCHED_BFQ`
- `DEFAULT_TCP_CONG` is derived from a `choice`; set `DEFAULT_BBR` instead
- `localmodconfig` drops anything not loaded right now: USB sticks, WireGuard,
  NFS, the SD reader, Bluetooth HID, loop devices (`mount -o loop` on an ISO
  failed with "failed to setup loop device"), `CONFIG_IIO` (which TUXEDO's DKMS
  drivers need to build at all)

## Requirements

Debian/Ubuntu-style system with `dpkg`, `gcc` ≥ 14 for `znver5`, ImageMagick
(for the logo), Secure Boot disabled or your own signing set up (the packages
are unsigned).
