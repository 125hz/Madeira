#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parents[1]
ship_arm64ec = root / "app" / "Madeira" / "arm64ec-windows"
ship_i386 = root / "app" / "Madeira" / "i386-windows"

VCRT_DLLS = {
    "vcruntime140.dll", "vcruntime140_1.dll", "vcruntime140_threads.dll",
    "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll",
    "vcomp140.dll", "vcamp140.dll", "vccorlib140.dll", "concrt140.dll",
    "mfc140.dll", "mfc140u.dll",
    "msvcr120.dll", "msvcp120.dll", "msvcr110.dll", "msvcp110.dll",
    "msvcr100.dll", "msvcp100.dll"
}


def parse_pe_imports(bin_path):
    with open(bin_path, "rb") as f:
        data = f.read()

    if len(data) < 64:
        return None, []

    pe_offset = struct.unpack_from("<I", data, 0x3c)[0]
    if pe_offset + 24 > len(data) or data[pe_offset:pe_offset + 4] != b"PE\x00\x00":
        return None, []

    machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
    num_sections = struct.unpack_from("<H", data, pe_offset + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    opt_offset = pe_offset + 24
    if opt_offset + 2 > len(data):
        return machine, []

    magic = struct.unpack_from("<H", data, opt_offset)[0]

    # Standard imports
    import_dir_offset = opt_offset + (120 if magic == 0x20b else 104)
    import_rva, import_sz = 0, 0
    if import_dir_offset + 8 <= opt_offset + opt_size:
        import_rva, import_sz = struct.unpack_from("<II", data, import_dir_offset)

    # Delay-load imports (DataDirectory[13])
    delay_dir_offset = opt_offset + (200 if magic == 0x20b else 184)
    delay_rva, delay_sz = 0, 0
    if delay_dir_offset + 8 <= opt_offset + opt_size:
        delay_rva, delay_sz = struct.unpack_from("<II", data, delay_dir_offset)

    sec_start = opt_offset + opt_size
    sections = []
    for i in range(num_sections):
        sec = data[sec_start + i * 40:sec_start + (i + 1) * 40]
        if len(sec) < 20:
            break
        vsize, vrva, rsize, roff = struct.unpack_from("<IIII", sec, 8)
        sections.append((vrva, vsize, roff, rsize))

    def rva2off(r):
        for vrva, vsize, roff, rsize in sections:
            if vrva <= r < vrva + max(vsize, rsize):
                return roff + (r - vrva)
        return None

    dlls = []

    # Read standard imports
    if import_rva:
        desc_off = rva2off(import_rva)
        while desc_off and desc_off + 20 <= len(data):
            entry = data[desc_off:desc_off + 20]
            if not entry or entry == b"\x00" * 20:
                break
            name_rva = struct.unpack_from("<I", entry, 12)[0]
            name_off = rva2off(name_rva)
            if name_off:
                end_off = data.find(b"\x00", name_off)
                if end_off != -1:
                    dlls.append(data[name_off:end_off].decode("latin1", errors="ignore"))
            desc_off += 20

    # Read delay-load imports
    if delay_rva:
        desc_off = rva2off(delay_rva)
        while desc_off and desc_off + 32 <= len(data):
            entry = data[desc_off:desc_off + 32]
            if not entry or entry == b"\x00" * 32:
                break
            name_rva = struct.unpack_from("<I", entry, 4)[0]
            if not name_rva:
                break
            name_off = rva2off(name_rva)
            if name_off:
                end_off = data.find(b"\x00", name_off)
                if end_off != -1:
                    dlls.append(data[name_off:end_off].decode("latin1", errors="ignore"))
            desc_off += 32

    return machine, sorted(set(dlls), key=lambda x: x.lower())


def main():
    p = argparse.ArgumentParser(description="Check game exe dll dependencies")
    p.add_argument("binary", help="Path to Windows EXE or DLL")
    p.add_argument("--ship-dir", default=None, help="Directory of shipped DLLs")
    args = p.parse_args()

    bin_path = Path(args.binary)
    if not bin_path.exists():
        print(f"error: file not found: {bin_path}", file=sys.stderr)
        return 1

    machine, deps = parse_pe_imports(bin_path)
    if not deps:
        print(f"no imports found in {bin_path.name}")
        return 0

    is_i386 = (machine == 0x014c)
    arch_name = "i386 (32-bit)" if is_i386 else "x64/arm64ec"
    target_ship = Path(args.ship_dir) if args.ship_dir else (ship_i386 if is_i386 else ship_arm64ec)

    shipped = set()
    if target_ship.exists():
        shipped = {f.name.lower() for f in target_ship.glob("*.dll")}

    print(f"Dependencies for {bin_path.name} [{arch_name}] ({len(deps)} total):")
    missing = 0
    for d in deps:
        d_lower = d.lower()
        if (d_lower in shipped) or d_lower.startswith("api-ms-win-") or d_lower.startswith("ext-ms-win-"):
            tag = "OK     "
            note = ""
        elif d_lower in VCRT_DLLS:
            tag = "PREFIX "
            note = " (installed into prefix at runtime)"
        else:
            tag = "MISSING"
            note = ""
            missing += 1
        print(f"  [{tag}] {d}{note}")

    if missing:
        print(f"\nWarning: {missing} DLLs missing from shipped bundle.")
    else:
        print("\nAll dependencies satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
