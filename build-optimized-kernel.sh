#!/usr/bin/env bash
# Build a machine-optimized vanilla kernel .deb for Indy (AMD Ryzen AI 9 HX 370,
# znver5) starting from the latest kernel.org "stable" release.
#
# What "optimized for this machine" means here, concretely:
#   1. Config trimmed to what THIS machine actually needs (localmodconfig from
#      the running system's lsmod) instead of Debian's generic everything-as-
#      module config -> much smaller build, smaller initrd, less to maintain.
#   2. CPU target set to the real microarchitecture (znver5) rather than the
#      generic x86-64 baseline Debian ships, via KCFLAGS -march=znver5 (vanilla
#      kernel.org has no per-microarch Kconfig choices like Debian's MZEN5 --
#      those are a Debian-only patch to their own kernel package).
#   3. Desktop/workstation tuning: HZ=1000 (Debian ships 250, server-leaning),
#      BFQ I/O scheduler available (best interactive feel under disk load),
#      UBSAN off (kernel-developer-only instrumentation with real runtime
#      cost, not needed on a daily-driver kernel), Tux boot logo re-enabled
#      (CONFIG_LOGO, off by default because Debian expects Plymouth), TCP BBR
#      as the default congestion control (better than CUBIC on variable-
#      latency links).
#   4. Optional: the BORE scheduler patch (opt-in, see ENABLE_BORE below) --
#      what CachyOS ships by default, tuned for bursty interactive workloads.
#   5. Produces standard Debian .deb packages (image + headers) via the
#      kernel's own `bindeb-pkg` target -> installs/removes like any kernel
#      package, works with the existing GRUB/initramfs tooling.
#
# What this does NOT do: touch the currently running/booted kernel. The new
# kernel is only ever a `dpkg -i` away from being installed as an additional
# boot entry; GRUB keeps the old one too. At the end it ASKS whether to install
# (INSTALL=ask|yes|no), it never installs on its own by default.
#
# TUXEDO's own kernel work (gitlab.com/tuxedocomputers/development/packages)
# is hardware-enablement (fan control, keyboard backlight, EC/WMI sensors via
# the tuxedo-drivers DKMS package), not performance tuning -- and it's already
# installed on Indy, rebuilding itself against whatever kernel is running.
# Nothing to add here for that.
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-$HOME/build}"
JOBS="${JOBS:-$(nproc)}"
MARCH="${MARCH:-znver5}"
KERNEL_NAME="${KERNEL_NAME:-stargate}"
KEEP_SOURCE="${KEEP_SOURCE:-1}"          # set to 0 to delete the source tree after building
ENABLE_BORE="${ENABLE_BORE:-0}"          # set to 1 to apply the BORE scheduler patch (opt-in: it
                                          # touches core scheduler code, more invasive than the
                                          # Kconfig-only tweaks below; best-effort, skips cleanly
                                          # if it doesn't apply to whatever version this runs against)
