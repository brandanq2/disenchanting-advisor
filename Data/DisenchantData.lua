-- DisenchantData.lua
-- Disenchanting outcome tables keyed by [expansionID][itemQuality].
-- Using expansion ID is squish-proof and requires no ilvl bracket maintenance.
--
-- To find an item ID in-game:
--   /run print(C_Item.GetItemInfoInstant("Item Name Here"))
--
-- Expansion ID constants (WoW globals):
--   LE_EXPANSION_WAR_WITHIN = 10
--   LE_EXPANSION_MIDNIGHT   = 11

DisenchantingAdvisor = DisenchantingAdvisor or {}
local DA = DisenchantingAdvisor

-- Safe references to expansion ID globals (fallback to literals if not defined)
local EXP_TWW      = (LE_EXPANSION_WAR_WITHIN ~= nil) and LE_EXPANSION_WAR_WITHIN or 10
local EXP_MIDNIGHT = (LE_EXPANSION_MIDNIGHT   ~= nil) and LE_EXPANSION_MIDNIGHT   or 11

-- Expose so Tracking.lua can reference them
DA.EXP_TWW      = EXP_TWW
DA.EXP_MIDNIGHT = EXP_MIDNIGHT

-- ---------------------------------------------------------------------------
-- Material definitions
-- Format: [key] = { id = itemID, name = fallbackName }
--
-- TWW quality tier system (3 tiers):
--   Storm Dust     Q1=219946, Q2=219947, Q3=219948
--   Gleaming Shard Q1=219949, Q2=219950, Q3=219951
--   Refulgent Crystal Q1=219952, Q2=219954, Q3=219955  (219953 unused)
--
-- Midnight rank system (2 tiers):
--   Rank 1 IDs: 243599 (Dust), 243602 (Shard), 243605 (Crystal)
--   Rank 2 IDs: 243600 (Dust), 243603 (Shard), 243606 (Crystal)
-- ---------------------------------------------------------------------------
DA.MATS = {
    -- ---- The War Within (expansionID 10) ----------------------------------
    -- Quality tier system: Q1 (lowest) → Q3 (highest).
    -- Higher Enchanting skill increases Q2/Q3 drop chance.
    TWW_STORM_DUST_Q1        = { id = 219946, name = "Storm Dust",        qualityTier = 1 },
    TWW_STORM_DUST_Q2        = { id = 219947, name = "Storm Dust",        qualityTier = 2 },
    TWW_STORM_DUST_Q3        = { id = 219948, name = "Storm Dust",        qualityTier = 3 },
    TWW_GLEAMING_SHARD_Q1    = { id = 219949, name = "Gleaming Shard",    qualityTier = 1 },
    TWW_GLEAMING_SHARD_Q2    = { id = 219950, name = "Gleaming Shard",    qualityTier = 2 },
    TWW_GLEAMING_SHARD_Q3    = { id = 219951, name = "Gleaming Shard",    qualityTier = 3 },
    TWW_REFULGENT_CRYSTAL_Q1 = { id = 219952, name = "Refulgent Crystal", qualityTier = 1 },
    TWW_REFULGENT_CRYSTAL_Q2 = { id = 219954, name = "Refulgent Crystal", qualityTier = 2 },
    TWW_REFULGENT_CRYSTAL_Q3 = { id = 219955, name = "Refulgent Crystal", qualityTier = 3 },

    -- ---- Midnight (expansionID 11) ----------------------------------------
    -- Rank system: R1 (lower) and R2 (higher) variant per mat type.
    EVERSINGING_DUST_R1 = { id = 243599, name = "Eversinging Dust",  qualityTier = 1 },
    EVERSINGING_DUST_R2 = { id = 243600, name = "Eversinging Dust",  qualityTier = 2 },
    RADIANT_SHARD_R1    = { id = 243602, name = "Radiant Shard",     qualityTier = 1 },
    RADIANT_SHARD_R2    = { id = 243603, name = "Radiant Shard",     qualityTier = 2 },
    DAWN_CRYSTAL_R1     = { id = 243605, name = "Dawn Crystal",      qualityTier = 1 },
    DAWN_CRYSTAL_R2     = { id = 243606, name = "Dawn Crystal",      qualityTier = 2 },
}

-- Reverse lookup: itemID → mat entry (built once after MATS is defined).
DA.MATS_BY_ID = {}
for _, mat in pairs(DA.MATS) do
    if mat.id and mat.id > 0 then
        DA.MATS_BY_ID[mat.id] = mat
    end
end

