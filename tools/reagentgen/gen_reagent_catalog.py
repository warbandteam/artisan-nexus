#!/usr/bin/env python3
"""Generate Modules/Data/MidnightReagentCatalog.lua from wago.tools DB2 CSVs.

Usage: python3 -I gen_reagent_catalog.py <csv_dir> <mid.json> <out.lua> [<debug.json>]
  mid.json = {"spellID": "Profession", ...} dumped from MidnightRecipeCatalog.lua

Join logic
  basic (SpellReagents)            : Reagent_n / ReagentCount_n (single-item basic slots)
  basic (ModifiedCraftingSpellSlot): SpellID -> ModifiedCraftingReagentSlotID (ReagentType=1)
                                     -> MCRSlotXMCRCategory -> CraftingReagentQuality
                                        (ItemID ordered by OrderIndex = quality rank low->high)
  finishing/modifying (Type 0/2)   : same slot chain -> category -> CraftingReagentQuality items
                                     + ModifiedCraftingReagentItem(category) <- ModifiedCraftingItem.ItemID
  output                           : SpellEffect Effect 288 (CRAFT_ITEM) MiscValue_0 = CraftingDataID
                                     -> CraftingDataItemQuality (sorted by Item.CraftingQualityID) / CraftingData.CraftedItemID
                                     / CraftingDataEnchantQuality.ItemID ; fallback SpellEffect Effect 24/296 EffectItemType
"""
import csv, json, sys, collections, datetime, os

BUILD = "12.1.5.70448"
d, midp, outp = sys.argv[1], sys.argv[2], sys.argv[3]
dbg = sys.argv[4] if len(sys.argv) > 4 else None


def rows(name):
    with open(os.path.join(d, name + ".csv"), newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)


I = int
mid = {I(k): v for k, v in json.load(open(midp)).items()}
spells = set(mid)

# Items: names + bonding (for "tradeable" filter on finishing candidates)
item_name, item_bind = {}, {}
for r in rows("ItemSparse"):
    i = I(r["ID"])
    item_name[i] = r["Display_lang"]
    item_bind[i] = I(r["Bonding"])

# Item.CraftingQualityID = quality rank of crafted/reagent quality variants (13 = rank 1, 14 = rank 2, ...)
item_cq = {I(r["ID"]): I(r["CraftingQualityID"]) for r in rows("Item")}

slot_type = {I(r["ID"]): I(r["ReagentType"]) for r in rows("ModifiedCraftingReagentSlot")}
slot_cats = collections.defaultdict(list)
for r in rows("MCRSlotXMCRCategory"):
    slot_cats[I(r["ModifiedCraftingReagentSlotID"])].append((I(r["_Order"]), I(r["ModifiedCraftingCategoryID"])))
cat_items = collections.defaultdict(list)   # category -> [(order, itemID)]
for r in rows("CraftingReagentQuality"):
    if I(r["CurrencyTypesID"]) or not I(r["ItemID"]):
        continue
    cat_items[I(r["ModifiedCraftingCategoryID"])].append((I(r["OrderIndex"]), I(r["ID"]), I(r["ItemID"])))
mcri_cat = {I(r["ID"]): I(r["ModifiedCraftingCategoryID"]) for r in rows("ModifiedCraftingReagentItem")}
cat_mci = collections.defaultdict(list)
for r in rows("ModifiedCraftingItem"):
    c = mcri_cat.get(I(r["ModifiedCraftingReagentItemID"]))
    if c is not None:
        cat_mci[c].append(I(r["ItemID"]))


def items_for_slot(sid, with_mci):
    # Basic slots take quality variants from CraftingReagentQuality only; ModifiedCraftingItem
    # also lists optional-reagent items (and unreleased variants absent from ItemSparse).
    out = []
    for _, c in sorted(slot_cats.get(sid, [])):
        for _, _, it in sorted(cat_items.get(c, [])):
            if it not in out:
                out.append(it)
        for it in (sorted(cat_mci.get(c, [])) if with_mci else []):
            if it not in out:
                out.append(it)
    return out


basic = collections.defaultdict(list)    # spell -> [(qty, [items])]
finish = collections.defaultdict(list)
for r in rows("SpellReagents"):
    s = I(r["SpellID"])
    if s not in spells:
        continue
    for n in range(8):
        it, q = I(r["Reagent_%d" % n]), I(r["ReagentCount_%d" % n])
        if it > 0 and q > 0:
            basic[s].append((q, [it]))

