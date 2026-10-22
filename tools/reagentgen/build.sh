#!/bin/sh
# Regenerate Modules/Data/MidnightRecipeCatalog.lua, then MidnightReagentCatalog.lua from it,
# from wago.tools DB2 exports of one build.
# Usage: tools/reagentgen/build.sh <build>      e.g. tools/reagentgen/build.sh 12.1.5.70391
# Optional validation against your own harvested schematics:
#   VALIDATE_SV="/path/to/WTF/Account/<acct>/SavedVariables/ArtisanNexus.lua" tools/reagentgen/build.sh <build>
set -eu
BUILD="${1:?usage: build.sh <client build, e.g. 12.1.5.70391>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/an-reagentgen-$BUILD"
mkdir -p "$WORK/csv"
for T in SpellReagents ModifiedCraftingSpellSlot ModifiedCraftingReagentSlot MCRSlotXMCRCategory \
         ModifiedCraftingCategory ModifiedCraftingReagentItem ModifiedCraftingItem CraftingReagentQuality \
         CraftingData CraftingDataItemQuality CraftingDataEnchantQuality SpellEffect Item ItemSparse \
         CurrencyTypes SkillLineAbility SpellName; do
    [ -s "$WORK/csv/$T.csv" ] || curl -sfL "https://wago.tools/db2/$T/csv?build=$BUILD" -o "$WORK/csv/$T.csv"
done
python3 -I "$HERE/gen_recipe_catalog.py" "$WORK/csv" "$BUILD" "$REPO/Modules/Data/MidnightRecipeCatalog.lua"
luajit -bl "$REPO/Modules/Data/MidnightRecipeCatalog.lua" >/dev/null
luajit "$HERE/dump_mid.lua" "$REPO/Modules/Data/MidnightRecipeCatalog.lua" "$WORK/mid.json"
sed -i.bak "s/^BUILD = .*/BUILD = \"$BUILD\"/" "$HERE/gen_reagent_catalog.py" && rm -f "$HERE/gen_reagent_catalog.py.bak"
python3 -I "$HERE/gen_reagent_catalog.py" "$WORK/csv" "$WORK/mid.json" "$REPO/Modules/Data/MidnightReagentCatalog.lua" "$WORK/dbg.json"
if [ -n "${VALIDATE_SV:-}" ]; then
    luajit "$HERE/dumpgt.lua" "$VALIDATE_SV" "$REPO/Modules/Data/MidnightRecipeCatalog.lua" "$WORK/gt.json"
    python3 -I "$HERE/validate.py" "$WORK/gt.json" "$WORK/dbg.json"
fi
luajit -bl "$REPO/Modules/Data/MidnightReagentCatalog.lua" >/dev/null && echo "OK: recipe + reagent catalogs regenerated for $BUILD"
