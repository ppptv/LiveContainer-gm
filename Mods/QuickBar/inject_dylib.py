#!/usr/bin/env python3
"""Insert LC_LOAD_WEAK_DYLIB commands into an arm64 Mach-O, in-place.

Usage: inject_dylib.py <macho> <dylib-path> [dylib-path ...]

Multiple paths can be given. dyld loads the first one that actually resolves;
missing paths are silently ignored because these are WEAK dylib commands. This
is used to cover both @loader_path and @executable_path bases for QuickBar.

Commands are written into the padding gap between the load-command region and
the first section, so no existing bytes are shifted.

IMPORTANT constant note (this was the original bug):
    LC_LOAD_WEAK_DYLIB = 0x80000018   # (LC_REQ_DYLD | 0x18)
    LC_RPATH           = 0x8000001C   # (LC_REQ_DYLD | 0x1C)  <-- WRONG ONE

The previous version used 0x8000001C, which silently registered the path as
an rpath instead of loading the dylib. This version removes any trailing stale
LC_RPATH / LC_LOAD_WEAK_DYLIB carrying one of the given paths, so it is
idempotent and self-healing.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_RPATH = 0x8000001C
MH_MAGIC_64 = 0xFEEDFACF


def align8(n):
    return (n + 7) & ~7


def lc_path(data, off):
    """Return the path string of a dylib/rpath load command at `off`."""
    name_off = struct.unpack_from("<I", data, off + 8)[0]
    start = off + name_off
    end = data.index(0, start)
    return bytes(data[start:end]).decode("utf-8", "replace")


def build_weak_cmd(dep):
    dep_b = dep.encode()
    needed = align8(len(dep_b) + 1)
    cmdsize = 24 + needed
    cmd = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 0, 0, 0)
    cmd += dep_b + b"\0" * (needed - len(dep_b))
    assert len(cmd) == cmdsize
    return cmd, cmdsize


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: inject_dylib.py <macho> <dylib-path> [dylib-path ...]")
    path = sys.argv[1]
    deps = sys.argv[2:]
    data = bytearray(open(path, "rb").read())
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        sys.exit(f"not a 64-bit Mach-O: {hex(magic)}")

    ncmds = struct.unpack_from("<I", data, 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, 20)[0]

    # Enumerate all load commands.
    lcs = []
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", data, off)
        lcs.append((off, cmd, sz))
        off += sz

    # Remove trailing stale commands with any of the given paths (self-heal the
    # previous LC_RPATH bug and make re-injection idempotent).
    healed = []
    while lcs:
        off, cmd, sz = lcs[-1]
        if cmd in (LC_RPATH, LC_LOAD_WEAK_DYLIB):
            try:
                stale = lc_path(data, off) in deps
            except Exception:
                stale = False
            if stale:
                healed.append("LC_RPATH" if cmd == LC_RPATH else "LC_LOAD_WEAK_DYLIB")
                lcs.pop()
                ncmds -= 1
                sizeofcmds -= sz
                struct.pack_into("<I", data, 16, ncmds)
                struct.pack_into("<I", data, 20, sizeofcmds)
                continue
        break
    if healed:
        print("removed stale trailing command(s): " + ", ".join(healed))

    # Find first section offset across all segments.
    def first_section_offset():
        first = None
        off = 32
        for _ in range(ncmds):
            cmd, sz = struct.unpack_from("<II", data, off)
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack_from("<I", data, off + 64)[0]
                so = off + 72
                for _ in range(nsects):
                    sec_off = struct.unpack_from("<I", data, so + 48)[0]
                    if sec_off and (first is None or sec_off < first):
                        first = sec_off
                    so += 80
            off += sz
        return first

    # Inject each dependency in order.
    for dep in deps:
        first_section = first_section_offset()
        lc_end = 32 + sizeofcmds
        cmd, cmdsize = build_weak_cmd(dep)
        if first_section is None or lc_end + cmdsize > first_section:
            sys.exit("not enough padding between load commands and first section")
        data[lc_end:lc_end + cmdsize] = cmd
        struct.pack_into("<I", data, 16, ncmds + 1)
        struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)
        print(f"  injected 0x{LC_LOAD_WEAK_DYLIB:x} {dep} (+{cmdsize}B)")
        ncmds += 1
        sizeofcmds += cmdsize

    open(path, "wb").write(data)
    print(f"done: ncmds={ncmds}, sizeofcmds={sizeofcmds}")


if __name__ == "__main__":
    main()
