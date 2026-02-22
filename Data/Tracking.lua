-- Tracking.lua
-- Records actual disenchant outcomes by monitoring bag changes on every
-- BAG_UPDATE_DELAYED event. A disenchant is detected when known DE mats
-- appear at the same time an equippable green/blue/epic disappears.
-- This requires no spell event hooks and is unaffected by API restrictions.
--
-- Minimum samples before observed rates show in tooltip.
-- Exposed on DA so the stats frame can show progress toward the threshold.
local MIN_SAMPLES = 10
DisenchantingAddon = DisenchantingAddon or {}
DisenchantingAddon.MIN_SAMPLES = MIN_SAMPLES
local DA = DisenchantingAddon

-- Set of equip locations that are disenchantable (mirrors DisenchantingAddon.lua)
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

-- Running bag snapshot, updated after every processed BAG_UPDATE_DELAYED.
local lastSnapshot = nil

-- Debug flag — toggled by /dea trackdebug
local debugMode = false

local function DebugPrint(...)
    if debugMode then
        print("|cFFFF9900[DEA Track]|r", ...)
    end
end

-- ---------------------------------------------------------------------------
-- Bag snapshot
-- Captures itemID, count, link, quality, expansionID, and equipLoc per slot.
-- These are stored now so we don't need GetItemInfo after the item has been
-- consumed by disenchanting.
-- ---------------------------------------------------------------------------
local function SnapshotBags()
    local snapshot = {}
    for bag = 0, 5 do  -- bag 5 = reagent bag slot
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID and info.itemID > 0 then
                    -- GetItemInfoInstant: (itemID, itemType, itemSubType, itemEquipLoc, ...)
                    -- Always synchronous — equipLoc (index 4) is always populated.
                    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(info.hyperlink or info.itemID)

                    -- GetItemInfo: quality (index 3) and expansionID (index 15).
                    -- May return nil for items not yet in the client cache (common on beta).
                    local _, _, quality, _, _, _, _, _, _, _, _, _, _, _, expansionID =
                        C_Item.GetItemInfo(info.hyperlink or info.itemID)

                    -- Fallback: extract quality from the hyperlink colour code when
                    -- GetItemInfo hasn't loaded the item data yet.
                    -- WoW links use lowercase |cffRRGGBB, so match |c + any 2 hex
                    -- chars (the alpha byte) + 6 hex chars (the RGB colour).
                    if not quality and info.hyperlink then
                        local hex = info.hyperlink:match("^|c%x%x(%x%x%x%x%x%x)")
                        if hex then
                            quality = ({
                                ["9D9D9D"]=0, ["FFFFFF"]=1, ["1EFF00"]=2,
                                ["0070DD"]=3, ["A335EE"]=4, ["FF8000"]=5, ["E6CC80"]=6,
                            })[hex:upper()]
                        end
                    end

                    snapshot[bag .. "_" .. slot] = {
                        itemID      = info.itemID,
                        count       = info.stackCount or 1,
                        link        = info.hyperlink,
                        quality     = quality,
                        expansionID = expansionID,
                        equipLoc    = equipLoc,
                    }
                end
            end
        end
    end
    return snapshot
end

-- ---------------------------------------------------------------------------
-- Bag diff — returns removed and added item lists
-- ---------------------------------------------------------------------------
local function DiffSnapshots(before, after)
    local removed, added = {}, {}

    for key, b in pairs(before) do
        local a = after[key]
        if not a then
            table.insert(removed, b)
        elseif a.itemID ~= b.itemID then
            table.insert(removed, b)
            table.insert(added, a)
        elseif a.count < b.count then
            local copy = {}
            for k, v in pairs(b) do copy[k] = v end
            copy.count = b.count - a.count
            table.insert(removed, copy)
        end
    end

    for key, a in pairs(after) do
        local b = before[key]
        if not b then
            table.insert(added, a)
        elseif a.itemID == b.itemID and a.count > b.count then
            local copy = {}
            for k, v in pairs(a) do copy[k] = v end
            copy.count = a.count - b.count
            table.insert(added, copy)
        end
    end

    return removed, added
end

-- ---------------------------------------------------------------------------
-- Returns true if itemID matches any tracked mat (with a valid id).
-- ---------------------------------------------------------------------------
local function IsKnownMat(itemID)
    for _, mat in pairs(DA.MATS) do
        if mat.id and mat.id > 0 and mat.id == itemID then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Enchanting skill helpers (Midnight-specific — skill drives yield variance).
-- ---------------------------------------------------------------------------

