-- DisenchantingAddon.lua
-- Core logic: initialization, tooltip hook, display formatting, slash commands.

DisenchantingAddon = DisenchantingAddon or {}
local DA = DisenchantingAddon

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local ADDON_NAME  = "DisenchantingAddon"
local COLOR_TITLE = "|cFF00FFFF"   -- cyan
local COLOR_GOLD  = "|cFFFFD700"   -- gold
local COLOR_WARN  = "|cFFFF8C00"   -- orange
local COLOR_ERR   = "|cFFFF4444"   -- red
local COLOR_RESET = "|r"

-- WoW item quality constants (Enum.ItemQuality)
local QUALITY_UNCOMMON = 2
local QUALITY_RARE     = 3
local QUALITY_EPIC     = 4

-- ---------------------------------------------------------------------------
-- SavedVariables / DB
-- ---------------------------------------------------------------------------
local function InitDB()
    if not DisenchantingAddonDB then
        DisenchantingAddonDB = {}
    end
    local db = DisenchantingAddonDB

    -- Global (shared across all characters on this account).
    if not db.prices   then db.prices   = {} end
    if not db.settings then
        db.settings = {
            showTooltip   = true,   -- master on/off for tooltip additions
            showBreakdown = true,   -- show per-mat lines (false = total line only)
            showSource    = false,  -- show price source tag (TSM / cached / stale)
        }
    end

    -- Per-character data, namespaced by "Realm-CharName".
    -- skillCache and tracking are character-specific: skill level and
    -- disenchanting history vary per character.
    if not db.chars then db.chars = {} end
    local charName  = UnitName("player") or "Unknown"
    local realmName = GetRealmName()     or "Unknown"
    local charKey   = realmName .. "-" .. charName
    if not db.chars[charKey] then db.chars[charKey] = {} end
    local charDb = db.chars[charKey]
    if not charDb.skillCache then charDb.skillCache = {} end
    if not charDb.tracking   then charDb.tracking   = {} end

    -- Migrate legacy flat-layout data (pre-per-character format).
    if db.skillCache and next(db.skillCache) then
        for k, v in pairs(db.skillCache) do
            if not charDb.skillCache[k] then charDb.skillCache[k] = v end
        end
        db.skillCache = nil
    end
    if db.tracking and next(db.tracking) then
        for k, v in pairs(db.tracking) do
            if not charDb.tracking[k] then charDb.tracking[k] = v end
        end
        db.tracking = nil
    end

    DA.db     = db
    DA.charDb = charDb
end

-- ---------------------------------------------------------------------------
-- Gold formatting
-- Converts a copper integer to a coloured "Xg Xs Xc" string.
-- ---------------------------------------------------------------------------
function DA:FormatGold(copper)
    if not copper or copper <= 0 then
        return COLOR_ERR .. "N/A" .. COLOR_RESET
    end
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop    = copper % 100

    if gold > 0 then
        return string.format("%s%dg%s %s%ds%s %s%dc%s",
            COLOR_GOLD,   gold,   COLOR_RESET,
            "|cFFC0C0C0", silver, COLOR_RESET,
            "|cFFCD7F32", cop,    COLOR_RESET)
    elseif silver > 0 then
        return string.format("%s%ds%s %s%dc%s",
            "|cFFC0C0C0", silver, COLOR_RESET,
            "|cFFCD7F32", cop,    COLOR_RESET)
    else
        return string.format("%s%dc%s", "|cFFCD7F32", cop, COLOR_RESET)
    end
end

-- ---------------------------------------------------------------------------
-- Item utility helpers
-- ---------------------------------------------------------------------------

