#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Post-link rewrite of an arm64 ELF .so: replace every PAC / BTI
HINT instruction with a plain NOP.

Why this exists. NDK 27 ships compiler-rt-builtins (the static
library containing the LSE atomic helpers `__aarch64_*` and the
ifunc resolvers `init_have_lse_atomics` / `__init_cpu_features_*`)
pre-compiled with `-mbranch-protection=standard`, which emits
PACIASP / AUTIASP at function prologue/epilogue and BTI at branch
landings. Per the ARM ARM these are HINT-space encodings that
"unallocated" implementations should treat as NOPs — but the
HiSilicon Kirin 659 (Cortex-A73 + A53, ARMv8.0-A, Linux 4.9) SIGILLs
on them. Since we cannot recompile compiler-rt-builtins from source
without forking the NDK, we strip PAC/BTI from libdazzle.so as a
post-link step.

Trade-off: we lose the PAC return-address protection on chips that
support it. The Dazzle SDK is not a security-sensitive surface (no
network input, no untrusted callers — it runs in-process inside the
host app's sandbox), and the Android linker still applies its own
PROT_RETPOLINE / NX hardening, so the security delta is acceptable.

Patched HINT opcodes (all four-byte little-endian):
    PACIASP  0xD503233F  → NOP 0xD503201F
    PACIBSP  0xD503237F  → NOP
    AUTIASP  0xD50323BF  → NOP
    AUTIBSP  0xD50323FF  → NOP
    BTI c    0xD503245F  → NOP
    BTI j    0xD503249F  → NOP
    BTI jc   0xD50324DF  → NOP

Run:
    python3 strip_pac_bti.py path/to/libdazzle.so
"""

from __future__ import annotations

import sys
from pathlib import Path

NOP = b"\x1f\x20\x03\xd5"  # 0xD503201F little-endian

REPLACEMENTS: dict[bytes, str] = {
    b"\x3f\x23\x03\xd5": "PACIASP",
    b"\x7f\x23\x03\xd5": "PACIBSP",
    b"\xbf\x23\x03\xd5": "AUTIASP",
    b"\xff\x23\x03\xd5": "AUTIBSP",
    b"\x5f\x24\x03\xd5": "BTI c",
    b"\x9f\x24\x03\xd5": "BTI j",
    b"\xdf\x24\x03\xd5": "BTI jc",
}


def patch(path: Path) -> dict[str, int]:
    data = bytearray(path.read_bytes())
    counts: dict[str, int] = {}
    for opcode, name in REPLACEMENTS.items():
        cnt = 0
        offset = 0
        while True:
            idx = data.find(opcode, offset)
            if idx < 0:
                break
            # Only patch if 4-byte aligned (instruction boundary).
            if idx % 4 == 0:
                data[idx:idx + 4] = NOP
                cnt += 1
            offset = idx + 4
        counts[name] = cnt
    path.write_bytes(bytes(data))
    return counts


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    p = Path(sys.argv[1])
    if not p.exists():
        print(f"missing: {p}", file=sys.stderr)
        return 2
    print(f"patching: {p}")
    counts = patch(p)
    total = sum(counts.values())
    for name, n in sorted(counts.items()):
        if n:
            print(f"  {name:<8}: {n}")
    print(f"total: {total} HINT opcodes replaced with NOP")
    return 0


if __name__ == "__main__":
    sys.exit(main())
