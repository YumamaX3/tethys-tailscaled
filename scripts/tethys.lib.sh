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

# ------------------------------------------------------------- the config schema
#
# One row per key:  NAME|DEFAULT|VALIDATOR
#
# This table is the SINGLE truth for three things that were once three truths:
# which keys exist, what they default to, and what a value may be. "Add a
# setting" and "add a validator" are therefore the same act - a setting with no
# opinion about its own values is not a setting, it is a rumour.
#
# VALIDATORS
#   bool            0 | 1
#   enum:a,b,c      exactly one of the listed literals
#   int:MIN:MAX     decimal integer, inclusive bounds
#   nometa          free text; control chars and shell metacharacters refused
#   hostname        DNS-shaped label, or empty
#   url             https://... , or empty for the stock control plane
#   uids            comma-separated uids and uid ranges
#   routes          comma-separated CIDRs
#
# A refusal is ALWAYS a refusal: the default stands and the reason is logged. No
# value is silently coerced into something plausible, because a config that
# quietly means something other than what it says is worse than one that says no.
#
# ONE DELIBERATE EXCEPTION: TS_LOG_MAX_KB keeps the full 128-10240 range here and
# is CLAMPED where it is consumed (tethys_log_max_bytes). A number slightly out
# of range is a preference to be bounded, not a lie to be refused.
TETHYS_SCHEMA="\
TS_START_ON_BOOT|1|bool \
TS_TUN_MODE|native-first|enum:native-first,native-only,netstack-only \
TS_DAEMON_ARGS|-no-logs-no-support|nometa \
TS_UP_ARGS|--accept-dns=false|nometa \
TS_EXTRA_UP_ARGS||nometa \
TS_LOGIN_SERVER||url \
TS_HOSTNAME||hostname \
TS_PROFILE|default|hostname \
TS_ENABLE_SSH|0|bool \
TS_ADVERTISE_ROUTES||routes \
TS_KILL_SWITCH|0|bool \
TS_SPLIT_TUNNEL_MODE|off|enum:off,include,exclude \
TS_SPLIT_TUNNEL_UIDS||uids \
TS_WATCHDOG_ENABLED|0|bool \
TS_POWER_MODE|balanced|enum:performance,balanced,saver \
TS_LOG_MAX_KB|512|int:128:10240 \
TS_THEME|full-ritual|enum:full-ritual,signature,plain \
TS_JOURNAL_ENABLED|1|bool"

TETHYS_TAB="$(printf '\t')"

tethys_schema_row() {
  for _row in $TETHYS_SCHEMA; do
    case "$_row" in "$1|"*) echo "$_row"; return 0 ;; esac
  done
  return 1
}

tethys_schema_default() {
  _row="$(tethys_schema_row "$1")" || return 1
  _row="${_row#*|}"
  echo "${_row%%|*}"
}

tethys_schema_type() {
  _row="$(tethys_schema_row "$1")" || return 1
  echo "${_row##*|}"
}

# The allowlist is DERIVED, never restated. A hand-kept second copy of the key
# list is the same drift class as a second copy of a path: it agrees until the
# day it does not, and nothing mechanical is comparing them.
tethys_key_allowed() {
  tethys_schema_row "$1" >/dev/null 2>&1
}