-- Returns true if the item's equipLoc indicates it is wearable gear.
local EQUIPPABLE = {
    INVTYPE_HEAD=true, INVTYPE_NECK=true, INVTYPE_SHOULDER=true,
    INVTYPE_BODY=true, INVTYPE_CHEST=true, INVTYPE_WAIST=true,
    INVTYPE_LEGS=true, INVTYPE_FEET=true, INVTYPE_WRIST=true,
    INVTYPE_HAND=true, INVTYPE_FINGER=true, INVTYPE_TRINKET=true,
    INVTYPE_CLOAK=true, INVTYPE_WEAPON=true, INVTYPE_SHIELD=true,
    INVTYPE_RANGED=true, INVTYPE_2HWEAPON=true, INVTYPE_WEAPONMAINHAND=true,
    INVTYPE_WEAPONOFFHAND=true, INVTYPE_HOLDABLE=true, INVTYPE_THROWN=true,
    INVTYPE_RANGEDRIGHT=true, INVTYPE_ROBE=true, INVTYPE_TABARD=true,
    INVTYPE_PROFESSION_GEAR=true, INVTYPE_PROFESSION_TOOL=true,
}

local function IsDisenchantableEquipLoc(equipLoc)
    return equipLoc and EQUIPPABLE[equipLoc] == true
end

-- Returns the display name for a mat, falling back to the static name if the
-- item isn't cached in the client yet.
local function GetMatName(mat)
    if mat.id and mat.id > 0 then
        -- GetItemName takes an ItemLocation; GetItemNameByID takes an item ID.
        local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(mat.id)
        if name then return name end
        -- Fallback: GetItemInfo still works and returns the name as the first value.
        local fallbackName = GetItemInfo(mat.id)
        if fallbackName then return fallbackName end
    end
    return mat.name or ("Item #" .. (mat.id or "?"))
end

