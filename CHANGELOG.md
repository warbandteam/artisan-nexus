## v0.4.0-beta1 (2026-10-17)

Beta: please report anything that looks wrong, especially prices and profits.

Artisan Hub (rebuilt):
- New Hub window with a navigation rail and seven pages: Overview, Crafting, Queue & Shopping, Concentration, Crafting Orders, Auction House and Ledger. Session Loot and Recipe Matcher open from the rail footer, with Settings as the last entry; the rail shows the craft queue size and the number of undercut auctions.
- Every page follows one layout: a title with a one-line purpose, one column header, collapsible groups with a summary on the right, and the details of a row in its tooltip.
- Overview: three cards (best craft now, net of the last 7 days, undercut auctions) and the top crafts. Each card opens the page that answers it; Best craft opens Crafting with that recipe pinned to the top.
- Crafting: recipes grouped by profession with Recipe, Craft cost, Profit and Profit % columns. Hover a recipe for the full breakdown: profit for every reachable result quality with the reagent rank mix it needs, the reagents and their sources, yield, AH cut, deposit loss, the concentration option and confidence. Click to open the recipe, Ctrl-click to queue it, Alt-click for price history, right-click to add it to the shopping list.
- Queue & Shopping: two groups with their totals on the header. The queue shows crafted / total, remaining cost and expected profit; Shopping lists the reagents still to get (gatherable ones open their Session Loot tab) and the recipes on the list. List actions are on the title bar.
- Concentration: one group per character with its profession pools (bar and time until full) and recipe cooldowns. A profession's concentration plan is in its tooltip; Ctrl-click queues the planned crafts.
- Crafting Orders: orders grouped by type (patron, public, personal, guild) with the best net per group; tip, rewards and the reagents you supply are in the tooltip.
- Auction House: your auctions with undercut status and cancel, price watch, and opportunities (deals and movers against the 7-day average), with the AH sync button.
- Ledger: 7 or 30 days of sales and crafts, observed proc factors, gold history and top items.
- Long tables scroll smoothly: rows outside the window are not drawn.
- Clear and reset actions ask for confirmation; Session Loot closes with Esc.

Economy engine (new):
- Crafting expected value: every recipe is valued per reachable quality from the game's own crafting prediction, which already includes your skill, profession stats, profession equipment, specialization and buffs. Multicraft yield, Resourcefulness savings, Ingenuity refunds, the AH cut and expected deposit loss are applied on top.
- Reagent rank choice: for every result quality the cheapest reagent rank mix is chosen on the same prices the profit uses (bags, current or 7-day prices, make vs buy, Resourcefulness), with and without concentration.
- Make vs buy: intermediate reagents are costed at the cheaper of buying or crafting them (up to 3 levels deep).
- Market depth: AH scans keep listed quantity and the cheapest price levels (your own listings excluded), so shopping costs walk the order book.
- Vendor prices: vendor-sold reagents are captured at merchants and used when cheaper than the AH.
- Craft ledger: every craft result is recorded and calibrates the proc factors once enough crafts are observed.
- TSM price source choice (DBMarket, DBMinBuyout, DBRecent, DBHistorical, DBRegionMarketAvg, DBRegionSaleAvg).
- Sales ledger: AH invoices, purchases, deposits, crafting order tips and gold history; the real house cut is learned from your invoices.
- Concentration planner, crafting orders evaluator, market intelligence (movers, deals, demand), recipe cooldowns with a daily reminder.
- Item tooltips: AH price, 7-day average and trend, listed quantity, net after cut, vendor prices, stock across characters and craft cost / profit (Shift for details).
- Posting helper rebuilt: legal price steps, match-or-undercut by wall depth, never undercuts your own listings, cost floor, deposit / net / profit preview.

AH sync:
- Prices every reagent and output of every Midnight recipe, including recipes you never opened. Soulbound items are no longer scanned.
- Current-expansion equipment is priced from one browse of weapons, armor and profession tools instead of one search per item; prices per item level are kept.
- One query budget under Blizzard's 100 searches per minute; the no-listings cache only records an item when the AH returned complete results.
- The tooltip and chat say how many items are priced, how many have no listings and how to force a full rescan (prices younger than the freshness window are kept).

Character data:
- One character data provider for concentration, recipe knowers, alt item counts and characters. With Warband Nexus installed (optional) its data is used; without it, Artisan Nexus collects everything itself.

Settings and UI:
- New interface built on the Warband Nexus UI (Modern and Classic skins, dark or light), resizable Hub that remembers its size, position and last page.
- Settings live in the Hub (General, Appearance, Gathering & Loot, Crafting & Economy, Auction House, Advanced); window gear buttons, the minimap right-click and Esc > Options > AddOns open it.
- Appearance settings from Warband Nexus: fonts, font scale, UI scale, theme and accent colour.
- Only three slash commands: /an (Hub), /an history (Session Loot) and /an config (Settings).

Fixed:
- Recipes with a plain reagent slot and a ranked reagent slot sharing a slot number merged them and priced ranked reagents at the plain reagent's price, showing large false profits (for example Sunfire Silk Backpack). Recipes are read again the next time you open each profession.
- Required non-basic reagent slots (for example Sparks) were left out of the craft cost.
- Soulbound reagents with no buy or craft cost hid the whole recipe; they are now listed as not included in the cost.
- Reagents and outputs could be priced from different sources and dates; an item whose listings are gone no longer keeps its old price as current.
- A quality without its own price was valued at the base item's price.
- Ingenuity uses the refund the game reports instead of a fixed share.
- Snapshots taken on another character no longer count as high confidence; a gear or specialization change made with the profession window closed now refreshes the prediction on the next open.
- Equipment was never found by the AH sync and was recorded as having no listings.
- The AH sync crawled at the end of a scan (silent searches slowed every following one).
- Gear deposits no longer use the commodity deposit rule.
- Lua error on login with WoW 12.1.5 (removed global item APIs); quality simulation sent reagents in the pre-12.0 shape; commodities missing from a batch were never priced; item auction prices were divided by quantity.
- Money in tables no longer gets cut off; cards are laid out like Warband Nexus.

Removed:
- Unused libraries (AceConfig, AceDBOptions, AceGUI, AceHook, AceSerializer, LibDeflate), the old Hub and other dead code and strings.