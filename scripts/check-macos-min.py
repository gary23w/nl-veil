#!/usr/bin/env python3
"""Refuse a macOS release binary that asks for a newer macOS than the release supports.

A native Zig build records the build machine's macOS as the oldest version the binary runs on: the
v1.1.28 Mac apps asked for 15.8.2 (Apple silicon) and 15.7.9 (Intel) only because that is what the CI
runners had. build.zig now sets macOS 13.0 for Mac builds; this reads the minimum each Mach-O file
records (LC_BUILD_VERSION minos, or LC_VERSION_MIN_MACOSX on older binaries) and fails when it is above
--max. A directory argument checks every Mach-O file in it, so a whole bundle (veil and neuron) is one
argument. Pure Python: no otool or llvm-objdump needed, so it runs on any runner.
"""
import argparse
import struct
import sys
from pathlib import Path

LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1
THIN = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">", b"\xce\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xce": ">"}
FAT = {b"\xca\xfe\xba\xbe": 20, b"\xca\xfe\xba\xbf": 32}  # fat_arch / fat_arch_64 entry sizes


def version(packed):
    return (packed >> 16, (packed >> 8) & 0xFF, packed & 0xFF)


def text(v):
    return ".".join(str(n) for n in v)


def thin_minimum(data, base):
    """The macOS minimum one thin Mach-O image records, or None when it records none."""
    end = THIN[data[base:base + 4]]
    ncmds = struct.unpack_from(end + "I", data, base + 16)[0]
    at = base + (32 if data[base:base + 4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf") else 28)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(end + "II", data, at)
        if cmd == LC_BUILD_VERSION:
            platform, minos = struct.unpack_from(end + "II", data, at + 8)
            if platform == PLATFORM_MACOS:
                return version(minos)
        elif cmd == LC_VERSION_MIN_MACOSX:
            return version(struct.unpack_from(end + "I", data, at + 8)[0])
        at += size
    return None


def minimums(path):
    """Every macOS minimum the file records (one per image of a universal binary); None if not Mach-O."""
    data = path.read_bytes()
    magic = data[:4]
    if magic in THIN:
        return [thin_minimum(data, 0)]
    if magic in FAT:
        count = struct.unpack_from(">I", data, 4)[0]
        # Java class files share CAFEBABE; a universal binary never has more than a handful of images.
        if count == 0 or count > 16:
            return None
        found = []
        for i in range(count):
            entry = 8 + i * FAT[magic]
            offset = struct.unpack_from(">Q" if FAT[magic] == 32 else ">I", data, entry + 8)[0]
            found.append(thin_minimum(data, offset))
        return found
    return None


def check(path, ceiling):
    found = minimums(path)
    if found is None:
        return None
    if any(v is None for v in found):
        print(f"FAIL {path.name}: records no macOS minimum")
        return False
    worst = max(found)
    if worst > ceiling:
        print(f"FAIL {path.name}: asks for macOS {text(worst)}, above {text(ceiling)}")
        return False
    print(f"PASS macOS minimum {text(worst)}: {path.name}")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max", required=True, help="the newest macOS minimum allowed, e.g. 13.0")
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    ceiling = tuple(int(n) for n in (args.max.split(".") + ["0", "0"])[:3])
    results = []
    for path in args.paths:
        if path.is_dir():
            found = [r for f in sorted(path.rglob("*")) if f.is_file() and not f.is_symlink()
                     for r in [check(f, ceiling)] if r is not None]
            if not found:
                print(f"FAIL {path}: no Mach-O files in it")
                found = [False]
            results += found
        else:
            result = check(path, ceiling)
            if result is None:
                print(f"FAIL {path.name}: not a Mach-O file")
                result = False
            results.append(result)
    sys.exit(0 if all(results) else 1)
