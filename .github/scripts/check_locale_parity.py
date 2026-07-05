#!/usr/bin/env python3
"""Locale key parity vs Locales/enUS.lua (Artisan Nexus)."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCALES = ROOT / "Locales"
TOC = ROOT / "ArtisanNexus.toc"

KEY_RE = re.compile(r'L\["([^"]+)"\]\s*=')


def keys_in(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return set(KEY_RE.findall(text))


def toc_locales() -> list[str]:
    names = []
    for line in TOC.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("Locales\\") and line.endswith(".lua"):
            names.append(line.split("\\")[-1])
    return names


def main() -> int:
    en = LOCALES / "enUS.lua"
    if not en.is_file():
        print("ERROR: missing enUS.lua")
        return 1
    en_keys = keys_in(en)
    errors = 0
    for name in toc_locales():
        path = LOCALES / name
        if not path.is_file():
            print(f"ERROR: missing {name}")
            errors += 1
            continue
        loc_keys = keys_in(path)
        missing = sorted(en_keys - loc_keys)
        extra = sorted(loc_keys - en_keys)
        if missing:
            errors += 1
            print(f"ERROR {name}: missing {len(missing)} keys (e.g. {missing[:5]})")
        if extra:
            errors += 1
            print(f"ERROR {name}: extra {len(extra)} keys (e.g. {extra[:5]})")
    if errors:
        print(f"\nLocale parity FAILED ({errors} file(s))")
        return 1
    print(f"Locale parity OK ({len(toc_locales())} files, {len(en_keys)} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
