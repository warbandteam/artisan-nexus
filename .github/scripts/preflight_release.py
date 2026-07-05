#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pre-release gate: locale parity, version sync, changelog keys.

Run from repo root:  python .github/scripts/preflight_release.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCALES = ROOT / "Locales"
CONSTANTS = ROOT / "Modules" / "Constants.lua"
TOC = ROOT / "ArtisanNexus.toc"
CHANGELOG = ROOT / "CHANGELOG.md"

TOC_LOCALE_NAMES = {
    "deDE.lua",
    "enUS.lua",
    "esES.lua",
    "esMX.lua",
    "frFR.lua",
    "itIT.lua",
    "koKR.lua",
    "ptBR.lua",
    "ruRU.lua",
    "zhCN.lua",
    "zhTW.lua",
}


def keys_from_locale(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return set(re.findall(r'L\["([^"]+)"\]\s*=', text))


def locale_syntax_errors(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    errors: list[str] = []
    if re.search(r'^"\] = ', text, re.M):
        errors.append("orphan \"] = \" line (broken CHANGELOG removal)")
    if re.search(r'^L\["L\[', text, re.M):
        errors.append('nested L["L[" locale key')
    return errors


def read_version_from_constants() -> str | None:
    text = CONSTANTS.read_text(encoding="utf-8")
    m = re.search(r'ADDON_VERSION\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else None


def read_version_from_toc() -> str | None:
    text = TOC.read_text(encoding="utf-8")
    m = re.search(r"(?m)^## Version:\s*(.+)\s*$", text)
    return m.group(1).strip() if m else None


def changelog_key_for_version(version: str) -> str | None:
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", version)
    if not m:
        return None
    return "CHANGELOG_V" + m.group(1) + m.group(2) + m.group(3)


def main() -> int:
    errors: list[str] = []

    en_path = LOCALES / "enUS.lua"
    if not en_path.is_file():
        errors.append("Locales/enUS.lua missing")
        _report(errors)
        return 1

    en_keys = keys_from_locale(en_path)

    for name in sorted(TOC_LOCALE_NAMES):
        path = LOCALES / name
        if not path.is_file():
            errors.append(f"Missing locale file: {name}")
            continue
        for msg in locale_syntax_errors(path):
            errors.append(f"{name}: {msg}")
        loc_keys = keys_from_locale(path)
        missing = en_keys - loc_keys
        extra = loc_keys - en_keys
        if missing:
            sample = ", ".join(sorted(missing)[:8])
            suffix = f" (+{len(missing) - 8} more)" if len(missing) > 8 else ""
            errors.append(f"{name}: {len(missing)} keys missing vs enUS (e.g. {sample}{suffix})")
        if extra:
            errors.append(f"{name}: {len(extra)} extra keys not in enUS")

    const_ver = read_version_from_constants()
    toc_ver = read_version_from_toc()
    if not const_ver:
        errors.append("Could not parse ADDON_VERSION from Modules/Constants.lua")
    if not toc_ver:
        errors.append("Could not parse ## Version from ArtisanNexus.toc")
    if const_ver and toc_ver and const_ver != toc_ver:
        errors.append(f"Version mismatch: Constants={const_ver!r} TOC={toc_ver!r}")

    version = const_ver or toc_ver
    if version:
        ck = changelog_key_for_version(version)
        if not ck:
            errors.append(f"Could not derive CHANGELOG key from version {version!r}")
        else:
            for name in sorted(TOC_LOCALE_NAMES):
                path = LOCALES / name
                if path.is_file() and ck not in keys_from_locale(path):
                    errors.append(f"{name}: missing {ck} for version {version}")
            if CHANGELOG.is_file():
                cl = CHANGELOG.read_text(encoding="utf-8")
                numeric = re.match(r"^[\d.]+", version)
                base = numeric.group(0) if numeric else version
                if not re.search(rf"(?m)^## v{re.escape(base)}\b", cl):
                    errors.append(f"CHANGELOG.md has no ## v{base} section for current version")
            else:
                errors.append("CHANGELOG.md missing at repo root")

    parity = subprocess.run(
        [sys.executable, str(ROOT / ".github" / "scripts" / "check_locale_parity.py")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if parity.returncode != 0:
        errors.append("Locale parity script failed")
        if parity.stdout:
            errors.extend(parity.stdout.strip().splitlines()[-3:])
        if parity.stderr:
            errors.extend(parity.stderr.strip().splitlines()[-3:])

    _report(errors)
    return 1 if errors else 0


def _report(errors: list[str]) -> None:
    if errors:
        print("\nPreflight FAILED:")
        for e in errors:
            print(f"  ERROR: {e}")
    else:
        print("\nPreflight OK - locale parity, version sync, and changelog keys passed.")


if __name__ == "__main__":
    sys.exit(main())
