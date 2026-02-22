-- UI/StatsFrame.lua
-- Movable window showing cached disenchanting tracking data.
-- Open/close with /dea stats.

DisenchantingAddon = DisenchantingAddon or {}
local DA = DisenchantingAddon

local FRAME_W    = 460
local FRAME_H    = 500
local CONTENT_W  = 400   -- scroll child width (inside scrollbar)
local PAD        = 14
local LINE_H     = 18
local SECTION_GAP = 8

local statsFrame
local linePool   = {}
local activeLines = 0

local COLOR_RESET  = "|r"
local COLOR_GOLD   = "|cFFFFD700"
local COLOR_GREY   = "|cFF888888"
local COLOR_WARN   = "|cFFFF8C00"

local QUALITY_COLORS = {
    [2] = "|cFF1EFF00",   -- green
    [3] = "|cFF0070DD",   -- blue
    [4] = "|cFFA335EE",   -- purple
}
local QUALITY_LABELS = {
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "Epic",
}
local QUALITY_ICONS = {
    [1] = "|cFFC0C0C0r1|r",
    [2] = "|cFFFFD700r2|r",
    [3] = "|cFF0070DDr3|r",
}

-- ---------------------------------------------------------------------------
-- FontString pool — reuse across refreshes to avoid GC churn.
-- ---------------------------------------------------------------------------
local function ResetLines()
    activeLines = 0
    for _, fs in ipairs(linePool) do
        fs:Hide()
    end
end

local function NextLine(parent)
    activeLines = activeLines + 1
    if not linePool[activeLines] then
        linePool[activeLines] = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    end
    local fs = linePool[activeLines]
    fs:Show()
    return fs
end

-- ---------------------------------------------------------------------------
-- Layout helpers
-- ---------------------------------------------------------------------------
local function AddHeaderLine(content, text, y)
    local fs = NextLine(content)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
    fs:SetWidth(CONTENT_W - PAD * 2)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - LINE_H
end

local function AddDoubleLine(content, leftText, rightText, y)
    local left = NextLine(content)
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", content, "TOPLEFT", PAD * 2, y)
    left:SetWidth(CONTENT_W - PAD * 2 - 110)
    left:SetJustifyH("LEFT")
    left:SetText(leftText)

    local right = NextLine(content)
    right:ClearAllPoints()
    right:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
    right:SetWidth(110)
    right:SetJustifyH("RIGHT")
    right:SetText(rightText)

    return y - LINE_H
end

