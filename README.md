# Artisan Nexus

Professions quality-of-life addon for World of Warcraft: Midnight (retail 12.1.5, Interface 120105).
Session loot for fishing and gathering, AH price sync, an economy engine (craft EV, concentration
planner, ledgers, posting helper), the Artisan Hub and the item tooltip.
Release metadata lives in [PUBLISHING.md](PUBLISHING.md) and the history in [CHANGELOG.md](CHANGELOG.md).

Warband Nexus is optional. When it is installed, Artisan Nexus reads alt data from it and does
not collect that data again. Without it, every feature still works on AN's own data.

## Usage

- `/an` toggles the Artisan Hub, `/an history` toggles Session loot, `/an config` opens Settings.
  `/artisan` is an alias for `/an`.
- Minimap button: left-click Hub, Shift+left-click Session loot, middle-click Recipe Matcher,
  right-click Settings.
- Settings are a tab inside the Hub (rail footer). The gear button in the Session loot and Recipe
  Matcher windows and Esc > Options > AddOns > Artisan Nexus open the same page.

---

## Developer guide

Lua 5.1 (the WoW client), Ace3 (AceAddon, AceEvent, AceDB, AceConsole, AceTimer, AceBucket,
AceLocale), LibDataBroker + LibDBIcon. Code, comments and identifiers are in English. Every module
receives `local ADDON_NAME, ns = ...` and publishes itself as `ns.<Name>`. Files load in
`ArtisanNexus.toc` order, so a module may only use another module at load time if it comes
earlier in the TOC. At runtime every module is available.

### Architecture

```
Data / catalogs      Modules/Data/*Catalog*.lua (generated DB2 tables), Fishing/Gathering spell data
      │
Services / Economy   Modules/*Service.lua, Modules/Economy/*  ── WoW events in, AN_* messages out
      │                                   ▲
Providers / Bridge   ns.CharacterData (Modules/Data/CharacterDataProvider.lua)
      │              ns.WarbandNexusBridge (optional Warband Nexus)
      ▼
UI                   Warband Nexus UI framework (verbatim copy) → Hub tabs (Modules/UI/Hub),
                     floating windows (ns.ArtisanWindow), tooltip, settings
```

- Services own their SavedVariables and announce changes with `ns.ArtisanNexus:SendMessage(E.X, payload)`.
  The UI subscribes to those messages and never writes service data directly.
- Lifecycle: file load (tables only) → `OnInitialize` (AceDB, migrations, slash, UI `Init`) →
  `OnEnable` (WarbandNexusBridge + CharacterData first, then services; the economy services start through
  `ECONOMY_SERVICES` in `Core.lua`; then `AN_LOADING_COMPLETE`) → `OnDisable` (reverse order).

### Character data: one interface, two backends

`ns.CharacterData` picks a backend separately for each capability. It uses Warband Nexus when the
bridge is available, WN has the public method, and WN tracks the logged-in character. Otherwise it
uses AN's own collector. While WN covers a capability, the AN collector for it registers no events
and writes nothing.

| Capability | WN method (warband-nexus v3.6.0) | AN-native collector |
|---|---|---|
| characters | `GetAllCharacters` | `Utilities:TouchCharRegistry` → `global.charRegistry` |
| concentration | `GetAllConcentrationData` (+ `GetEstimatedConcentration`) | `ProfessionSnapshotService` → `global.professionSnapshots` |
| recipes (known by) | `GetCraftersForRecipe` | `RecipeService` harvest → `recipeSchematics[*].learnedBy` |
| items (alt stock) | `GetDetailedItemCountsFast` | provider snapshot → `global.itemSnapshots` (catalog reagents only) |
| cooldowns | none yet (TODO: `GetAllProfessionCooldowns`) | `CooldownService` → `global.recipeCooldowns` |

The current character's concentration is always read live. When a backend switches, the provider
sends `AN_CHARACTER_DATA_SOURCE_CHANGED`. Native rows that have not been refreshed for 30 days are
pruned. Consumers call the provider (or the service APIs built on it, such as
`ConcentrationPlannerService:GetPools()` and `CooldownService:GetCooldowns()`). They never call the bridge.

### Module responsibilities

