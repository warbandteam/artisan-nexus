#!/usr/bin/env python3
"""Generate Modules/Data/MidnightRecipeCatalog.lua from wago.tools DB2 CSVs.

Usage: python3 -I gen_recipe_catalog.py <csv_dir> <build> <out.lua>
  csv_dir holds SkillLineAbility.csv and SpellName.csv of <build>.

Join logic
  recipes : SkillLineAbility rows whose SkillupSkillLineID is a Midnight child skill line
            (2906-2918). Matching on SkillLineAbility.SkillLine misses them: those child lines
            have no rows in the SkillLine column.
  names   : SpellName.Name_lang by SkillLineAbility.Spell; "" when the spell has no SpellName row
            (kept for ID parity; the catalog strips empty names at load).
"""
import csv, datetime, os, sys

d, BUILD, outp = sys.argv[1], sys.argv[2], sys.argv[3]

# Midnight child skill line -> (profession key, base profession skill line). Output order is fixed.
PROFESSIONS = [
    ("Alchemy", 2906, 171),
    ("Blacksmithing", 2907, 164),
    ("Cooking", 2908, 185),
    ("Enchanting", 2909, 333),
    ("Engineering", 2910, 202),
    ("Inscription", 2913, 773),
    ("Jewelcrafting", 2914, 755),
    ("Leatherworking", 2915, 165),
    ("Tailoring", 2918, 197),
    ("Fishing", 2911, 356),
    ("Herbalism", 2912, 182),
    ("Mining", 2916, 186),
    ("Skinning", 2917, 393),
]


def rows(name):
    with open(os.path.join(d, name + ".csv"), newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)


I = int
child_to_key = {child: key for key, child, _ in PROFESSIONS}
recipes = {key: set() for key, _, _ in PROFESSIONS}
for r in rows("SkillLineAbility"):
    key = child_to_key.get(I(r["SkillupSkillLineID"] or 0))
    spell = I(r["Spell"] or 0)
    if key and spell:
        recipes[key].add(spell)

wanted = set().union(*recipes.values())
names = {}
for r in rows("SpellName"):
    i = I(r["ID"])
    if i in wanted:
        names[i] = r["Name_lang"]


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


lines, n = [], 0
for key, child, parent in PROFESSIONS:
    lines.append("    %s = {" % key)
    lines.append("        skillLineID = %d," % child)
    lines.append("        parentSkillLineID = %d," % parent)
    lines.append("        recipes = {")
    for spell in sorted(recipes[key]):
        lines.append("            [%d] = %s," % (spell, lua_str(names.get(spell, ""))))
        n += 1
    lines.append("        },")
    lines.append("    },")

hdr = """--[[ Generated %s from wago.tools DB2 build %s (tables: SkillLineAbility, SpellName).
     Do not edit by hand; regenerate with tools/reagentgen/build.sh <build>.
     Midnight child skill-lines 2906-2918 mapped to their base profession parent skill-lines;
     recipes are matched on SkillLineAbility.SkillupSkillLineID (not SkillLine).
     Empty string = spell has no SpellName row in this build (kept for ID parity).

     Schema: ns.MidnightRecipeCatalog[profession] = {
       skillLineID       = <midnight child SLID>,
       parentSkillLineID = <base profession SLID>,
       recipes           = { [spellID] = name, ... }
     }
     %d recipes. ]]

local ADDON_NAME, ns = ...

ns.MidnightRecipeCatalog = {
""" % (datetime.date.today().isoformat(), BUILD, n)

ftr = """}

-- Strip empty placeholder names so harvest/UI fall back to live schematic names.
do
    local cat = ns.MidnightRecipeCatalog
    if type(cat) == "table" then
        for _, prof in pairs(cat) do
            if type(prof) == "table" and type(prof.recipes) == "table" then
                for spellID, name in pairs(prof.recipes) do
                    if type(name) ~= "string" or name == "" then
                        prof.recipes[spellID] = nil
                    end
                end
            end
        end
    end
end
"""
with open(outp, "w", encoding="utf-8") as fo:
    fo.write(hdr + "\n".join(lines) + "\n" + ftr)
print("recipes:", n)
