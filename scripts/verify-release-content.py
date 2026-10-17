#!/usr/bin/env python3
"""Verify the deliberate contents of an official portable application bundle."""
import argparse
from pathlib import Path, PurePosixPath
import stat
import tarfile
import zipfile


def verify_bundle(path):
    seen = set()
    roots = set()
    files = {}
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if entry.filename.rstrip("/") in seen:
                    raise ValueError("Bundle contains a duplicate member")
                if stat.S_ISLNK(entry.external_attr >> 16):
                    raise ValueError("Bundle contains a symbolic link")
                if not entry.is_dir():
                    files[entry.filename] = entry.file_size
                seen.add(entry.filename.rstrip("/"))
    else:
        with tarfile.open(path) as archive:
            for entry in archive:
                if entry.name.rstrip("/") in seen:
                    raise ValueError("Bundle contains a duplicate member")
                if not (entry.isfile() or entry.isdir()):
                    raise ValueError("Bundle contains a non-regular member")
                if entry.isfile():
                    files[entry.name] = entry.size
                seen.add(entry.name.rstrip("/"))
    for name in seen:
        member = PurePosixPath(name)
        if member.is_absolute() or ".." in member.parts or "\\" in name or ":" in name:
            raise ValueError("Bundle contains an unsafe path")
        roots.add(member.parts[0])
    if len(roots) != 1:
        raise ValueError("Bundle must have exactly one installation directory")
    root = roots.pop()
    windows = "windows-" in root
    suffix = ".exe" if windows else ""
    required = {"veil" + suffix, "bin/neuron" + suffix, "veil-install.txt", "LICENSE", "README.txt", "start", "start.cmd"}
    allowed = {root, root + "/bin"} | {root + "/" + name for name in required}
    if seen - allowed:
        raise ValueError("Bundle contains unexpected files or directories")
    if set(files) != {root + "/" + name for name in required}:
        raise ValueError("Bundle is missing required application files")
    if any(size <= 0 for size in files.values()):
        raise ValueError("Bundle contains an empty required file")
    print(f"PASS package contents: {Path(path).name} ({len(files)} deliberate files)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundles", nargs="+", type=Path)
    for bundle in parser.parse_args().bundles:
        verify_bundle(bundle)