BORE_PATCH_URL="${BORE_PATCH_URL:-https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches/testing/0001-linux7.2-rc1-bore-7.0.0.patch}"
# Boot logo shown by fbcon instead of Tux. Any image ImageMagick can read; it is
# converted at build time to the 224-color PPM the kernel wants. Set to "" to
# keep the stock Tux. Number of copies / position are runtime knobs, not build
# ones: fbcon=logo-count:1 on the kernel cmdline (see grub/ in this repo).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOGO_FILE="${LOGO_FILE:-$SCRIPT_DIR/logo/stargate-logo.png}"
LOGO_SIZE="${LOGO_SIZE:-128}"
# CHANNEL=stable (default) or mainline: "mainline" is the current -rcN release
# candidate from Linus' tree (tar.gz from git.kernel.org, no PGP signature) --
# expect out-of-tree DKMS modules (tuxedo-drivers) to possibly not build yet.
CHANNEL="${CHANNEL:-stable}"
# FORCE=1: build even if the selected release is already installed/running as -$KERNEL_NAME.
# CONFIG_ONLY=1: stop after the .config is ready (no compile), useful to test the script.
# INSTALL=ask (default) asks "install now?" once the packages are built, when a
# terminal is attached, and just prints the commands otherwise; INSTALL=yes
# installs without asking (headers first, then the image); INSTALL=no never asks.
INSTALL="${INSTALL:-ask}"
# PRUNE=1 (default): once the build succeeds, keep only the newest linux-image and
# linux-headers .deb in BUILD_DIR and delete the rest of what bindeb-pkg leaves
# behind (-dbg image, linux-libc-dev, older revisions, their .buildinfo/.changes,
# and any decompressed linux-*.tar from older versions of this script). The -dbg
# package alone is ~1 GB per build. PRUNE=0 keeps everything.
PRUNE="${PRUNE:-1}"
# PURGE_OLD=ask (default): after a successful install, offer to purge the older
# -$KERNEL_NAME kernels still installed (linux-image-7.2.6-stargate, ...). The kernel
# running now and the one just installed are always kept, and so are the stock
# Debian ones. yes purges without asking, no leaves them. Skipped unless every
# DKMS module of the new kernel came out "installed".
PURGE_OLD="${PURGE_OLD:-ask}"
# CONFIG_HISTORY: where every successful build's .config is saved (config-<ver>-<name>).
# The next build's .config is diffed against it, and the options new in a release
# are listed in newconfig-<ver>.txt. Kept outside BUILD_DIR so cleaning the build
# tree does not lose the history.
CONFIG_HISTORY="${CONFIG_HISTORY:-${XDG_STATE_HOME:-$HOME/.local/state}/stargate-kernel/configs}"
# KEEP_FAMILIES: prefixes of Kconfig symbols whose drivers are restored, all of
# them, from the stock Debian config after localmodconfig (see below). REF_CONFIG
# is the reference: by default the newest /boot/config-*+deb*-amd64, so one Debian
# kernel has to stay installed. KEEP_FAMILIES="" turns the feature off.
KEEP_FAMILIES="${KEEP_FAMILIES-UHID HID_ I2C_HID USB_HID BT_ INPUT_ JOYSTICK_ TABLET_ MOUSE_ KEYBOARD_ SND_USB TYPEC USB4 THUNDERBOLT USB_ACM USB_WDM USB_SERIAL}"
REF_CONFIG="${REF_CONFIG:-$(ls -1v /boot/config-*+deb*-amd64 2>/dev/null | tail -n 1 || true)}"

banner() {
  printf '\033[1;36m'
  # generated with: figlet -f slant STARGATE  (embedded so figlet is not a build dependency)
  cat <<'EOF'
   ______________    ____  _________  ____________
  / ___/_  __/   |  / __ \/ ____/   |/_  __/ ____/
  \__ \ / / / /| | / /_/ / / __/ /| | / / / __/
 ___/ // / / ___ |/ _, _/ /_/ / ___ |/ / / /___
/____//_/ /_/  |_/_/ |_|\____/_/  |_/_/ /_____/
EOF
  printf '\033[0m'
  printf '            %s\n' "$*"
}

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Fail on a typo now, not after the build.
case "$INSTALL" in ask|yes|no) ;; *) die "INSTALL must be ask, yes or no (got '$INSTALL')";; esac
case "$PURGE_OLD" in ask|yes|no) ;; *) die "PURGE_OLD must be ask, yes or no (got '$PURGE_OLD')";; esac
trap 'echo "ERROR: unexpected exit at line $LINENO (command: $BASH_COMMAND)" >&2' ERR

# --------------------------------------------------------------------------- #
# 1. Find the latest stable release on kernel.org
# --------------------------------------------------------------------------- #
banner "optimized kernel build for $(hostname) -- -march=$MARCH, LOCALVERSION -$KERNEL_NAME"
cat <<EOF

  What is different from the stock Debian kernel:
    - CPU target     -march=$MARCH (Debian: generic x86-64)
    - config         localmodconfig: only the modules this machine loads,
                     plus KEEP_MODULES for hot-plug/VPN/network shares and
                     KEEP_FAMILIES: every HID/input/Bluetooth/USB-serial driver
                     of the stock Debian config, so a peripheral you have not
                     plugged in yet still works
    - scheduler tick HZ=1000 (Debian: 250)
    - I/O scheduler  BFQ available as a module
    - TCP            BBR as default congestion control (Debian: CUBIC)
    - debug          UBSAN off
    - boot           fbcon logo (CONFIG_LOGO): $( [[ -n "$LOGO_FILE" ]] && echo "$(basename "$LOGO_FILE") ${LOGO_SIZE}px" || echo "stock Tux" )
    - BORE           $( [[ "$ENABLE_BORE" == "1" ]] && echo "ON (ENABLE_BORE=1, best-effort patch)" || echo "off (opt-in with ENABLE_BORE=1)" )
    - output         Debian .deb packages via bindeb-pkg, name suffix -$KERNEL_NAME