-- ---------------------------------------------------------------------------
-- Core tooltip builder
-- Called after each item tooltip is populated.
-- ---------------------------------------------------------------------------
local function BuildDisenchantLines(tooltip, data)
    if not tooltip then return end
    if not DA.db or not DA.db.settings.showTooltip then return end

    -- Resolve the item link.
    -- tooltip:GetItem() is preferred: it reads directly from the tooltip's internal
    -- state and works even for items not yet in the client cache.  However, in
    -- Midnight some tooltip frame types don't expose this method, so fall back to
    -- the TooltipDataProcessor data object fields when it's unavailable.
    local itemLink
    if tooltip.GetItem then
        local _, link = tooltip:GetItem()
        itemLink = link
    end
    if not itemLink and data then
        itemLink = data.hyperlink or data.link or data.itemLink
        if not itemLink and (data.id or data.itemID) then
            -- GetItemInfo returns nil for uncached items; the hook re-fires once cached.
            local _, link = GetItemInfo(data.id or data.itemID)
            itemLink = link
        end
    end
    -- One-shot diagnostic: dump tooltip + data fields to the debug frame.
    if DA.tooltipDebug then
        DA.tooltipDebug = false
        DA:ClearDebugOutput()
        DA:DebugOutput("=== /dea tooltipdebug ===")
        DA:DebugOutput("tooltip type : " .. tostring(type(tooltip)))
        DA:DebugOutput("tooltip.GetItem : " .. tostring(tooltip and tooltip.GetItem))
        DA:DebugOutput("itemLink resolved: " .. tostring(itemLink))
        if data then
            DA:DebugOutput("data fields:")
            local ok, err = pcall(function()
                for k, v in pairs(data) do
                    DA:DebugOutput(string.format("  .%s = %s  (%s)", tostring(k), tostring(v), type(v)))
                end
            end)
            if not ok then DA:DebugOutput("  pairs(data) error: " .. tostring(err)) end
        else
            DA:DebugOutput("data: nil")
        end
    end

    if not itemLink then return end

    -- ---- If this item is one of our tracked mats, show its AH price. --------
    local matItemID = C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(itemLink)
    if matItemID and DA.MATS_BY_ID and DA.MATS_BY_ID[matItemID] then
        local price, source = DA:GetItemPrice(matItemID)
        local stale = (source == "cache") and DA:IsPriceStale(matItemID)

        -- When shift is held, try to read the stack count from the bag slot.
        local stackCount = 1
        if IsShiftKeyDown and IsShiftKeyDown() then
            local owner = tooltip:GetOwner()
            if owner and owner.GetParent and owner.GetID then
                local bag  = owner:GetParent():GetID()
                local slot = owner:GetID()
                if bag and slot and bag >= 0 and bag <= 5 then
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if info and info.stackCount and info.stackCount > 1 then
                        stackCount = info.stackCount
                    end
                end
            end
        end

        tooltip:AddLine(" ")
        if price then
            local staleTag = stale and (" " .. COLOR_WARN .. "[stale]" .. COLOR_RESET) or ""
            local srcTag   = (not stale and DA.db.settings.showSource and source)
                and (" |cFF888888[" .. source .. "]|r") or ""

            -- Per-unit price
            tooltip:AddDoubleLine(
                COLOR_TITLE .. "AH Price" .. COLOR_RESET,
                DA:FormatGold(price) .. staleTag .. srcTag,
                1, 1, 1, 1, 1, 1)

            -- Stack total (only when shift is held and count > 1)
            if stackCount > 1 then
                tooltip:AddDoubleLine(
                    COLOR_TITLE .. "Stack Value" .. COLOR_RESET
                        .. string.format(" |cFF888888(x%d)|r", stackCount),
                    DA:FormatGold(price * stackCount),
                    1, 1, 1, 1, 1, 1)
            end
        else
            tooltip:AddDoubleLine(
                COLOR_TITLE .. "AH Price" .. COLOR_RESET,
                COLOR_ERR .. "No price — run /dea scan" .. COLOR_RESET,
                1, 1, 1, 1, 1, 1)
        end
        tooltip:Show()
        return
    end

    -- GetItemInfo may return nil on first call if the item isn't cached yet.
    -- WoW will call the tooltip hook again once data arrives, so this is fine.
    -- expansionID is the 15th return value.
    local _, _, quality, _, _, _, _, _, equipLoc, _, _, _, _, _, expansionID =
        C_Item.GetItemInfo(itemLink)
    if not quality then return end

    -- Only process equippable greens / blues / epics.
    if quality < QUALITY_UNCOMMON or quality > QUALITY_EPIC then return end
    if not IsDisenchantableEquipLoc(equipLoc) then return end

    -- Show a simple unsupported note for expansions we don't have data for.
    local results = DA:GetDisenchantResults(quality, expansionID)
    if not results or #results == 0 then
        tooltip:AddLine(" ")
        tooltip:AddLine(COLOR_TITLE .. "Disenchanting" .. COLOR_RESET
            .. "  |cFF888888(expansion not supported)|r")
        tooltip:Show()
        return
    end

    -- ---- Require observed data — no static estimates shown ------------------
    local trackedRates, trackedAttempts, rateSource = DA:GetTrackedRates(quality, expansionID)

    if not trackedRates then
        tooltip:AddLine(" ")
        tooltip:AddLine(COLOR_TITLE .. "Disenchanting" .. COLOR_RESET
            .. "  |cFF888888(disenchant to build data)|r")
        tooltip:Show()
        return
    end

    -- Build mat list from observed rates only.
    local matList    = {}
    local dataSource = "observed"
    for _, r in ipairs(trackedRates) do
        table.insert(matList, {
            itemID             = r.itemID,
            avgQty             = r.avgQty,
            dropChance         = r.dropChance,
            avgQtyWhenReceived = r.avgQtyWhenReceived,
        })
    end

    -- ---- Build display data ------------------------------------------------
    local lines         = {}
    local totalCopper   = 0
    local allHavePrices = true
    local anyStale      = false

    -- Quality tier labels (r1/r2/r3 — placeholder until Midnight atlas names are confirmed).
    local QUALITY_ICONS = {
        [1] = "|cFFC0C0C0r1|r",
        [2] = "|cFFFFD700r2|r",
        [3] = "|cFF0070DDr3|r",
    }

    for _, entry in ipairs(matList) do
        local itemID = entry.itemID
        local avgQty = entry.avgQty

        -- Resolve mat definition (for name + quality tier icon).
        local mat = entry.mat or (DA.MATS_BY_ID and DA.MATS_BY_ID[itemID])

        -- Resolve display name
        local name
        if mat then
            name = GetMatName(mat)
        else
            name = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID))
                or GetItemInfo(itemID)
                or ("Item #" .. itemID)
        end

        -- Append quality tier icon if available.
        local qualityIcon = mat and mat.qualityTier and QUALITY_ICONS[mat.qualityTier]
        if qualityIcon then
            name = name .. " " .. qualityIcon
        end

        local price, source = DA:GetItemPrice(itemID)
        local stale = (source == "cache") and DA:IsPriceStale(itemID)
        if stale then anyStale = true end

        local leftText, rightText

        if DA.db.settings.showBreakdown then
            if dataSource == "observed" then
                if entry.dropChance then
                    leftText = string.format("  %s  |cFFFFFFFF%.0f%%|r · |cFFFFFFFFavg %.1fx|r",
                        name, entry.dropChance * 100, entry.avgQtyWhenReceived)
                else
                    leftText = string.format("  %s  |cFFFFFFFFavg %.2fx|r", name, avgQty)
                end
            else
                local result = entry.result
                if result.minQty == result.maxQty then
                    leftText = string.format("  %s x%d", name, result.minQty)
                else
                    leftText = string.format("  %s x%d-%d", name, result.minQty, result.maxQty)
                end
                if result.chance < 1.0 then
                    leftText = leftText .. string.format(" (%.0f%%)", result.chance * 100)
                end
            end
        else
            leftText = string.format("  %s", name)
        end

        if price then
            local expectedCopper = math.floor(avgQty * price)
            totalCopper = totalCopper + expectedCopper
            -- Per-row shows actual value when received (not probability-weighted),
            -- so the number is intuitive. Total uses probability-weighted avgQty.
            local displayCopper = entry.avgQtyWhenReceived
                and math.floor(entry.avgQtyWhenReceived * price)
                or  expectedCopper
            rightText = DA:FormatGold(displayCopper)
            if stale then
                rightText = rightText .. " " .. COLOR_WARN .. "[stale]" .. COLOR_RESET
            elseif DA.db.settings.showSource and source then
                rightText = rightText .. " " .. "|cFF888888[" .. source .. "]" .. COLOR_RESET
            end
        else
            allHavePrices = false
            rightText = COLOR_ERR .. "No price" .. COLOR_RESET
        end

        table.insert(lines, { left = leftText, right = rightText })
    end

    -- ---- Append to tooltip -------------------------------------------------
    -- Separator + header
    tooltip:AddLine(" ")
    tooltip:AddLine(COLOR_TITLE .. "Disenchanting" .. COLOR_RESET)

    -- Per-mat breakdown lines
    if DA.db.settings.showBreakdown then
        for _, line in ipairs(lines) do
            tooltip:AddDoubleLine(line.left, line.right, 1, 1, 1, 1, 1, 1)
        end
    end

    -- Divider + total expected value
    if totalCopper > 0 then
        tooltip:AddLine("|cFF555555" .. string.rep("-", 65) .. "|r")
        local totalLabel = "  " .. COLOR_GOLD .. "Expected Value" .. COLOR_RESET
        tooltip:AddDoubleLine(totalLabel, DA:FormatGold(totalCopper), 1, 1, 1, 1, 1, 1)
    end

    -- Data source footnote
    if rateSource == "community" then
        tooltip:AddLine(string.format("  |cFF888888Community data (%d disenchant(s))|r", trackedAttempts))
    else
        tooltip:AddLine(string.format("  |cFF888888Based on %d disenchant(s)|r", trackedAttempts))
    end

    -- Hints when prices are missing or stale
    if not allHavePrices then
        tooltip:AddLine("  " .. COLOR_WARN .. "Visit the AH and /dea scan for prices" .. COLOR_RESET)
    elseif anyStale then
        tooltip:AddLine("  " .. COLOR_WARN .. "Prices may be outdated — run /dea scan" .. COLOR_RESET)
    end

    -- Force the tooltip to resize to fit the new lines.
    tooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Tooltip hooks
