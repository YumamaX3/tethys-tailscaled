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

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