| Module | Responsibility |
|---|---|
| `Core.lua` | AceAddon bootstrap, `defaults` (exported as `ns.DEFAULTS`), enable order, slash commands |
| `Modules/Constants.lua` | `ADDON_VERSION`, shared constants, `EVENTS` message catalog |
| `Modules/MigrationService.lua` | versioned, non-destructive SavedVariables migrations |
| `Modules/Utilities.lua`, `ProfessionLocale.lua`, `DebugPrint.lua` | helpers: GUID, `ns.FormatCopper`, `ns.SafeLocaleString`, `ns.NewEventOwner`, debug output |
| `Modules/WarbandNexusBridge.lua` | pcall wrappers over public Warband Nexus methods + message relay |
| `Modules/Data/*` | generated catalogs (`MidnightRecipeCatalog`, `MidnightReagentCatalog`, gathering, fishing, overload nodes) + the hand-written `CharacterDataProvider.lua` (`ns.CharacterData`) |
| `SessionLootService`, `Fishing/*`, `Gathering/*`, `CraftLootService`, `BagPressureGuard`, `LootWindowBridge` | loot capture, session/overall history, overload tracking |
| `RecipeService`, `CraftEventService`, `CraftingQueueService`, `ShoppingListService`, `ProfitabilityService`, `CraftBriefingService`, `ProfessionSnapshotService`, `ProfessionEquipmentService` | recipe schematics, craft queue, shopping, profitability, briefing, profession window state |
| `AHPriceService`, `PriceHistoryService`, `PostingHelperService` | AH scanning and price store, price history, posting suggestions |
| `Modules/Economy/*` | economy engine: `EconomyCore` (fees, config), vendor prices, craft ops/ledger/EV, sales & owned auctions, market intel, concentration planner, cooldowns, crafting orders, tooltip |
| WN UI framework (`tools/wnsync/files.txt`) | the Warband Nexus UI copied verbatim: `FontManager`, `WindowManager`, `SearchStateManager`, `APIWrapper`, `Profiler`, `LoadingTracker`, `Modules/UI/SharedWidgets*.lua`, `IconRegistry`, `FormatHelpers`, `ColumnOrderHelpers`, `LayoutCoordinator`, `FramePoolFactory`, `WindowFactory`, `SearchBoxComponent`, `TooltipFactory`, `NotificationToastFactory`, `SettingsUI*.lua`, the main window (`Modules/UI.lua`, `UI_MainShell`, `UI_TabHost`, `UI_RefreshRouter`) + `libs/LibSharedMedia-3.0`, `Fonts/`, `Media/Icon-*.tga` |
| `Modules/UI/Hub/*` | the Hub tabs drawn in the WN main window: `HubData.lua` (data, ink and money helpers), `HubTabKit.lua` (WN-pattern body kit, title toolbar, profession filter), `Pages/*.lua` |
| `Modules/UI/ArtisanWindow.lua` | `ns.ArtisanWindow`: the WN PlansTracker floating-window shell used by every standalone window, its HUD variant, tiling, and the one themed dropdown |
| `Modules/UI/Settings/SettingsSchema.lua`, `SettingsUI_Artisan.lua` | every Artisan Nexus setting as one schema row (`ns.SettingsSchema`), rendered with the WN settings builders into the WN Settings tab |
| `Config.lua` | `ns.OpenAddonSettings` (Hub on the Settings tab) + the Blizzard Options launcher |
| other `Modules/UI/*` | loot windows, loot toasts, recipe matcher, posting helper / price history, profession sidecar, overload tracker |

### Message catalog (`Constants.EVENTS`, all prefixed `AN_`)

| Area | Messages |
|---|---|
| Lifecycle / settings | `LOADING_COMPLETE`, `MODULE_TOGGLED`, `THEME_CHANGED`, `ECONOMY_CONFIG_CHANGED` |
| Loot | `FISHING_CHANNEL_STARTED/STOPPED`, `FISHING_HISTORY_UPDATED`, `GATHERING_LOOT_RECORDED`, `GATHERING_HISTORY_UPDATED`, `GATHERING_OVERLOAD_HINT_UPDATED`, `LOOT_HISTORY_UPDATED`, `SESSION_LOOT_UPDATED`, `CRAFT_LOOT_RECORDED` |
| Crafting | `RECIPE_SCHEMATICS_UPDATED`, `CRAFT_QUEUE_UPDATED`, `SHOPPING_LIST_UPDATED`, `CRAFT_BRIEFING_UPDATED`, `PROFESSION_SNAPSHOT_UPDATED`, `PROFESSION_EQUIPMENT_UPDATED` |
| Market | `AH_PRICES_UPDATED`, `AH_SCAN_COMPLETE`, `VENDOR_PRICES_UPDATED`, `MARKET_INTEL_UPDATED`, `OWNED_AUCTIONS_UPDATED`, `SALES_LEDGER_UPDATED` |
| Economy | `CRAFT_OPS_UPDATED`, `CRAFT_LEDGER_UPDATED`, `CRAFTING_ORDERS_UPDATED`, `COOLDOWNS_UPDATED`, `CONCENTRATION_PLAN_UPDATED` |
| Character data | `WN_DATA_UPDATED` (coalesced WN relay), `CHARACTER_DATA_SOURCE_CHANGED` |

