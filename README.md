# Tethys · tailscaled

A Magisk / KernelSU module that runs a **patched Tailscale daemon** on rooted
Android, with its entire state rooted in one directory you can find, back up, and
delete.

Built for the **Google Pixel 6 Pro** (`raven`, `arm64-v8a`) from the pinned
Tailscale **v1.98.8** Android patch series. Module id `tethys-tailscaled`; the
panel it will grow is titled **The Beacon**.

## Requirements

| requirement | why |
|---|---|
| Magisk or KernelSU | the module format, and root for the daemon's own socket marks |
| `arm64-v8a` device | the payload is arm64 only; the installer refuses any other ABI |
| ~40 MB free on `/data` | state, logs and the daemon itself |

## Install

```sh
# from the module zip
magisk --install-module tethys-tailscaled-v1.98.8-tethys.0.zip
# or flash the zip in the Magisk / KernelSU app, then reboot
```

The installer refuses loudly rather than installing something broken. It stops if
the ABI is not arm64, if `system/bin/tailscaled` is missing or empty, or if
`/data` is not writable — because a module that installs silently and then does
nothing at boot is worse than one that says no.

## Layout

```
module.prop                 module identity (Magisk / KernelSU)
customize.sh                installer — validates ABI and payload, seeds the config
service.sh                  boot launcher — starts the supervisor, returns immediately
uninstall.sh                stops the daemon, and by default keeps your state
config.env                  the schema (plan §8.3) — seed template only
system/bin/tailscaled       the daemon — taken from the fork's release assets, never committed (see debt)
system/bin/tailscale        symlink to it; both land on PATH
scripts/tethys.lib.sh       shared POSIX-sh helpers
tests/shell-smoke.sh        behavioural test for everything above
tools/pack-module.sh        the packer — refuses what it cannot prove, then proves what it built
tools/module-archive.py     the archive mechanics the packer drives
.github/workflows/build-module.yml  fetches the released daemon and packs the zip
```

At runtime the module lives at `/data/adb/modules/tethys-tailscaled/`.

**Why `system/bin/`.** Magisk overlays a module's `system/` tree onto the real
system partitions, so both binaries appear as `/system/bin/tailscaled` and
`/system/bin/tailscale` — on `PATH` for every shell on the device, which is how
upstream ships them too. The daemon is a multi-call binary and creates its own
`tailscale` symlink on start; the installer pre-creates it as well, so the CLI
answers *before* the daemon has ever been started. The daemon's own creation is
idempotent, so there is no race — only earlier availability.

## The state root — the one contract that matters

The patched daemon does not take a state path from you. On Android it looks for
`/data/adb/tailscale`, and if that directory exists it **adopts it for
everything** (source: `patches/0002-paths-and-runtime-locations.patch`):

| path | what lives there |
|---|---|
| `tailscaled.state` | the node private key — this device's identity to your tailnet |
| `tailscaled.sock` | the control socket the CLI talks to |
| `log/` | daemon and service logs |
| `etc/resolv.conf` | resolver state, plus a `.pre-tailscale-backup` beside it |
| `certs/` | TLS material for the local web surface |

That directory *is* the contract. If it does not exist, state leaks into
`$TMPDIR` and vanishes on reboot — so the module creates it, and nothing else in
this module may relocate it.

`log/`, `etc/` and `certs/` are created because the series reads them. There is
deliberately **no `bin/`** under it: the daemon's `tailscale` symlink is created
beside the *executable*, not here.

## Configuration

**Edit `/data/adb/tailscale/config.env`, not the copy in the module directory.**
Magisk replaces the module directory on every upgrade, so anything kept inside it
is silently reverted. The installer seeds the file to the data directory once,
and `service.sh` reads that copy in preference to the packaged template.

The config follows the plan's §8.3 schema and one law:

> **Read as data, never sourced.** `tethys.lib.sh` parses `KEY=VALUE` lines,
> assigns only **allowlisted** keys, and never executes a line of the file.
> `TS_EXTRA_UP_ARGS` is rejected outright if it contains shell metacharacters.

The schema (`TETHYS_SCHEMA` in `scripts/tethys.lib.sh`) is the single truth for
three things at once: **which keys exist**, **what they default to**, and **what a
value may be**. Adding a setting and adding a validator are therefore the same
act — a setting with no opinion about its own values is not a setting. On every
install, `customize.sh` checks the file against it:

- **The packaged template must pass its own schema**, or the installer refuses to
  seed it. A broken default never reaches a device.
- **An existing config is never overwritten.** The canonical v2.3.1 file carried
  seven keys; this schema has eighteen, so the missing ones are filled **once**,
  with their defaults, and a note is left at `etc/config-migrated.note`. Values
  already present are never rewritten — including present-but-**empty** ones,
  because empty means "pass nothing", which is a decision rather than an absence.
