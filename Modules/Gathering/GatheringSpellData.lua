--[[
    Gathering spells → UI category (herb / mine / leather / disenchant).
    Static IDs cover every castable ability on the base profession skill lines
    (Herbalism 182 / Mining 186 / Skinning 393 / Enchanting 333), which by
    construction includes the whole Midnight child line — so 12.x casts, the 12.1
    Cursed nodes included, resolve exactly. The C_Spell icon fallback now only
    catches IDs Blizzard adds after this table was generated.
    Item routing: reference catalog first, then Trade Goods subclass heuristics.
]]

local ADDON_NAME, ns = ...

---@class GatheringSpellData
local GatheringSpellData = {}

--- GENERATED from wago.tools DB2 (SkillLineAbility + SpellName), build 12.1.0.69497,
--- verified 2026-08-29. Rule: every ability on the base profession skill line, minus
--- entries that yield no gathering loot — stat passives (Quality / Knowledge / Skill /
--- Finesse / Perception / Deftness / Multicraft / Concentration / Resourcefulness /
--- Ingenuity / Artisan's … Moxie), profession journals, "Refine …" conversions, placed
--- consumables (Mulch / Diffuser / Lure), beast tracking, and per-expansion skill-line
--- root passives. Regenerate rather than hand-edit: a wrong ID misroutes loot, and a
--- neighbouring ID is almost never the spell you meant.

--- Herbalism — skill line 182, 201 gather casts (all expansions incl. Midnight + 12.1 Cursed)
local HERB = {
    [2366] = true, [2368] = true, [3570] = true, [11993] = true, [28695] = true, [32605] = true,
    [50300] = true, [74519] = true, [110413] = true, [158745] = true, [193292] = true, [193293] = true,
    [193294] = true, [193295] = true, [193296] = true, [193297] = true, [193298] = true, [193299] = true,
    [193300] = true, [193301] = true, [193302] = true, [193303] = true, [193304] = true, [193305] = true,
    [193306] = true, [193307] = true, [193308] = true, [193309] = true, [195114] = true, [247812] = true,
    [247813] = true, [247814] = true, [252405] = true, [252406] = true, [252407] = true, [252408] = true,
    [252409] = true, [252410] = true, [252411] = true, [252412] = true, [252413] = true, [252415] = true,
    [252416] = true, [252417] = true, [252418] = true, [252419] = true, [252420] = true, [252421] = true,
    [252422] = true, [252423] = true, [252424] = true, [252425] = true, [252426] = true, [265819] = true,
    [265821] = true, [265823] = true, [265825] = true, [265827] = true, [265829] = true, [265831] = true,
    [265834] = true, [265835] = true, [298142] = true, [298143] = true, [298144] = true, [309780] = true,
    [366252] = true, [382582] = true, [390392] = true, [391406] = true, [391415] = true, [391431] = true,
    [391441] = true, [391444] = true, [391447] = true, [391460] = true, [391492] = true, [391496] = true,
    [391498] = true, [391499] = true, [391500] = true, [391501] = true, [391502] = true, [391503] = true,
    [391504] = true, [391505] = true, [391506] = true, [391507] = true, [391508] = true, [391509] = true,
    [391510] = true, [391511] = true, [391512] = true, [391513] = true, [391514] = true, [391515] = true,
    [391516] = true, [391557] = true, [391558] = true, [391560] = true, [391562] = true, [391564] = true,
    [395275] = true, [396171] = true, [405123] = true, [405124] = true, [405126] = true, [405127] = true,
    [405134] = true, [421176] = true, [421224] = true, [421226] = true, [421227] = true, [422293] = true,
    [423395] = true, [435811] = true, [435812] = true, [435821] = true, [435822] = true, [435823] = true,
    [435826] = true, [435829] = true, [435830] = true, [435834] = true, [435836] = true, [435838] = true,
    [435840] = true, [435843] = true, [435850] = true, [435851] = true, [435857] = true, [435858] = true,
    [435859] = true, [435860] = true, [435861] = true, [435862] = true, [435864] = true, [435865] = true,
    [435866] = true, [435867] = true, [435870] = true, [435871] = true, [435872] = true, [435873] = true,
    [435877] = true, [435878] = true, [435879] = true, [435880] = true, [438952] = true, [438953] = true,
    [438955] = true, [438961] = true, [439871] = true, [441327] = true, [452269] = true, [471009] = true,
    [1221172] = true, [1223014] = true, [1223099] = true, [1223135] = true, [1223137] = true, [1223138] = true,
    [1223139] = true, [1223146] = true, [1223148] = true, [1223149] = true, [1223150] = true, [1223151] = true,
    [1224882] = true, [1224883] = true, [1224884] = true, [1224885] = true, [1224886] = true, [1224887] = true,
    [1224888] = true, [1224889] = true, [1224890] = true, [1224891] = true, [1224892] = true, [1224893] = true,
    [1224894] = true, [1224895] = true, [1224896] = true, [1224897] = true, [1224898] = true, [1224899] = true,
    [1224900] = true, [1224901] = true, [1225128] = true, [1225137] = true, [1225144] = true, [1225150] = true,
    [1225182] = true, [1250314] = true, [1250317] = true, [1301647] = true, [1301649] = true, [1301651] = true,
    [1301654] = true, [1301655] = true, [1301657] = true,
}

--- Mining — skill line 186, 167 gather casts (all expansions incl. Midnight + 12.1 Cursed)
local MINE = {
    [2575] = true, [2576] = true, [3564] = true, [10248] = true, [29354] = true, [32606] = true,
    [50310] = true, [74517] = true, [102161] = true, [158754] = true, [184454] = true, [184456] = true,
    [184457] = true, [184484] = true, [184485] = true, [184486] = true, [184488] = true, [184489] = true,
    [184490] = true, [184492] = true, [184493] = true, [184494] = true, [184496] = true, [184497] = true,
    [184498] = true, [184500] = true, [184501] = true, [184502] = true, [184504] = true, [184505] = true,
    [191970] = true, [195122] = true, [247848] = true, [247849] = true, [247850] = true, [247851] = true,
    [247852] = true, [247853] = true, [253333] = true, [253334] = true, [253335] = true, [253336] = true,
    [253337] = true, [253338] = true, [253339] = true, [253340] = true, [253341] = true, [253342] = true,
    [253343] = true, [253344] = true, [253345] = true, [253346] = true, [253347] = true, [265837] = true,
    [265839] = true, [265841] = true, [265843] = true, [265845] = true, [265847] = true, [265849] = true,
    [265851] = true, [265853] = true, [296143] = true, [296144] = true, [296145] = true, [296147] = true,
    [296148] = true, [296149] = true, [309835] = true, [366260] = true, [382586] = true, [384688] = true,
    [384690] = true, [384692] = true, [384693] = true, [388213] = true, [389406] = true, [389409] = true,
    [389413] = true, [389420] = true, [389458] = true, [389459] = true, [389460] = true, [389461] = true,
    [389462] = true, [389463] = true, [389464] = true, [389465] = true, [389700] = true, [389701] = true,
    [389702] = true, [389703] = true, [389704] = true, [395269] = true, [396162] = true, [396169] = true,
    [405120] = true, [405121] = true, [405131] = true, [421244] = true, [421247] = true, [422809] = true,
    [423394] = true, [423882] = true, [439705] = true, [439707] = true, [439708] = true, [439709] = true,
    [439710] = true, [439711] = true, [439712] = true, [439713] = true, [439714] = true, [439715] = true,
    [439716] = true, [439717] = true, [439718] = true, [439719] = true, [439720] = true, [439721] = true,
    [439722] = true, [439723] = true, [439724] = true, [439725] = true, [439726] = true, [439727] = true,
    [439728] = true, [439729] = true, [439742] = true, [439743] = true, [439744] = true, [439747] = true,
    [453381] = true, [1225343] = true, [1225347] = true, [1225348] = true, [1225349] = true, [1225350] = true,
    [1225351] = true, [1225352] = true, [1225353] = true, [1225354] = true, [1225355] = true, [1225357] = true,
    [1225359] = true, [1225361] = true, [1225362] = true, [1225363] = true, [1225365] = true, [1225366] = true,
    [1225367] = true, [1225368] = true, [1225369] = true, [1225370] = true, [1225392] = true, [1225817] = true,
    [1225818] = true, [1225819] = true, [1225820] = true, [1226062] = true, [1250351] = true, [1250356] = true,
    [1285705] = true, [1301486] = true, [1301492] = true, [1301494] = true, [1301495] = true,
}

--- Skinning / leather gathering (loot attributed to “leather” tab)
--- Skill line 393, 72 gather casts (incl. Midnight hides/scales and Carve Meat)
local LEATHER = {
    [8613] = true, [8617] = true, [8618] = true, [10768] = true, [32678] = true, [50305] = true,
    [74522] = true, [102216] = true, [158756] = true, [194161] = true, [194162] = true, [194163] = true,
    [194164] = true, [194165] = true, [194166] = true, [194167] = true, [194168] = true, [194169] = true,
    [194170] = true, [194171] = true, [195125] = true, [205243] = true, [247842] = true, [247843] = true,
    [247844] = true, [257146] = true, [257147] = true, [257148] = true, [257149] = true, [257150] = true,
    [257151] = true, [257152] = true, [257153] = true, [257154] = true, [265855] = true, [265857] = true,
    [265859] = true, [265861] = true, [265863] = true, [265865] = true, [265867] = true, [265869] = true,
    [265871] = true, [302007] = true, [302010] = true, [302011] = true, [302014] = true, [302015] = true,
    [302016] = true, [308569] = true, [366259] = true, [382587] = true, [392440] = true, [392445] = true,
    [395282] = true, [395700] = true, [395706] = true, [396173] = true, [440977] = true, [442566] = true,
    [442567] = true, [442569] = true, [442572] = true, [442615] = true, [469989] = true, [1223388] = true,
    [1225897] = true, [1225901] = true, [1225902] = true, [1225903] = true, [1225908] = true, [1226037] = true,
}

--- Disenchant — skill line 333, the 13 abilities actually named "Disenchant"
--- (the rest of 333 is enchant recipes). Midnight rank is 1280952.
local DISENCHANT = {
    [13262] = true, [300381] = true, [300382] = true, [302690] = true, [302691] = true, [302692] = true,
    [302693] = true, [302694] = true, [302695] = true, [324750] = true, [392888] = true, [455970] = true,
    [1280952] = true,
}

--- Profession-line abilities that are NOT a gathering pickup: they keep their profession
--- (GetCategory, for ownership / tab mapping) but never open the gathering cast context
--- (IsGatheringSpell), so a vendor/quest herb or a mob corpse after them is not "gathered".
--- Partitioned 2026-10-15 from the tables above by DB2 12.1.5 SpellName + SpellEffect:
---   track  = Effect 6 / EffectAura 45 (track resources): Find Herbs, Find Minerals x2
---   create = Effect 24 (create item): every "Smelt …", Enchanted Thorium Bar, Earth
---            Shatter, Fire Sunder — crafts, their output is not loot
---   place  = Effect 288 consumables placed in the world, no loot of their own: Heart in a
---            Bottle x3, Bottled Pheromones, Elusive Creature Bait, Beast Lure Scent,
---            Infusion: Frost/Earth/Decay/Titan/Crystal/Spores/Writhing
--- Real gathers carry Effect 33 (open lock: Herb Gathering, Mining, "Opening") or 95
--- (skinning). The generator must keep emitting this split.
local UTILITY = {
    -- track
    [2383] = "herb", [2580] = "mine", [8388] = "mine",
    -- create (Mining)
    [2657] = "mine", [2658] = "mine", [2659] = "mine", [3304] = "mine", [3307] = "mine", [3308] = "mine",
    [3569] = "mine", [10097] = "mine", [10098] = "mine", [14891] = "mine", [16153] = "mine", [22967] = "mine",
    [29356] = "mine", [29358] = "mine", [29359] = "mine", [29360] = "mine", [29361] = "mine", [29686] = "mine",
    [46353] = "mine", [49252] = "mine", [49258] = "mine", [55208] = "mine", [55211] = "mine", [74529] = "mine",
    [74530] = "mine", [74537] = "mine", [84038] = "mine", [102165] = "mine", [102167] = "mine",
    [35750] = "mine", [35751] = "mine", [70524] = "mine",
    -- place
    [377984] = "herb", [377987] = "mine", [377988] = "leather",
    [383128] = "leather", [383132] = "leather", [442654] = "leather",
    [385972] = "leather", [385982] = "leather", [385984] = "leather", [385985] = "leather",
    [442649] = "leather", [442650] = "leather", [442651] = "leather",
}

--- Gathering casts only (UTILITY is deliberately not merged in).
local ALL = {}

local function MergeInto(dst, src)
    for k in pairs(src) do
        dst[k] = true
    end
end

MergeInto(ALL, HERB)
MergeInto(ALL, MINE)
MergeInto(ALL, LEATHER)
MergeInto(ALL, DISENCHANT)

--- Profession icons — locale-stable, used only when spellID ∉ ALL (a cast Blizzard
--- added after the tables above were generated).
--- Verified against DB2 SpellMisc + ManifestInterfaceData, build 12.1.0.69497 (2026-08-29):
--- these are the icons the base gather casts actually carry. The previous constants
--- (136246 Trade_Herbalism / 134708 INV_Pick_02 / 134366 INV_Misc_Pelt_Wolf_01 /
--- 135433 INV_Torch_Thrown) matched no gathering spell in the game, so this fallback
--- could never fire. Other spells sharing these icons are rank passives, which never
--- raise UNIT_SPELLCAST_* and so never reach this path.
local SPELL_ICON_HERB = 4620675 -- UI_Profession_Herbalism
local SPELL_ICON_MINE = 4620679 -- UI_Profession_Mining
local SPELL_ICON_LEATHER = 4620680 -- UI_Profession_Skinning
local SPELL_ICON_DISENCHANT = 132853 -- INV_Enchant_Disenchant

---@param spellId number|nil
---@return "herb"|"mine"|"leather"|"disenchant"|nil
function GatheringSpellData.GetCategory(spellId)
    if not spellId then return nil end
    if HERB[spellId] then return "herb" end
    if MINE[spellId] then return "mine" end
    if LEATHER[spellId] then return "leather" end
    if DISENCHANT[spellId] then return "disenchant" end
    return UTILITY[spellId]
end

--- True for a profession-line utility ability (tracking, smelting, placed consumables).
---@param spellId number|nil
---@return boolean
function GatheringSpellData.IsUtilitySpell(spellId)
    return spellId ~= nil and UTILITY[spellId] ~= nil
end

--- Infer gathering tab from spell art + fishing exclusion (Midnight unknown IDs).
---@param spellId number|nil
---@return "herb"|"mine"|"leather"|"disenchant"|nil
function GatheringSpellData.InferGatheringCategoryFromSpell(spellId)
    if not spellId then
        return nil
    end
    if issecretvalue and issecretvalue(spellId) then
        return nil
    end
    local known = GatheringSpellData.GetCategory(spellId)
    if known then
        return known
    end
    if ns.FishingSpellData and ns.FishingSpellData.IsFishingSpell(spellId) then
        return nil
    end
    if not C_Spell or not C_Spell.GetSpellInfo then
        return nil
    end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
    if not ok or not info or not info.iconID then
        return nil
    end
    local icon = info.iconID
    if issecretvalue and issecretvalue(icon) then
        return nil
    end
    if icon == SPELL_ICON_HERB then
        return "herb"
    end
    if icon == SPELL_ICON_MINE then
        return "mine"
    end
    if icon == SPELL_ICON_LEATHER then
        return "leather"
    end
    if icon == SPELL_ICON_DISENCHANT then
        return "disenchant"
    end
    return nil
end

--- A gathering cast (opens the loot attribution context). Utility abilities are excluded.
---@param spellId number|nil
---@return boolean
function GatheringSpellData.IsGatheringSpell(spellId)
    if not spellId then
        return false
    end
    if ALL[spellId] then
        return true
    end
    if UTILITY[spellId] then
        return false
    end
    return GatheringSpellData.InferGatheringCategoryFromSpell(spellId) ~= nil
end

--- Trade Goods (classID 7) subclass -> gathering tab. Verified 2026-10-15 against DB2 Item
--- 12.1.5.70391 (scratchpad item.csv ClassID/SubclassID of the catalog items): herbs
--- (Tranquility Bloom 236761) = 9 "Herb", ores (Refulgent Copper Ore 237359) = 7
--- "Metal & Stone", skinning mats (Void-Tempered Leather 238511) = 6 "Leather",
--- dust/shard/crystal (Eversinging Dust 243599) = 12 "Enchanting". 11 "Other" (motes) and
--- 8 "Cooking" are shared drops with no single tab, so they are not inferred.
local TRADEGOODS_SUBCLASS_TAB = {
    [9] = "herb",
    [7] = "mine",
    [6] = "leather",
    [12] = "disenchant",
}

--- Catalog first, then Trade Goods subclasses via C_Item.GetItemInfoInstant (works before GetItemInfo cache fills).
---@param itemID number|nil
---@return "herb"|"mine"|"leather"|"disenchant"|"others"|nil
function GatheringSpellData.InferCategoryFromItemId(itemID)
    if not itemID then
        return nil
    end
    local fromCat = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID)
    if fromCat then
        return fromCat
    end
    local classID, subID
    if C_Item and C_Item.GetItemInfoInstant then
        -- Multiple returns (ItemDocumentation 12.1.5): itemID, itemType, itemSubType,
        -- itemEquipLoc, icon, classID, subClassID — not a table.
        local ok, _, _, _, _, _, cls, sub = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok then
            classID, subID = cls, sub
        end
    end
    if type(classID) ~= "number" or (issecretvalue and (issecretvalue(classID) or issecretvalue(subID))) then
        return nil
    end
    if classID == 7 and subID then
        return TRADEGOODS_SUBCLASS_TAB[subID]
    end
    return nil
end

ns.GatheringSpellData = GatheringSpellData
