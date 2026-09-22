#!/system/bin/sh
# Tethys · uninstaller
#
# Magisk / KernelSU call this when the module is removed, while the module
# directory still exists.
#
# The rule here is deliberate: stopping the daemon is this script's business, but
# deleting the tailnet identity is NOT. /data/adb/tailscale holds the node's
# private key; the device is still logged in to the tailnet because of that file,
# and a removal that silently threw it away would cost the user a re-auth they
# never asked for. So this script reports the path and leaves it alone - unless
# the user has explicitly asked, by creating the purge flag.

MODDIR=${0%/*}
. "$MODDIR/scripts/tethys.lib.sh" 2>/dev/null || exit 0

TETHYS_PIDFILE="$TETHYS_DATA_DIR/tailscaled.pid"
TETHYS_PURGEFLAG="$TETHYS_DATA_DIR/.purge-on-uninstall"

# ------------------------------------------------------------------- stop first
# Raise the stop flag before signalling, so the supervisor does not interpret the
# death as a crash and restart the daemon while we are removing it.
if [ -d "$TETHYS_DATA_DIR" ]; then
  : > "$TETHYS_STOPFILE" 2>/dev/null || true
fi

if [ -f "$TETHYS_PIDFILE" ]; then
  _pid="$(cat "$TETHYS_PIDFILE" 2>/dev/null)"
  case "$_pid" in
    ''|*[!0-9]*) : ;;
    *) kill "$_pid" 2>/dev/null || true; sleep 1; kill -9 "$_pid" 2>/dev/null || true ;;
  esac
  rm -f "$TETHYS_PIDFILE"
fi

# Belt and braces: any tailscaled started from this module's own directory. The
# pattern is anchored on the module path so an unrelated tailscaled build is not
# touched by someone else's uninstall.
pkill -f "$MODDIR/system/bin/tailscaled" 2>/dev/null || true

# ------------------------------------------------------------------- state root
if [ -f "$TETHYS_PURGEFLAG" ]; then
  rm -f "$TETHYS_STOPFILE"
  rm -rf "$TETHYS_DATA_DIR"
  tethys_ui "  Tethys: purge flag found - removed $TETHYS_DATA_DIR"
else
  rm -f "$TETHYS_STOPFILE"
  tethys_ui "  Tethys: daemon stopped. State kept at $TETHYS_DATA_DIR"
  tethys_ui "  Tethys: node identity and logs are still there."
  tethys_ui "  Tethys: to remove everything, delete that directory yourself -"
  tethys_ui "          rm -rf $TETHYS_DATA_DIR"
  tethys_ui "  Tethys: or create $TETHYS_PURGEFLAG before uninstalling."
fi

exit 0