-- Sums spec-tree skill bonuses for the given expansion skill line.
-- quality (optional): if provided, quality-specific node bonuses are included
--   alongside the "all quality" bonuses.  Pass nil to get only all-quality
--   bonuses (used for a quality-agnostic baseline).
--
-- Point counts per path are read from C_Traits.GetNodeInfo(configID, pathID).currentRank.
-- C_ProfSpecs.GetStateForPath returns an enum (0=locked, 2=active), NOT a count.
-- Bonus amounts are looked up from DA.MIDNIGHT_SPEC_NODES (hardcoded) because
-- perkIDs from GetPerksForPath exceed the int32 range accepted by the perk API.
local function GetSpecSkillBonus(specLine, quality)
    if not C_ProfSpecs then return 0 end
    local getConfig   = C_ProfSpecs.GetConfigIDForSkillLine
    local getTabs     = C_ProfSpecs.GetSpecTabIDsForSkillLine
    local getRootPath = C_ProfSpecs.GetRootPathForTab
    local getChildren = C_ProfSpecs.GetChildrenForPath
    if not (getConfig and getTabs and getRootPath and getChildren) then
        return 0
    end

    local configID = getConfig(specLine)
    if not configID or configID == 0 then return 0 end

    local tabIDs = getTabs(specLine)
    if not tabIDs then return 0 end

    local bonus = 0
    for _, tabID in ipairs(tabIDs) do
        local rootPath = getRootPath(tabID)
        if rootPath then
            local visited = {}
            local function WalkPath(pathID)
                if visited[pathID] then return end
                visited[pathID] = true

                local nodeData = DA.MIDNIGHT_SPEC_NODES and DA.MIDNIGHT_SPEC_NODES[pathID]
                if nodeData then
                    -- nil qualityFilter = applies to all qualities.
                    -- Non-nil qualityFilter = only applies when quality matches.
                    local applies = (nodeData.qualityFilter == nil)
                                 or (quality ~= nil and nodeData.qualityFilter == quality)
                    if applies then
                        -- C_Traits.GetNodeInfo returns currentRank = actual points invested.
                        -- GetStateForPath returns an enum (0=locked, 2=active), NOT a count.
                        local points = nil
                        if C_Traits and C_Traits.GetNodeInfo then
                            local ok, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, pathID)
                            if ok and nodeInfo and type(nodeInfo.currentRank) == "number" then
                                points = nodeInfo.currentRank
                            end
                        end
                        if points and points > 0 then
                            bonus = bonus + points * (nodeData.perPointSkill or 0)
                            for _, bp in ipairs(nodeData.breakpoints or {}) do
                                if points >= bp.minPoints then
                                    bonus = bonus + (bp.skill or 0)
                                end
                            end
                        end
                    end
                end

                local children = getChildren(pathID)
                for _, child in ipairs(children or {}) do
                    WalkPath(child)
                end
            end
            WalkPath(rootPath)
        end
    end
    return bonus
end

