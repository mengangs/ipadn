#!/usr/bin/env python3
"""Inspect an IPA: per-Mach-O LC_ENCRYPTION_INFO(_64) state + codesign entitlements.

Host-side verifier for the FairPlay research build; no device needed.

Usage:
  python tools/fp_ipa_check.py path/to/app.ipa            # cryptid report + summary
  python tools/fp_ipa_check.py path/to/app.ipa --entitlements
"""
from __future__ import annotations

import argparse
import plistlib
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_CIGAM = 0xBEBAFECA
FAT_CIGAM_64 = 0xBFBAFECA
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D
CPU_ARCH_ABI64 = 0x01000000


def thin_slices(data: bytes, base: int) -> list[dict]:
    if len(data) < 32:
        return []
    magic, cputype, _sub, _ft, ncmds, sizeofcmds = struct.unpack_from("<IIIIII", data, 0)
    if magic != MH_MAGIC_64:
        return []
    out: list[dict] = []
    pos = 32
    for _ in range(ncmds):
        if pos + 8 > 32 + sizeofcmds or pos + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8:
            break
        if cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64) and pos + 20 <= len(data):
            cryptoff, cryptsize, cryptid = struct.unpack_from("<III", data, pos + 8)
            out.append({"cputype": cputype, "cryptoff": cryptoff,
                        "cryptsize": cryptsize, "cryptid": cryptid})
        if cmd == LC_CODE_SIGNATURE and pos + 16 <= len(data):
            dataoff, datasize = struct.unpack_from("<II", data, pos + 8)
            out.append({"codesig": (dataoff, datasize)})
        pos += cmdsize
    return out


def parse_slices(data: bytes) -> list[dict]:
    if len(data) < 8:
        return []
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == MH_MAGIC_64:
        return thin_slices(data, 0)
    if magic in (FAT_CIGAM, FAT_CIGAM_64):
        is64 = magic == FAT_CIGAM_64
        count = struct.unpack_from(">I", data, 4)[0]
        pos = 8
        out: list[dict] = []
        for _ in range(min(count, 64)):
            if is64:
                if pos + 32 > len(data):
                    break
                _cpu, _sub, offset, _size, _align, _res = struct.unpack_from("<IIQQII", data, pos)
                pos += 32
            else:
                if pos + 20 > len(data):
                    break
                _cpu, _sub, offset, _size, _align = struct.unpack_from("<IIIII", data, pos)
                pos += 20
            out.extend(thin_slices(data[offset:], offset))
        return out
    return []


def entitlement_blob(data: bytes) -> bytes | None:
    """Return the entitlements blob from the code signature (CS_ENTITLEMENTS)."""
    if len(data) < 32:
        return None
    magic, _cpu, _sub, _ft, ncmds, sizeofcmds = struct.unpack_from("<IIIIII", data, 0)
    if magic != MH_MAGIC_64:
        return None
    pos = 32
    cs_off = None
    for _ in range(ncmds):
        if pos + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8:
            break
        if cmd == LC_CODE_SIGNATURE and pos + 16 <= len(data):
            cs_off = struct.unpack_from("<I", data, pos + 8)[0]
        pos += cmdsize
    if cs_off is None or cs_off + 12 > len(data):
        return None
    blob_magic, _length, count = struct.unpack_from(">III", data, cs_off)
    if blob_magic != 0xFADE0CC0:  # CSMAGIC_EMBEDDED_SIGNATURE
        return None
    for index in range(count):
        entry = cs_off + 12 + index * 8
        if entry + 8 > len(data):
            break
        slot, offset = struct.unpack_from(">II", data, entry)
        if slot != 5:  # CS_ENTITLEMENTS
            continue
        blob = cs_off + offset
        if blob + 8 > len(data):
            return None
        what, length = struct.unpack_from(">II", data, blob)
        if what != 0xFADE7171:  # CSMAGIC_EMBEDDED_ENTITLEMENTS
            return None
        return data[blob + 8: blob + length]
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    parser.add_argument("--entitlements", action="store_true", help="also dump embedded entitlements")
    args = parser.parse_args()

    encrypted = 0
    plain = 0
    noinfo = 0
    rows = []
    with zipfile.ZipFile(args.ipa) as archive:
        names = [n for n in archive.namelist() if not n.endswith("/")]
        for name in names:
            info = archive.getinfo(name)
            if info.file_size < 32:
                continue
            with archive.open(name) as handle:
                head = handle.read(1 << 20)
            slices = parse_slices(head)
            macho = [s for s in slices if "cryptid" in s]
            if not macho:
                continue
            states = ", ".join(f"cryptid={s['cryptid']} off=0x{s['cryptoff']:x} size=0x{s['cryptsize']:x}"
                               for s in macho)
            if any(s["cryptid"] for s in macho):
                encrypted += 1
                mark = "ENCRYPTED"
            else:
                plain += 1
                mark = "plain"
            rows.append((mark, name, states, info.file_size))
        for mark, name, states, size in sorted(rows):
            print(f"{mark:9} {name}  {states}  ({size} B)")

        if args.entitlements:
            for name in names:
                if name.endswith(".app/" + args.ipa.split("/")[-1].rsplit(".", 1)[0]) or True:
                    pass
            # entitlements come from the main executable of Payload/*.app
            candidates = [n for n in names if n.count("/") == 2 and n.startswith("Payload/")
                          and n.split("/")[1].endswith(".app")]
            for name in candidates:
                with zipfile.ZipFile(args.ipa) as archive:
                    with archive.open(name) as handle:
                        blob = entitlement_blob(handle.read())
                if blob:
                    try:
                        parsed = plistlib.loads(blob)
                    except Exception as exc:  # noqa: BLE001
                        print(f"entitlements({name}): unparsable ({exc})")
                        continue
                    print(f"entitlements({name}):")
                    for key in sorted(parsed):
                        print(f"  {key} = {parsed[key]}")

    print(f"\nsummary: {plain} plain, {encrypted} encrypted, {len(rows)} Mach-O")
    return 1 if encrypted else 0


if __name__ == "__main__":
    sys.exit(main())
