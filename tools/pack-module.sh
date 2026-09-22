#!/bin/sh
# Tethys · module packer
#
# Builds the flashable zip this project kept promising and had no hand to make:
#
#     dist/tethys-tailscaled-v1.98.8-tethys.0.zip
#
# WHY THIS EXISTS
# ---------------
# customize.sh refuses to install a zip that carries no daemon - by design. The
# README and customize.sh's own comment both say the daemon is "injected by CI",
# and no step anywhere did that; no tool built the archive at all. A claim with no
# mechanism behind it is the drift class this project exists to kill, so this file
# is the mechanism.
#
# TWO LISTS, NOT A FILTER
# -----------------------
# What ships is DECLARED. Every top-level entry of the tree must be either shipped
# or explicitly acknowledged as not-shipped; anything else refuses the pack. So a
# new runtime file cannot be silently left OUT of the zip, and a stray file cannot
# be silently put IN it. That is the config schema's law applied to the archive:
# an entry with no opinion about its own fate is not an entry. When M12 adds
# webroot/ or M19 adds post-fs-data.sh, add it below deliberately - the pack stops
# and says so until you do.
#
# THE PAYLOAD IS PROVEN, NOT ASSUMED
# ----------------------------------
# The daemon is never copied out of the tree: system/ is CONSTRUCTED from the
# argument, because a payload's provenance is the argument and its checksum, not
# whatever stray file is lying on disk (both payload paths are gitignored). Its
# sha256 is verified against the sidecar the CI release ships, its length must
# survive the round trip through the archive, and the archive's own structure is
# read back with tools/module-archive.py before this script calls the result
# finished - never taken on trust, because a packer that trusts its own output
# ships a wrapper directory one day and finds out on someone else's phone.
#
# Usage:  sh tools/pack-module.sh <path-to-tailscaled> [repo-root]
# Exit:   0 = zip built and its structure proven, 1 = refused
#
# The daemon is built by the fork's CI (milestone M2), never here:
#   tethys-tailscale-android/.github/workflows/build-android.yml

set -u

_here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
_root=${2:-$(CDPATH= cd -- "$_here/.." && pwd)}
_daemon=${1:-}

# SHIPPED - staged, then archived. Every one of these must exist in the tree.
# The top-level set handed to zip is DERIVED from this, so there is one truth
# about what ships and not two that can drift apart.
_required='module.prop customize.sh service.sh uninstall.sh config.env scripts/tethys.lib.sh'