-- ---------------------------------------------------------------------------
-- Populate content frame with current data
-- ---------------------------------------------------------------------------
local function RefreshStats()
    if not statsFrame then return end

    local content = statsFrame.content
    ResetLines()

        local minSamples     = DA.MIN_SAMPLES or 5
    local expansionOrder = { DA.EXP_TWW, DA.EXP_MIDNIGHT }
    local expansionNames = {
        [DA.EXP_TWW]      = "The War Within",
        [DA.EXP_MIDNIGHT] = "Midnight",
    }
    -- Midnight buckets are split by 25-point skill tiers.
    -- Tiers are discovered dynamically from actual data so values above 100
    -- (from spec/equipment bonuses) appear automatically.
    local function GetMidnightTiers(quality)
        local seen = {}
        local tiers = {}
        local prefix = DA.EXP_MIDNIGHT .. "_" .. quality .. "_"
        local noSuffix = DA.EXP_MIDNIGHT .. "_" .. quality

        local function Scan(source)
            if not source then return end
            for key in pairs(source) do
                if key == noSuffix and not seen["unknown"] then
                    seen["unknown"] = true
                    table.insert(tiers, "unknown")
                elseif key:sub(1, #prefix) == prefix then
                    local t = tonumber(key:sub(#prefix + 1))
                    if t and not seen[t] then
                        seen[t] = true
                        table.insert(tiers, t)
                    end
                end
            end
        end

        Scan(DA.charDb and DA.charDb.tracking)
        Scan(DisenchantingAddonCommunityData and DisenchantingAddonCommunityData.rates)

        table.sort(tiers, function(a, b)
            if a == "unknown" then return false end
            if b == "unknown" then return true end
            return a < b
        end)
        return tiers
    end

    -- Build a human-readable label for a skill tier value.
    local function SkillTierLabel(tier)
        if tier == "unknown" then return "Skill unknown" end
        return string.format("Skill %d–%d", tier, tier + 24)
    end

    local y       = -PAD
    local anyData = false

    -- Returns { source, matRows, attempts, belowThreshold } or nil for a raw bucket key.
    local function LoadBucket(key)
        local function BuildRows(bucket)
            local rows = {}
            for itemID, total in pairs(bucket.matTotals) do
                local dropCount = bucket.matCounts and bucket.matCounts[itemID]
                table.insert(rows, {
                    itemID             = itemID,
                    avgQty             = total / bucket.attempts,
                    dropChance         = dropCount and (dropCount / bucket.attempts) or nil,
                    avgQtyWhenReceived = dropCount and (total / dropCount) or nil,
                })
            end
            table.sort(rows, function(a, b) return a.avgQty > b.avgQty end)
            return rows
        end

        local bucket = DA.charDb and DA.charDb.tracking and DA.charDb.tracking[key]
        if bucket and bucket.attempts > 0 then
            return "personal", BuildRows(bucket), bucket.attempts, bucket.attempts < minSamples
        end
        if DisenchantingAddonCommunityData and DisenchantingAddonCommunityData.rates then
            local cb = DisenchantingAddonCommunityData.rates[key]
            if cb and cb.attempts >= minSamples then
                return "community", BuildRows(cb), cb.attempts, false
            end
        end
        return nil
    end

    for _, expID in ipairs(expansionOrder) do
        -- Build a list of { key, skillTier } pairs to iterate for this expansion.
        -- TWW: one key per quality; Midnight: one key per quality×skillTier.
        for _, quality in ipairs({ 2, 3, 4 }) do
          -- Resolve current effective skill once per quality (used for both
          -- keyList building and the no-data body below).
          local currentSkill = DA.GetEnchantingSkillForQuality and DA.GetEnchantingSkillForQuality(quality)
          if currentSkill == 0 then currentSkill = nil end  -- treat 0 as unknown
          local currentTier  = currentSkill and (math.floor(currentSkill / 25) * 25)

          -- Build keyList per quality so Midnight tiers are data-driven.
          local keyList = {}
          if expID == DA.EXP_MIDNIGHT then
              -- Only show the bucket matching the player's current effective skill tier.
              -- Historical buckets from lower skill tiers remain cached but are not displayed.
              if currentTier then
                  table.insert(keyList, { tierSuffix = "_" .. currentTier, skillTier = currentTier })
              else
                  -- Skill unavailable — fall back to showing all tiers with data.
                  for _, tier in ipairs(GetMidnightTiers(quality)) do
                      local suffix = (tier == "unknown") and "" or ("_" .. tier)
                      table.insert(keyList, { tierSuffix = suffix, skillTier = tier })
                  end
              end
          else
              table.insert(keyList, { tierSuffix = "", skillTier = nil })
          end

          for _, kEntry in ipairs(keyList) do
            local bucketKey = expID .. "_" .. quality .. kEntry.tierSuffix
            local source, matRows, attempts, belowThreshold = LoadBucket(bucketKey)

            -- For Midnight: always render so the player can see their current
            -- skill tier even before any disenchants have been recorded.
            -- For other expansions: only render when data exists.
            if source or (expID == DA.EXP_MIDNIGHT) then
                anyData = true

                -- Section header
                local expName  = expansionNames[expID] or ("Expansion " .. expID)
                local qColor   = QUALITY_COLORS[quality] or "|cFFFFFFFF"
                local qLabel   = QUALITY_LABELS[quality]  or ("Q" .. quality)
                local tierLabel = kEntry.skillTier and SkillTierLabel(kEntry.skillTier)
                local tierStr  = tierLabel and
                    (" " .. COLOR_GREY .. tierLabel .. COLOR_RESET)
                    or ""

                local countStr
                if not source then
                    countStr = COLOR_GREY .. "(no data yet)" .. COLOR_RESET
                elseif belowThreshold then
                    countStr = string.format("%s(%d/%d — building…)%s",
                        COLOR_WARN, attempts, minSamples, COLOR_RESET)
                else
                    countStr = string.format("%s(%d disenchants)%s",
                        COLOR_GREY, attempts, COLOR_RESET)
                end

                local srcTag = (source == "community")
                    and (" " .. COLOR_GREY .. "[community]" .. COLOR_RESET)
                    or  ""

                y = AddHeaderLine(content,
                    string.format("%s%s — %s%s%s%s",
                        COLOR_GOLD, expName, COLOR_RESET,
                        qColor, qLabel, COLOR_RESET)
                    .. tierStr .. "  " .. countStr .. srcTag,
                    y)

                if not source then
                    -- No data yet: show effective skill then prompt.
                    if currentSkill then
                        y = AddHeaderLine(content,
                            "  " .. COLOR_GREY .. string.format("Effective skill: %d", currentSkill) .. COLOR_RESET, y)
                    end
                    y = AddHeaderLine(content,
                        "  " .. COLOR_GREY .. "Disenchant items to build stats" .. COLOR_RESET, y)
                else
                    y = AddHeaderLine(content,
                        COLOR_GREY .. string.rep("-", 52) .. COLOR_RESET, y)

                    -- Mat rows
                    local totalCopper   = 0
                    local allHavePrices = true

                    for _, r in ipairs(matRows) do
                        local mat     = DA.MATS_BY_ID and DA.MATS_BY_ID[r.itemID]
                        local matName = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID))
                                     or GetItemInfo(r.itemID)
                                     or ("Item #" .. r.itemID)

                        local iconStr = ""
                        if mat and mat.qualityTier then
                            iconStr = (QUALITY_ICONS[mat.qualityTier] or "") .. " "
                        end

                        local price, _ = DA:GetItemPrice(r.itemID)
                        local stale    = DA:IsPriceStale(r.itemID)

                        local statsStr
                        if r.dropChance then
                            statsStr = string.format("|cFFFFFFFF%.0f%%|r · |cFFFFFFFFavg %.1fx|r",
                                r.dropChance * 100, r.avgQtyWhenReceived)
                        else
                            statsStr = string.format("|cFFFFFFFFavg %.2fx|r", r.avgQty)
                        end
                        local leftText = string.format("  %s%s  %s", iconStr, matName, statsStr)
                        local rightText

                        if price then
                            -- Expected total uses probability-weighted value (avgQty already
                            -- incorporates drop chance: avgQty = dropChance × avgQtyWhenReceived).
                            local expectedCopper = math.floor(r.avgQty * price)
                            totalCopper = totalCopper + expectedCopper
                            -- Per-row display shows actual value when received, not the
                            -- probability-weighted contribution, so the number is intuitive.
                            local displayCopper = r.avgQtyWhenReceived
                                and math.floor(r.avgQtyWhenReceived * price)
                                or  expectedCopper
                            rightText = DA:FormatGold(displayCopper)
                            if stale then
                                rightText = rightText .. " " .. COLOR_WARN .. "*" .. COLOR_RESET
                            end
                        else
                            allHavePrices = false
                            rightText = "|cFFFF4444No price|r"
                        end

                        y = AddDoubleLine(content, leftText, rightText, y)
                    end

                    -- Expected total (only when we have reliable data)
                    if totalCopper > 0 and not belowThreshold then
                        y = AddHeaderLine(content,
                            COLOR_GREY .. string.rep("-", 52) .. COLOR_RESET, y)
                        y = AddDoubleLine(content,
                            "  " .. COLOR_GOLD .. "Expected Value" .. COLOR_RESET,
                            DA:FormatGold(totalCopper),
                            y)
                    end

                    if not allHavePrices then
                        y = AddHeaderLine(content,
                            "  " .. COLOR_WARN .. "Run /dea scan at the AH for prices" .. COLOR_RESET, y)
                    end
                end

                y = y - SECTION_GAP
            end
          end  -- kEntry loop
        end    -- quality loop
    end        -- expID loop

    -- No data at all
    if not anyData then
        y = AddHeaderLine(content,
            COLOR_GREY .. "No disenchanting data yet." .. COLOR_RESET, y)
        y = AddHeaderLine(content,
            COLOR_GREY .. "Disenchant items to build up stats." .. COLOR_RESET, y)
    end

    content:SetHeight(math.abs(y) + PAD)
end

-- ---------------------------------------------------------------------------
-- Build the frame (called once on first open)
-- ---------------------------------------------------------------------------
local function CreateStatsFrame()
    local f = CreateFrame("Frame", "DisenchantingAddonStatsFrame", UIParent,
        "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()

    f.TitleText:SetText("Disenchanting Advisor — Stats")

    -- Scroll frame (inset accounts for frame border + scrollbar)
    local sf = CreateFrame("ScrollFrame", "DisenchantingAddonStatsScroll", f,
        "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",      8, -28)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28,   8)

    -- Scroll child
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(CONTENT_W)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    f.content    = content
    f.scrollFrame = sf

    -- Repopulate every time the window is shown
    f:SetScript("OnShow", RefreshStats)

    statsFrame = f
end

-- ---------------------------------------------------------------------------
-- Public: refresh the stats window if it is currently open.
-- Called by Tracking.lua after each disenchant is recorded.
-- ---------------------------------------------------------------------------
function DA:RefreshStatsFrame()
    if statsFrame and statsFrame:IsShown() then
        RefreshStats()
    end
end

-- ---------------------------------------------------------------------------
-- Public: toggle the stats window open/closed.
-- ---------------------------------------------------------------------------
function DA:ToggleStatsFrame()
    if not statsFrame then
        CreateStatsFrame()
    end
    if statsFrame:IsShown() then
        statsFrame:Hide()
    else
        statsFrame:Show()
    end
end
