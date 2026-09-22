#!/system/bin/sh
# Tethys · shared shell helpers  (scripts/tethys.lib.sh)
#
# Sourced by customize.sh (install time) and service.sh (runtime). POSIX sh only:
# this runs under Android's mksh and Magisk's busybox ash, not bash.
#
# Nothing here decides policy. It reads facts, parses config as DATA, writes
# logs, and fails loudly.

# The daemon's own hard-coded root (SEEN: patches/0002 - paths/paths.go,
# paths_unix.go, logpolicy.go and net/dns/resolvconfpath_android.go all key off
# the existence of this directory). If it exists, the daemon adopts it. So the
# module must create it, or state leaks into $TMPDIR and vanishes on reboot.
#
# DEFAULT, not assignment: `:=` fills the value only when nothing has set it
# already. An unconditional assignment would stamp on any caller's choice - which
# made this library untestable off-device, and would make the state root
# unrelocatable without editing the library itself. Both are defects.
: "${TETHYS_DATA_DIR:=/data/adb/tailscale}"

# ---------------------------------------------------------------------- output

tethys_ui() {
  # ui_print is provided by Magisk and KernelSU during install; at runtime it is
  # absent and this degrades to a plain line on stderr.
  if command -v ui_print >/dev/null 2>&1; then ui_print "$*"; else echo "$*" >&2; fi
}

tethys_log() {
  _lvl="$1"; shift
  _line="$(date +'%Y-%m-%dT%H:%M:%S') $_lvl $*"
  echo "$_line" >&2
  if [ -d "$TETHYS_DATA_DIR/log" ]; then
    echo "$_line" >> "$TETHYS_DATA_DIR/log/service.log"
  fi
}

tethys_die() {
  tethys_log ERROR "$*"
  tethys_ui "!! Tethys: $*"
  # `abort` is Magisk's installer-only exit path with a message; outside install
  # it is undefined, so fall back to a plain nonzero exit.
  if command -v abort >/dev/null 2>&1; then abort "Tethys: $*"; fi
  exit 1
}

tethys_prop() {
  # getprop is toybox; a missing property prints an empty line, which is the
  # honest answer for "this device does not have it".
  getprop "$1" 2>/dev/null | tr -d '\r\n'
}

# ------------------------------------------------------------------ state root

tethys_ensure_dirs() {
  # The exact subdirectories the patched daemon reaches for, each verified
  # against the series rather than guessed:
  #   log   <- patches/0002 logpolicy.go         ($prefix/log)
  #   etc   <- patches/0002 dnsDir               ($prefix/etc/resolv.conf and
  #                                               its .pre-tailscale-backup)
  #   certs <- patches/0012 tsweb.DefaultCertDir ($prefix/certs)
  # There is deliberately no `bin`: nothing in the series reads one, and the
  # daemon's own `tailscale` symlink is created beside the EXECUTABLE. A
  # directory no code reads is not a cushion, it is a lie about the tree.
  #
  # 0700: the state file is a node private key - this tree IS the device's
  # identity to the tailnet, and nothing else on the device has business in it.
  mkdir -p "$TETHYS_DATA_DIR" || return 1
  chmod 0700 "$TETHYS_DATA_DIR"
  for _d in log etc certs; do
    mkdir -p "$TETHYS_DATA_DIR/$_d" || return 1
    chmod 0700 "$TETHYS_DATA_DIR/$_d"
  done
  return 0
}

# -------------------------------------------------------------- config parsing
#
# Plan §8.3: allowlisted keys only, parsed as data, NEVER sourced. A config file
# that is `source`d is a program; this one is read line by line and its keys are
# checked against a fixed list before anything is assigned.

TETHYS_ALLOWED_KEYS="TS_START_ON_BOOT TS_TUN_MODE TS_DAEMON_ARGS TS_UP_ARGS \
TS_EXTRA_UP_ARGS TS_LOGIN_SERVER TS_HOSTNAME TS_PROFILE TS_ENABLE_SSH \
TS_ADVERTISE_ROUTES TS_KILL_SWITCH TS_SPLIT_TUNNEL_MODE TS_SPLIT_TUNNEL_UIDS \
TS_WATCHDOG_ENABLED TS_POWER_MODE TS_LOG_MAX_KB TS_THEME TS_JOURNAL_ENABLED"

tethys_key_allowed() {
  for _k in $TETHYS_ALLOWED_KEYS; do
    [ "$1" = "$_k" ] && return 0
  done
  return 1
}