EOF
case "$CHANNEL" in stable|mainline) ;; *) die "CHANNEL must be 'stable' or 'mainline' (got '$CHANNEL')";; esac
log "Querying kernel.org for the latest $CHANNEL release..."
# version, source tarball URL and (optional) signature URL, straight from kernel.org
read -r KVER SRC_URL SIGN_URL < <(curl -fsSL https://www.kernel.org/releases.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d['releases']:
    if r['moniker'] == '$CHANNEL':
        print(r['version'], r['source'], r.get('pgp') or '-'); break
")
[[ -n "${KVER:-}" ]] || die "could not determine the latest $CHANNEL version"
MAJOR="${KVER%%.*}"
# An -rcN tarball unpacks and reports itself as X.Y.0-rcN (e.g. 7.3-rc4 -> 7.3.0-rc4).
KREL="$KVER"
[[ "$KVER" == *-rc* ]] && KREL="${KVER%%-rc*}.0-rc${KVER##*-rc}"
log "Latest $CHANNEL: $KVER (${MAJOR}.x series, kernel release string $KREL)"

# Nothing to do if this exact release is already built and installed as our
# kernel (running or just installed). FORCE=1 rebuilds anyway (config changes,
# new KEEP_MODULES, different LOGO_FILE...).
TARGET_RELEASE="${KREL}-${KERNEL_NAME}"
if [[ "${FORCE:-0}" != "1" ]]; then
  if [[ "$(uname -r)" == "$TARGET_RELEASE" ]]; then
    log "Already running $TARGET_RELEASE, which is the latest $CHANNEL. Nothing to do (FORCE=1 to rebuild anyway)."
    exit 0
  fi
  if dpkg -s "linux-image-${TARGET_RELEASE}" >/dev/null 2>&1; then
    log "linux-image-${TARGET_RELEASE} is already installed (not the running kernel: reboot to use it). Nothing to do (FORCE=1 to rebuild anyway)."
    exit 0
  fi
fi

# --------------------------------------------------------------------------- #
# 2. Build dependencies
# --------------------------------------------------------------------------- #
NEEDED_PKGS=(build-essential libncurses-dev bison flex libssl-dev libelf-dev
             dwarves rsync bc kmod cpio fakeroot gnupg2 ccache
             debhelper libdw-dev imagemagick)
MISSING=()
for p in "${NEEDED_PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if ((${#MISSING[@]})); then
  log "Installing missing packages: ${MISSING[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${MISSING[@]}"
else
  log "All build dependencies are already present."
fi

export PATH="/usr/lib/ccache:$PATH"

# --------------------------------------------------------------------------- #
# 3. Download + signature check
# --------------------------------------------------------------------------- #
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
TARBALL="$(basename "$SRC_URL")"     # linux-7.2.7.tar.xz (stable) or linux-7.3-rc4.tar.gz (mainline)

if [[ -f "$TARBALL" ]]; then
  log "Tarball already present, skipping download: $TARBALL"
else
  log "Downloading $SRC_URL"
  curl -fL --progress-bar -o "$TARBALL" "$SRC_URL"
  if [[ "$SIGN_URL" != "-" ]]; then
    curl -fsSL -o "linux-${KVER}.tar.sign" "$SIGN_URL" || warn ".sign file not found, skipping PGP verification"
  else
    warn "kernel.org publishes no PGP signature for $CHANNEL tarballs, skipping verification (HTTPS from git.kernel.org only)"
  fi
fi

if [[ -f "linux-${KVER}.tar.sign" && "$TARBALL" == *.xz ]]; then
  log "Verifying the PGP signature (Linux kernel developers' keys)..."
  # Stable point releases are signed by Greg Kroah-Hartman (647F...693E), not
  # by Linus (ABAF...1886, who signs mainline). Both are fetched, Greg's is the
  # one that must be present for a "stable" tarball to verify.
  gpg --list-keys 647F28654894E3BD457199BE38DBBDC86092693E >/dev/null 2>&1 || \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys \
      647F28654894E3BD457199BE38DBBDC86092693E \
      ABAF11C65A2970B130ABE3C479BE3E4300411886 2>/dev/null || \
    warn "could not fetch the PGP keys, proceeding without signature verification"
  # The signature covers the uncompressed .tar: stream it from unxz instead of
  # writing a 1.6 GB linux-X.Y.Z.tar to disk just to check it.
  gpg_out="$(unxz -c "$TARBALL" | gpg --verify "linux-${KVER}.tar.sign" - 2>&1 || true)"
  printf '%s\n' "$gpg_out" > /tmp/gpg-verify.log
  if grep -q "Good signature" <<< "$gpg_out"; then
    log "Signature verified."
  else
    warn "signature NOT verified (see /tmp/gpg-verify.log) — proceeding anyway, the tarball comes from cdn.kernel.org over HTTPS"
  fi
fi

# --------------------------------------------------------------------------- #
# 4. Extraction
# --------------------------------------------------------------------------- #
SRC_DIR="$BUILD_DIR/linux-${KVER}"
if [[ -d "$SRC_DIR" ]]; then
  log "Source already extracted in $SRC_DIR"
else
  log "Extracting source..."
  tar xf "$TARBALL"
fi
cd "$SRC_DIR"

# --------------------------------------------------------------------------- #
# 5. (Optional) BORE scheduler patch — opt-in, best-effort
# --------------------------------------------------------------------------- #
if [[ "$ENABLE_BORE" == "1" ]]; then
  log "ENABLE_BORE=1: fetching and trying the BORE scheduler patch..."
  BORE_PATCH="/tmp/bore-${KVER}.patch"
  if curl -fsSL -o "$BORE_PATCH" "$BORE_PATCH_URL"; then
    if patch -p1 --dry-run < "$BORE_PATCH" >/dev/null 2>&1; then
      patch -p1 < "$BORE_PATCH"
      log "BORE scheduler patch applied."
    else
      warn "BORE patch does not apply cleanly to $KVER, skipping it (kernel-only tuning still applies)"
    fi
  else
    warn "could not download the BORE patch, skipping it"
  fi
  rm -f "$BORE_PATCH"
fi

# --------------------------------------------------------------------------- #
# 6. Configuration: start from the running kernel, then trim to only the
#    modules this machine actually loads.
# --------------------------------------------------------------------------- #
log "Configuring from /boot/config-$(uname -r)..."
cp "/boot/config-$(uname -r)" .config
# What this release adds on top of the running kernel's config. The olddefconfig
# below takes the default of every one of these without saying a word: list them.
mkdir -p "$CONFIG_HISTORY"
NEWCONFIG_FILE="$CONFIG_HISTORY/newconfig-${KREL}.txt"
make -s listnewconfig 2>/dev/null | grep -E '^(# )?CONFIG_' > "$NEWCONFIG_FILE" || true
log "Options new in $KREL vs /boot/config-$(uname -r): $(wc -l < "$NEWCONFIG_FILE"), $(grep -cE '^CONFIG_.*=[ym]$' "$NEWCONFIG_FILE" || true) of them on by default (list: $NEWCONFIG_FILE)"
make olddefconfig
log "Trimming to modules actually loaded on this machine (localmodconfig)..."
# NB: with `set -o pipefail` on, `yes` dying of SIGPIPE once make stops
# reading would fail the whole pipeline even though make itself succeeded --
# the `|| true` neutralizes only that; make's own failure is still caught
# right below by checking that .config exists.
yes '' | make localmodconfig || true
[[ -s .config ]] || die "localmodconfig did not produce a valid .config"

# localmodconfig only keeps what is loaded RIGHT NOW, so anything not plugged
# in / not in use at build time silently disappears from the kernel: USB
# sticks (usb_storage/uas + vfat/exfat/ntfs3), WireGuard (ProtonVPN), NFS and
# CIFS shares from the home network, ISO/UDF images, Docker's br_netfilter,
# libvirt's vhost_net. Force those back in as modules — they cost nothing
# until loaded. Verified against the 7.2.7 build: every one of these had been
# dropped. Extend KEEP_MODULES (space-separated) to add more.
KEEP_MODULES="${KEEP_MODULES:-
  TUN WIREGUARD BRIDGE_NETFILTER VHOST_NET MACVLAN MACVTAP VLAN_8021Q
  NET_SCH_FQ NET_SCH_CAKE
  USB_STORAGE USB_UAS USB_SERIAL USB_NET_CDC_NCM USB_NET_AX88179_178A USB_IPHETH USB4_NET
  MMC_BLOCK MMC_SDHCI_PCI
  VFAT_FS EXFAT_FS NTFS3_FS HFSPLUS_FS ISO9660_FS UDF_FS SQUASHFS NLS_CODEPAGE_850
  NFS_FS NFS_V4 CIFS BTRFS_FS XFS_FS F2FS_FS
  BLK_DEV_LOOP BLK_DEV_NBD DM_SNAPSHOT DM_THIN_PROVISIONING
  BT_HIDP UHID INPUT_UINPUT HID_LOGITECH HID_LOGITECH_DJ JOYSTICK_XPAD HID_PLAYSTATION SND_ALOOP
  IIO}"
