#!/bin/sh
# Tethys · shell-layer smoke test
#
# Runs the module's shell logic OFF-DEVICE against a temporary state root, and
# asserts the behaviour the daemon and the plan actually depend on. No device, no
# root, no Android - just POSIX sh.
#
# Why this exists: `sh -n` (syntax) passed on a library that silently ignored its
# own TETHYS_DATA_DIR override AND created a directory (`bin`) that no patch in
# the series reads, while omitting one it does (`certs`). Both were real defects;
# a parser smiled at both. So the checks here are behavioural - and one of them
# proves a SECURITY property (plan §8.3: config is data, never a program).
#
# Usage:  sh tests/shell-smoke.sh
# Exit:   0 = all checks passed, 1 = at least one failed.

set -u

_here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
_lib="$_here/../scripts/tethys.lib.sh"

pass=0
fail=0

check() {
  _label="$1"; _expected="$2"; _actual="$3"
  if [ "$_expected" = "$_actual" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$_label"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        expected: %s\n        actual  : %s\n' "$_label" "$_expected" "$_actual"
  fi
}

check_dir() {
  _label="$1"; _want="$2"; _path="$3"
  if [ -d "$_path" ]; then _got=present; else _got=absent; fi
  check "$_label" "$_want" "$_got"
}

[ -r "$_lib" ] || { echo "cannot read $_lib" >&2; exit 1; }

# A temp state root. The library must HONOUR this, not overwrite it - if it
# overwrites, every check below lands on the real /data/adb path instead.
_work=$(mktemp -d) || exit 1
trap 'rm -rf "$_work"' EXIT INT TERM
TETHYS_DATA_DIR="$_work/state"
export TETHYS_DATA_DIR

# shellcheck disable=SC1090
. "$_lib"

echo "Tethys shell smoke test"
echo "  state root (temp): $TETHYS_DATA_DIR"
echo

# ---------------------------------------------------------------- state root
check "lib honours a pre-set TETHYS_DATA_DIR" "$_work/state" "$TETHYS_DATA_DIR"
check "lib exposes a temp path, not the device path" "no" \
  "$( [ "$TETHYS_DATA_DIR" = "/data/adb/tailscale" ] && echo yes || echo no )"

tethys_ensure_dirs
check "ensure_dirs returns success" "0" "$?"
check_dir "creates the state root"  "present" "$TETHYS_DATA_DIR"
check_dir "creates log/"            "present" "$TETHYS_DATA_DIR/log"
check_dir "creates etc/"            "present" "$TETHYS_DATA_DIR/etc"
check_dir "creates certs/"          "present" "$TETHYS_DATA_DIR/certs"
check_dir "does NOT create bin/"    "absent"  "$TETHYS_DATA_DIR/bin"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) perms="(n/a on windows)" ;;
  *) perms=$(stat -c '%a' "$TETHYS_DATA_DIR" 2>/dev/null || echo "?") ;;
esac
if [ "$perms" = "(n/a on windows)" ]; then
  printf '  skip  state root is 0700 (file modes not assertable on this host)\n'
else
  check "state root is 0700" "700" "$perms"
fi

# ---------------------------------------------------- config: data, not code
# The plan's §8.3 law. These are the checks that matter most, because a config
# that is `source`d is a program, and a child process is the proof.

cat > "$_work/good.env" <<'EOF'
# a comment, ignored
TS_START_ON_BOOT="0"
TS_TUN_MODE='native-only'
TS_DAEMON_ARGS=-no-logs-no-support --verbose=1
TS_LOG_MAX_KB="128"
NOT_AN_ALLOWED_KEY="should be ignored"
EOF

tethys_cfg_load "$_work/good.env" >/dev/null 2>&1
check "parses a double-quoted value"     "0"              "$TS_START_ON_BOOT"
check "parses a single-quoted value"     "native-only"    "$TS_TUN_MODE"
check "keeps an unquoted multi-word arg" "-no-logs-no-support --verbose=1" "$TS_DAEMON_ARGS"
check "ignores a non-allowlisted key"    "unset"          "${NOT_AN_ALLOWED_KEY:-unset}"

# The proof: a line that would EXECUTE if the file were sourced. Nothing may run.
_sent="$_work/should-never-exist"
cat > "$_work/hostile.env" <<EOF
TS_TUN_MODE="netstack-only"; touch $_sent
TS_EXTRA_UP_ARGS="--advertise-routes=10.0.0.0/8; rm -rf /"
EOF
tethys_cfg_load "$_work/hostile.env" >/dev/null 2>&1
check "config is NEVER sourced (no command ran)" "absent" \
  "$( [ -f "$_sent" ] && echo present || echo absent )"