Each payload is documented next to its entry in `Modules/Constants.lua`. Add new messages there.

### SavedVariables (`ArtisanNexusDB`, AceDB)

- `profile`: every user setting, declared once in `Core.lua` `defaults.profile` (including `economy`,
  `posting`, `tooltip` and the window anchors). Code that needs a fallback reads `ns.DEFAULTS` and does
  not declare its own copy.
- `global`: loot histories and event tails, `ahPrices`/`ahPriceHistory`, `recipeSchematics`, `craftQueue`,
  `shoppingList`, `craftBriefing`, `charRegistry`, `professionSnapshots`. Stores created at runtime:
  `vendorPrices`, `craftOps`, `craftOpsMeta`, `craftLedger`, `salesLedger`, `ownedAuctions`,
  `recipeCooldowns`, `cooldownReminder`, `concentrationPlanner`, `ahEmpty`, `itemSnapshots`.
  Every per-character record is keyed by GUID.
- `char`: `professionEquipmentHints`.
- Schema: `global._schemaVersion` against `CURRENT_SCHEMA_VERSION` in `MigrationService.lua` (currently 8).
  To change the layout, bump the version and add `MIGRATIONS[old]`. Steps must be idempotent and must never
  wipe another character's data. Every growing table needs a cap or pruning.

### How to

- **Add a service:** create the file and add it to the TOC after its dependencies. Export `ns.<Name>` with
  idempotent `:Enable()` / `:Disable()`, and wire events through `ns.NewEventOwner("<Name>")`. Economy
  services go into `ECONOMY_SERVICES` in `Core.lua`; any other service is enabled explicitly in `OnEnable`.
  Announce changes with an `EVENTS` entry. If the service collects per-character data that Warband Nexus
  may also have, put it behind `ns.CharacterData` and gate it on `UsesNative(capability)`.
- **UI rule:** the UI is Warband Nexus's framework copied verbatim (same file names; only the mechanical
  renames of `tools/wnsync/wn_transform.py`). Never restyle or re-implement a WN widget, and do not edit
  the copies beyond the small, commented AN adaptations of the `adapted` files; build AN screens from WN
  components exactly as WN tabs and windows use them. Re-sync with WN: `tools/wnsync/README.md`.
- **Add a Hub tab:** WN tab pattern (reference: `Hub/Pages/ConcentrationPage.lua`, `LedgerPage.lua`; WN
  `StatisticsUI` / `CurrencyUI`). Create `Modules/UI/Hub/Pages/<Name>Page.lua` with
  `function ArtisanNexus:Draw<Name>Tab(parent)` that returns the content height, then add the key to
  `ns.UI_MAIN_TAB_ORDER` (`SharedWidgets_Theme.lua` + the `Modules/UI.lua` fallback), the draw dispatch in
  `UI_TabHost.lua`, the label in `UI_MainShell.lua` `TAB_LABELS`, the icon in `SharedWidgets.lua`
  `TAB_NAV_TEXTURE_FALLBACK`, its `AN_*` messages in `UI_RefreshRouter.lua` `AN_TAB_REFRESH`, and the file
  to the TOC after `Hub/HubTabKit.lua`.
  - Fixed header: `ns.UI_BeginTabChromeLayout` → `ns.UI_CreateStandardTabTitleCard` → title-toolbar
    buttons (`H.ToolbarButton`, `H.ProfessionFilterButton`, chained with `H.LayoutToolbar`) →
    `ns.UI_PageStack_Place` → `ns.UI_CommitTabFixedHeader`.
  - Body: `H.NewTabBody(tabKey, expandProfileKey)` gives WN collapsible sections, TableKit tables, dim lines
    and the WN empty-state card; frames are cached and re-parented on every paint (the main window recycles
    the scroll child). Text: `ns.FontManager:CreateFontString` + `ns.UI_SetTextColorRole`; inline colour:
    `H.Ink(text, kind)`; money: `H.Money` / `H.Signed`.
  - In-tab gestures repaint with `H.Refresh(tabKey)` (`UI_MAIN_REFRESH_REQUESTED`, `instantPopulate`).
  - Rail badges: `Modules/UI.lua` `UpdateTabCountBadges` (Plan = queue size, Market = undercut auctions).
