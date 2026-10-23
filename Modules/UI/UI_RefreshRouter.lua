--[[
    Warband Nexus - Main shell WN_* message listeners (PopulateContent coalescing).
    Split from Modules/UI.lua CreateMainWindow closure.
    Loaded from WarbandNexus.toc immediately before Modules/UI.lua.
]]

local _, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

ns.UI_RefreshRouter = ns.UI_RefreshRouter or {}

function ns.UI_RefreshRouter.RegisterMainShellListeners(ctx)
    if not ctx or not ctx.addon or not ctx.frame or not ctx.eventsSelf or not ctx.constants or not ctx.state then
        return
    end
    local UIEvents = ctx.eventsSelf
    if UIEvents._wnMainShellListenersRegistered then
        return
    end
    UIEvents._wnMainShellListenersRegistered = true
    local WarbandNexus = ctx.addon
    local f = ctx.frame
    local Constants = ctx.constants
    local st = ctx.state
    local SchedulePopulateContent = ctx.schedulePopulate
    local ScheduleGearTabInventoryNarrowRefresh = ctx.scheduleGearInvNarrow
    local ThrottledScheduleGearAsyncRepaint = ctx.throttledGearAsyncRepaint
    local IsGearTabPopulateQuiet = ctx.isGearTabQuiet
    local UpdateTabVisibility = ctx.updateTabVisibility
    local ScrollMainNavEnsureTabVisible = ctx.scrollNavEnsureTabVisible
    local UpdateTabButtonStates = ctx.updateTabButtonStates
    local GEAR_STORAGE_REC_REFRESH_DEBOUNCE = ctx.gearStorageRecRefreshDebounce or 0.06

    -- Tab-leave paint cancel (gear draw gen, plans browse pump, pve/items chunk gens): UI.lua
    -- ActivateMainTab calls ns.UI_CancelLeavingTabStagedPaint before staged detach/populate.
    -- update arrived so the master OnShow hook (UI.lua CreateMainWindow) can repaint
    -- once on reopen; without this, events during combat-hide or a manual close leave
    -- stale tab content until the user switches tabs.
    local function HiddenOrMissing()
        if not f then return true end
        if not f:IsShown() then
            st.dirtyWhileHidden = true
            return true
        end
        return false
    end
    -- NOTE: All RegisterMessage calls use UIEvents as the 'self' key to avoid
    -- overwriting other modules' handlers for the same AceEvent message.
    -- AceEvent allows only ONE handler per (event, self) pair.
    -- Artisan Nexus tabs (replaces the Warband Nexus data listeners: items, gear, PvE, currency,
    -- reputation, plans, collections, professions, characters, bags, money, vault, tracking, gold,
    -- money log, item metadata, achievement criteria, GET_ITEM_INFO_RECEIVED).
    -- AN_* data message -> coalesced repaint of the tabs that read it ("*" = whichever tab is
    -- visible; former Hub/HubWindow.lua hooks). Rail count badges follow every message.
    local ANY = "*"
    local AN_TAB_REFRESH = {
        { "AH_PRICES_UPDATED", ANY },
        { "RECIPE_SCHEMATICS_UPDATED", ANY },
        { "PROFESSION_SNAPSHOT_UPDATED", ANY },
        { "CRAFT_BRIEFING_UPDATED", ANY },
        { "PROFESSION_EQUIPMENT_UPDATED", ANY },
        { "CRAFT_OPS_UPDATED", ANY },
        { "VENDOR_PRICES_UPDATED", ANY },
        { "ECONOMY_CONFIG_CHANGED", ANY },
        -- Crafting marks recipes that are on the list / in the queue.
        { "SHOPPING_LIST_UPDATED", { plan = true, crafting = true, settings = true } },
        { "CRAFT_QUEUE_UPDATED", { plan = true, crafting = true } },
        { "CRAFTING_ORDERS_UPDATED", { orders = true, overview = true } },
        { "MARKET_INTEL_UPDATED", { market = true, overview = true } },
        { "OWNED_AUCTIONS_UPDATED", { market = true, overview = true } },
        { "SALES_LEDGER_UPDATED", { ledger = true, overview = true, settings = true } },
        { "CRAFT_LEDGER_UPDATED", { ledger = true, overview = true } },
        { "COOLDOWNS_UPDATED", { concentration = true, overview = true } },
        -- New shadow price changes concentration value -> profit recommendations too.
        { "CONCENTRATION_PLAN_UPDATED", { concentration = true, crafting = true, plan = true, overview = true, settings = true } },
        -- Warband Nexus alt inventories / concentration (bridge already coalesces 0.5s).
        { "WN_DATA_UPDATED", { plan = true, concentration = true, overview = true } },
        -- Crafting row names are inked by craft status (reagents in bags / bank / warband bank); the
        -- shopping list's have / buy counts follow purchases, mail, crafts and auctions posted.
        { "BAG_STOCK_UPDATED", { crafting = true, plan = true } },
    }
    for i = 1, #AN_TAB_REFRESH do
        local msg = Constants.EVENTS[AN_TAB_REFRESH[i][1]]
        local tabs = AN_TAB_REFRESH[i][2]
        if msg then
            WarbandNexus.RegisterMessage(UIEvents, msg, function()
                -- Hidden: only mark dirty; the OnShow repaint (PopulateContent) recounts the badges.
                if HiddenOrMissing() then return end
                if WarbandNexus.UpdateTabCountBadges then
                    WarbandNexus:UpdateTabCountBadges()
                end
                if tabs == ANY or tabs[f.currentTab] then
                    SchedulePopulateContent(true)
                end
            end)
        end
    end
    WarbandNexus.RegisterMessage(UIEvents, Constants.EVENTS.SESSION_LOOT_UPDATED, function()
        local p = WarbandNexus.db and WarbandNexus.db.profile
        if not HiddenOrMissing() and f.currentTab == "crafting" and p and p.hubSessionOnly then
            SchedulePopulateContent(true)
        end
    end)
    -- AH open state gates the Market tab's Cancel buttons.
    WarbandNexus.RegisterEvent(UIEvents, "AUCTION_HOUSE_SHOW", function()
        if not HiddenOrMissing() and f.currentTab == "market" then SchedulePopulateContent(true) end
    end)
    WarbandNexus.RegisterEvent(UIEvents, "AUCTION_HOUSE_CLOSED", function()
        if not HiddenOrMissing() and f.currentTab == "market" then SchedulePopulateContent(true) end
    end)

    -- Pure UI state (sub-tab switches, expand/collapse, column pickers, theme accent): coalesced rebuild.
    WarbandNexus.RegisterMessage(UIEvents, Constants.EVENTS.UI_MAIN_REFRESH_REQUESTED, function(_, payload)
        if HiddenOrMissing() then return end
        local tab = payload and payload.tab
        if tab and f.currentTab ~= tab then return end
        local skipCooldown = true
        if payload and payload.skipCooldown == false then
            skipCooldown = false
        end
        -- Bypass POPULATE_DEBOUNCE for explicit UI gestures (e.g. Storage section expand/collapse).
        if payload and payload.instantPopulate then
            if st.pendingPopulateTimer then
                if st.pendingPopulateTimer.Cancel then
                    st.pendingPopulateTimer:Cancel()
                end
            end
            st.pendingPopulateTimer = nil
            st.populateDebounceGen = st.populateDebounceGen + 1
            st.pendingPopulateSkipCooldown = false
            if HiddenOrMissing() then return end
            st.lastEventPopulateTime = GetTime()
            local P = ns.Profiler
            local mlab = P and P.enabled and P.SliceLabel and P:SliceLabel(P.CAT.MSG, "UI_MAIN_REFRESH_instant")
            if mlab then P:Start(mlab) end
            WarbandNexus:PopulateContent(true)
            if mlab then P:Stop(mlab) end
            return
        end
        SchedulePopulateContent(skipCooldown)
    end)

    WarbandNexus.RegisterMessage(UIEvents, Constants.EVENTS.MODULE_TOGGLED, function(_, moduleName, enabled)
        if HiddenOrMissing() or not f.tabButtons then return end
        -- Map module name to tab key (currencies -> currency; others same)
        local tabKey = (moduleName == "currencies") and "currency" or moduleName
        UpdateTabVisibility(f)
        if f.currentTab then
            ScrollMainNavEnsureTabVisible(f, f.currentTab)
        end
        -- Only leave the tab when the module is turned off (enabling must not bounce to Characters).
        if enabled == false and f.currentTab == tabKey then
            f.currentTab = (ns.UI_MAIN_TAB_ORDER and ns.UI_MAIN_TAB_ORDER[1]) or "overview"
            if WarbandNexus.db and WarbandNexus.db.profile then
                WarbandNexus.db.profile.lastTab = f.currentTab
            end
            UpdateTabButtonStates(f)
            ScrollMainNavEnsureTabVisible(f, f.currentTab)
            SchedulePopulateContent()
        elseif f.currentTab == "items" and ns.UI_GetItemsSubTab and ns.UI_GetItemsSubTab() == "warband"
            and (moduleName == "items" or moduleName == "storage") then
            SchedulePopulateContent(true)
        end
    end)

    WarbandNexus.RegisterMessage(UIEvents, Constants.EVENTS.FONT_CHANGED, function()
        if ns.UI_RefreshExternalFloatingWindows then
            ns.UI_RefreshExternalFloatingWindows()
        end
        if not HiddenOrMissing() then
            SchedulePopulateContent()
        end
    end)