check "TS_EXTRA_UP_ARGS with metacharacters is rejected" "" "${TS_EXTRA_UP_ARGS:-}"

# A missing file must degrade to defaults, not abort the boot.
tethys_cfg_load "$_work/does-not-exist.env" >/dev/null 2>&1
check "a missing config file is not fatal" "0" "$?"

# ------------------------------------------------------------- tun mode mapping
TS_TUN_MODE=native-first;  check "TUN native-first -> kernel then userspace" "tailscale0,userspace-networking" "$(tethys_tun_flag)"
TS_TUN_MODE=native-only;   check "TUN native-only  -> kernel interface"      "tailscale0"                      "$(tethys_tun_flag)"
TS_TUN_MODE=netstack-only; check "TUN netstack-only -> userspace stack"      "userspace-networking"            "$(tethys_tun_flag)"
TS_TUN_MODE=banana;        check "TUN unknown value falls back to a real mode" "tailscale0,userspace-networking" "$(tethys_tun_flag)" 2>/dev/null

# ------------------------------------------------------------------ daemon argv
TS_TUN_MODE=native-only
TS_DAEMON_ARGS="-no-logs-no-support"
check "build_args: tun flag first, daemon flags in order" \
  "--tun=tailscale0 -no-logs-no-support" \
  "$(tethys_build_args | tr '\n' ' ' | sed 's/ $//')"
TS_DAEMON_ARGS=""
check "build_args with no daemon flags emits only the tun flag" \
  "--tun=tailscale0" "$(tethys_build_args | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------- log ceiling
TS_LOG_MAX_KB=512;   check "TS_LOG_MAX_KB honoured"          "$((512 * 1024))"   "$(tethys_log_max_bytes)"
TS_LOG_MAX_KB=64;    check "below the 128 KB floor, clamped" "$((128 * 1024))"   "$(tethys_log_max_bytes)"
TS_LOG_MAX_KB=99999; check "above the 10240 KB ceiling, clamped" "$((10240 * 1024))" "$(tethys_log_max_bytes)"
TS_LOG_MAX_KB=abc;   check "non-numeric falls back to 512"   "$((512 * 1024))"   "$(tethys_log_max_bytes)"

mkdir -p "$TETHYS_DATA_DIR/log"
# The ceiling must be EXCEEDED for trimming to be the correct behaviour. With the
# schema's 128 KB floor, a 5000-byte log is simply under it - asking for a trim
# there would assert the wrong thing and, worse, would pass on a broken trimmer
# that never trimmed at all. So the fixture is 200000 bytes.
head -c 200000 /dev/zero | tr '\0' 'x' > "$TETHYS_DATA_DIR/log/service.log"
TS_LOG_MAX_KB=128
check "trim_log bounds a 200000-byte log to the 131072-byte ceiling" "$((128 * 1024))" \
  "$(tethys_trim_log; wc -c < "$TETHYS_DATA_DIR/log/service.log" | tr -d ' ')"
printf 'small' > "$TETHYS_DATA_DIR/log/service.log"
check "trim_log leaves a log under the ceiling alone" "5" \
  "$(tethys_trim_log; wc -c < "$TETHYS_DATA_DIR/log/service.log" | tr -d ' ')"

# ------------------------------------------------------------- device probing
# getprop is absent here, as it is on any non-Android host. The honest answer is
# a named default, never an empty string that a caller might treat as a device.
check "codename falls back to a named default without getprop" "unknown" "$(tethys_device_codename)"
check "abi falls back to empty without getprop" "" "$(tethys_abi)"

# ===================== M4 · schema, validator, and one-time migration ========
# The plan's §8.3 deliverable, proven in both halves: values refused by TYPE,
# and a legacy config completed ONCE with every existing value preserved.
#
# The fixtures are the real artifacts - tests/fixtures/config-v2.3.1.env is the
# canonical legacy file as upstream v2.3.1 shipped it, not a shape we invented.

vok() { if tethys_cfg_value_ok "$1" "$2"; then echo ok; else echo refused; fi; }

# sed-based reader: the value of $2 in file $1, with one layer of quotes removed.
cfgval() { sed -n "s/^$2='\(.*\)'\$/\1/p" "$1" | head -n1; }

# --- the schema is ONE truth; the documented template must not drift from it --
_defaults="$_work/schema-defaults.env"
tethys_cfg_default_lines > "$_defaults"