-- ---------------------------------------------------------------------------
-- Midnight Disenchanting Specialization node data
-- Hardcoded because perkIDs returned by C_ProfSpecs.GetPerksForPath exceed the
-- signed int32 range accepted by GetDescriptionForPerk/GetStateForPerk, making
-- those values unreadable at runtime.
--
-- Structure per node entry:
--   name          human-readable label (used in /dea skillcheck output)
--   perPointSkill enchanting skill gained per point invested in this node
--   qualityFilter item quality the skill applies to, nil = all qualities
--                 (2 = Uncommon, 3 = Rare, 4 = Epic)
--   breakpoints   list of { minPoints, skill } — each flat bonus is awarded
--                 when points invested reaches or exceeds minPoints; all
--                 thresholds that are met are summed together
--   parentPathID  pathID of the parent node, nil for tab root paths
--
-- Path IDs come from C_ProfSpecs.GetRootPathForTab / GetChildrenForPath.
-- Run /dea skillcheck to confirm IDs after any major patch.
-- ---------------------------------------------------------------------------
DA.MIDNIGHT_SPEC_NODES = {

    -- Disenchanting Delegate — root path of spec tab 1153 (pathID confirmed by /dea skillcheck)
    -- maxRanks = 31.  Every point gives +1 Enchanting skill (all qualities).
    -- Breakpoints at 5 / 15 / 25 pts unlock child nodes (no flat skill bonus).
    [107649] = {
        name          = "Disenchanting Delegate",
        perPointSkill = 1,
        qualityFilter = nil,      -- applies to all item qualities
        breakpoints   = {
            { minPoints = 1,  skill = 5  },
            { minPoints = 10, skill = 5  },
            { minPoints = 20, skill = 10 },
            { minPoints = 30, skill = 20 },
        },
        parentPathID  = nil,
    },

    -- Shard Supplier (pathID 107647) — child of Disenchanting Delegate.
    -- Description: "Practice your ritual for disenchanting Rare Midnight equipment,
    --   gaining +1 Skill per point in this Specialization when disenchanting Rare
    --   Midnight equipment."
    -- maxRanks = 31.  Unlocked at 5 pts in Disenchanting Delegate.
    -- Every point gives +1 Enchanting skill for Rare items only.
    [107647] = {
        name          = "Shard Supplier",
        perPointSkill = 1,
        qualityFilter = 3,        -- Rare items only
        breakpoints   = {
            { minPoints = 1,  skill = 5  },
            { minPoints = 5,  skill = 5  },
            { minPoints = 10, skill = 5  },
            { minPoints = 15, skill = 5  },
            -- 20 pts: chance for bonus Radiant Shards (no flat skill bonus)
            { minPoints = 25, skill = 10 },
            { minPoints = 30, skill = 20 },
        },
        parentPathID  = 107649,
    },

    -- Dust Deliverer (pathID 107648) — child of Disenchanting Delegate.
    -- Description: "Learn the art of Disenchanting Uncommon Midnight equipment,
    --   gaining +1 Skill per point in this Specialization when disenchanting them."
    -- maxRanks = 31.  Unlocked at 15 pts in Disenchanting Delegate.
    -- Every point gives +1 Enchanting skill for Uncommon items only.
    -- Same breakpoint structure as Shard Supplier.
    [107648] = {
        name          = "Dust Deliverer",
        perPointSkill = 1,
        qualityFilter = 2,        -- Uncommon items only
        breakpoints   = {
            { minPoints = 1,  skill = 5  },
            { minPoints = 5,  skill = 5  },
            { minPoints = 10, skill = 5  },
            { minPoints = 15, skill = 5  },
            -- 20 pts: chance for bonus Eversinging Dust (no flat skill bonus)
            { minPoints = 25, skill = 10 },
            { minPoints = 30, skill = 20 },
        },
        parentPathID  = 107649,
    },

    -- Crystal Collector (pathID 107646) — child of Disenchanting Delegate.
    -- Description: "Improve your understanding of complex Disenchanting rituals,
    --   improving the quality of materials you receive when breaking down Epic items."
    -- maxRanks = 31.  Unlocked at 25 pts in Disenchanting Delegate.
    -- Every point gives +1 Enchanting skill for Epic items only.
    -- Same breakpoint structure as Shard Supplier.
    -- 20 pts proc: "Midnight's native magical essences" (bonus item — no flat skill bonus).
    [107646] = {
        name          = "Crystal Collector",
        perPointSkill = 1,
        qualityFilter = 4,        -- Epic items only
        breakpoints   = {
            { minPoints = 1,  skill = 5  },
            { minPoints = 5,  skill = 5  },
            { minPoints = 10, skill = 5  },
            { minPoints = 15, skill = 5  },
            -- 20 pts: chance for "Midnight's native magical essences" (no flat skill bonus)
            { minPoints = 25, skill = 10 },
            { minPoints = 30, skill = 20 },
        },
        parentPathID  = 107649,
    },
}