- **Add a window:** `ns.ArtisanWindow.Create(cfg)` (`Modules/UI/ArtisanWindow.lua`, WN PlansTracker shell:
  title band, header buttons, close, resize, position store, FLOATING strata, Esc, combat hide);
  `cfg.hud = true` for an always-on panel outside the Esc stack (`cfg.combatHide`). Open it with
  `W.Present(frame, { tileAfter = opener })`; the Hub opens beside a window with `W.ShowHubBeside(frame)`.
  Every dropdown or filter uses `W.CreateDropdown` / `W.OpenDropdownMenu` (WN `CreateThemedCategoryDropdown`).
- **Add a locale key:** add it to `Locales/enUS.lua` and to the other 10 locales with real translations.
  `check_locale_parity.py` must pass. Read keys with `ns.SafeLocaleString(key, fallback)`. Keep colour
  codes out of locale strings and apply colour where the string is used.
- **Add a setting:** add the default to `Core.lua` `defaults.profile`, then one row in
  `Modules/UI/Settings/SettingsSchema.lua` under its section (= WN settings category): `type` (toggle,
  slider, dropdown, radio, button, note, header), `key` (dotted profile path), label `X` and tooltip `X_DESC`
  (locale keys). Side effects go in `onChange` (send the message the consumers listen to); dependent rows
  use `parent = "<key>"` or `enabled = fn` and grey out live. Sliders that broadcast or rebuild use
  `applyOnRelease = true`. If another window also writes the key, call `ns.RefreshAddonSettings()` after
  the write. The row contract is in the header of `Modules/UI/Settings/SettingsSchema.lua`. Look, fonts,
  scale, keybinding and debug are WN's own Settings rows (`Modules/UI/SettingsUI.lua`): font family
  (bundled `Fonts/` + LibSharedMedia), font scale presets / custom scale, anti-aliasing, auto-scale for
  resolution, UI scale with auto-fit, theme presets and accent colour.
- **Regenerate the reagent catalog:** run `tools/reagentgen/build.sh <build>` (see `tools/reagentgen/README.md`;
  `gen_reagent_catalog.py` writes `Modules/Data/MidnightReagentCatalog.lua`, which the AH sync uses to price
  every recipe's reagents). The other catalog tables in `Modules/Data/` are also built from wago.tools DB2
  exports, so never edit them by hand; `CharacterDataProvider.lua` is the one hand-written file there.

### API verification

Never write a WoW API, event, payload or field from memory. Check it against warcraft.wiki.gg,
Blizzard_APIDocumentationGenerated, or a wago.tools DB2 build, and leave a stamp such as
`-- verified 2026-10-14, <source>`. If you cannot verify something, mark it `UNVERIFIED` and guard it.
12.1.5 removed the global item and coin functions, so bind the namespaced APIs (`C_Item.*`, `C_Spell.*`).

### Gates (`.claude/gates.json`, CI `.github/workflows/preflight.yml`)

```
luajit -bl <file> >/dev/null                      # Lua 5.1 syntax, every .lua outside libs/
python3 .github/scripts/check_locale_parity.py    # 11 locales, enUS reference
python3 .github/scripts/preflight_release.py      # Constants/TOC version sync + changelog key
# every file listed in ArtisanNexus.toc exists; no duplicate [id] keys in Modules/Data tables
xmllint --noout embeds.xml Bindings.xml
```

Packaging uses `.pkgmeta` (BigWigs packager, CurseForge/Wago). `Pack-ArtisanNexus.ps1` builds a local zip.

### Known limitations

- **Overload detection reads world-tooltip text.** Herb / ore node names are matched in every locale
  through the client's localized item names (`C_Item.GetItemNameByID` of the catalog items). The
  overload and modifier words (Overload, Wild, Infused, Empowered, Cursed, Deposit) are matched in
  English only: node templates are server-side and the client has no localized source for them. On
  non-English clients the category may be detected while the overload / modifier hint usually is not.
- **Loot attribution is context-based.** Gathering / fishing loot is recorded only right after a
  gathering cast, from a node or fishing loot window, or while fishing. An unrelated catalog item
  received within seconds of a gather (vendor, quest, mail) can still be counted.

### E2E harness

An offline simulation harness (WoW API stubs built from the 12.1.5 API docs and the retail UI source)
loads the full TOC. It runs login, loot, profession, AH, crafting, mail, orders, UI (modern/classic/light),
slash and disable/enable phases, then reports errors, unknown or undocumented `C_*` calls, argument type
mismatches and the SavedVariables sizes. It runs without Warband Nexus, which exercises the AN-native
backends. `AN_E2E_WN=1` installs a Warband Nexus stand-in and checks that AN writes no WN-covered data.
The harness is maintainer tooling and is not part of the repository. The expected result is
`errors=0 unknownApi=0 argIssues=0`.
