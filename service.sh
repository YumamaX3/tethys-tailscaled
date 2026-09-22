#!/system/bin/sh
# Tethys · service
#
# Runs from Magisk's / KernelSU's late_start service mode, as root, once /data is
# mounted. It starts the daemon under a supervisor and returns immediately: a
# boot script that blocks is a boot script that gets killed.
#
# Design notes that come from the source, not from taste:
#
#   * The patched daemon defaults its state, socket, log and resolv.conf paths to
#     /data/adb/tailscale when that directory exists (SEEN: patches/0002). This
#     script therefore passes NO path flags - passing them would only create a
#     second place to be wrong.
#   * The daemon is a multi-call binary; it creates its own 'tailscale' symlink
#     on start (SEEN: patches/0003).
#   * Supervision uses `wait`, not polling. The supervisor sleeps only when the
#     daemon has actually died, so it costs no wakeups while the daemon lives.
#     That matters for the plan's "must not battery drain" lever 7: a supervisor
#     that polled would itself be the drain.

MODDIR=${0%/*}
. "$MODDIR/scripts/tethys.lib.sh" 2>/dev/null || exit 1

# Config is READ AS DATA, never sourced (plan §8.3). The persistent copy wins;
# the packaged copy is only the template.
tethys_cfg_load "$TETHYS_DATA_DIR/config.env"
tethys_cfg_load "$MODDIR/config.env"

TETHYS_BIN="$MODDIR/system/bin/tailscaled"
TETHYS_STOPFILE="$TETHYS_DATA_DIR/stop"
TETHYS_PIDFILE="$TETHYS_DATA_DIR/tailscaled.pid"

tethys_supervise() {
  # Backoff ladder from the plan (§8.2 / R10): 5, 15, 30, 60, 120, 300 s, then
  # hold at 300. Off by default is the *watchdog's* rule (TS_WATCHDOG_ENABLED);
  # this supervisor is the daemon's own parent and must not exit, or the daemon
  # would be orphaned with no restart path at all.
  _i=0
  _ladder="5 15 30 60 120 300"
  while :; do
    if [ -f "$TETHYS_STOPFILE" ]; then
      tethys_log INFO "stop flag present at $TETHYS_STOPFILE - supervisor standing down"
      return 0
    fi

    set --
    for _a in $(tethys_build_args); do set -- "$@" "$_a"; done

    tethys_log INFO "starting $TETHYS_BIN $*"
    "$TETHYS_BIN" "$@" >> "$TETHYS_DATA_DIR/log/tailscaled.log" 2>&1 &
    _pid=$!
    echo "$_pid" > "$TETHYS_PIDFILE"
    tethys_log INFO "tailscaled pid $_pid"

    wait "$_pid"
    _rc=$?
    rm -f "$TETHYS_PIDFILE"
    tethys_log INFO "tailscaled exited rc=$_rc"

    # A clean stop by the user is never fought. The stop flag is the way to say
    # "stay down" - the manual-stop marker the plan requires (§8.2, R9), so that
    # recovery never resurrects a deliberately stopped daemon.
    if [ -f "$TETHYS_STOPFILE" ]; then
      tethys_log INFO "stop flag present after exit - not restarting"
      return 0
    fi

    _i=$((_i + 1))
    _delay=300
    _n=1
    for _d in $_ladder; do
      if [ "$_n" -eq "$_i" ]; then _delay="$_d"; break; fi
      _n=$((_n + 1))
    done
    tethys_log WARN "restarting in ${_delay}s (attempt $_i)"
    sleep "$_delay"
  done
}

case "${TS_START_ON_BOOT:-1}" in
  1) : ;;
  *) tethys_log INFO "autostart disabled by TS_START_ON_BOOT - not starting"; exit 0 ;;
esac

[ -x "$TETHYS_BIN" ] || { tethys_log ERROR "daemon missing or not executable: $TETHYS_BIN"; exit 1; }

tethys_ensure_dirs || { tethys_log ERROR "cannot prepare $TETHYS_DATA_DIR"; exit 1; }
tethys_trim_log

if [ -f "$TETHYS_PIDFILE" ] && kill -0 "$(cat "$TETHYS_PIDFILE" 2>/dev/null)" 2>/dev/null; then
  tethys_log INFO "tailscaled already running (pid $(cat "$TETHYS_PIDFILE")) - not starting a second"
  exit 0
fi

tethys_log INFO "supervisor starting for device $(tethys_device_codename), tun=$(tethys_tun_flag)"
tethys_supervise &
exit 0