# Why each group (all verified as dropped by localmodconfig on the 7.2.7 build):
#   net      VPN/containers/VMs (tun, wireguard, br_netfilter, vhost, macvlan/tap),
#            VLANs, fq (BBR pacing) and cake qdiscs
#   usb      sticks/disks, serial adapters, USB-C dock and phone NICs (ncm, asix,
#            iphone), thunderbolt networking
#   mmc      the GL9767 SD reader: sdhci is loaded but mmc_block only when a card
#            is inserted -> without it a card is detected and never appears
#   fs       removable-media and network filesystems, mac disks, squashfs (ISOs,
#            appimages), cp850 for old FAT labels
#   block    loop (`mount -o loop`, losetup: ISOs and disk images; without it
#            mount fails with "failed to setup loop device"), nbd (mount
#            qcow2), LVM snapshots/thin pools
#   input    classic BT HID, uhid (BLE keyboards and mice: BlueZ HID-over-GATT
#            creates their input device through /dev/uhid; without it a
#            Logitech K380s shows as connected and types nothing, bluetoothd
#            logs "input-hog profile accept failed"), uinput
#            (ydotool/sunshine), Logitech receivers, gamepads, ALSA loopback (OBS)
#   iio      the tuxedo-drivers DKMS package builds an IIO accelerometer driver
#            (stk8321); without CONFIG_IIO its modpost fails and DKMS installs
#            NONE of the tuxedo modules (fan control, keyboard backlight...)
log "Re-enabling modules localmodconfig drops for hardware/services not active right now..."
# shellcheck disable=SC2086
./scripts/config $(printf -- '--module %s ' $KEEP_MODULES)

