#!/usr/bin/env python3
"""Mechanical WN -> AN rename rules for copied Warband Nexus UI files.
Usage: wn_transform.py SRC DST
Rules (applied to code and string literals only; comments are left untouched):
  R1  _G.WarbandNexus or ns.WarbandNexus   -> ns.ArtisanNexus      (addon object; WN's global would be WN's own db)
  R2  rawget(_G, "WarbandNexus")           -> ns.ArtisanNexus
  R3  ns.WarbandNexus                      -> ns.ArtisanNexus
  R4  _G.WarbandNexus<Name>                -> _G.ArtisanNexus<Name> (global frame names)
  R4b _G.WarbandNexus (bare)               -> ns.ArtisanNexus
  R5  "...WarbandNexus..." in strings      -> "...ArtisanNexus..."  (frame names, media paths Interface\\AddOns\\WarbandNexus\\)
"""
import re, sys

def tokenize(src):
    """Yield (kind, text) with kind in code|string|comment."""
    i, n = 0, len(src)
    buf = []
    out = []
    def flush():
        if buf:
            out.append(("code", "".join(buf)))
            buf.clear()
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            flush()
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            out.append(("comment", src[i:j])); i = j; continue
        m = re.match(r"\[(=*)\[", src[i:]) if c == "[" else None
        if m:
            flush()
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(("string", src[i:j])); i = j; continue
        if c in "\"'":
            flush()
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\": j += 2
                elif src[j] == "\n": break
                else: j += 1
            j = min(j + 1, n)
            out.append(("string", src[i:j])); i = j; continue
        buf.append(c); i += 1
    flush()
    return out

def transform(src):
    toks = tokenize(src)
    res = []
    for kind, t in toks:
        if kind == "code":
            t = re.sub(r"_G\.WarbandNexus\s+or\s+ns\.WarbandNexus\b", "ns.ArtisanNexus", t)
            t = re.sub(r"\bns\.WarbandNexus\b", "ns.ArtisanNexus", t)
            t = re.sub(r"_G\.WarbandNexus(\w+)", r"_G.ArtisanNexus\1", t)
            t = re.sub(r"_G\.WarbandNexus\b", "ns.ArtisanNexus", t)
        elif kind == "string":
            t = t.replace("WarbandNexus", "ArtisanNexus")
        res.append(t)
    out = "".join(res)
    # R2 spans code+string tokens
    out = re.sub(r'rawget\(_G,\s*"ArtisanNexus"\)', "ns.ArtisanNexus", out)
    return out

if __name__ == "__main__":
    s = open(sys.argv[1], encoding="utf-8", errors="surrogateescape").read()
    open(sys.argv[2], "w", encoding="utf-8", errors="surrogateescape").write(transform(s))