# ACKNOWLEDGED - may exist in the tree, never enters the zip.
_ack='.git .gitignore README.md tests tools dist system'

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }
check() {  # $1 label, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
refuse() { printf '\n  REFUSED - %s\n\n' "$1" >&2; exit 1; }

in_list() {  # $1 = needle, $2 = space-separated list
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

printf 'Tethys module packer\n'
printf '  repo  : %s\n' "$_root"
printf '  daemon: %s\n\n' "${_daemon:-<none given>}"

# ------------------------------------------------------------------- the tools
# The archive is built, listed, measured and hashed by ONE implementation:
# tools/module-archive.py - not the `zip` CLI, because this zip has to be
# buildable on the machine that owns the project as well as on CI, and `zip` is
# installed on only one of them (measured 2026-09-23: zip absent here, unzip and
# python present). python3 is on both, so the archive step has one behaviour
# instead of two that can disagree about entry order, modes, or layout.
_py=''
for _c in python3 python py; do
  if command -v "$_c" >/dev/null 2>&1; then _py=$_c; break; fi
done
[ -n "$_py" ] || refuse "no python3 / python / py on PATH, so the archive cannot be built OR read back.
       This packer does not claim a structure it did not verify."
_arc="$_here/module-archive.py"
[ -f "$_arc" ] || refuse "tools/module-archive.py is missing - it IS the archive mechanics this packer drives."
info "archive mechanics: $_py $_arc"

# ------------------------------------------------------------------ the daemon
[ -n "$_daemon" ] || refuse "no daemon given.
       usage: sh tools/pack-module.sh <path-to-tailscaled> [repo-root]
       The daemon is produced by the fork's CI from the pinned patch series
       (tethys-tailscale-android, workflow build-android.yml, milestone M2).
       Without it the installer refuses the zip, so there is nothing to pack."
[ -f "$_daemon" ] || refuse "the daemon path does not exist: $_daemon"
[ -s "$_daemon" ] || refuse "the daemon is empty: $_daemon"

_magic=$(dd if="$_daemon" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$_magic" = "7f454c46" ] || refuse "the payload is not an ELF object (first bytes: ${_magic:-unreadable}).
       An Android arm64 daemon is ELF; anything else is not the artifact this module runs."
ok "the payload is an ELF object"

# Architecture, when the host can be asked. A wrong-arch payload is the one
# defect the installer CANNOT catch: it validates the device's ABI, not the
# binary's, so an x86-64 build would install cleanly and then fail to exec.
if command -v file >/dev/null 2>&1; then
  _ft=$(file -b "$_daemon" 2>/dev/null || printf '')
  case "$_ft" in
    *AArch64*|*aarch64*|*arm64*) ok "architecture: $_ft" ;;
    *) refuse "the payload is not arm64: ${_ft:-file produced nothing}
       This module ships arm64-v8a only, and the installer cannot see this - it
       checks the device's ABI, not the binary's." ;;
  esac
else
  info "file(1) is absent - the payload's architecture is NOT verified on this host"
fi

_daemon_sha=$("$_py" "$_arc" sha256 "$_daemon" 2>/dev/null) || refuse "could not hash the daemon: $_daemon"
info "daemon sha256: $_daemon_sha"

# Provenance: the CI release ships <artifact>.sha256 beside the binary. When it is
# present it must agree, because that hash is the only witness binding the binary
# this zip carries to the build that produced it.
if [ -f "$_daemon.sha256" ]; then
  _want=$(awk '{print $1}' "$_daemon.sha256" | head -n 1 | tr -d '\r')
  [ "$_want" = "$_daemon_sha" ] || refuse "the daemon does not match its own checksum.
       sidecar : $_want
       computed: $_daemon_sha
       Either the artifact is not the one that was built, or the sidecar is stale.
       Both mean: do not ship it."
  ok "the daemon matches the checksum shipped beside it"
else
  info "no $_daemon.sha256 beside the daemon - its provenance is unverified on this host"
fi

# ------------------------------------------------------------- module identity
# The zip's name is derived from module.prop, so a missing or unusable id/version
# is not a naming nicety: it is the artifact's identity, and its filename.
_prop="$_root/module.prop"
[ -f "$_prop" ] || refuse "module.prop is missing from $_root - a Magisk/KernelSU module without it is not a module."
_id=$(sed -n 's/^id=//p' "$_prop" | head -n 1 | tr -d '\r')
_ver=$(sed -n 's/^version=//p' "$_prop" | head -n 1 | tr -d '\r')
[ -n "$_id" ]  || refuse "module.prop declares no id=, and the zip name is built from it."
[ -n "$_ver" ] || refuse "module.prop declares no version=, and the zip name is built from it."
# Both land in a filename, so neither may carry anything that is not safe there.
case "$_id"  in *[!A-Za-z0-9._-]*) refuse "module.prop id= is not filename-safe: $_id" ;; esac
case "$_ver" in *[!A-Za-z0-9._-]*) refuse "module.prop version= is not filename-safe: $_ver" ;; esac
ok "identity: $_id $_ver"

# --------------------------------------------------------------- the manifest
for _f in $_required; do
  [ -f "$_root/$_f" ] || refuse "required file missing from the tree: $_f"
done
ok "all 6 required files are present"