-- ---------------------------------------------------------------------------
local function HookTooltips()
    -- TooltipDataProcessor is the modern (retail DF/TWW) API.
    -- It fires after all tooltip lines have been set, including for item links
    -- in chat, loot windows, bags, etc.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            BuildDisenchantLines(tooltip, data)
        end)
    else
        -- Fallback: direct script hook on the primary game tooltip.
        GameTooltip:HookScript("OnTooltipSetItem", BuildDisenchantLines)
        ItemRefTooltip:HookScript("OnTooltipSetItem", BuildDisenchantLines)
    end
end

-- ---------------------------------------------------------------------------
-- Addon event frame
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame", ADDON_NAME .. "Frame", UIParent)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        HookTooltips()
        DA:RegisterPriceEvents(self)    -- from Prices.lua
        DA:RegisterTrackingEvents(self) -- from Tracking.lua
        DA:PreloadMatNames()            -- from DisenchantData.lua
        print(COLOR_TITLE .. "Disenchanting Advisor" .. COLOR_RESET .. " loaded. Type /dea for commands.")

    elseif event == "PLAYER_LOGIN" then
        DA:PrintLoginSummary()

    else
        -- Delegate to subsystem handlers.
        DA:HandlePriceEvent(event, arg1, ...)
        DA:HandleTrackingEvent(event, arg1, ...)
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_DISENCHANTADDON1 = "/dea"
SLASH_DISENCHANTADDON2 = "/disenchantadvisor"