# Every default, as canonical NAME='VALUE' lines. This is the shape a fresh
# config is written in, and the shape a migration fills gaps with, so the seed
# and the migration can never disagree about what a default IS.
tethys_cfg_default_lines() {
  for _row in $TETHYS_SCHEMA; do
    _k=${_row%%|*}
    _rest=${_row#*|}
    echo "$_k='${_rest%%|*}'"
  done
}

tethys_has_meta() {
  # Shell metacharacters. We never eval and never interpolate a config value into
  # a shell string, so this is defence in depth - but the value is surfaced
  # through the panel's `up` path, and a value that can never reach a shell
  # cannot be used to reach one.
  case "$1" in
    *[\`\$\;\|\&\<\>\(\)\{\}\!\*]* ) return 0 ;;
  esac
  return 1
}

tethys_cfg_value_ok() {
  # $1 = key, $2 = value. 0 = the value is acceptable for that key's validator.
  _t="$(tethys_schema_type "$1")" || return 1
  _val="$2"
  case "$_t" in
    bool)
      case "$_val" in 0|1) return 0 ;; esac
      return 1 ;;
    int:*)
      _b=${_t#int:}
      case "$_val" in ''|*[!0-9]*) return 1 ;; esac
      [ "$_val" -ge "${_b%%:*}" ] 2>/dev/null || return 1
      [ "$_val" -le "${_b##*:}" ] 2>/dev/null || return 1
      return 0 ;;
    enum:*)
      for _cand in $(echo "${_t#enum:}" | tr ',' ' '); do
        [ "$_val" = "$_cand" ] && return 0
      done
      return 1 ;;
    nometa)
      tethys_has_meta "$_val" && return 1
      case "$_val" in *"$TETHYS_TAB"*|*"$(printf '\r')"*) return 1 ;; esac
      return 0 ;;
    hostname)
      [ -z "$_val" ] && return 0
      case "$_val" in *[!A-Za-z0-9.-]*) return 1 ;; esac
      case "$_val" in -*|*-|.*|*.) return 1 ;; esac
      return 0 ;;
    url)
      [ -z "$_val" ] && return 0
      case "$_val" in https://?*) : ;; *) return 1 ;; esac
      tethys_has_meta "$_val" && return 1
      case "$_val" in *\'*|*'"'*|*" "*) return 1 ;; esac
      return 0 ;;
    uids)
      [ -z "$_val" ] && return 0
      case "$_val" in *[!0-9,-]*) return 1 ;; esac
      case "$_val" in ,*|*,|*,,*) return 1 ;; esac
      return 0 ;;
    routes)
      [ -z "$_val" ] && return 0
      case "$_val" in *[!0-9A-Fa-f:./,]*) return 1 ;; esac
      return 0 ;;
  esac
  return 1
}

# Trim trailing blanks from $1 and print the result. Space and tab only - a line
# has already been read, so there is no newline to consider, and '\r' is removed
# by the caller before this runs. A loop rather than a sed call because this sits
# on the boot path.
tethys_trim_blanks() {
  _tb="$1"
  while :; do
    case "$_tb" in
      *' ')           _tb=${_tb% } ;;
      *"$TETHYS_TAB") _tb=${_tb%"$TETHYS_TAB"} ;;
      *) break ;;
    esac
  done
  printf '%s' "$_tb"
}

# Classify one config line. Sets _LK (key) and _LV (value).
#   0 = a real key line that passed validation
#   1 = not a key line (blank or comment) - skip in silence
#   2 = a real key line that FAILED; _LREASON says why, WITHOUT the value
#
# _LREASON never carries the value, deliberately: a config value may be a login
# URL or a hostname, and a validator that echoes what it rejected turns the log
# into a leak.
tethys_cfg_classify() {
  _LK=""; _LV=""; _LREASON=""
  _lead="$1"
  while :; do
    case "$_lead" in
      ' '*) _lead=${_lead# } ;;
      "$TETHYS_TAB"*) _lead=${_lead#"$TETHYS_TAB"} ;;
      *) break ;;
    esac
  done
  case "$_lead" in ''|'#'*) return 1 ;; esac
  case "$_lead" in *=*) : ;; *) _LREASON="expected KEY='VALUE'"; return 2 ;; esac
  _LK=${_lead%%=*}
  _LV=${_lead#*=}
  _LK=$(printf '%s' "$_LK" | tr -d ' \t\r')
  tethys_key_allowed "$_LK" || { _LREASON="unsupported key name"; return 2; }

  # A trailing note belongs to the LINE, not to the value. The packaged template
  # documents its own defaults that way -
  #     TS_ENABLE_SSH="0"            # adds --ssh            [M14]
  # - and a template that cannot satisfy its own schema is a lie shipped to every
  # device, so the classifier must read the note. Order matters: trim blanks, cut
  # an unquoted tail's note, trim again, THEN strip quotes. A value that is FULLY
  # quoted is never cut, so a '#' or ' #' inside quotes survives as content. Only
  # a SPACE-prefixed '#' opens a note, so a '#' inside a bare word survives too.
  _LV=$(printf '%s' "$_LV" | tr -d '\r')
  _LV=$(tethys_trim_blanks "$_LV")
  case "$_LV" in
    '"'*'"'|"'"*"'") : ;;
    *)
      case "$_LV" in
        *' #'*)             _LV=${_LV%%' #'*} ;;
        *"$TETHYS_TAB"#*)   _LV=${_LV%%"$TETHYS_TAB"#*} ;;
      esac
      _LV=$(tethys_trim_blanks "$_LV")
      ;;
  esac
  # Strip ONE layer of matching quotes; keep the inner text verbatim.
  case "$_LV" in
    '"'*'"') _LV=${_LV#\"}; _LV=${_LV%\"} ;;
    "'"*"'") _LV=${_LV#\'}; _LV=${_LV%\'} ;;
  esac
  tethys_cfg_value_ok "$_LK" "$_LV" || { _LREASON="value is not $(tethys_schema_type "$_LK")"; return 2; }
  return 0
}

tethys_cfg_load() {
  # $1 = config file. Returns 0 ALWAYS: a bad file degrades to defaults with a
  # logged reason rather than refusing to boot the device. Strictness lives in
  # tethys_cfg_validate, which the installer calls to REFUSE a broken file -
  # the two have different jobs on purpose, and both call the same classifier.
  [ -r "$1" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    tethys_cfg_classify "$_line"
    case "$?" in
      0) export "$_LK=$_LV" ;;
      1) : ;;
      *) tethys_log WARN "config: a line was ignored ($_LREASON)" ;;
    esac
  done < "$1"
  return 0
}

tethys_cfg_validate() {
  # $1 = config file. 0 = every real line is a known key with an acceptable
  # value and no key appears twice. Reasons go to stderr, line-numbered, and
  # NEVER carry a value.
  _f="$1"
  [ -r "$_f" ] || return 0
  _ln=0; _bad=0; _seen=" "
  while IFS= read -r _line || [ -n "$_line" ]; do
    _ln=$((_ln + 1))
    tethys_cfg_classify "$_line"; _rc=$?
    [ "$_rc" -eq 1 ] && continue
    if [ "$_rc" -eq 2 ]; then
      echo "Invalid config line $_ln: $_LREASON" >&2
      _bad=1
      continue
    fi
    case "$_seen" in
      *" $_LK "*) echo "Invalid config line $_ln: duplicate key $_LK" >&2; _bad=1; continue ;;
    esac
    _seen="$_seen$_LK "
  done < "$_f"
  [ "$_bad" -eq 0 ]
}

# ------------------------------------------------------------------- migration
#
# The legacy truth, measured rather than assumed: the canonical v2.3.1 config
# carried SEVEN keys, and every one of them is a key this schema still knows.
# An upgrade therefore does not translate anything - it COMPLETES a file that is
# missing keys, preserving every value already present, including a present-but-
# empty one (empty means "pass nothing", which is a decision, not an absence).
tethys_cfg_migrate() {
  # $1 = config file. Sets TETHYS_CFG_ADDED to the number of keys filled in.
  TETHYS_CFG_ADDED=0
  _f="$1"
  [ -f "$_f" ] || return 0

  _tmp="$_f.migrate.$$"
  _old_umask=$(umask)
  umask 077
  if ! cp -f "$_f" "$_tmp" 2>/dev/null; then
    umask "$_old_umask"
    tethys_log WARN "config: could not stage a migration copy of $_f"
    return 1
  fi

  # A file whose last line carries no trailing newline would have the first added
  # key WELDED onto it, producing one line that is two keys and parses as
  # neither. Normalise the boundary before anything is appended.
  if [ -s "$_tmp" ] && ! tail -c 1 "$_tmp" 2>/dev/null | grep -q '^$'; then
    echo "" >> "$_tmp"
  fi

  _added=""
  for _row in $TETHYS_SCHEMA; do
    _k=${_row%%|*}
    _rest=${_row#*|}
    # Present wins. Match the KEY only, at the start of a line - a key that is
    # present with an empty value was set deliberately and is left alone. The
    # pattern is a literal key name (letters, digits, underscore), so no regex
    # metacharacter can appear in it and no BRE extension is needed; Android's
    # grep variants all read this the same way.
    if grep -q "^$_k=" "$_f" 2>/dev/null; then continue; fi
    echo "$_k='${_rest%%|*}'" >> "$_tmp" || {
      umask "$_old_umask"; rm -f "$_tmp"
      tethys_log WARN "config: migration write failed"
      return 1
    }
    TETHYS_CFG_ADDED=$((TETHYS_CFG_ADDED + 1))
    _added="$_added $_k"
  done

  if [ "$TETHYS_CFG_ADDED" -gt 0 ]; then
    chmod 0600 "$_tmp" 2>/dev/null
    if ! mv -f "$_tmp" "$_f"; then
      umask "$_old_umask"; rm -f "$_tmp"
      tethys_log WARN "config: migration switch failed; the original is untouched"
      return 1
    fi
    # The note the plan asks for: what happened, when, and to which keys. It is
    # written AFTER the switch, so a failed migration never leaves a note
    # claiming a change that did not land.
    _note="$TETHYS_DATA_DIR/etc/config-migrated.note"
    if [ -d "$TETHYS_DATA_DIR/etc" ]; then
      {
        echo "config migrated at $(date +'%Y-%m-%dT%H:%M:%S')"
        echo "keys added ($TETHYS_CFG_ADDED):$_added"
        echo "existing values were preserved untouched; none were rewritten."
      } > "$_note" 2>/dev/null
    fi
  else
    rm -f "$_tmp"
  fi
  umask "$_old_umask"
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