end

--- Shell OnShow dirty-repaint + debug header sync (ops-039 slice).
function ns.UI_RefreshRouter.RegisterShellLifecycleHooks(ctx)
    if not ctx or not ctx.addon or not ctx.frame or not ctx.state or not ctx.schedulePopulate then
        return
    end
    local f = ctx.frame
    if f._wnShellLifecycleHooksRegistered then
        return
    end
    f._wnShellLifecycleHooksRegistered = true
    local WarbandNexus = ctx.addon
    local st = ctx.state
    local SchedulePopulateContent = ctx.schedulePopulate

    f:HookScript("OnShow", function(self)
        ns._wnMainWindowVisible = true
        if not st.dirtyWhileHidden then return end
        st.lastEventPopulateTime = 0
        C_Timer.After(0.2, function()
            if not self:IsShown() then return end
            if st.dirtyWhileHidden then
                SchedulePopulateContent(true)
            end
        end)
    end)

    if ctx.syncDebugHeader then
        local shellEv = ns.Constants and ns.Constants.EVENTS
        if WarbandNexus.RegisterMessage and shellEv and shellEv.UI_DEBUG_HEADER_SYNC then
            if not ns._uiDebugHeaderSyncListener then
                ns._uiDebugHeaderSyncListener = {}
                WarbandNexus.RegisterMessage(ns._uiDebugHeaderSyncListener, shellEv.UI_DEBUG_HEADER_SYNC, function()
                    if f.SyncMainHeaderDebugReloadLayout then
                        f:SyncMainHeaderDebugReloadLayout()
                    end
                end)
            end
        end
    end
end