# Whole families of plug-in peripherals (input, HID, Bluetooth, USB serial...).
# localmodconfig drops every driver whose device is not plugged in during the
# build, and KEEP_MODULES can only name them one by one: UHID, IIO and loop were
# each found by breaking something. So restore, from the stock Debian config,
# every symbol of these families, with the value Debian gives it (module ->
# module, sub-option -> enabled). Symbols the config already has are left alone,
# so nothing built in gets turned into a module. Best effort: what lacks a
# dependency, or no longer exists in this kernel, is dropped by olddefconfig and
# reported after it.
FAMILY_SYMS=()
if [[ -n "$KEEP_FAMILIES" ]]; then
  if [[ -f "${REF_CONFIG:-}" ]]; then
    read -ra family_list <<< "$KEEP_FAMILIES"
    family_regex="^CONFIG_($(IFS='|'; echo "${family_list[*]}"))[A-Z0-9_]*=[ym]$"
    family_args=()
    while IFS='=' read -r name value; do
      name="${name#CONFIG_}"
      FAMILY_SYMS+=("$name")
      grep -qE "^CONFIG_${name}=[ym]$" .config && continue
      if [[ "$value" == "m" ]]; then family_args+=(--module "$name"); else family_args+=(--enable "$name"); fi
    done < <(grep -E "$family_regex" "$REF_CONFIG")
    log "Restoring peripheral families ($KEEP_FAMILIES) from $(basename "$REF_CONFIG"): ${#FAMILY_SYMS[@]} options, $(( ${#family_args[@]} / 2 )) of them missing right now..."
    if ((${#family_args[@]})); then ./scripts/config "${family_args[@]}"; fi
  else
    warn "no stock Debian config in /boot (REF_CONFIG), skipping KEEP_FAMILIES: keep one Debian kernel installed"
  fi
fi

log "Enabling the boot logo (CONFIG_LOGO, off by default on Debian)..."
./scripts/config --enable LOGO
LOGO_PPM=""
if [[ -n "$LOGO_FILE" ]]; then
  [[ -f "$LOGO_FILE" ]] || die "LOGO_FILE not found: $LOGO_FILE"
  LOGO_PPM="$BUILD_DIR/logo_${KERNEL_NAME}_clut224.ppm"
  log "Converting $LOGO_FILE -> ${LOGO_SIZE}x${LOGO_SIZE}, 224 colors, PPM (P3)..."
  magick "$LOGO_FILE" -background black -alpha remove -alpha off \
    -resize "${LOGO_SIZE}x${LOGO_SIZE}" -colors 224 -compress none "$LOGO_PPM"
  ./scripts/config --set-str LOGO_LINUX_CLUT224_FILE "$LOGO_PPM"
fi

log "Desktop tuning: HZ=1000 (Debian ships 250, server-leaning), BFQ I/O" \
    "scheduler (best interactive feel under load; localmodconfig drops it" \
    "since it's not the active scheduler right now), UBSAN off (kernel-" \
    "developer instrumentation, real runtime cost, not needed on a daily" \
    "driver), TCP BBR as the default congestion control (handles variable-" \
    "latency links better than CUBIC)."
./scripts/config --enable HZ_1000 --disable HZ_250 --disable HZ_300 --disable HZ_100
# NB: the symbol is IOSCHED_BFQ (no MQ_ prefix, unlike MQ_IOSCHED_DEADLINE/KYBER).
./scripts/config --module IOSCHED_BFQ
./scripts/config --disable UBSAN
# DEFAULT_TCP_CONG is a derived string: setting it directly is silently reverted
# by olddefconfig. The real knob is the DEFAULT_* choice in net/ipv4/Kconfig.
./scripts/config --enable TCP_CONG_BBR --enable DEFAULT_BBR --disable DEFAULT_CUBIC
make olddefconfig

# scripts/config happily writes symbols that don't exist and olddefconfig then
# silently discards them (that's how BFQ went missing once). Fail loudly instead.
log "Verifying the tuning actually landed in .config..."
for sym in LOGO HZ_1000 IOSCHED_BFQ TCP_CONG_BBR $KEEP_MODULES; do
  grep -qE "^CONFIG_${sym}=[ym]$" .config || die "CONFIG_${sym} is not enabled after olddefconfig (wrong symbol name or unmet dependency)"
done
grep -qE '^CONFIG_DEFAULT_TCP_CONG="bbr"$' .config || die "DEFAULT_TCP_CONG is not bbr"
if ((${#FAMILY_SYMS[@]})); then
  landed=0
  for sym in "${FAMILY_SYMS[@]}"; do grep -qE "^CONFIG_${sym}=[ym]$" .config && landed=$((landed + 1)); done
  log "Peripheral families: ${landed}/${#FAMILY_SYMS[@]} options are in .config (the rest lack a dependency or no longer exist in this kernel)."
fi
grep -qE '^CONFIG_UBSAN=y' .config && die "UBSAN is still enabled"
if [[ -n "$LOGO_PPM" ]]; then
  grep -qF "CONFIG_LOGO_LINUX_CLUT224_FILE=\"$LOGO_PPM\"" .config || die "custom logo path did not land in .config"
fi

# What differs from the last kernel this script built: an earlier run of the same
# release (so a change to the script shows up), else the newest other release.
config_symbols() {   # one "NAME value" line per symbol, "n" for "is not set"
  sed -nE 's/^CONFIG_([A-Za-z0-9_]+)=(.*)$/\1 \2/p; s/^# CONFIG_([A-Za-z0-9_]+) is not set$/\1 n/p' "$1" | LC_ALL=C sort
}
config_diff() {      # "+ added", "- removed", "~ changed", by symbol name; a symbol that is only "n" on one side is noise
  awk 'NR == FNR { old[$1] = substr($0, length($1) + 2); next }
       { val = substr($0, length($1) + 2)
         if (!($1 in old)) { if (val != "n") print "+ " $1 "=" val }
         else { if (old[$1] != val) print "~ " $1 ": " old[$1] " -> " val; delete old[$1] } }
       END { for (k in old) if (old[k] != "n") print "- " k "=" old[k] }' \
    <(config_symbols "$1") <(config_symbols "$2") | LC_ALL=C sort -k2
}
SNAPSHOT="$CONFIG_HISTORY/config-${KREL}-${KERNEL_NAME}"
prev_config="$SNAPSHOT"
[[ -f "$prev_config" ]] || prev_config="$(ls -1v "$CONFIG_HISTORY"/config-* 2>/dev/null | tail -n 1 || true)"
if [[ -f "$prev_config" ]]; then
  DIFF_FILE="$CONFIG_HISTORY/diff-${KREL}-${KERNEL_NAME}.txt"
  config_diff "$prev_config" .config > "$DIFF_FILE"
  log "Config vs the last build ($(basename "$prev_config")): $(grep -c '^+ ' "$DIFF_FILE" || true) added, $(grep -c '^- ' "$DIFF_FILE" || true) removed, $(grep -c '^~ ' "$DIFF_FILE" || true) changed (full list: $DIFF_FILE)"
  sed 's/^/    /' "$DIFF_FILE" | head -n 30
  diff_lines="$(wc -l < "$DIFF_FILE")"
  if (( diff_lines > 30 )); then printf '    ... %d more in %s\n' "$((diff_lines - 30))" "$DIFF_FILE"; fi
else
  log "No earlier build config in $CONFIG_HISTORY: this one becomes the baseline once the build succeeds."
fi

# CPU target: vanilla kernel.org has no per-microarch Kconfig choices
# (those are a Debian-only patch to their own kernel package — verified:
# arch/x86/Kconfig.cpu here only goes up to legacy options like MATOM).
# The only correct way on vanilla source is an explicit -march= via KCFLAGS.
log "Setting -march=$MARCH via KCFLAGS (vanilla source has no per-CPU Kconfig choices)."
EXTRA_MAKE_ARGS=(KCFLAGS="-march=$MARCH -O2" KCPPFLAGS="-march=$MARCH")

# --------------------------------------------------------------------------- #
# 7. Build
# --------------------------------------------------------------------------- #
log "Building with $JOBS parallel jobs (ccache on). Can take from a couple of minutes (warm cache) up to 60+ minutes (cold)."
LOCALVERSION="-${KERNEL_NAME}"
if [[ "${CONFIG_ONLY:-0}" == "1" ]]; then
  log "CONFIG_ONLY=1: .config is ready in $SRC_DIR, not compiling."
  exit 0
fi
time nice -n 10 make -j"$JOBS" LOCALVERSION="$LOCALVERSION" "${EXTRA_MAKE_ARGS[@]}" bindeb-pkg

banner "build complete: linux ${KREL}-${KERNEL_NAME}"
cp -f .config "$SNAPSHOT"
log "Saved this build's config as $SNAPSHOT (the next build is diffed against it)."
log "Produced .deb packages:"
ls -la "$BUILD_DIR"/*"${KREL}${LOCALVERSION}"*.deb 2>/dev/null || ls -la "$BUILD_DIR"/linux-*.deb

if [[ "$KEEP_SOURCE" == "0" ]]; then
  log "Removing the source tree (KEEP_SOURCE=0)..."
  rm -rf "$SRC_DIR"
fi

# --------------------------------------------------------------------------- #
# 8. Install (asks first)
# --------------------------------------------------------------------------- #
# Several builds leave several revisions in BUILD_DIR: take the newest of each
# (the glob for the image does not match the -dbg package, its name continues
# with "-dbg_", not "_").
newest_deb() { ls -1t "$BUILD_DIR"/$1 2>/dev/null | head -n 1; }
HEADERS_DEB="$(newest_deb "linux-headers-${KREL}${LOCALVERSION}_*_amd64.deb")"
IMAGE_DEB="$(newest_deb "linux-image-${KREL}${LOCALVERSION}_*_amd64.deb")"
[[ -f "$HEADERS_DEB" && -f "$IMAGE_DEB" ]] || die "could not find the freshly built headers/image .deb in $BUILD_DIR"

# Delete the build leftovers, never the two packages picked above nor the
# .buildinfo/.changes of their revision. Runs in a subshell so nullglob does not
# leak. Only names this script's build produces are matched.
prune_build_dir() {
  local revision keep_prefix f size total=0 count=0
  revision="${IMAGE_DEB##*/}"; revision="${revision#*_}"; revision="${revision%_amd64.deb}"   # e.g. 7.2.7-9
  keep_prefix="$BUILD_DIR/linux-upstream_${revision}_amd64"
  shopt -s nullglob
  for f in "$BUILD_DIR"/linux-image-*-"${KERNEL_NAME}"_*.deb \
           "$BUILD_DIR"/linux-image-*-"${KERNEL_NAME}"-dbg_*.deb \
           "$BUILD_DIR"/linux-headers-*-"${KERNEL_NAME}"_*.deb \
           "$BUILD_DIR"/linux-libc-dev_*.deb \
           "$BUILD_DIR"/linux-upstream_*.buildinfo \
           "$BUILD_DIR"/linux-upstream_*.changes \
           "$BUILD_DIR"/linux-*.tar; do
    [[ "$f" == "$IMAGE_DEB" || "$f" == "$HEADERS_DEB" ]] && continue
    [[ "$f" == "$keep_prefix".buildinfo || "$f" == "$keep_prefix".changes ]] && continue
    # a plain .tar is only a leftover when the .tar.xz it came from is still there
    [[ "$f" == *.tar && ! -f "$f.xz" ]] && continue
    size="$(stat -c %s "$f")"
    rm -f -- "$f" || continue
    total=$((total + size))
    count=$((count + 1))
  done
  log "PRUNE: removed $count file(s), $(numfmt --to=iec "$total") freed. Kept $(basename "$IMAGE_DEB") and $(basename "$HEADERS_DEB")."
}
if [[ "$PRUNE" == "1" ]]; then
  ( prune_build_dir )
else
  log "PRUNE=$PRUNE: leaving the build directory as it is."
fi

print_install_help() {
  cat <<EOF

To install (adds a new GRUB entry, does NOT touch the currently running kernel).
Headers FIRST, image SECOND, as two separate commands: the image's postinst
triggers DKMS (tuxedo-drivers, tuxedo-yt6801 = the 2.5GbE NIC driver), which
needs the matching headers already configured or it silently builds nothing.
  sudo dpkg -i $HEADERS_DEB
  sudo dpkg -i $IMAGE_DEB
  sudo dkms status | grep '${KREL}${LOCALVERSION}'   # expect tuxedo-drivers + tuxedo-yt6801 "installed"

To roll back, just reboot and pick the old kernel from the GRUB menu,
or 'sudo apt remove linux-image-${KREL}${LOCALVERSION}'.
EOF
}

# Revisions of one release replace each other in place (same package name), so
# what piles up is other RELEASES: linux-image-7.2.6-stargate next to 7.2.7. Never
# touched: the release just installed, the one running now (the fallback, and dpkg
# would remove it from under you) and every kernel not named -$KERNEL_NAME, the
# stock Debian ones included (REF_CONFIG reads one of their configs).
purge_old_kernels() {
  local status pkg release old=()
  while read -r status pkg; do
    [[ "$status" == ii || "$status" == rc ]] || continue
    release="${pkg#linux-image-}"; release="${release#linux-headers-}"
    [[ "$release" == "${KREL}${LOCALVERSION}" || "$release" == "$(uname -r)" ]] && continue
    old+=("$pkg")
  done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "linux-image-*${LOCALVERSION}" "linux-headers-*${LOCALVERSION}" 2>/dev/null)

  if ((${#old[@]} == 0)); then
    log "PURGE_OLD: no older ${KERNEL_NAME} kernel installed."
    return 0
  fi
  log "PURGE_OLD: older ${KERNEL_NAME} kernels installed (kept: ${KREL}${LOCALVERSION} new, $(uname -r) running): ${old[*]}"

  local do_purge=0 reply
  case "$PURGE_OLD" in
    yes) do_purge=1 ;;
    ask)
      if [[ -t 0 && -t 1 ]]; then
        read -r -p "Purge them now? Their GRUB entries and DKMS modules go with them. [y/N] " reply || reply=""
        [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] && do_purge=1
      fi
      ;;
  esac
  if (( do_purge )); then
    sudo dpkg --purge "${old[@]}" || warn "purging ${old[*]} failed, see the output above"
  else
    log "Not purged. To do it later: sudo dpkg --purge ${old[*]}"
  fi
}

want_install=0
case "$INSTALL" in
  yes) want_install=1 ;;
  ask)
    if [[ -t 0 && -t 1 ]]; then
      printf '\n'
      read -r -p "Install ${KREL}${LOCALVERSION} now? It adds a GRUB entry, the running kernel is untouched. [y/N] " reply || reply=""
      [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] && want_install=1
    fi
    ;;
esac

if (( want_install )); then
  log "Installing the headers first (DKMS needs them), then the image..."
  sudo dpkg -i "$HEADERS_DEB" || die "installing $HEADERS_DEB failed, nothing else was installed"
  sudo dpkg -i "$IMAGE_DEB" || die "installing $IMAGE_DEB failed (a DKMS module that does not build is the usual cause: see the output above). Remove it with: sudo dpkg --purge linux-image-${KREL}${LOCALVERSION} linux-headers-${KREL}${LOCALVERSION}"

  log "DKMS status for ${KREL}${LOCALVERSION}:"
  dkms_state="$(sudo dkms status 2>/dev/null | grep -F "${KREL}${LOCALVERSION}" || true)"
  printf '%s\n' "${dkms_state:-  (no DKMS module registered for this kernel)}"
  dkms_ok=0
  if [[ -n "$dkms_state" && "$dkms_state" == *installed* && "$dkms_state" != *built* ]]; then
    log "All DKMS modules are installed."
    dkms_ok=1
  else
    warn "check the DKMS lines above: every module for ${KREL}${LOCALVERSION} should say \"installed\" (tuxedo-drivers, tuxedo-yt6801)"
  fi
  if (( dkms_ok )); then
    purge_old_kernels
  else
    warn "PURGE_OLD skipped: older ${KERNEL_NAME} kernels stay as a fallback until the DKMS modules are sorted out"
  fi
  log "Installed. Reboot and pick ${KREL}${LOCALVERSION} in GRUB. Roll back by choosing the old kernel there, then: sudo apt remove linux-image-${KREL}${LOCALVERSION}"
else
  print_install_help
fi