_ship=''
for _f in $_required; do
  _t=${_f%%/*}
  in_list "$_t" "$_ship" || _ship="$_ship $_t"
done
_ship=${_ship# }

_unknown=''
for _e in "$_root"/* "$_root"/.[!.]*; do
  [ -e "$_e" ] || continue
  _n=$(basename -- "$_e")
  if in_list "$_n" "$_ship"; then :
  elif in_list "$_n" "$_ack"; then info "acknowledged, not shipped: $_n"
  else _unknown="$_unknown $_n"
  fi
done
[ -z "$_unknown" ] || refuse "the tree carries entries this packer has no opinion about:$_unknown
       Every top-level entry must be either shipped or acknowledged, or the
       archive is assembled by guesswork - and guesswork is how a file ends up
       silently missing from a zip that then fails on someone's device."
ok "every top-level entry is declared"

# system/ is CONSTRUCTED, never copied. This scan catches a tree-side file that
# would be silently dropped rather than shipped.
if [ -e "$_root/system" ]; then
  for _e in "$_root"/system/* "$_root"/system/.[!.]*; do
    [ -e "$_e" ] || continue
    _n=$(basename -- "$_e")
    [ "$_n" = "bin" ] || refuse "unexpected entry in system/: $_n
       system/ is built from the daemon argument, so a tree-side file here would
       be silently dropped from the zip. Move it, or teach this packer about it."
    for _b in "$_e"/* "$_e"/.[!.]*; do
      [ -e "$_b" ] || continue
      _bn=$(basename -- "$_b")
      case "$_bn" in
        tailscaled|tailscale) : ;;
        *) refuse "unexpected entry in system/bin/: $_bn (only the two gitignored payload paths belong there)" ;;
      esac
    done
  done
  ok "tree-side system/ holds only the payload paths - acknowledged, never copied"
fi

# ------------------------------------------------------------------- the suite
# The module's own suite gates the pack. Packing a tree whose runtime is broken
# moves that failure onto the device, at boot, where it is worst.
[ -f "$_root/tests/shell-smoke.sh" ] || refuse "tests/shell-smoke.sh is missing.
       The packer gates on the module's own suite, and a tree without it cannot be gated."
if ( cd "$_root" && sh tests/shell-smoke.sh >/dev/null 2>&1 ); then
  ok "the module's own suite is green"
else
  refuse "the module's own suite is RED - see it for yourself:
       cd $_root && sh tests/shell-smoke.sh"
fi

# --------------------------------------------------------------------- staging
_stage=$(mktemp -d) || refuse "could not create a staging directory"
trap 'rm -rf "$_stage"' EXIT INT TERM

for _f in $_required; do
  _d=$(dirname -- "$_f")
  [ "$_d" = "." ] || mkdir -p "$_stage/$_d" || refuse "could not stage $_f"
  cp -p "$_root/$_f" "$_stage/$_f" || refuse "could not stage $_f"
done
mkdir -p "$_stage/system/bin" || refuse "could not create the payload directory"
cp -p "$_daemon" "$_stage/system/bin/tailscaled" || refuse "could not stage the daemon"
chmod 0755 "$_stage/system/bin/tailscaled" 2>/dev/null || true
info "the 'tailscale' symlink is deliberately NOT packed - customize.sh creates it at install"

# ---------------------------------------------------------------------- build
mkdir -p "$_root/dist" || refuse "could not create $_root/dist"
_name="$_id-$_ver.zip"
_out="$_root/dist/$_name"
rm -f "$_out" "$_out.sha256"
# Entries are written ROOT-LEVEL, with the staging directory as the archive's
# root: Magisk and KernelSU read module.prop from the archive root, and a wrapper
# directory would make the zip install nothing at all.
"$_py" "$_arc" build "$_stage" "$_out" $_ship system || refuse "the archive could not be built"
ok "archive built: $_name"

# ----------------------------------------------------------------- the witness
_zip_sha=$("$_py" "$_arc" sha256 "$_out") || refuse "could not hash the archive"
printf '%s  %s\n' "$_zip_sha" "$_name" > "$_out.sha256" || refuse "could not write the checksum"
ok "checksum written beside it"

# ------------------------------------------------------- prove what was built
# Read the archive back. A packer that trusts its own output is a packer that
# ships a wrapper directory one day and finds out on someone else's phone.
_listing=$("$_py" "$_arc" list "$_out") || refuse "could not list $_out - its structure is unproven, so it is not shipped"
present()   { if printf '%s\n' "$_listing" | grep -qx "$1"; then printf 'yes'; else printf 'no'; fi; }
carried() {  # $1 = name - present as a path component, top level or below
  if printf '%s\n' "$_listing" | grep -q "^$1/" || printf '%s\n' "$_listing" | grep -qx "$1"
  then printf 'yes'; else printf 'no'; fi
}

check "module.prop sits at the archive root" "yes" "$(present module.prop)"
if printf '%s\n' "$_listing" | grep -q '/module.prop$'; then
  bad "the archive is wrapped in a directory - Magisk and KernelSU would install nothing"
else
  ok "the archive is not wrapped in a directory"
fi
check "the daemon travels inside it"  "yes" "$(present system/bin/tailscaled)"
for _f in customize.sh service.sh uninstall.sh config.env scripts/tethys.lib.sh; do
  check "packed: $_f" "yes" "$(present "$_f")"
done
for _x in README.md .gitignore tools tests dist; do
  check "not packed: $_x" "no" "$(carried "$_x")"
done

# The payload must survive the round trip at the same length. Byte identity is the
# checksum's job; this catches the cruder failure - an empty or truncated entry.
_src_len=$(wc -c < "$_daemon" | tr -d ' ')
_zip_len=$("$_py" "$_arc" size "$_out" system/bin/tailscaled 2>/dev/null)
check "the packed daemon is the same length as the one given" "$_src_len" "${_zip_len:-0}"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '  artifact: %s\n' "$_out"
  printf '  size    : %s bytes\n' "$(wc -c < "$_out" | tr -d ' ')"
  printf '  sha256  : %s\n' "$(awk '{print $1}' "$_out.sha256")"
  printf '\n  flash it with:\n    magisk --install-module %s\n  or install it from storage in the manager (Magisk / KernelSU / SukiSU).\n\n' "$_out"
  exit 0
fi
exit 1
