#!/system/bin/sh
# Tethys · installer
#
# Magisk / KernelSU run this from the module zip before the module is committed.
# Environment provided by the installer: $MODPATH (staging dir), $ARCH, $API,
# $IS64BIT, plus ui_print / abort / set_perm during install.
#
# The installer's job is to refuse bad installs loudly. A module that installs
# silently and then does nothing at boot is worse than one that says no.

SKIPUNZIP=0

. "$MODPATH/scripts/tethys.lib.sh" 2>/dev/null || {
  echo "!! Tethys: scripts/tethys.lib.sh is missing from the zip - the module is incomplete." >&2
  exit 1
}

tethys_ui " "
tethys_ui "  Tethys · tailscaled"
tethys_ui "  ----------------------------------------"

# ---------------------------------------------------------------- architecture
# The payload is built for arm64-v8a only. Installing it on another ABI would
# place a binary on the device that cannot execute - so this is a hard stop.
_arch="${ARCH:-$(tethys_abi)}"
case "$_arch" in
  arm64|arm64-v8a|aarch64) : ;;
  *)
    tethys_die "this build is arm64-v8a only; this device reports '$_arch'."
  ;;
esac

_device_abi="$(tethys_abi)"
case "$_device_abi" in
  arm64*|aarch64*) : ;;
  *)
    tethys_die "device ABI is '$_device_abi'; this module ships an arm64-v8a payload only."
  ;;
esac

# --------------------------------------------------------------------- payload
# system/bin/{tailscaled,tailscale} are injected by CI from the pinned patch
# series (plan §8.1). Magisk overlays system/bin onto /system/bin, so both land
# on PATH for every shell on the device.
if [ ! -s "$MODPATH/system/bin/tailscaled" ]; then
  tethys_die "system/bin/tailscaled is missing or empty - this zip carries no daemon. Build it with node tools/split-android-patch.mjs + the android.sh arm64 target."
fi

# The daemon is a multi-call binary: it creates a 'tailscale' symlink beside
# itself on start (SEEN: patches/0003, createTailscaleSymlink). We create it here
# too so the CLI answers BEFORE the daemon has ever been started - the daemon's
# own creation is idempotent, so there is no race, only an earlier availability.
if [ ! -e "$MODPATH/system/bin/tailscale" ]; then
  ln -sf tailscaled "$MODPATH/system/bin/tailscale" || \
    tethys_log WARN "could not pre-create the tailscale symlink - the daemon will create it on start"
fi

# ------------------------------------------------------------------ state root
# /data/adb/tailscale is the directory the patched daemon looks for and adopts
# (SEEN: patches/0002). It must exist before first start, or state lands in
# $TMPDIR and is lost on reboot.
if ! tethys_ensure_dirs; then
  tethys_die "could not create $TETHYS_DATA_DIR - is /data writable?"
fi

# ---------------------------------------------------------- persistent config
# Seeded once. Never overwritten: this file is the user's, and an upgrade that
# took their tuning away would be a bug dressed as an install.
if [ -f "$TETHYS_DATA_DIR/config.env" ]; then
  tethys_ui "  config    : kept existing $TETHYS_DATA_DIR/config.env"
else
  cp -f "$MODPATH/config.env" "$TETHYS_DATA_DIR/config.env" || \
    tethys_die "could not seed $TETHYS_DATA_DIR/config.env"
  chmod 0600 "$TETHYS_DATA_DIR/config.env"
  tethys_ui "  config    : seeded $TETHYS_DATA_DIR/config.env"
fi

# ------------------------------------------------------------------ permissions
# set_perm is an installer-provided helper; outside the installer it is absent,
# so fall back to plain chmod rather than assuming either exists.
_set_perm() {
  if command -v set_perm >/dev/null 2>&1; then set_perm "$1" 0 0 "$2"; else chmod "$2" "$1"; fi
}

for _f in "$MODPATH/system/bin/tailscaled" "$MODPATH/service.sh" "$MODPATH/uninstall.sh" "$MODPATH/customize.sh"; do
  [ -f "$_f" ] && _set_perm "$_f" 0755
done
_set_perm "$MODPATH/scripts/tethys.lib.sh" 0755
chmod 0700 "$TETHYS_DATA_DIR" 2>/dev/null

# ---------------------------------------------------------------------- summary
tethys_ui "  device    : $(tethys_device_codename) (ABI $_device_abi)"
tethys_ui "  state root: $TETHYS_DATA_DIR"
tethys_ui "  autostart : $( [ "$(grep -m1 '^TS_START_ON_BOOT=' "$TETHYS_DATA_DIR/config.env" 2>/dev/null | cut -d= -f2- | tr -d '\"')" = "0" ] && echo 'off' || echo 'on' )"
tethys_ui "  ----------------------------------------"
tethys_ui "  next      : reboot, then"
tethys_ui "              tailscale status"
tethys_ui "              log: $TETHYS_DATA_DIR/log/service.log"
tethys_ui " "