- **A value that fails its key's validator is refused**: the default stands and
  the reason is logged with a line number. Nothing is silently coerced into
  something plausible, because a config that quietly means something other than
  what it says is worse than one that says no. One deliberate exception —
  `TS_LOG_MAX_KB` keeps the full 128–10240 range in the schema and is **clamped**
  where it is consumed: a number slightly out of range is a preference to be
  bounded, not a lie to be refused.
- **A trailing `# note` belongs to the line, not the value.** The template
  documents its own defaults that way. A **fully quoted** value is never cut, so a
  `#` inside quotes survives as content.
- **Upstream's `settings.sh` is never read.** It was a shell script that the
  service `source`d, and a file that once ran your shell is exactly the file a
  migration must not trust.

Keys consumed today (M3):

| key | default | effect |
|---|---|---|
| `TS_START_ON_BOOT` | `1` | gates `service.sh` |
| `TS_TUN_MODE` | `native-first` | `native-first` → `--tun=tailscale0,userspace-networking`; `native-only` → `--tun=tailscale0`; `netstack-only` → `--tun=userspace-networking` |
| `TS_DAEMON_ARGS` | `-no-logs-no-support` | extra `tailscaled` flags |
| `TS_LOG_MAX_KB` | `512` | log ceiling, **clamped** to 128–10240 rather than obeyed |

Keys the schema declares for their own milestones — present so the file is the
one config truth, not yet read by the daemon launch: `TS_UP_ARGS` and
`TS_EXTRA_UP_ARGS` (M4), `TS_POWER_MODE` (M9), `TS_WATCHDOG_ENABLED` (M19),
`TS_KILL_SWITCH` (M16), `TS_SPLIT_TUNNEL_*` (M17), `TS_PROFILE` /
`TS_LOGIN_SERVER` / `TS_HOSTNAME` (M18), `TS_ENABLE_SSH` / `TS_ADVERTISE_ROUTES`
(M14), `TS_THEME` / `TS_JOURNAL_ENABLED` (M15).

**An empty value means "pass nothing", never "pass zero".**

**No `GOMAXPROCS`/`GOGC`/`MSS` knobs here, deliberately.** An earlier draft of this
module tuned the Go runtime from the shell. That was the wrong layer: the plan
fixes economy *inside the daemon* (levers M9 power governor, M10 MTU-derived MSS),
where the value can be measured rather than guessed at.

## Operating it

```sh
M=/data/adb/modules/tethys-tailscaled

tailscale status                            # both binaries are on PATH
tail -f /data/adb/tailscale/log/tailscaled.log
cat /data/adb/tailscale/log/service.log     # supervisor decisions

# stop, and STAY stopped
touch /data/adb/tailscale/stop
kill "$(cat /data/adb/tailscale/tailscaled.pid)"

# start again
rm -f /data/adb/tailscale/stop
sh $M/service.sh
```

`touch /data/adb/tailscale/stop` is the **manual-stop marker** — the only way to
say *stay down*. Without it the supervisor treats an exit as a crash and restarts.

## How the supervisor works

`service.sh` starts the daemon under a supervisor and **returns immediately** — a
boot script that blocks is a boot script that gets killed.

The supervisor waits on the daemon with `wait`, not a polling loop. That is a
deliberate choice for your battery: a supervisor that polled would itself be the
drain, whereas this one wakes only when the daemon actually dies. On a crash it
restarts along the plan's ladder **5 → 15 → 30 → 60 → 120 → 300 s**, holding at
300, so a daemon that dies instantly cannot become a tight restart loop.

## Uninstall

```
daemon stopped.
State kept at /data/adb/tailscale
```

**Removing the module does not delete your tailnet identity.** `tailscaled.state`
is the node key; a silent removal would cost you a re-auth you never asked for.
So the uninstaller stops the daemon, reports the path, and leaves it. To remove
everything, either delete that directory yourself, or create
`/data/adb/tailscale/.purge-on-uninstall` before removing the module.

## Testing

```sh
sh tests/shell-smoke.sh
```

This is not a syntax check. It runs the shell layer against a temporary state
root and asserts what the daemon actually depends on. It has already earned its
place by catching real defects that `sh -n` passed straight through:

1. `tethys.lib.sh`'s predecessor **assigned** its state root instead of
   defaulting it, so it silently ignored any override — the library was
   untestable off-device.
2. The directory list created `bin/` (read by no patch in the series) while
   omitting `certs/` (required by `patches/0012`).