tethys_has_meta() {
  # Shell metacharacters. We never eval and never interpolate a config value into
  # a shell string, so this is defence in depth - but the value is surfaced
  # through the panel's future `up` path, and a value that can never reach a
  # shell cannot be used to reach one.
  case "$1" in
    *[\`\$\;\|\&\<\>\(\)\{\}\!\*]* ) return 0 ;;
  esac
  return 1
}

tethys_cfg_load() {
  # $1 = config file. Returns 0 always: a bad file degrades to defaults with a
  # logged warning rather than refusing to boot the device.
  [ -r "$1" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in *=*) : ;; *) continue ;; esac
    _k=${_line%%=*}
    _v=${_line#*=}
    # Trim surrounding whitespace on the key, as hand-edited files are messy.
    _k=$(echo "$_k" | tr -d ' \t\r')
    if ! tethys_key_allowed "$_k"; then
      tethys_log WARN "config: ignoring unknown key '$_k'"
      continue
    fi
    # Strip one layer of matching quotes; keep the inner text verbatim.
    case "$_v" in
      '"'*'"') _v=${_v#\"}; _v=${_v%\"} ;;
      "'"*"'") _v=${_v#\'}; _v=${_v%\'} ;;
    esac
    _v=$(echo "$_v" | tr -d '\r')
    if [ "$_k" = "TS_EXTRA_UP_ARGS" ] && tethys_has_meta "$_v"; then
      tethys_log WARN "config: TS_EXTRA_UP_ARGS contains shell metacharacters - ignored"
      continue
    fi
    export "$_k=$_v"
  done < "$1"
  return 0
}

# ------------------------------------------------------------ derived values

tethys_tun_flag() {
  # Plan D3. The candidate list is the daemon's own syntax: it tries each name in
  # order and falls back to its in-process userspace stack.
  case "${TS_TUN_MODE:-native-first}" in
    native-first) echo "tailscale0,userspace-networking" ;;
    native-only)  echo "tailscale0" ;;
    netstack-only) echo "userspace-networking" ;;
    *)
      tethys_log WARN "TS_TUN_MODE='$TS_TUN_MODE' is not native-first|native-only|netstack-only - using native-first"
      echo "tailscale0,userspace-networking"
      ;;
  esac
}

tethys_build_args() {
  # Emits tailscaled arguments, one per line, each already validated non-empty.
  #
  # STATE AND SOCKET PATHS ARE DELIBERATELY NOT PASSED: the android patch already
  # defaults them to $TETHYS_DATA_DIR when that directory exists (SEEN:
  # patches/0002), so passing them would only add a way for two places to
  # disagree about one truth.
  echo "--tun=$(tethys_tun_flag)"
  if [ -n "${TS_DAEMON_ARGS:-}" ]; then
    for _f in ${TS_DAEMON_ARGS}; do echo "$_f"; done
  fi
  return 0
}

tethys_log_max_bytes() {
  # TS_LOG_MAX_KB, clamped to the schema's stated 128-10240 range. A value
  # outside the range is CLAMPED, not obeyed, and the clamp is logged.
  _kb="${TS_LOG_MAX_KB:-512}"
  case "$_kb" in
    ''|*[!0-9]*)
      tethys_log WARN "TS_LOG_MAX_KB='$_kb' is not a number - using 512"
      _kb=512 ;;
  esac
  if [ "$_kb" -lt 128 ]; then
    tethys_log WARN "TS_LOG_MAX_KB=$_kb is below the 128 KB floor - clamping"
    _kb=128
  elif [ "$_kb" -gt 10240 ]; then
    tethys_log WARN "TS_LOG_MAX_KB=$_kb is above the 10240 KB ceiling - clamping"
    _kb=10240
  fi
  echo $((_kb * 1024))
}

tethys_trim_log() {
  # Keep the service log bounded. Called once at daemon start, not in a loop -
  # a rotating log with a timer would be a wakeup class all its own.
  _f="$TETHYS_DATA_DIR/log/service.log"
  [ -f "$_f" ] || return 0
  _max="$(tethys_log_max_bytes)"
  _sz="$(wc -c < "$_f" 2>/dev/null | tr -d ' ')"
  case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_sz" -gt "$_max" ]; then
    tail -c "$_max" "$_f" > "$_f.tmp" 2>/dev/null && mv -f "$_f.tmp" "$_f"
  fi
  return 0
}

# ------------------------------------------------------------- device probing

tethys_device_codename() {
  # ro.product.device is the authoritative codename; the vendor variant is the
  # fallback on some builds. Never guess from the model string.
  _c="$(tethys_prop ro.product.device)"
  [ -n "$_c" ] || _c="$(tethys_prop ro.product.vendor.device)"
  [ -n "$_c" ] || _c="unknown"
  echo "$_c"
}

tethys_abi() {
  # The primary ABI is what a payload must match. ro.product.cpu.abi is a single
  # value; ro.product.cpu.abilist is the preference order - we read the first.
  _a="$(tethys_prop ro.product.cpu.abi)"
  [ -n "$_a" ] || _a="$(tethys_prop ro.product.cpu.abilist | cut -d, -f1)"
  echo "$_a"
}
