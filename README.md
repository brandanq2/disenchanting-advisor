# Disenchanting Advisor

A World of Warcraft: Midnight beta addon that extends item tooltips with expected disenchanting materials and their Auction House values.

## Features

### Tooltip Integration
- Automatically appends disenchanting information to item tooltips for equippable Uncommon, Rare, and Epic items
- Shows each mat's **drop chance** and **average quantity when received**
- Shows per-mat gold value (actual value when received, not probability-weighted)
- Shows **Expected Value** total (probability-weighted sum across all mats)
- Displays AH price for known enchanting mats when hovering them directly (with stack total when Shift is held)

### Disenchant Tracking
- Tracks your personal disenchanting outcomes by monitoring bag changes — no spell hooks required
- Buckets data by **item quality** (Uncommon / Rare / Epic), **expansion**, and **enchanting skill tier** (25-point bands) for Midnight
- Handles split-event disenchants where spec procs deliver mats in a separate server event
- Minimum 10 samples required before observed rates are shown (prevents misleading data from small samples)

### Skill-Aware Bucketing (Midnight)
- Enchanting skill is cached per character when the Enchanting window is open, persisting across reloads via SavedVariables
- Skill cache is protected against contamination from other profession windows (Tailoring, Alchemy, etc.)
- Disenchants recorded with no profession window open use the cached skill tier so bucketing remains accurate

### Stats Frame (`/dea stats`)
- Movable window showing your tracked disenchanting rates for each quality tier
- Displays effective skill, drop chances, average quantities, and expected gold value
- Live-updates as you disenchant

### Per-Character Data
- Tracking data and skill cache are stored per character (`Realm-CharName`) within a single SavedVariable
- AH prices and settings are shared globally across all characters on the account
- Automatic migration from pre-per-character data format

### AH Price Integration
- Reads prices from TSM (TradeSkillMaster) if installed, with fallback to a manual price cache
- `/dea scan` scans the Auction House for current mat prices
- `/dea setprice <itemID> <gold>` manually sets a price for any mat

## Commands

| Command | Description |
|---|---|
| `/dea stats` | Open/close the disenchant stats window |
| `/dea scan` | Scan AH mat prices (must be at the Auction House) |
| `/dea toggle` | Toggle tooltip display on/off |
| `/dea breakdown` | Toggle per-mat breakdown lines in tooltip |
| `/dea source` | Toggle price source tag (TSM/cache) |
| `/dea setprice <id> <gold>` | Manually set a mat price |
| `/dea clearstats` | Wipe all personal tracking data |
| `/dea prices` | Debug: show price for every known mat |
| `/dea skillcheck` | Dev: verify spec skill values and path IDs |
| `/dea debug` | Debug: show addon data for hovered item |
| `/dea tooltipdebug` | Debug: dump raw tooltip/data object on next hover |

## Compatibility

- **WoW: Midnight** beta (Interface version 120001)
- Designed around Midnight's skill-based disenchanting system where yield varies by enchanting skill tier