_missing=""
while IFS= read -r _want; do
  _k=${_want%%=*}
  grep -q "^${_k}=" "$_here/../config.env" || _missing="$_missing $_k"
done < "$_defaults"
check "every schema key appears in config.env (one truth, not two)" "" "$_missing"

# Read the template the way a human writes it and the loader reads it: trim
# blanks, cut a trailing note, trim again, then strip one layer of quotes. The
# template spells its values with DOUBLE quotes and trails some with "# notes",
# so a reader that knew only one quote style - or that cut a note without
# trimming what the cut left behind - would report every default as drifted, a
# false alarm that teaches the next reader to distrust the check, not the file.
# tethys_trim_blanks comes from the library under test, so the two cannot drift.
tplval() {
  _tv=$(sed -n "s/^$1=//p" "$_here/../config.env" | head -n1)
  _tv=$(printf '%s' "$_tv" | tr -d '\r')
  _tv=$(tethys_trim_blanks "$_tv")
  case "$_tv" in
    '"'*'"'|"'"*"'") : ;;
    *)
      case "$_tv" in *' #'*) _tv=${_tv%%' #'*} ;; esac
      _tv=$(tethys_trim_blanks "$_tv")
      ;;
  esac
  case "$_tv" in
    '"'*'"') _tv=${_tv#\"}; _tv=${_tv%\"} ;;
    "'"*"'") _tv=${_tv#\'}; _tv=${_tv%\'} ;;
  esac
  printf '%s' "$_tv"
}