3. The packaged `config.env` **could not pass its own schema**: it documents its
   defaults with trailing `# notes`, and the first classifier never learned to
   strip one, so the template was judged as carrying values like
   `"0"   # adds --ssh`. A template that cannot satisfy its own law is a lie
   shipped to every device, and only a check for exactly that revealed it.

It also proves the §8.3 law rather than assuming it: a config line that *would*
execute if the file were sourced is loaded, and the test asserts the command
never ran.

One check reports **skipped, not passed**: this host cannot assert Unix file
modes, so the `0700` claim on the state root remains **unproven here**. The
device will settle it.

## Packing

Nothing assembles the zip by hand:

```sh
sh tools/pack-module.sh /path/to/tailscaled.arm64 .
```

The packer refuses, loudly, rather than shipping something broken:

- a payload that is not an ELF object, or is not `arm64`;
- a payload that disagrees with the `.sha256` shipped beside it — a mismatch
  means either the binary is not the one that was built or the sidecar is stale,
  and both mean *do not ship it*;
- a tree missing any of the six files a module needs in order to install, or
  carrying a top-level entry the packer has no opinion about — every entry is
  either shipped or acknowledged, because guesswork is how a file goes missing
  from a zip that then fails on someone's device;
- a **red** `tests/shell-smoke.sh`: packing a broken runtime moves that failure
  onto a device, at boot, which is the worst place to learn it;
- anything in `system/` but the two gitignored payload paths, because `system/`
  is *constructed* from the daemon argument rather than copied from the tree.

Then it reads its own output back — `module.prop` at the archive root, no wrapper
directory, the daemon inside, every shipped file present, every withheld entry
absent, and the packed daemon the same length as the one it was given. A packer
that trusts what it wrote ships a wrapper directory one day and finds out on
someone else's phone.

The archive is built by `tools/module-archive.py`, not the `zip` CLI, and that is
a portability decision rather than a taste one: `zip` is installed on GitHub's
runners and **not** on the Windows machine this project is developed on, while
python is on both. One implementation, so the two shores cannot disagree about
entry order, modes, or layout — and every entry carries a fixed timestamp and an
explicit mode, so packing the same tree twice yields byte-identical archives. A
checksum that describes the moment it ran is worth nothing to whoever verifies it
later.

`dist/` is never committed: the payload comes from CI, and the sidecar checksum
only means anything for the exact bytes it was built from.

## Debt, named rather than hidden

1. **`system/bin/tailscaled` is not in this repository, and will not be.** The
   daemon is produced by applying the patch series in `tethys-tailscale-android`
   and building the `arm64` target, and `.github/workflows/build-module.yml`
   takes it from that repository's **release assets** — checking it against the
   `SHA256SUMS` published beside it — then hands it to `tools/pack-module.sh`,
   which gates on this module's own suite before it packs anything.

   So the tooling no longer owes a daemon; the fork's **first release** does.
   Until that tag exists this zip is still not installable — `customize.sh`
   refuses it, by design, because a module whose daemon is absent cannot work.

   The fork is **public**, so this repository's built-in token reads its release
   assets and no secret is required. If it is ever made private that stops being
   true — another private repository cannot be read by this one's token — and a
   classic PAT with `repo` read must then be stored as the `FORK_TOKEN` secret.
   The workflow already prefers that secret when it exists, so the only thing
   that would change is the secret's presence.
2. **Identity keys are still reconciled by hand.** The fork's
   `devices/pixel6pro.env` and this module's `config.env` both name device
   identity (`TETHYS_MATCH_*`), and the two are compared by eye today. Proving
   they agree spans two repositories, so the check needs both trees present —
   owed, and narrowed to exactly this.

   The **build** half is no longer a debt. The fork's workflow sources each device
   profile for the leg it describes and runs `tools/check-device-profile.sh`
   first, which re-derives the NDK version from patch 0001, the CGO decision and
   the arch matrix from the workflow, and the ABI from the profile's own
   `GOARCH` — so drift fails the run instead of shipping a wrong binary.

   The **runtime** half is deliberately *not* wired. Those keys are the daemon's
   specification (plan M9 power governor, M10 MTU-derived MSS), and this module
   tunes no Go runtime from the shell: a knob the daemon owns cannot be measured
   from outside it, so setting it here would be a guess wearing a setting's name.
3. **The panel, the six feature bundles, and the ritual journal do not exist
   yet.** They are M12–M19 of the sealed plan; this module is its M3 skeleton.

## Provenance and licence

The daemon is Tailscale (**BSD-3-Clause**), modified by the Android patch series
recreated in `tethys-tailscale-android`. Those modifications are the work of
**Anas** (@anasfanani) in
Magisk-Tailscale. Every constant this module's defaults rest on is recorded with
its source and a sha256 in that repository's `docs/PROVENANCE.md`.
