#!/usr/bin/env python3
"""Tethys · archive mechanics for the module packer.

Four operations, all driven by tools/pack-module.sh:

    module-archive.py build  <stage-dir> <out.zip> <entry> [entry...]
    module-archive.py list   <archive.zip>          # one entry name per line
    module-archive.py size   <archive.zip> <name>   # uncompressed bytes
    module-archive.py sha256 <file>                 # lowercase hex digest

WHY THIS FILE EXISTS
--------------------
The archive must be buildable on the Windows shore that owns this project AND on
GitHub's Linux runners, and the `zip` CLI is installed on only one of them.
Measured on this shore (2026-09-23): zip ABSENT, unzip present, python present.
python3 is present on both, so the archive step speaks ONE implementation rather
than two that can quietly disagree about entry order, modes, or layout.

WHY IT IS REPRODUCIBLE
----------------------
Every entry is written with a fixed timestamp and an explicit mode, so packing
the same tree twice yields byte-identical archives. That is not a flourish: the
checksum published beside the zip is worth something only if it describes the
build rather than the moment it happened to run.

WHY IT ALSO HASHES
------------------
The packer needs a sha256 to witness both the payload it was handed and the
artifact it produced. Reaching for sha256sum/shasum would add a dependency whose
presence differs per host - measured here, `sha256sum` resolves through the
interactive shell and is not a dependable child of a script - so the digest lives
beside the archive, in hashlib, on both shores.
"""
import hashlib
import os
import stat
import sys
import zipfile

FIXED_TIME = (1980, 1, 1, 0, 0, 0)  # the zip epoch - any fixed value will do


def _entries(stage, names):
    """Every file under the named entries, in a deterministic order."""
    paths = []
    for name in names:
        target = os.path.join(stage, name)
        if os.path.isdir(target):
            for dirpath, dirnames, filenames in os.walk(target):
                dirnames.sort()
                for filename in sorted(filenames):
                    full = os.path.join(dirpath, filename)
                    paths.append(os.path.relpath(full, stage))
        elif os.path.isfile(target):
            paths.append(name)
        else:
            sys.exit("entry not found in the staging tree: %s" % name)
    return sorted(paths)


def build(stage, out, names):
    """Write the archive with root-level entries and stable metadata."""
    paths = _entries(stage, names)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for rel in paths:
            source = os.path.join(stage, rel)
            info = zipfile.ZipInfo(rel.replace(os.sep, "/"), FIXED_TIME)
            mode = stat.S_IMODE(os.stat(source).st_mode)
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(source, "rb") as handle:
                archive.writestr(info, handle.read())
    return paths


def listing(path):
    with zipfile.ZipFile(path) as archive:
        return [info.filename for info in archive.infolist()]


def size(path, name):
    with zipfile.ZipFile(path) as archive:
        try:
            info = archive.getinfo(name)
        except KeyError:
            sys.exit("no such entry in the archive: %s" % name)
    return info.file_size


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    op, rest = argv[1], argv[2:]
    if op == "build":
        if len(rest) < 3:
            sys.exit("usage: module-archive.py build <stage-dir> <out.zip> <entry> [entry...]")
        build(rest[0], rest[1], rest[2:])
    elif op == "list":
        print("\n".join(listing(rest[0])))
    elif op == "size":
        if len(rest) < 2:
            sys.exit("usage: module-archive.py size <archive.zip> <name>")
        print(size(rest[0], rest[1]))
    elif op == "sha256":
        print(digest(rest[0]))
    else:
        sys.exit("unknown operation: %s" % op)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
