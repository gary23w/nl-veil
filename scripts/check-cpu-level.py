#!/usr/bin/env python3
"""Refuse an x86-64 release binary that uses instructions beyond its CPU level.

v1.1.26 and v1.1.27 shipped a veil compiled for the CI runner's own CPU, AVX-512 included, and it
crashed before opening a window on every machine without AVX-512. This disassembles each binary and
fails when it finds:
  baseline  any VEX or EVEX instruction (AVX, AVX2, FMA, AVX-512) or BMI1/BMI2/LZCNT/MOVBE
  avx2      any AVX-512 instruction (zmm or opmask registers, xmm16-31/ymm16-31, embedded broadcast)

It is for the Zig-built veil binaries. A static scan cannot tell code a program only runs after checking
the CPU from code it always runs: the Rust neuron engine (built for the baseline CPU) carries a few such
run-time-selected instructions and would fail here.
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

LINE = re.compile(r"^\s*[0-9a-f]+:\s+(\S+)\s*(.*)$")
EVEX = re.compile(r"%zmm\d|%k[0-7]\b|%[xy]mm(?:1[6-9]|2\d|3[01])\b|\{1to\d+\}")
PREFIXES = {"rep", "repe", "repz", "repne", "repnz", "lock", "data16", "data32", "addr32", "notrack", "bnd",
            "cs", "ds", "es", "fs", "gs", "ss", "{vex}", "{vex3}", "{evex}", "rex", "rex.w"}
# Mnemonics starting with "v" that are not VEX: segment verification and the VMX/SVM instructions.
NOT_VEX = {"verr", "verw", "vmcall", "vmclear", "vmfunc", "vmlaunch", "vmload", "vmmcall", "vmptrld", "vmptrst",
           "vmread", "vmresume", "vmrun", "vmsave", "vmwrite", "vmxoff", "vmxon"}
# Beyond the x86-64 baseline without VEX. TZCNT is absent on purpose: compilers emit it for baseline
# because older CPUs execute the same bytes as BSF.
BMI = {"andn", "bextr", "blsi", "blsmsk", "blsr", "bzhi", "lzcnt", "movbe", "mulx", "pdep", "pext", "rorx",
       "sarx", "shlx", "shrx"}


def disassemblers():
    found = [os.environ.get("OBJDUMP"), shutil.which("llvm-objdump")]
    found += sorted(glob.glob("/usr/lib/llvm-*/bin/llvm-objdump"), reverse=True)
    found += [shutil.which("objdump"), r"C:\Program Files\LLVM\bin\llvm-objdump.exe", r"C:\mingw64\bin\objdump.exe",
              r"C:\Strawberry\c\bin\objdump.exe"]
    tools = []
    for tool in found:
        if tool and Path(tool).is_file() and tool not in tools:
            tools.append(tool)
    if not tools:
        raise SystemExit("FAIL no disassembler found (set OBJDUMP=<llvm-objdump or objdump>)")
    return tools


def violation(level, mnemonic, operands):
    if EVEX.search(operands):
        return "AVX-512"
    if level == "baseline":
        if mnemonic.startswith("v") and mnemonic not in NOT_VEX:
            return "AVX"
        # llvm-objdump spells these with the AT&T size suffix (shlxq, andnl), GNU objdump without it
        if mnemonic in BMI or (mnemonic[-1:] in ("b", "w", "l", "q") and mnemonic[:-1] in BMI):
            return "BMI/LZCNT/MOVBE"
    return None


def scan(tool, level, path):
    """(instructions, {kind: count}, examples), or None when this tool cannot disassemble the file."""
    proc = subprocess.Popen([tool, "-d", "--no-show-raw-insn", str(path)], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, errors="replace")
    total = 0
    counts = {}
    examples = []
    for line in proc.stdout:
        m = LINE.match(line)
        if not m:
            continue
        words = (m.group(1) + " " + m.group(2)).split(None, 1)
        while words and words[0].lower() in PREFIXES:
            words = words[1].split(None, 1) if len(words) > 1 else []
        if not words:
            continue
        mnemonic = words[0].lower()
        operands = words[1] if len(words) > 1 else ""
        total += 1
        kind = violation(level, mnemonic, operands)
        if kind:
            counts[kind] = counts.get(kind, 0) + 1
            if len(examples) < 5:
                examples.append(line.strip())
    if proc.wait() != 0 or total < 1000:
        return None
    return total, counts, examples


def check(tools, level, path):
    for tool in tools:
        result = scan(tool, level, path)
        if result:
            break
    else:
        raise SystemExit(f"FAIL could not disassemble {path} with any of: {', '.join(tools)}")
    total, counts, examples = result
    if counts:
        print(f"FAIL {path.name}: {total} instructions, beyond {level}: "
              + ", ".join(f"{n} {k}" for k, n in sorted(counts.items())))
        for example in examples:
            print(f"    {example}")
        return False
    print(f"PASS CPU level {level}: {path.name} ({total} instructions, {Path(tool).name})")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--level", choices=("baseline", "avx2"), required=True)
    parser.add_argument("binaries", nargs="+", type=Path)
    args = parser.parse_args()
    tools = disassemblers()
    results = [check(tools, args.level, path) for path in args.binaries]
    sys.exit(0 if all(results) else 1)