mcss = collections.defaultdict(list)
for r in rows("ModifiedCraftingSpellSlot"):
    s = I(r["SpellID"])
    if s in spells:
        mcss[s].append((I(r["Slot"]), I(r["ModifiedCraftingReagentSlotID"]), I(r["ReagentCount"])))
unresolved = []
for s, lst in mcss.items():
    for _, sid, q in sorted(lst):
        t = slot_type.get(sid)
        its = items_for_slot(sid, t != 1)
        if t == 1:
            if its:
                basic[s].append((q, its))
            else:
                unresolved.append((s, sid))
        else:
            for it in its:
                # tradeable only: skip BoP (1) and quest (4) items
                if it not in item_bind or item_bind[it] in (1, 4):
                    continue
                if it not in finish[s]:
                    finish[s].append(it)

cd_item = {}
for r in rows("CraftingData"):
    cd_item[I(r["ID"])] = I(r["CraftedItemID"])
cd_q = collections.defaultdict(list)
for r in rows("CraftingDataItemQuality"):
    cd_q[I(r["CraftingDataID"])].append((I(r["ID"]), I(r["ItemID"])))
cd_e = collections.defaultdict(list)
for r in rows("CraftingDataEnchantQuality"):
    if I(r["ItemID"]):
        cd_e[I(r["CraftingDataID"])].append((I(r["Rank"]), I(r["ItemID"])))
output = collections.defaultdict(list)
create = collections.defaultdict(list)
for r in rows("SpellEffect"):
    s = I(r["SpellID"])
    if s not in spells:
        continue
    e = I(r["Effect"])
    if e == 288:
        c = I(r["EffectMiscValue_0"])
        its = [x for _, x in sorted(cd_q.get(c, []))] or [x for _, x in sorted(cd_e.get(c, []))]
        if not its and cd_item.get(c):
            its = [cd_item[c]]
        for x in its:
            if x not in output[s]:
                output[s].append(x)
    elif e in (24, 296) and I(r["EffectItemType"]):  # CREATE_ITEM, recycle/salvage-style create
        create[s].append(I(r["EffectItemType"]))
for s, its in create.items():
    if not output[s]:
        output[s] = its
# CraftingDataItemQuality row order is not always rank order (e.g. Box of Rocks); sort low->high.
for s in output:
    output[s] = [x for _, x in sorted(enumerate(output[s]), key=lambda p: (item_cq.get(p[1], 0), p[0]))]

lines, n = [], 0
for s in sorted(spells):
    b, f, o = basic.get(s), finish.get(s), output.get(s)
    if not b and not o:
        continue
    parts = []
    if b:
        parts.append("b={" + ",".join("{%d,%s}" % (q, ",".join(map(str, its))) for q, its in b) + "}")
    if f:
        parts.append("f={" + ",".join(map(str, f)) + "}")
    if o:
        parts.append("o={" + ",".join(map(str, o)) + "}")
    lines.append("    [%d] = { %s }," % (s, ", ".join(parts)))
    n += 1

hdr = """--[[ Generated %s from wago.tools DB2 build %s (tables: SpellReagents, ModifiedCraftingSpellSlot,
     ModifiedCraftingReagentSlot, MCRSlotXMCRCategory, CraftingReagentQuality, ModifiedCraftingReagentItem,
     ModifiedCraftingItem, SpellEffect, CraftingData, CraftingDataItemQuality, CraftingDataEnchantQuality, Item, ItemSparse).
     Do not edit by hand; regenerate with gen_reagent_catalog.py.

     Schema: ns.MidnightReagentCatalog[spellID] = {
       b = { {qty, itemID1, itemID2?}, ... },  -- required basic slots; itemIDs = quality variants low->high
       f = { itemID, ... },                    -- optional finishing/modifying candidates (tradeable only)
       o = { itemID, ... },                    -- output item(s) / quality variants
     }
     %d recipes. Currencies excluded. ]]

local ADDON_NAME, ns = ...

ns.MidnightReagentCatalog = {
""" % (datetime.date.today().isoformat(), BUILD, n)
with open(outp, "w", encoding="utf-8") as fo:
    fo.write(hdr + "\n".join(lines) + "\n}\n")
if dbg:
    json.dump({"basic": basic, "finish": finish, "output": output, "names": {
        str(i): item_name.get(i, "") for s in spells for i in
        [x for _, its in basic.get(s, []) for x in its] + finish.get(s, []) + output.get(s, [])},
        "unresolved": unresolved}, open(dbg, "w"))
print("recipes", n, "unresolved basic slots", len(unresolved))
