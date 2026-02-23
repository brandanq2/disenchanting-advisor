-- Prices.lua
-- Resolves Auction House prices for disenchant materials.
--
-- Priority order:
--   1. TradeSkillMaster (TSM) — if installed and running, provides live/market prices.
--   2. Cached AH scan       — prices saved by a previous /dea scan at the Auction House.
--
-- AH scanning uses C_AuctionHouse.SendBrowseQuery (the same path as the AH UI itself).
-- Results are stored in DisenchantingAdvisorDB.prices[itemID] = { price, timestamp }.

DisenchantingAdvisor = DisenchantingAdvisor or {}
local DA = DisenchantingAdvisor

-- How long (seconds) before a cached price is considered stale and shown with a warning.
local CACHE_STALE_AGE = 60 * 60 * 24 * 2  -- 2 days

-- ---------------------------------------------------------------------------
-- Public: get the best available price (in copper) for an item ID.
-- Returns price (number, in copper) or nil if no price is known.
-- ---------------------------------------------------------------------------
function DA:GetItemPrice(itemID)
    -- 1. TradeSkillMaster
    if TSM_API then
        local itemString = "i:" .. itemID
        local price = TSM_API.GetCustomPriceValue("first(dbminbuyout,dbmarket,vendorbuy)", itemString)
        if price and price > 0 then
            return price, "tsm"
        end
    end

    -- 2. Locally cached scan price
    if DA.db and DA.db.prices and DA.db.prices[itemID] then
        local entry = DA.db.prices[itemID]
        if entry.price and entry.price > 0 then
            return entry.price, "cache"
        end
    end

    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Public: returns true if a cached price exists but is older than CACHE_STALE_AGE.
-- ---------------------------------------------------------------------------
function DA:IsPriceStale(itemID)
    if DA.db and DA.db.prices and DA.db.prices[itemID] then
        local entry = DA.db.prices[itemID]
        if entry.timestamp then
            return (time() - entry.timestamp) > CACHE_STALE_AGE
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Public: manually set a price for an item (copper). Useful for testing.
-- ---------------------------------------------------------------------------
function DA:SetManualPrice(itemID, copperValue)
    if not DA.db then return end
    DA.db.prices[itemID] = {
        price     = copperValue,
        timestamp = time(),
        source    = "manual",
    }
end

-- ---------------------------------------------------------------------------
-- AH Scan — fetches current prices for all tracked mats via SendBrowseQuery.
-- Must be called while the Auction House UI is open.
--
-- Strategy: query by item name, match results by itemID, save minPrice.
-- Multiple quality variants of the same mat share a name, so one query
-- captures all variants; we identify each by itemKey.itemID in the results.
-- ---------------------------------------------------------------------------

local scanState = {
    active    = false,
    queue     = {},   -- { itemID, itemName } pairs still to query
    completed = 0,
    total     = 0,
}

-- Build a deduplicated list of { itemID, itemName } pairs, grouped so that
-- items sharing a name are queried together in a single browse call.
local function BuildScanQueue()
    -- name → list of itemIDs
    local byName = {}
    for _, mat in pairs(DA.MATS) do
        if mat.id and mat.id > 0 then
            local name = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(mat.id))
                      or mat.name
            if name then
                if not byName[name] then byName[name] = {} end
                table.insert(byName[name], mat.id)
            end
        end
    end
    -- Flatten into queue: each entry is { name, ids[] }
    local queue = {}
    for name, ids in pairs(byName) do
        table.insert(queue, { name = name, ids = ids })
    end
    return queue
end

-- Send the next browse query in the queue.
local function ScanNext()
    if #scanState.queue == 0 then
        scanState.active = false
        print(string.format("|cFF00FFFFDisenchanting Advisor:|r Scan complete. Updated %d/%d prices.",
            scanState.completed, scanState.total))
        return
    end

    local entry = table.remove(scanState.queue, 1)
    scanState.currentName = entry.name
    scanState.currentIDs  = entry.ids

    local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, {
        searchString     = entry.name,
        minLevel         = 0,
        maxLevel         = 0,
        filters          = {},
        itemClassFilters = {},
        sorts            = {},
        offset           = 0,
        maxResults       = 50,
    })
    if not ok then
        print("|cFFFF4444[DEA Scan]|r Browse query error (" .. entry.name .. "): " .. tostring(err))
        ScanNext()
    end
end

-- Handle browse results: find our target itemIDs, save minPrice for each.
local function OnBrowseResults()
    if not scanState.active then return end

    -- Build a set of the IDs we're looking for in this batch.
    local wantedIDs = {}
    for _, id in ipairs(scanState.currentIDs or {}) do
        wantedIDs[id] = true
    end

    -- GetBrowseResults() returns the full array directly (12.0+ API).
    local results = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
    for _, result in ipairs(results) do
        if result and result.itemKey then
            local id = result.itemKey.itemID
            if id and wantedIDs[id] and result.minPrice and result.minPrice > 0 then
                DA.db.prices[id] = {
                    price     = result.minPrice,
                    timestamp = time(),
                    source    = "scan",
                }
                scanState.completed = scanState.completed + 1
                wantedIDs[id] = nil  -- mark found
            end
        end
    end

    ScanNext()
end

-- ---------------------------------------------------------------------------
-- Public: kick off a scan for all mat prices.
-- ---------------------------------------------------------------------------
function DA:ScanAHPrices()
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        print("|cFF00FFFFDisenchanting Advisor:|r You must be at the Auction House to scan prices.")
        print("  Tip: Open the AH, then run |cFFFFD700/dea scan|r")
        return
    end

    if scanState.active then
        print("|cFF00FFFFDisenchanting Advisor:|r A scan is already in progress.")
        return
    end

    local queue = BuildScanQueue()
    if #queue == 0 then
        print("|cFF00FFFFDisenchanting Advisor:|r No materials with cached names to scan.")
        print("  Tip: Wait a moment after login for item names to load, then try again.")
        return
    end

    -- Count total unique mat IDs across all queue entries.
    local total = 0
    for _, entry in ipairs(queue) do total = total + #entry.ids end

    scanState.active    = true
    scanState.queue     = queue
    scanState.completed = 0
    scanState.total     = total

    print(string.format("|cFF00FFFFDisenchanting Advisor:|r Scanning prices (%d queries for %d mats)...",
        #queue, total))
    ScanNext()
end

-- ---------------------------------------------------------------------------
-- Register AH event listeners.
-- ---------------------------------------------------------------------------
function DA:RegisterPriceEvents(frame)
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
end

function DA:HandlePriceEvent(event, ...)
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        OnBrowseResults()
    end
end
