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
# The packaged template must itself pass the schema. A zip whose own defaults
# fail validation would seed a broken truth onto every device that installs it,
# and the failure would surface at boot - the worst possible moment.
if ! tethys_cfg_validate "$MODPATH/config.env"; then
  tethys_die "the packaged config.env does not satisfy the schema - refusing to install a broken default"
fi

if [ -f "$TETHYS_DATA_DIR/config.env" ]; then
  # An EXISTING config belongs to the user and is never overwritten - an upgrade
  # that took their tuning away would be a bug dressed as an install. But it IS
  # completed: the canonical v2.3.1 file carried seven keys and this schema has
  # eighteen, so the missing ones are filled ONCE (plan §8.3, R35). Present
  # values are never rewritten - including present-but-empty ones, since empty
  # means "pass nothing", which is a decision rather than an absence.
  if ! tethys_cfg_validate "$TETHYS_DATA_DIR/config.env" >/dev/null 2>&1; then
    tethys_ui "  config    : WARNING - existing config.env has invalid lines."
    tethys_ui "              Those settings fall back to defaults; see"
    tethys_ui "              $TETHYS_DATA_DIR/log/service.log for the reasons."
  fi
  tethys_cfg_migrate "$TETHYS_DATA_DIR/config.env"
  tethys_ui "  config    : kept existing $TETHYS_DATA_DIR/config.env"
  if [ "$TETHYS_CFG_ADDED" -gt 0 ]; then
    tethys_ui "  config    : completed it - $TETHYS_CFG_ADDED key(s) added with defaults"
    tethys_ui "              note: $TETHYS_DATA_DIR/etc/config-migrated.note"
  fi
else
  cp -f "$MODPATH/config.env" "$TETHYS_DATA_DIR/config.env" || \
    tethys_die "could not seed $TETHYS_DATA_DIR/config.env"
  chmod 0600 "$TETHYS_DATA_DIR/config.env"
  tethys_ui "  config    : seeded $TETHYS_DATA_DIR/config.env"
fi

# ---------------------------------------------- the legacy truth, left alone
# Upstream kept its settings in tailscale/settings.sh - a SHELL SCRIPT that the
# service `source`d. That file is not read here, and its absence from our read
# path is the whole point of §8.3: a file that once ran your shell is exactly
# the file a migration must not trust. It is reported, never executed.
if [ -f "$TETHYS_DATA_DIR/settings.sh" ]; then
  tethys_ui "  legacy    : found $TETHYS_DATA_DIR/settings.sh"
  tethys_ui "              NOT read - it is a script, and this module parses its"
  tethys_ui "              config as data. Re-apply any settings in config.env."
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
# Both quote styles: the seed template writes double quotes and the migration
# writes single ones, so a reader that knew only one of them would report 'off'
# as 'on' - a summary line that lies about the very setting it exists to show.
_boot=$(grep -m1 '^TS_START_ON_BOOT=' "$TETHYS_DATA_DIR/config.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'")
tethys_ui "  autostart : $( [ "$_boot" = "0" ] && echo 'off' || echo 'on' )"
tethys_ui "  ----------------------------------------"
tethys_ui "  next      : reboot, then"
tethys_ui "              tailscale status"
tethys_ui "              log: $TETHYS_DATA_DIR/log/service.log"
tethys_ui " "
