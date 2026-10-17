#!/usr/bin/env python3
"""Re-sync the Warband Nexus UI framework files listed in files.txt into Artisan Nexus.

Usage (from the Artisan Nexus repo root):
    python3 tools/wnsync/wnsync.py --wn ../warband-nexus            # report only
    python3 tools/wnsync/wnsync.py --wn ../warband-nexus --apply    # write the merged files

verbatim files: AN file = wn_transform(WN working-tree file). Reported as "differs" when they drift.
adapted files:  three-way merge (git merge-file) of
                    ours   = the AN file,
                    base   = wn_transform(WN file at the revision in WN_REV),
                    theirs = wn_transform(WN working-tree file),
                so the Artisan Nexus edits are kept and WN's changes come in. Conflicts are left as
                <<<<<<< markers in the written file and listed in the report.
After a successful --apply, write the WN revision you synced from into WN_REV.
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wn_transform import transform  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def read_list():
    out = []
    with open(os.path.join(HERE, "files.txt"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            kind, path = line.split(None, 1)
            out.append((kind, path))
    return out


def read(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)


def wn_at_rev(wn, rev, path):
    res = subprocess.run(["git", "-C", wn, "show", f"{rev}:{path}"], capture_output=True)
    if res.returncode != 0:
        return None
    return res.stdout.decode("utf-8", errors="surrogateescape")


def merge(ours, base, theirs):
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for name, text in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = os.path.join(tmp, name)
            write(p, text)
            paths.append(p)
        res = subprocess.run(["git", "merge-file", "-p", *paths], capture_output=True)
        return res.stdout.decode("utf-8", errors="surrogateescape"), res.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wn", required=True, help="path to the warband-nexus checkout")
    ap.add_argument("--base", help="WN revision the AN copies came from (default: WN_REV)")
    ap.add_argument("--apply", action="store_true", help="write the updated files")
    args = ap.parse_args()
    base_rev = args.base or read(os.path.join(HERE, "WN_REV")).strip()
    problems = 0
    for kind, path in read_list():
        an_path = os.path.join(ROOT, path)
        wn_path = os.path.join(args.wn, path)
        if not os.path.isfile(wn_path):
            print(f"MISSING-IN-WN  {path}")
            problems += 1
            continue
        theirs = transform(read(wn_path))
        ours = read(an_path) if os.path.isfile(an_path) else ""
        if kind == "verbatim":
            if ours == theirs:
                print(f"ok             {path}")
                continue
            print(f"updated        {path}" if args.apply else f"differs        {path}")
            if args.apply:
                write(an_path, theirs)
            continue
        base_src = wn_at_rev(args.wn, base_rev, path)
        if base_src is None:
            print(f"NO-BASE        {path} (not in WN {base_rev}); merge by hand")
            problems += 1
            continue
        base = transform(base_src)
        if base == theirs:
            print(f"ok             {path} (no WN change)")
            continue
        merged, conflicts = merge(ours, base, theirs)
        if conflicts:
            problems += 1
            print(f"CONFLICTS({conflicts})   {path}")
        else:
            print(f"merged         {path}")
        if args.apply:
            write(an_path, merged)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
