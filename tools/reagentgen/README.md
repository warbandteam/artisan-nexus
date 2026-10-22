# Recipe + reagent catalog generators

`Modules/Data/MidnightRecipeCatalog.lua` lists every Midnight recipe per profession
(`gen_recipe_catalog.py`: SkillLineAbility rows whose `SkillupSkillLineID` is a Midnight child
skill line 2906-2918, names from SpellName). `build.sh` regenerates it first, then the reagent
catalog from it, so both always come from the same build.

`Modules/Data/MidnightReagentCatalog.lua` lists the required reagents (with quality variants),
tradeable optional reagents and outputs of every Midnight recipe in
`Modules/Data/MidnightRecipeCatalog.lua`. The AH scan uses it to price materials of recipes the
player never opened. It is generated from wago.tools DB2 exports — do not edit it by hand.

Regenerate after a client patch:

    tools/reagentgen/build.sh 12.1.5.70391

Validate against schematics the addon harvested in-game (read-only):

    VALIDATE_SV=".../WTF/Account/<account>/SavedVariables/ArtisanNexus.lua" tools/reagentgen/build.sh <build>

Join logic is documented at the top of `gen_reagent_catalog.py`. Requires `curl`, `python3`, `luajit`.
