#!/usr/bin/env python3
"""Compare generated catalog (dbg.json) against harvested schematics (gt.json)."""
import json, sys, collections
gt = json.load(open(sys.argv[1]))
dbg = json.load(open(sys.argv[2]))
basic, output = dbg["basic"], dbg["output"]
names = dbg["names"]
cats = collections.defaultdict(list)
okb = oko = nb = no = 0
for s, v in gt.items():
    rg = v.get("reagents") or []
    if isinstance(rg, dict):
        rg = list(rg.values())
    # ground truth basic: group by (dataSlotType, dataSlotIndex)
    slots = collections.OrderedDict()
    for r in rg:
        if r.get("slotType") != 1:
            continue
        slots.setdefault((r.get("dataSlotType"), r.get("dataSlotIndex")), (r["qty"], []))[1].append(r["itemID"])
    g = sorted((q, tuple(sorted(i))) for q, i in slots.values())
    m = sorted((q, tuple(sorted(i))) for q, i in basic.get(s, []))
    if rg or basic.get(s):
        nb += 1
        if g == m:
            okb += 1
        else:
            gi = {x for _, i in g for x in i}; mi = {x for _, i in m for x in i}
            if gi == mi:
                cats["basic: qty/grouping differs"].append((s, v.get("name"), g, m))
            elif not g:
                cats["basic: GT empty, catalog has reagents"].append((s, v.get("name"), g, m))
            elif not m:
                cats["basic: catalog empty"].append((s, v.get("name"), g, m))
            else:
                cats["basic: item set differs"].append((s, v.get("name"), sorted(gi - mi), sorted(mi - gi)))
    gq = list(v.get("qualityItemIDs") or [])
    go = (v.get("output") or {}).get("itemID")
    gset = set(gq) | ({go} if go else set())
    mset = set(output.get(s, []))
    if gset or mset:
        no += 1
        if gset == mset:
            oko += 1
        elif not gset:
            cats["output: GT has no item, catalog has"].append((s, v.get("name"), [], sorted(mset)))
        elif gset <= mset or mset <= gset:
            cats["output: subset"].append((s, v.get("name"), sorted(gset), sorted(mset)))
        else:
            cats["output: differs"].append((s, v.get("name"), sorted(gset), sorted(mset)))
print("GT recipes:", len(gt))
print("basic compared %d match %d (%.1f%%)" % (nb, okb, 100.0 * okb / max(nb, 1)))
print("output compared %d match %d (%.1f%%)" % (no, oko, 100.0 * oko / max(no, 1)))
for k, l in cats.items():
    print("==", k, len(l))
    for e in l[:6]:
        print("   ", e)