-- ---------------------------------------------------------------------------
-- Disenchant outcome table
-- Indexed by [expansionID][itemQuality]
--   itemQuality: 2 = Uncommon (green), 3 = Rare (blue), 4 = Epic (purple)
--   Each entry is a list of results: { matKey, minQty, maxQty, chance }
--     matKey  = key into DA.MATS
--     minQty  = minimum quantity dropped
--     maxQty  = maximum quantity dropped
--     chance  = probability this mat appears (1.0 = always)
--
-- Items from expansions not listed here will show nothing in the tooltip.
-- ---------------------------------------------------------------------------
DA.DISENCHANT = {

    -- -----------------------------------------------------------------------
    -- The War Within (expansionID 10)
    -- Item IDs confirmed. Quality tier ratios are estimates — disenchant
    -- items to accumulate observed rates and replace these automatically.
    -- Quality tier (Q1/Q2/Q3) depends on Enchanting skill/specialization.
    -- -----------------------------------------------------------------------
    [EXP_TWW] = {
        [2] = {  -- Uncommon (green) → Storm Dust (Q1/Q2/Q3)
            { matKey = "TWW_STORM_DUST_Q3", minQty = 1, maxQty = 2, chance = 0.50 },
            { matKey = "TWW_STORM_DUST_Q2", minQty = 1, maxQty = 3, chance = 0.35 },
            { matKey = "TWW_STORM_DUST_Q1", minQty = 1, maxQty = 3, chance = 0.15 },
        },
        [3] = {  -- Rare (blue) → Gleaming Shard (Q1/Q2/Q3)
            { matKey = "TWW_GLEAMING_SHARD_Q3", minQty = 1, maxQty = 1, chance = 0.50 },
            { matKey = "TWW_GLEAMING_SHARD_Q2", minQty = 1, maxQty = 1, chance = 0.35 },
            { matKey = "TWW_GLEAMING_SHARD_Q1", minQty = 1, maxQty = 1, chance = 0.15 },
        },
        [4] = {  -- Epic (purple) → Refulgent Crystal (Q1/Q2/Q3)
            { matKey = "TWW_REFULGENT_CRYSTAL_Q3", minQty = 1, maxQty = 1, chance = 0.50 },
            { matKey = "TWW_REFULGENT_CRYSTAL_Q2", minQty = 1, maxQty = 1, chance = 0.35 },
            { matKey = "TWW_REFULGENT_CRYSTAL_Q1", minQty = 1, maxQty = 1, chance = 0.15 },
        },
    },

    -- -----------------------------------------------------------------------
    -- Midnight (expansionID 11)
    -- Sources: community testing Feb 2026, pre-expansion launch
    -- [NEEDS DATA] entries are still approximate
    -- -----------------------------------------------------------------------
    [EXP_MIDNIGHT] = {
        [2] = {  -- Uncommon (green) — ~10% chance confirmed, qty [NEEDS DATA]
            { matKey = "EVERSINGING_DUST_R2", minQty = 1, maxQty = 2, chance = 0.90 },
            { matKey = "EVERSINGING_DUST_R1", minQty = 1, maxQty = 2, chance = 0.10 },
        },
        [3] = {  -- Rare (blue) — ~50% shard confirmed, failure outcome [NEEDS DATA]
            { matKey = "RADIANT_SHARD_R2",    minQty = 1, maxQty = 1, chance = 0.45 },
            { matKey = "RADIANT_SHARD_R1",    minQty = 1, maxQty = 1, chance = 0.45 },
            { matKey = "EVERSINGING_DUST_R2", minQty = 1, maxQty = 3, chance = 0.10 },
        },
        [4] = {  -- Epic (purple) — 100% crystal confirmed, rank ratio [NEEDS DATA]
            { matKey = "DAWN_CRYSTAL_R2", minQty = 1, maxQty = 1, chance = 0.75 },
            { matKey = "DAWN_CRYSTAL_R1", minQty = 1, maxQty = 1, chance = 0.25 },
        },
    },
}

-- ---------------------------------------------------------------------------
-- Helper: look up disenchant results for a given expansionID + quality.
-- Returns the results array, or nil if no data exists for that combination.
-- ---------------------------------------------------------------------------
function DA:GetDisenchantResults(quality, expansionID)
    local expData = DA.DISENCHANT[expansionID]
    if not expData then return nil end
    return expData[quality]
end

-- ---------------------------------------------------------------------------
-- Helper: preload mat item names into the client cache on login.
-- ---------------------------------------------------------------------------
function DA:PreloadMatNames()
    for _, mat in pairs(DA.MATS) do
        if mat.id and mat.id > 0 then
            if C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(mat.id)
            else
                GetItemInfo(mat.id)
            end
        end
    end
end