-- Returns the player's effective Enchanting skill for items of the given quality,
-- or nil if Enchanting is not found.
--
-- quality (optional): pass the item quality (2/3/4) to include quality-specific
--   spec bonuses (e.g. Shard Supplier's +skill for Rare items only).
--   Pass nil to get the base skill plus all-quality spec bonuses only.
--
-- Components:
--   base skill    from C_TradeSkillUI (includes racial bonus via skillModifier)
--   all-quality   spec node bonuses (e.g. Disenchanting Delegate +1/pt)
--   quality-spec  spec node bonuses that apply only to one quality tier
local function GetEnchantingSkillForQuality(quality)
    local prof1, prof2 = GetProfessions()
    for _, idx in ipairs({ prof1, prof2 }) do
        if idx then
            local name, _, skillLevel, _, _, _, skillLine, skillModifier = GetProfessionInfo(idx)
            if name and name:lower():find("enchanting") then
                -- Resolve the expansion-specific skill line (e.g. 333 → 2909 for Midnight).
                local specSkillLine = skillLine
                if skillLine and C_ProfSpecs and C_ProfSpecs.GetDefaultSpecSkillLine then
                    local candidate = C_ProfSpecs.GetDefaultSpecSkillLine(skillLine) or skillLine
                    -- Guard: in Midnight beta GetDefaultSpecSkillLine may return the
                    -- currently-open profession's spec line instead of Enchanting's.
                    -- Verify the returned line still belongs to Enchanting before using it.
                    if candidate ~= skillLine
                       and C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
                        local candInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID(candidate)
                        if candInfo then
                            local candName = candInfo.professionName or candInfo.displayName or ""
                            if not candName:lower():find("enchanting") then
                                -- Spec line belongs to another profession — fall back.
                                candidate = skillLine
                            end
                        else
                            -- candInfo nil: can't verify — fall back to base line to avoid
                            -- using a context-dependent spec line that belongs to another
                            -- profession but hasn't loaded its info into the API yet.
                            candidate = skillLine
                        end
                    end
                    specSkillLine = candidate
                end

                -- Prefer C_TradeSkillUI which includes equipment/racial modifiers.
                local baseSkill
                if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
                    local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(specSkillLine)
                    if info and info.skillLevel then
                        baseSkill = info.skillLevel + (info.skillModifier or 0)
                    end
                end
                if not baseSkill then
                    baseSkill = skillLevel + (skillModifier or 0)
                end

                local specBonus = GetSpecSkillBonus(specSkillLine, quality)
                local total = baseSkill + specBonus
                DebugPrint(string.format(
                    "Enchanting skill (specLine=%d quality=%s): base=%d specBonus=%d total=%d",
                    specSkillLine, tostring(quality), baseSkill, specBonus, total))
                return total
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Skill cache — addresses APIs that return 0/nil when the profession window
-- is closed (C_TradeSkillUI.GetProfessionInfoBySkillLineID, C_ProfSpecs.*).
-- The cache is refreshed on PLAYER_ENTERING_WORLD, TRADE_SKILL_SHOW, and
-- TRADE_SKILL_UPDATE, which all fire while the profession data is accessible.
-- RecordResult and GetTrackedRates use GetEffectiveSkillForQuality so that
-- disenchants recorded during BAG_UPDATE_DELAYED (profession window closed)
-- are still bucketed under the correct skill tier.
-- ---------------------------------------------------------------------------
-- skillCache is stored in DA.db.skillCache (SavedVariables) so values survive
-- logout/reload. DA.db is guaranteed set before any cache read/write because
-- InitDB runs on ADDON_LOADED, which fires before PLAYER_ENTERING_WORLD or
-- any BAG_UPDATE_DELAYED that could precede a disenchant.
local function GetSkillCacheTable()
    return DA.charDb and DA.charDb.skillCache
end

local function UpdateSkillCache()
    local cache = GetSkillCacheTable()
    if not cache then return end
    local function store(quality, key)
        local skill = GetEnchantingSkillForQuality(quality)
        if skill and skill > 0 then
            cache[key] = skill
            DebugPrint("SkillCache: quality=" .. tostring(quality) .. " skill=" .. skill)
        end
    end
    store(nil, 0)
    store(2, 2)
    store(3, 3)
    store(4, 4)
    if DA.RefreshStatsFrame then DA:RefreshStatsFrame() end
end

-- Forward declaration — defined near HandleTrackingEvent below.
local IsEnchantingTradeSkillOpen

-- Cache-first skill lookup.
--
-- UpdateSkillCache (called when the Enchanting window is open) writes full
-- spec-inclusive skill values into DA.db.skillCache.  Using those cached
-- values for both RECORDING and LOOKUP guarantees both operations use the
-- same tier key regardless of which profession window is currently open.
--
-- A live read is attempted only when the cache is completely empty (first
-- login before the player has opened Enchanting).  It is skipped when a
-- non-Enchanting profession window is open because C_ProfSpecs would then
-- return that profession's data and produce a wrong (base-only) result.
local function GetEffectiveSkillForQuality(quality)
    local cache = GetSkillCacheTable()
    local cached = cache and cache[quality or 0]
    if cached and cached > 0 then
        return cached
    end

    -- Cache empty — attempt a one-time live read so the tracker is not
    -- completely blind on first login before Enchanting has been opened.
    if not IsEnchantingTradeSkillOpen() then
        DebugPrint("GetEffectiveSkill: no cache and non-Enchanting window open — returning nil")
        return nil
    end
    local live = GetEnchantingSkillForQuality(quality)
    if live and live > 0 then
        if cache then
            cache[quality or 0] = live
            DebugPrint("GetEffectiveSkill: seeded cache from live: quality="
                .. tostring(quality) .. " → " .. live)
        end
        return live
    end
    return nil  -- RecordResult / GetTrackedRates handle nil gracefully
end

-- Backward-compatible alias: returns skill with all-quality spec bonuses only.
local function GetEnchantingSkill()
    return GetEffectiveSkillForQuality(nil)
end
DA.GetEnchantingSkill           = GetEnchantingSkill
DA.GetEnchantingSkillForQuality = GetEffectiveSkillForQuality   -- StatsFrame uses this
DA.UpdateSkillCache             = UpdateSkillCache

-- Quantize a 0–100 skill value to the nearest 25-point tier boundary.
-- Returns 0, 25, 50, 75, or 100.
local function GetSkillTier(skill)
    if not skill then return nil end
    return math.floor(skill / 25) * 25
end

-- ---------------------------------------------------------------------------
-- Tracking key.
-- TWW:      "expansionID_quality"            e.g. "10_2"
-- Midnight: "expansionID_quality_skillTier"  e.g. "11_3_75"
-- ---------------------------------------------------------------------------
local function GetTrackingKey(quality, expansionID, skillTier)
    if not quality or not expansionID then return nil end
    local key = expansionID .. "_" .. quality
    if skillTier then
        key = key .. "_" .. skillTier
    end
    return key
end

-- ---------------------------------------------------------------------------
-- Store one completed disenchant observation
-- ---------------------------------------------------------------------------
local function RecordResult(sourceItem, mats)
    if not DA.charDb then return end
    if not DA.charDb.tracking then DA.charDb.tracking = {} end

    local quality     = sourceItem.quality
    local expansionID = sourceItem.expansionID

    -- If expansionID wasn't cached when the snapshot was taken, infer it from
    -- the mats that dropped — each mat only exists in one expansion.
    if not expansionID then
        for _, mat in ipairs(mats) do
            local matDef = DA.MATS_BY_ID and DA.MATS_BY_ID[mat.itemID]
            if matDef then
                -- Walk DISENCHANT table to find which expansion owns this mat key
                for expID, expData in pairs(DA.DISENCHANT or {}) do
                    for _, results in pairs(expData) do
                        for _, r in ipairs(results) do
                            local key = r.matKey
                            if key and DA.MATS[key] and DA.MATS[key].id == mat.itemID then
                                expansionID = expID
                                break
                            end
                        end
                        if expansionID then break end
                    end
                    if expansionID then break end
                end
                if expansionID then break end
            end
        end
        if expansionID then
            DebugPrint("RecordResult: inferred expansionID", expansionID, "from mats")
        end
    end

    if not quality or not expansionID then
        DebugPrint("RecordResult: quality or expansionID nil, skipping")
        return
    end
    if quality < 2 or quality > 4 then
        DebugPrint("RecordResult: quality", quality, "out of range 2-4, skipping")
        return
    end

    -- For Midnight, bucket by enchanting skill tier (25-point bands).
    -- Pass quality so quality-specific spec bonuses (e.g. Shard Supplier for
    -- Rare items) are included in the effective skill used for bucketing.
    local skillTier = nil
    if expansionID == DA.EXP_MIDNIGHT then
        skillTier = GetSkillTier(GetEffectiveSkillForQuality(quality))
    end

    local key = GetTrackingKey(quality, expansionID, skillTier)
    if not key then return end

    if not DA.charDb.tracking[key] then
        DA.charDb.tracking[key] = {
            quality     = quality,
            expansionID = expansionID,
            skillTier   = skillTier,   -- nil for non-skill-tracked expansions
            attempts    = 0,
            matTotals   = {},
            matCounts   = {},  -- number of disenchants that yielded each itemID
        }
    end

    local bucket = DA.charDb.tracking[key]
    -- Backfill matCounts for buckets created before this field existed.
    if not bucket.matCounts then bucket.matCounts = {} end
    bucket.attempts = bucket.attempts + 1

    for _, mat in ipairs(mats) do
        bucket.matTotals[mat.itemID] = (bucket.matTotals[mat.itemID] or 0) + mat.count
        bucket.matCounts[mat.itemID] = (bucket.matCounts[mat.itemID] or 0) + 1
    end

    DebugPrint(string.format("Recorded: expansionID=%d quality=%d skillTier=%s mats=%d attempt#%d",
        expansionID, quality, tostring(skillTier), #mats, bucket.attempts))

    -- Live-update the stats frame if it's open.
    if DA.RefreshStatsFrame then DA:RefreshStatsFrame() end
end

-- ---------------------------------------------------------------------------
-- Core bag-change handler — called on every BAG_UPDATE_DELAYED
--
-- Split-event handling: spec procs (e.g. Shard Supplier bonus shards) can
-- cause the server to send the item removal and the mat additions in two
-- separate BAG_UPDATE_DELAYED events.  pendingSource holds an equippable that
-- was removed without matching mats; it is used by the following event if mats
-- then arrive.  A short timer clears it to avoid false attribution from
-- unrelated equippable removals (vendoring, deletion, etc.).
-- ---------------------------------------------------------------------------
local pendingSource      = nil
local pendingSourceTimer = nil

local function ClearPendingSource()
    DebugPrint("  Pending source expired without matching mats — cleared")
    pendingSource      = nil
    pendingSourceTimer = nil
end

local function OnBagUpdateDelayed()
    local current = SnapshotBags()

    if not lastSnapshot then
        lastSnapshot = current
        return
    end

    local removed, added = DiffSnapshots(lastSnapshot, current)
    lastSnapshot = current  -- always advance

    if #added == 0 and #removed == 0 then return end

    DebugPrint(string.format("Bag diff: +%d -%d items", #added, #removed))

    -- Find any known DE mats that were added
    local matsAdded = {}
    for _, item in ipairs(added) do
        DebugPrint(string.format("  Added itemID=%d x%d (knownMat=%s)",
            item.itemID, item.count, tostring(IsKnownMat(item.itemID))))
        if IsKnownMat(item.itemID) then
            table.insert(matsAdded, item)
        end
    end

    -- Find an equippable green/blue/epic that was removed in this update
    local sourceItem = nil
    for _, item in ipairs(removed) do
        local q  = item.quality
        local eq = item.equipLoc
        DebugPrint(string.format("  Removed: itemID=%d quality=%s equipLoc=%s",
            item.itemID, tostring(q), tostring(eq)))
        if q and q >= 2 and q <= 4 and eq and EQUIPPABLE[eq] then
            sourceItem = item
            break
        end
    end

    if #matsAdded > 0 then
        -- Mats received — prefer a source from this same event, then fall back
        -- to a pending source stored by the previous event (split-event case).
        if not sourceItem and pendingSource then
            DebugPrint("  Using pending source from previous event:", pendingSource.itemID)
            sourceItem = pendingSource
        end

        -- Consume pending regardless (matched or superseded).
        if pendingSourceTimer then pendingSourceTimer:Cancel() end
        pendingSource      = nil
        pendingSourceTimer = nil

        if sourceItem then
            DebugPrint("  Source gear found:", sourceItem.itemID, "quality:", sourceItem.quality)
            RecordResult(sourceItem, matsAdded)
        else
            DebugPrint("  No source gear found in removed items — not recording")
        end

    elseif sourceItem then
        -- Equippable removed but no mats yet — spec proc may deliver mats in
        -- the next event.  Store source and wait up to 3 seconds.
        DebugPrint("  Equippable removed with no mats — storing as pending source")
        if pendingSourceTimer then pendingSourceTimer:Cancel() end
        pendingSource      = sourceItem
        pendingSourceTimer = C_Timer.NewTimer(3, ClearPendingSource)
    end
end

-- ---------------------------------------------------------------------------
-- Public: get observed rates for a quality + expansionID.
-- Returns rates list, attempt count, and source ("personal" or "community").
-- Returns nil if neither personal nor community data meets MIN_SAMPLES.
--
-- Priority:
--   1. Personal observed data (DA.db.tracking)
--   2. Community data from companion addon (DisenchantingAddonCommunityData)
-- ---------------------------------------------------------------------------
local function BucketToRates(bucket)
    local rates = {}
    for itemID, total in pairs(bucket.matTotals) do
        local dropCount = bucket.matCounts and bucket.matCounts[itemID]
        table.insert(rates, {
            itemID             = itemID,
            avgQty             = total / bucket.attempts,
            dropChance         = dropCount and (dropCount / bucket.attempts) or nil,
            avgQtyWhenReceived = dropCount and (total / dropCount) or nil,
        })
    end
    table.sort(rates, function(a, b) return a.avgQty > b.avgQty end)
    return rates
end

function DA:GetTrackedRates(quality, expansionID)
    -- For Midnight, resolve the player's current skill tier for key lookup.
    -- Pass quality so quality-specific spec bonuses are included.
    local skillTier = nil
    if expansionID == DA.EXP_MIDNIGHT then
        skillTier = GetSkillTier(GetEffectiveSkillForQuality(quality))
    end

    local key = GetTrackingKey(quality, expansionID, skillTier)
    if not key then return nil end

    -- 1. Personal observed data
    if DA.charDb and DA.charDb.tracking then
        local bucket = DA.charDb.tracking[key]
        if bucket and bucket.attempts >= MIN_SAMPLES then
            return BucketToRates(bucket), bucket.attempts, "personal"
        end
    end

    -- 2. Community data from companion addon
    if DisenchantingAddonCommunityData and DisenchantingAddonCommunityData.rates then
        local bucket = DisenchantingAddonCommunityData.rates[key]
        if bucket and bucket.attempts >= MIN_SAMPLES then
            return BucketToRates(bucket), bucket.attempts, "community"
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Public: print tracking stats to chat
-- ---------------------------------------------------------------------------
function DA:PrintTrackingStats()
    if not DA.charDb or not DA.charDb.tracking then
        print("|cFF00FFFFDisenchanting Advisor:|r No tracking data yet.")
        return
    end

    local qualityNames  = { [2] = "Uncommon (Green)", [3] = "Rare (Blue)", [4] = "Epic (Purple)" }
    local expansionNames = { [10] = "The War Within", [11] = "Midnight" }
    local found = false

    for _, bucket in pairs(DA.charDb.tracking) do
        found = true
        local qName   = qualityNames[bucket.quality]   or ("Quality "   .. tostring(bucket.quality))
        local expName = expansionNames[bucket.expansionID] or ("Expansion " .. tostring(bucket.expansionID))
        print(string.format("|cFF00FFFF[%s — %s]|r %d disenchant(s)",
            expName, qName, bucket.attempts))
        for itemID, total in pairs(bucket.matTotals) do
            local name = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID))
                      or GetItemInfo(itemID)
                      or ("Item #" .. itemID)
            print(string.format("  %s: avg %.2f per disenchant", name, total / bucket.attempts))
        end
    end

    if not found then
        print("|cFF00FFFFDisenchanting Advisor:|r No tracking data yet. Disenchant some items!")
    end
end

-- ---------------------------------------------------------------------------
-- Public: print a brief login summary of cached skill + tracking data.
-- Called on PLAYER_LOGIN so the player knows their data loaded correctly.
-- ---------------------------------------------------------------------------
function DA:PrintLoginSummary()
    if not DA.charDb then return end

    -- Skill cache summary
    local cache = DA.charDb.skillCache
    local baseSkill = cache and cache[0]
    local skillStr
    if baseSkill and baseSkill > 0 then
        -- Show per-quality overrides only if they differ from base
        local parts = {}
        for _, q in ipairs({ 2, 3, 4 }) do
            local qSkill = cache[q]
            if qSkill and qSkill ~= baseSkill then
                local label = q == 2 and "Unc" or q == 3 and "Rare" or "Epic"
                table.insert(parts, label .. ":" .. qSkill)
            end
        end
        skillStr = tostring(baseSkill)
        if #parts > 0 then
            skillStr = skillStr .. " (" .. table.concat(parts, " ") .. ")"
        end
    else
        skillStr = "|cFFFF8C00none cached — open Enchanting to populate|r"
    end

    -- Tracking summary
    local tracking = DA.charDb.tracking
    local totalDisenchants = 0
    local bucketCount = 0
    if tracking then
        for _, bucket in pairs(tracking) do
            bucketCount = bucketCount + 1
            totalDisenchants = totalDisenchants + (bucket.attempts or 0)
        end
    end
    local trackStr
    if totalDisenchants > 0 then
        trackStr = string.format("|cFFFFFFFF%d|r disenchant(s) across |cFFFFFFFF%d|r bucket(s)",
            totalDisenchants, bucketCount)
    else
        trackStr = "|cFF888888no data yet|r"
    end

    print(string.format("%sDisenchanting Advisor:|r  Skill: %s  |cFF888888·|r  Tracked: %s",
        "|cFF00FFFF", skillStr, trackStr))
end

-- ---------------------------------------------------------------------------
-- Public: wipe all personal tracking data from the saved variables.
-- Called by /dea clearstats.  Community data is unaffected.
-- ---------------------------------------------------------------------------
function DA:ClearTrackingData()
    if DA.charDb then
        DA.charDb.tracking = {}
        -- skillCache is intentionally NOT cleared here: it holds character
        -- state (effective skill per quality) that is unrelated to tracking
        -- results and would be expensive to repopulate without the prof window.
    end
    print("|cFF00FFFFDisenchanting Advisor:|r All personal tracking data cleared.")
    if DA.RefreshStatsFrame then DA:RefreshStatsFrame() end
end

-- ---------------------------------------------------------------------------
-- Public: dump all profession-skill API values to help locate spec bonuses.
-- Run /dea skillcheck after opening your profession window.
-- ---------------------------------------------------------------------------
function DA:SkillCheck()
    local out = DA.DebugOutput and function(s) DA:DebugOutput(s) end or print
    DA:ClearDebugOutput()

    local prof1, prof2 = GetProfessions()
    local found = false

    for _, idx in ipairs({ prof1, prof2 }) do
        if idx then
            local name, _, skillLevel, maxSkill, _, _, skillLine, skillModifier = GetProfessionInfo(idx)
            if name and name:lower():find("enchanting") then
                found = true
                out(string.format("GetProfessionInfo: %s  skill=%d/%d  mod=%d  skillLine=%d",
                    name, skillLevel, maxSkill, skillModifier or 0, skillLine or 0))

                -- Resolve expansion-specific skill line (333 → e.g. 2810 for Midnight)
                local specLine = skillLine
                if skillLine and C_ProfSpecs and C_ProfSpecs.GetDefaultSpecSkillLine then
                    specLine = C_ProfSpecs.GetDefaultSpecSkillLine(skillLine) or skillLine
                end
                out(string.format("Expansion spec skill line: %d  (base=%d)", specLine, skillLine or 0))

                -- C_TradeSkillUI with BOTH lines
                local function dumpTradeSkillInfo(line)
                    if not (C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID) then return end
                    local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(line)
                    if info then
                        out(string.format("C_TradeSkillUI.GetProfessionInfoBySkillLineID(%d):", line))
                        for k, v in pairs(info) do
                            out(string.format("  .%s = %s", tostring(k), tostring(v)))
                        end
                    else
                        out(string.format("C_TradeSkillUI(%d): nil", line))
                    end
                end
                dumpTradeSkillInfo(skillLine)
                if specLine ~= skillLine then dumpTradeSkillInfo(specLine) end

                -- List every function available in C_ProfSpecs (useful after patches)
                out("--- C_ProfSpecs functions ---")
                if C_ProfSpecs then
                    local fnList = {}
                    for k, v in pairs(C_ProfSpecs) do
                        if type(v) == "function" then
                            table.insert(fnList, k)
                        end
                    end
                    table.sort(fnList)
                    for _, fn in ipairs(fnList) do out("  " .. fn) end
                else
                    out("  C_ProfSpecs namespace is nil")
                end

                -- C_ProfSpecs: spec tabs, paths, and perks using the correct configID
                out(string.format("--- C_ProfSpecs (specLine=%d) ---", specLine))
                if C_ProfSpecs then
                    -- Get configID first — required by most state functions
                    local configID = C_ProfSpecs.GetConfigIDForSkillLine and
                        C_ProfSpecs.GetConfigIDForSkillLine(specLine) or 0
                    out(string.format("configID = %d", configID))

                    local tabIDs = C_ProfSpecs.GetSpecTabIDsForSkillLine and
                        C_ProfSpecs.GetSpecTabIDsForSkillLine(specLine)
                    out("tabIDs: " .. (tabIDs and ("count="..#tabIDs) or "nil"))

                    for _, tabID in ipairs(tabIDs or {}) do
                        local ok, err = pcall(function()
                            out(string.format("  tab=%d", tabID))

                            -- Tab info (no configID needed)
                            local ti = C_ProfSpecs.GetTabInfo and C_ProfSpecs.GetTabInfo(tabID)
                            if ti then
                                for k, v in pairs(ti) do
                                    if type(v) ~= "table" then
                                        out(string.format("    tabInfo.%s = %s", k, tostring(v)))
                                    end
                                end
                            end

                            -- Tab state — returns a number (points spent), not a table
                            local tiState = C_ProfSpecs.GetStateForTab and
                                C_ProfSpecs.GetStateForTab(tabID, configID)
                            out(string.format("    tabState (points) = %s", tostring(tiState)))

                            -- Walk paths from root; dump ALL perks with descriptions + full state
                            local rootPath = C_ProfSpecs.GetRootPathForTab and
                                C_ProfSpecs.GetRootPathForTab(tabID)
                            if not rootPath then
                                out("    rootPath=nil")
                                return
                            end
                            out(string.format("    rootPath=%d", rootPath))

                            local visited = {}
                            local function WalkPath(pathID, depth)
                                if visited[pathID] or depth > 20 then return end
                                visited[pathID] = true
                                local ind = string.rep("  ", depth + 3)

                                -- Path state (points invested)
                                local psOk, ps = pcall(C_ProfSpecs.GetStateForPath, pathID, configID)
                                if not psOk then psOk, ps = pcall(C_ProfSpecs.GetStateForPath, pathID) end

                                local pd = C_ProfSpecs.GetDescriptionForPath and
                                    C_ProfSpecs.GetDescriptionForPath(pathID)

                                -- Annotate paths we have hardcoded bonus data for
                                local knownNode = DA.MIDNIGHT_SPEC_NODES and DA.MIDNIGHT_SPEC_NODES[pathID]
                                local nodeLabel = knownNode
                                    and ("[" .. knownNode.name .. "]")
                                    or  "[unknown]"

                                -- C_Traits.GetNodeInfo: currentRank = actual points invested.
                                -- GetStateForPath returns enum (0=locked, 2=active) — not a count.
                                local traitRank = "n/a"
                                if C_Traits and C_Traits.GetNodeInfo then
                                    local tok, tInfo = pcall(C_Traits.GetNodeInfo, configID, pathID)
                                    if tok and tInfo then
                                        traitRank = string.format("currentRank=%s maxRanks=%s",
                                            tostring(tInfo.currentRank), tostring(tInfo.maxRanks))
                                    else
                                        traitRank = "ERR:" .. tostring(tInfo)
                                    end
                                end

                                out(string.format("%spath=%d %s  pathState=%s  traitInfo=[%s]  desc=%s",
                                    ind, pathID, nodeLabel,
                                    tostring(psOk and ps or "ERR"),
                                    traitRank,
                                    tostring(pd)))

                                -- Perk IDs from GetPerksForPath exceed the int32 range accepted by
                                -- GetDescriptionForPerk / GetStateForPerk — skip iteration entirely.
                                local perks = C_ProfSpecs.GetPerksForPath and
                                    C_ProfSpecs.GetPerksForPath(pathID)
                                if perks and #perks > 0 then
                                    out(string.format("%s  (%d perks — skipped, perkIDs exceed int32)",
                                        ind, #perks))
                                end

                                local children = C_ProfSpecs.GetChildrenForPath and
                                    C_ProfSpecs.GetChildrenForPath(pathID)
                                for _, child in ipairs(children or {}) do
                                    WalkPath(child, depth + 1)
                                end
                            end
                            WalkPath(rootPath, 0)
                        end)
                        if not ok then
                            out("  ERROR: " .. tostring(err))
                        end
                    end
                else
                    out("  C_ProfSpecs namespace is nil")
                end

                -- Summary: computed effective skill per quality using hardcoded node data.
                -- Use this to verify GetEnchantingSkillForQuality returns the right values.
                -- Note: ipairs stops at nil so qualities are iterated explicitly.
                out("--- Computed effective Enchanting skill ---")
                local qualityNames = { [2]="Uncommon(2)", [3]="Rare(3)", [4]="Epic(4)" }
                local function dumpSkillForQuality(q)
                    local total = GetEnchantingSkillForQuality(q)
                    out(string.format("  quality=%-14s → %s",
                        q and qualityNames[q] or "all (base)",
                        tostring(total)))
                end
                dumpSkillForQuality(nil)
                dumpSkillForQuality(2)
                dumpSkillForQuality(3)
                dumpSkillForQuality(4)

                -- Persist the verified values so the stats frame and tracker
                -- can use them even when the profession window is closed.
                UpdateSkillCache()
                out("--- Skill cache updated ---")
            end
        end
    end

    if not found then
        out("Enchanting profession not found.")
    end
end

-- ---------------------------------------------------------------------------
-- Public: toggle debug output
-- ---------------------------------------------------------------------------
function DA:ToggleTrackDebug()
    debugMode = not debugMode
    print("|cFF00FFFFDisenchanting Advisor:|r Tracking debug "
        .. (debugMode and "|cFF00FF00ON|r" or "|cFFFF4444OFF|r"))
end

-- ---------------------------------------------------------------------------
-- Event registration (called once from DisenchantingAddon.lua on ADDON_LOADED)
-- ---------------------------------------------------------------------------
function DA:RegisterTrackingEvents(frame)
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    -- Refresh the skill cache whenever profession data is guaranteed accessible.
    -- TRADE_SKILL_SHOW fires when the window opens but the API may not have
    -- loaded data yet; TRADE_SKILL_UPDATE fires after the data is ready.
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("TRADE_SKILL_SHOW")
    frame:RegisterEvent("SKILL_LINES_CHANGED")
end

-- Returns true if the Enchanting trade skill window is currently open.
-- Used to guard TRADE_SKILL_SHOW/UPDATE so that opening Alchemy, Blacksmithing,
-- etc. does not trigger a cache update — C_ProfSpecs APIs return data for
-- whichever profession is active in the UI, which would corrupt the skill cache.
IsEnchantingTradeSkillOpen = function()
    local function dbg(s)
        if debugMode and DA.DebugOutput then DA:DebugOutput(s) end
    end

    if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then
        dbg("IsEnchantingTradeSkillOpen: GetBaseProfessionInfo unavailable — allowing update")
        return true  -- API unavailable; allow update
    end
    local info = C_TradeSkillUI.GetBaseProfessionInfo()
    if not info then
        dbg("IsEnchantingTradeSkillOpen: GetBaseProfessionInfo returned nil — allowing update")
        return true
    end
    -- Dump every field so we can see the exact structure in Midnight.
    dbg("IsEnchantingTradeSkillOpen: GetBaseProfessionInfo fields:")
    for k, v in pairs(info) do
        dbg(string.format("  .%s = %s", tostring(k), tostring(v)))
    end
    local name = info.professionName or info.displayName
    if not name then
        dbg("IsEnchantingTradeSkillOpen: no professionName/displayName field — allowing update")
        return true
    end
    local isEnchanting = name:lower():find("enchanting") ~= nil
    dbg(string.format("IsEnchantingTradeSkillOpen: professionName=%q → %s",
        name, isEnchanting and "ENCHANTING" or "OTHER — skipping"))
    return isEnchanting
end

function DA:HandleTrackingEvent(event)
    if event == "BAG_UPDATE_DELAYED" then
        OnBagUpdateDelayed()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Skill cache persists via SavedVariables, so the correct value survives
        -- reloads without needing a refresh here.  Calling UpdateSkillCache at
        -- login would overwrite the cached value with base-only skill (no spec
        -- bonuses) because the profession window is not open yet.
        -- The cache will be refreshed properly when the player opens Enchanting.
    elseif event == "SKILL_LINES_CHANGED" then
        -- Guard: fires while any profession window may be open; treat the same
        -- as TRADE_SKILL_SHOW/UPDATE to avoid reading another profession's data.
        C_Timer.After(0, function()
            if IsEnchantingTradeSkillOpen() then UpdateSkillCache() end
        end)
    elseif event == "TRADE_SKILL_SHOW" then
        -- Only refresh when Enchanting is the profession that was opened.
        -- Other professions fire these same events and C_ProfSpecs would then
        -- return data for the wrong profession, poisoning the skill cache.
        C_Timer.After(0, function()
            if IsEnchantingTradeSkillOpen() then
                UpdateSkillCache()
            end
        end)
    end
end
