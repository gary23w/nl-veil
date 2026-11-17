#!/usr/bin/env python3
"""Reject Linux release binaries that need a glibc newer than Ubuntu 24.04's."""

import argparse
from pathlib import Path
import re
import subprocess

MAX_GLIBC = (2, 39, 0)


def check_binary(path):
    output = subprocess.check_output(["readelf", "--wide", "--version-info", path], text=True)
    versions = re.findall(r"\bName: GLIBC_(\S+)", output)
    required = []
    for version in versions:
        match = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?", version)
        if not match:
            print(f"FAIL {path}: unsupported glibc version {version}")
            return False
        required.append(tuple(int(part or 0) for part in match.groups()))
    newest = max(required, default=(0, 0, 0))
    if newest > MAX_GLIBC:
        print(f"FAIL {path}: needs glibc {'.'.join(map(str, newest))}, expected 2.39 or earlier")
        return False
    print(f"PASS glibc floor: {path}")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binaries", nargs="+", type=Path)
    results = [check_binary(path) for path in parser.parse_args().binaries]
    raise SystemExit(0 if all(results) else 1)