_drift=""
while IFS= read -r _want; do
  _k=${_want%%=*}; _dv=${_want#*=}
  # tethys_cfg_default_lines emits canonical NAME='VALUE' lines, so the schema's
  # default arrives quoted while the template's arrives bare. Strip the schema
  # side's quotes, or every single row reads as a mismatch.
  case "$_dv" in "'"*"'") _dv=${_dv#\'}; _dv=${_dv%\'} ;; esac
  _tv=$(tplval "$_k")
  [ "$_dv" = "$_tv" ] || _drift="$_drift $_k(schema=[$_dv] template=[$_tv])"
done < "$_defaults"
check "the template's stated defaults equal the schema's" "" "$_drift"

# --- a value is judged by ITS key's type, and a refusal is not a coercion ----
check "bool accepts 1"                      "ok"      "$(vok TS_START_ON_BOOT 1)"
check "bool refuses 2"                      "refused" "$(vok TS_START_ON_BOOT 2)"
check "enum accepts a listed value"         "ok"      "$(vok TS_TUN_MODE netstack-only)"
check "enum refuses an unlisted value"      "refused" "$(vok TS_TUN_MODE banana)"
check "int accepts an in-range value"       "ok"      "$(vok TS_LOG_MAX_KB 512)"
check "int refuses a non-number"            "refused" "$(vok TS_LOG_MAX_KB abc)"
check "metacharacters are refused"          "refused" "$(vok TS_EXTRA_UP_ARGS '--x; rm -rf /')"
check "a glob is refused"                   "refused" "$(vok TS_EXTRA_UP_ARGS '*')"
check "an embedded tab is refused"          "refused" "$(vok TS_EXTRA_UP_ARGS "$(printf 'a\tb')")"
check "an empty value is legal where stated" "ok"     "$(vok TS_EXTRA_UP_ARGS '')"
check "a bare-word url is refused"          "refused" "$(vok TS_LOGIN_SERVER headscale.example.com)"
check "an https url is accepted"            "ok"      "$(vok TS_LOGIN_SERVER https://hs.example.com)"
check "a hostname with a space is refused"  "refused" "$(vok TS_HOSTNAME 'bad host')"
check "a plain hostname is accepted"        "ok"      "$(vok TS_HOSTNAME phone)"
check "a uids range list is accepted"       "ok"      "$(vok TS_SPLIT_TUNNEL_UIDS '1000,10123-10130')"
check "a uids word is refused"              "refused" "$(vok TS_SPLIT_TUNNEL_UIDS abc)"
check "a key outside the schema is refused" "refused" "$(vok TS_NOT_A_KEY 1)"

# --- the FILE validator reports reasons, and the reasons leak no values ------
tethys_cfg_validate "$_here/../config.env" >/dev/null 2>&1
check "the packaged template validates" "0" "$?"

cat > "$_work/dup.env" <<'EOF'
TS_HOSTNAME='phone'
TS_HOSTNAME='other'
EOF
_out=$(tethys_cfg_validate "$_work/dup.env" 2>&1); _rc=$?
check "a duplicate key is refused" "1" "$_rc"
check "the duplicate reason names the offending line" "yes" \
  "$(case "$_out" in *"line 2: duplicate key TS_HOSTNAME"*) echo yes ;; *) echo no ;; esac)"

cat > "$_work/unknown.env" <<'EOF'
TS_UNSUPPORTED_SECRET_NAME='do-not-echo-me'
EOF
_out=$(tethys_cfg_validate "$_work/unknown.env" 2>&1); _rc=$?
check "an unsupported key is refused" "1" "$_rc"
check "the refused key's NAME is not echoed back" "no" \
  "$(case "$_out" in *TS_UNSUPPORTED_SECRET_NAME*|*do-not-echo-me*) echo yes ;; *) echo no ;; esac)"

# --- migration: complete a legacy config ONCE, preserving every value -------
_leg="$_work/legacy.env"
cp "$_here/fixtures/config-v2.3.1.env" "$_leg"
tethys_cfg_migrate "$_leg"
check "migration reports how many keys it added" "11" "$TETHYS_CFG_ADDED"

check "a legacy value that differs from the default survives verbatim" \
  "--accept-dns=false --accept-routes=true --advertise-exit-node=false --shields-up=false --exit-node= --ssh=false" \
  "$(cfgval "$_leg" TS_UP_ARGS)"
# A value that DIFFERS from the schema default must never be "corrected" back to
# it. The fixture's own values mostly coincide with the defaults, so this needs a
# file of its own: one key set to a non-default literal, then a full completion.
_nond="$_work/nondefault.env"
printf "TS_POWER_MODE='saver'\n" > "$_nond"
tethys_cfg_migrate "$_nond"
check "a non-default enum value is preserved, not reset" "saver" "$(cfgval "$_nond" TS_POWER_MODE)"
check "the rest of that file is still completed"         "17"    "$TETHYS_CFG_ADDED"
check "a legacy empty value stays empty"   ""  "$(cfgval "$_leg" TS_HOSTNAME)"
check "a newly added key takes the schema default" "balanced"    "$(cfgval "$_leg" TS_POWER_MODE)"
check "the added tun mode default is correct"      "native-first" "$(cfgval "$_leg" TS_TUN_MODE)"
check "the added log ceiling default is correct"   "512"          "$(cfgval "$_leg" TS_LOG_MAX_KB)"

_missing=""
while IFS= read -r _want; do
  _k=${_want%%=*}
  grep -q "^${_k}=" "$_leg" || _missing="$_missing $_k"
done < "$_defaults"
check "the migrated file now carries every schema key" "" "$_missing"
check "the migrated file passes validation" "0" "$(tethys_cfg_validate "$_leg" >/dev/null 2>&1; echo $?)"
check "a migration note was left behind" "present" \
  "$( [ -f "$TETHYS_DATA_DIR/etc/config-migrated.note" ] && echo present || echo absent )"

# ONCE. A second run must add nothing: an install that rewrote the file on
# every upgrade would be a slow corruption of the user's own tuning.
tethys_cfg_migrate "$_leg"
check "a second migration adds nothing (one-time act)" "0" "$TETHYS_CFG_ADDED"

# A file with no trailing newline must not weld the first added key onto its
# last line - the file would then parse as neither.
_nofinal="$_work/no-final-newline.env"
printf 'TS_TUN_MODE=netstack-only' > "$_nofinal"
tethys_cfg_migrate "$_nofinal"
check "a newline-less tail is not welded to the added keys" "yes" \
  "$(if grep -q 'netstack-onlyTS_' "$_nofinal"; then echo no; else echo yes; fi)"
check "the newline-less file still validates" "0" \
  "$(tethys_cfg_validate "$_nofinal" >/dev/null 2>&1; echo $?)"

# A key present but EMPTY is a decision ("pass nothing"), not an absence.
printf "TS_KILL_SWITCH=''\n" >> "$_leg"
tethys_cfg_migrate "$_leg"
check "a present-but-empty key is not refilled" "0" "$TETHYS_CFG_ADDED"

# --- the loader degrades per line; a bad value never takes the boot down -----
cat > "$_work/badval.env" <<'EOF'
TS_POWER_MODE='turbo'
TS_TUN_MODE='netstack-only'
EOF
TS_POWER_MODE=balanced
tethys_cfg_load "$_work/badval.env" >/dev/null 2>&1
check "an out-of-enum value is refused; the default stands" "balanced"      "$TS_POWER_MODE"
check "a valid line in the same file is still applied"      "netstack-only" "$TS_TUN_MODE"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