SlashCmdList["DISENCHANTADDON"] = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.*)")
    cmd = (cmd or ""):lower()

    if cmd == "scan" then
        DA:ScanAHPrices()

    elseif cmd == "toggle" then
        DA.db.settings.showTooltip = not DA.db.settings.showTooltip
        local state = DA.db.settings.showTooltip
            and ("|cFF00FF00enabled" .. COLOR_RESET)
            or  (COLOR_ERR .. "disabled" .. COLOR_RESET)
        print(COLOR_TITLE .. "Disenchanting Advisor:" .. COLOR_RESET .. " Tooltip " .. state)

    elseif cmd == "breakdown" then
        DA.db.settings.showBreakdown = not DA.db.settings.showBreakdown
        local state = DA.db.settings.showBreakdown
            and ("|cFF00FF00enabled" .. COLOR_RESET)
            or  (COLOR_ERR .. "disabled" .. COLOR_RESET)
        print(COLOR_TITLE .. "Disenchanting Advisor:" .. COLOR_RESET .. " Per-mat breakdown " .. state)

    elseif cmd == "source" then
        DA.db.settings.showSource = not DA.db.settings.showSource
        local state = DA.db.settings.showSource
            and ("|cFF00FF00shown" .. COLOR_RESET)
            or  (COLOR_ERR .. "hidden" .. COLOR_RESET)
        print(COLOR_TITLE .. "Disenchanting Advisor:" .. COLOR_RESET .. " Price source tag " .. state)

    elseif cmd == "setprice" then
        -- Usage: /dea setprice <itemID> <gold>[g] [<silver>s] [<copper>c]
        -- Simple form: /dea setprice 224069 50g
        local itemID, goldStr = rest:match("^(%d+)%s+(%d+)g?$")
        if itemID and goldStr then
            local copper = tonumber(goldStr) * 10000
            DA:SetManualPrice(tonumber(itemID), copper)
            print(string.format("%sDisenchanting Advisor:%s Set price for item %d to %s",
                COLOR_TITLE, COLOR_RESET, tonumber(itemID), DA:FormatGold(copper)))
        else
            print(COLOR_TITLE .. "Disenchanting Advisor:" .. COLOR_RESET ..
                " Usage: /dea setprice <itemID> <gold>  (e.g. /dea setprice 224069 50)")
        end

    elseif cmd == "stats" then
        DA:ToggleStatsFrame()

    elseif cmd == "trackdebug" then
        DA:ToggleTrackDebug()

    elseif cmd == "skillcheck" then
        DA:SkillCheck()

    elseif cmd == "clearstats" then
        DA:ClearTrackingData()

    elseif cmd == "prices" then
        -- Dump price lookup results for every known mat.
        print(COLOR_TITLE .. "Disenchanting Advisor — price diagnostics:" .. COLOR_RESET)
        print("  TSM_API present: " .. tostring(TSM_API ~= nil))
        for key, mat in pairs(DA.MATS) do
            if mat.id and mat.id > 0 then
                local name = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(mat.id))
                          or mat.name or ("Item #" .. mat.id)
                local price, source = DA:GetItemPrice(mat.id)
                local priceStr = price and DA:FormatGold(price) or (COLOR_ERR .. "nil" .. COLOR_RESET)
                print(string.format("  [%d] %s → %s (src=%s)", mat.id, name, priceStr, tostring(source)))
            end
        end

    elseif cmd == "tooltipdebug" then
        DA.tooltipDebug = true
        print(COLOR_TITLE .. "Disenchanting Advisor:" .. COLOR_RESET
            .. " Hover any item — the debug frame will show tooltip/data fields on the next call.")
        DA:ToggleDebugFrame()

    elseif cmd == "debug" then
        -- Print what the addon sees for the currently hovered item.
        local itemLink
        if GameTooltip.GetItem then
            local _, link = GameTooltip:GetItem()
            itemLink = link
        end
        if not itemLink then
            print(COLOR_TITLE .. "Disenchanting Advisor:" .. COLOR_RESET .. " No item currently in tooltip.")
        else
            local name, _, quality, ilvl, _, _, _, _, equipLoc, _, _, _, _, _, expansionID =
                C_Item.GetItemInfo(itemLink)
            print(string.format("%sDisenchanting Advisor:%s item=%s quality=%s ilvl=%s expansionID=%s equipLoc=%s",
                COLOR_TITLE, COLOR_RESET,
                tostring(name), tostring(quality), tostring(ilvl),
                tostring(expansionID), tostring(equipLoc)))
            local results = quality and expansionID and DA:GetDisenchantResults(quality, expansionID)
            if results then
                print("  Disenchant results found: " .. #results .. " mat(s)")
            else
                print("  " .. COLOR_WARN .. "No disenchant data for this quality/expansionID." .. COLOR_RESET)
            end
        end

    else
        print(COLOR_TITLE .. "Disenchanting Advisor" .. COLOR_RESET .. " — commands:")
        print("  " .. COLOR_GOLD .. "/dea scan" .. COLOR_RESET ..
              "          — Scan AH mat prices (must be at the Auction House)")
        print("  " .. COLOR_GOLD .. "/dea toggle" .. COLOR_RESET ..
              "        — Toggle tooltip display on/off")
        print("  " .. COLOR_GOLD .. "/dea breakdown" .. COLOR_RESET ..
              "     — Toggle per-mat breakdown lines")
        print("  " .. COLOR_GOLD .. "/dea source" .. COLOR_RESET ..
              "        — Toggle price source tag (TSM/cache)")
        print("  " .. COLOR_GOLD .. "/dea setprice <id> <g>" .. COLOR_RESET ..
              " — Manually set a mat price")
        print("  " .. COLOR_GOLD .. "/dea stats" .. COLOR_RESET ..
              "         — Open/close the disenchant stats window")
        print("  " .. COLOR_GOLD .. "/dea trackdebug" .. COLOR_RESET ..
              "     — Toggle verbose tracking output (disenchant detection)")
        print("  " .. COLOR_GOLD .. "/dea skillcheck" .. COLOR_RESET ..
              "     — Dev: verify spec skill values and path IDs (not needed for normal use)")
        print("  " .. COLOR_GOLD .. "/dea clearstats" .. COLOR_RESET ..
              "     — Debug: clear all personal tracking data (irreversible)")
        print("  " .. COLOR_GOLD .. "/dea prices" .. COLOR_RESET ..
              "        — Debug: show TSM/cache price for every known mat")
        print("  " .. COLOR_GOLD .. "/dea debug" .. COLOR_RESET ..
              "         — Debug: show what addon sees for hovered item")
        print("  " .. COLOR_GOLD .. "/dea tooltipdebug" .. COLOR_RESET ..
              "  — Debug: dump raw tooltip/data object on next item hover")
    end
end
