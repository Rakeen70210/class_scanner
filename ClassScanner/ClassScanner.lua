local addonName, addonTable = ...

-- Initialize the database
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TALENT_UPDATE")
frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
frame:RegisterEvent("INSPECT_READY")



local NULL_GUID = "0x0000000000000000"

local function IsGuidString(value)
    if type(value) ~= "string" then return false end
    -- WotLK uses hex-style GUIDs like "0xF130...". Some clients use "Player-..." etc.
    if value:sub(1, 2) == "0x" then return true end
    if value:match("^Player%-") then return true end
    if value:match("^Creature%-") then return true end
    if value:match("^Pet%-") then return true end
    if value:match("^Vehicle%-") then return true end
    return false
end

local RACES = {
    -- WotLK English race tokens are space-separated (e.g. "Night Elf", "Blood Elf").
    ["Human"] = "Alliance",
    ["Dwarf"] = "Alliance",
    ["Night Elf"] = "Alliance",
    ["Gnome"] = "Alliance",
    ["Draenei"] = "Alliance",

    ["Orc"] = "Horde",
    ["Undead"] = "Horde",
    ["Tauren"] = "Horde",
    ["Troll"] = "Horde",
    ["Blood Elf"] = "Horde",

    -- Backwards-compatible / alternative tokens
    ["NightElf"] = "Alliance",
    ["BloodElf"] = "Horde",
    ["Scourge"] = "Horde"
}

local function GetFactionFromRace(race)
    return RACES[race] or "Unknown"
end

-- Some servers/clients use alternative race tokens (e.g. "NightElf").
-- Keep display/stats consistent without forcing a DB migration.
local function CanonicalizeRace(race)
    if race == "NightElf" then return "Night Elf" end
    if race == "BloodElf" then return "Blood Elf" end
    if race == "Scourge" then return "Undead" end
    return race
end

local localizedClassToToken
local function BuildLocalizedClassToToken()
    if localizedClassToToken then return localizedClassToToken end
    localizedClassToToken = {}

    -- LOCALIZED_CLASS_NAMES_* maps token -> localized string; invert it.
    local function InvertLocalized(map)
        if type(map) ~= "table" then return end
        for token, localized in pairs(map) do
            if type(token) == "string" and type(localized) == "string" then
                localizedClassToToken[localized] = token
            end
        end
    end

    InvertLocalized(_G.LOCALIZED_CLASS_NAMES_MALE)
    InvertLocalized(_G.LOCALIZED_CLASS_NAMES_FEMALE)

    -- Common variants seen in some UIs/APIs
    localizedClassToToken["Death Knight"] = localizedClassToToken["Death Knight"] or "DEATHKNIGHT"
    localizedClassToToken["DEATH KNIGHT"] = localizedClassToToken["DEATH KNIGHT"] or "DEATHKNIGHT"
    localizedClassToToken["DeathKnight"] = localizedClassToToken["DeathKnight"] or "DEATHKNIGHT"

    return localizedClassToToken
end

local function CanonicalizeClass(class)
    if type(class) ~= "string" then return nil end
    class = class:match("^%s*(.-)%s*$")
    if class == "" then return nil end

    -- Fast path: already a token we recognize
    if (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]) then
        return class
    end

    local upper = class:upper()
    if (RAID_CLASS_COLORS and RAID_CLASS_COLORS[upper]) then
        return upper
    end

    local map = BuildLocalizedClassToToken()
    if map[class] then return map[class] end
    if map[upper] then return map[upper] end

    return nil
end

local STANDARD_CLASS_SPECS = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE = { "Assassination", "Combat", "Subtlety" },
    PRIEST = { "Discipline", "Holy", "Shadow" },
    DEATHKNIGHT = { "Blood", "Frost", "Unholy" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" },
    MAGE = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID = { "Balance", "Feral", "Restoration" },
}

-- Flat lookup set of every valid spec name; used to prevent garbage strings
-- (e.g. spell names from the combat log) from being stored as spec values.
local VALID_SPEC_NAMES = {}
for _, specs in pairs(STANDARD_CLASS_SPECS) do
    for _, specName in ipairs(specs) do
        VALID_SPEC_NAMES[specName] = true
    end
end

local SPEC_SOURCE_PRIORITY = {
    combatlog = 1,
    buff = 2,
    inspect = 3,
    talent = 4,
}

local SPEC_SOURCE_CONFIDENCE = {
    combatlog = "low",
    buff = "medium",
    inspect = "high",
    talent = "high",
}

local SPEC_STALE_REPLACE_SEC = 3600

-- Buff-based spec inference for quickly identifying obvious specs.
local SPEC_BUFF_BY_CLASS = {
    WARRIOR = {
        [71] = "Protection",       -- Defensive Stance
        [2457] = "Arms",           -- Battle Stance
        [2458] = "Fury",           -- Berserker Stance
    },
    PRIEST = {
        [15473] = "Shadow",        -- Shadowform
    },
    DRUID = {
        [24858] = "Balance",       -- Moonkin Form
        [33891] = "Restoration",   -- Tree of Life
        [5487] = "Feral",          -- Bear Form
        [9634] = "Feral",          -- Dire Bear Form
        [768] = "Feral",           -- Cat Form
    },
    PALADIN = {
        [25780] = "Protection",    -- Righteous Fury
    },
    DEATHKNIGHT = {
        [48266] = "Blood",         -- Blood Presence
        [48263] = "Frost",         -- Frost Presence
        [48265] = "Unholy",        -- Unholy Presence
    },
    SHAMAN = {
        [52127] = "Restoration",   -- Water Shield
    },
}

-- Distinctive combat-log spell IDs for low-confidence spec inference.
local SPEC_COMBAT_SPELLS = {
    WARRIOR = {
        [12294] = "Arms",       -- Mortal Strike
        [46924] = "Arms",       -- Bladestorm
        [23881] = "Fury",       -- Bloodthirst
        [1680] = "Fury",        -- Whirlwind
        [23922] = "Protection", -- Shield Slam
        [46968] = "Protection", -- Shockwave
    },
    PALADIN = {
        [20473] = "Holy",       -- Holy Shock
        [53563] = "Holy",       -- Beacon of Light
        [48827] = "Protection", -- Avenger's Shield
        [53595] = "Protection", -- Hammer of the Righteous
        [35395] = "Retribution",-- Crusader Strike
        [53385] = "Retribution",-- Divine Storm
    },
    HUNTER = {
        [19574] = "Beast Mastery", -- Bestial Wrath
        [19577] = "Beast Mastery", -- Intimidation
        [53209] = "Marksmanship",  -- Chimera Shot
        [19434] = "Marksmanship",  -- Aimed Shot
        [53301] = "Survival",      -- Explosive Shot
        [3674] = "Survival",       -- Black Arrow
    },
    ROGUE = {
        [1329] = "Assassination",  -- Mutilate
        [32645] = "Assassination", -- Envenom
        [51690] = "Combat",        -- Killing Spree
        [13877] = "Combat",        -- Blade Flurry
        [36554] = "Subtlety",      -- Shadowstep
        [51713] = "Subtlety",      -- Shadow Dance
    },
    PRIEST = {
        [47540] = "Discipline",    -- Penance
        [33206] = "Discipline",    -- Pain Suppression
        [48089] = "Holy",          -- Circle of Healing
        [47788] = "Holy",          -- Guardian Spirit
        [34914] = "Shadow",        -- Vampiric Touch
        [15407] = "Shadow",        -- Mind Flay
    },
    DEATHKNIGHT = {
        [55050] = "Blood",         -- Heart Strike
        [55233] = "Blood",         -- Vampiric Blood
        [49184] = "Frost",         -- Howling Blast
        [49143] = "Frost",         -- Frost Strike
        [55090] = "Unholy",        -- Scourge Strike
        [49206] = "Unholy",        -- Summon Gargoyle
    },
    SHAMAN = {
        [51505] = "Elemental",     -- Lava Burst
        [51490] = "Elemental",     -- Thunderstorm
        [17364] = "Enhancement",   -- Stormstrike
        [60103] = "Enhancement",   -- Lava Lash
        [61295] = "Restoration",   -- Riptide
        [974] = "Restoration",     -- Earth Shield
    },
    MAGE = {
        [44425] = "Arcane",        -- Arcane Barrage
        [42897] = "Arcane",        -- Arcane Blast
        [44457] = "Fire",          -- Living Bomb
        [42891] = "Fire",          -- Pyroblast
        [44572] = "Frost",         -- Deep Freeze
        [12472] = "Frost",         -- Icy Veins
    },
    WARLOCK = {
        [47843] = "Affliction",    -- Unstable Affliction
        [48181] = "Affliction",    -- Haunt
        [47241] = "Demonology",    -- Metamorphosis
        [47897] = "Demonology",    -- Hand of Gul'dan
        [17962] = "Destruction",   -- Conflagrate
        [50796] = "Destruction",   -- Chaos Bolt
    },
    DRUID = {
        [53201] = "Balance",       -- Starfall
        [50516] = "Balance",       -- Typhoon
        [33876] = "Feral",         -- Mangle (Cat)
        [33878] = "Feral",         -- Mangle (Bear)
        [48438] = "Restoration",   -- Wild Growth
        [18562] = "Restoration",   -- Swiftmend
    },
}

-- Spell name-based lookup for combat log inference.
-- Fallback when IDs differ across WotLK clients, ranks, or private-server forks.
local SPEC_COMBAT_SPELL_NAMES = {
    WARRIOR = {
        ["Mortal Strike"] = "Arms", ["Bladestorm"] = "Arms",
        ["Bloodthirst"] = "Fury", ["Whirlwind"] = "Fury",
        ["Shield Slam"] = "Protection", ["Shockwave"] = "Protection",
    },
    PALADIN = {
        ["Holy Shock"] = "Holy", ["Beacon of Light"] = "Holy",
        ["Avenger's Shield"] = "Protection", ["Hammer of the Righteous"] = "Protection",
        ["Crusader Strike"] = "Retribution", ["Divine Storm"] = "Retribution",
    },
    HUNTER = {
        ["Bestial Wrath"] = "Beast Mastery", ["Intimidation"] = "Beast Mastery",
        ["Chimera Shot"] = "Marksmanship", ["Aimed Shot"] = "Marksmanship",
        ["Explosive Shot"] = "Survival", ["Black Arrow"] = "Survival",
    },
    ROGUE = {
        ["Mutilate"] = "Assassination", ["Envenom"] = "Assassination",
        ["Killing Spree"] = "Combat", ["Blade Flurry"] = "Combat",
        ["Shadowstep"] = "Subtlety", ["Shadow Dance"] = "Subtlety",
    },
    PRIEST = {
        ["Penance"] = "Discipline", ["Pain Suppression"] = "Discipline",
        ["Circle of Healing"] = "Holy", ["Guardian Spirit"] = "Holy",
        ["Vampiric Touch"] = "Shadow", ["Mind Flay"] = "Shadow",
    },
    DEATHKNIGHT = {
        ["Heart Strike"] = "Blood", ["Vampiric Blood"] = "Blood",
        ["Howling Blast"] = "Frost", ["Frost Strike"] = "Frost",
        ["Scourge Strike"] = "Unholy", ["Summon Gargoyle"] = "Unholy",
    },
    SHAMAN = {
        ["Lava Burst"] = "Elemental", ["Thunderstorm"] = "Elemental",
        ["Stormstrike"] = "Enhancement", ["Lava Lash"] = "Enhancement",
        ["Riptide"] = "Restoration", ["Earth Shield"] = "Restoration",
    },
    MAGE = {
        ["Arcane Barrage"] = "Arcane", ["Arcane Blast"] = "Arcane",
        ["Living Bomb"] = "Fire", ["Pyroblast"] = "Fire",
        ["Deep Freeze"] = "Frost", ["Icy Veins"] = "Frost",
    },
    WARLOCK = {
        ["Unstable Affliction"] = "Affliction", ["Haunt"] = "Affliction",
        ["Metamorphosis"] = "Demonology", ["Hand of Gul'dan"] = "Demonology",
        ["Conflagrate"] = "Destruction", ["Chaos Bolt"] = "Destruction",
    },
    DRUID = {
        ["Starfall"] = "Balance", ["Typhoon"] = "Balance",
        ["Mangle (Cat)"] = "Feral", ["Mangle (Bear)"] = "Feral", ["Mangle"] = "Feral",
        ["Wild Growth"] = "Restoration", ["Swiftmend"] = "Restoration",
    },
}

-- Buff name-based lookup (fallback when buff spell IDs differ across clients).
-- ONLY includes SELF-ONLY buffs/procs. Party/raid-wide buffs are excluded
-- because they would appear on party members who are NOT that spec.
local SPEC_BUFF_NAMES_BY_CLASS = {
    WARRIOR = {
        ["Defensive Stance"] = "Protection",
        ["Battle Stance"] = "Arms",
        ["Berserker Stance"] = "Fury",
        -- Self-only talent procs
        ["Sword and Board"] = "Protection",
        ["Taste for Blood"] = "Arms",
        -- NOTE: "Rampage" removed — party-wide buff
    },
    PRIEST = {
        ["Shadowform"] = "Shadow",
        -- Self-only talent procs
        ["Vampiric Embrace"] = "Shadow",
        ["Surge of Light"] = "Holy",
        ["Borrowed Time"] = "Discipline",
        ["Inner Focus"] = "Discipline",
    },
    DRUID = {
        ["Moonkin Form"] = "Balance",
        ["Tree of Life"] = "Restoration",
        ["Bear Form"] = "Feral",
        ["Dire Bear Form"] = "Feral",
        ["Cat Form"] = "Feral",
        -- Self-only talent procs
        ["Eclipse"] = "Balance",
        ["Eclipse (Solar)"] = "Balance",
        ["Eclipse (Lunar)"] = "Balance",
        ["Savage Roar"] = "Feral",
        ["Survival Instincts"] = "Feral",
        ["Nature's Swiftness"] = "Restoration",
    },
    PALADIN = {
        ["Righteous Fury"] = "Protection",
        -- Self-only talent procs
        ["The Art of War"] = "Retribution",
        ["Infusion of Light"] = "Holy",
        ["Holy Shield"] = "Protection",
        ["Sheath of Light"] = "Retribution",
    },
    DEATHKNIGHT = {
        ["Blood Presence"] = "Blood",
        ["Frost Presence"] = "Frost",
        ["Unholy Presence"] = "Unholy",
        -- Self-only talent procs
        ["Bone Shield"] = "Unholy",
        ["Blade Barrier"] = "Blood",
        ["Killing Machine"] = "Frost",
        ["Freezing Fog"] = "Frost",
    },
    SHAMAN = {
        ["Water Shield"] = "Restoration",
        -- Self-only talent procs
        ["Elemental Focus"] = "Elemental",
        ["Elemental Mastery"] = "Elemental",
        ["Maelstrom Weapon"] = "Enhancement",
        ["Shamanistic Rage"] = "Enhancement",
        ["Spirit Weapons"] = "Enhancement",
        ["Flurry"] = "Enhancement",
        ["Tidal Waves"] = "Restoration",
    },
    MAGE = {
        -- Self-only talent procs
        ["Arcane Power"] = "Arcane",
        ["Presence of Mind"] = "Arcane",
        ["Missile Barrage"] = "Arcane",
        ["Hot Streak"] = "Fire",
        ["Combustion"] = "Fire",
        ["Fingers of Frost"] = "Frost",
        ["Brain Freeze"] = "Frost",
        ["Ice Barrier"] = "Frost",
    },
    WARLOCK = {
        -- Self-only talent procs
        ["Eradication"] = "Affliction",
        ["Nightfall"] = "Affliction",
        ["Molten Core"] = "Demonology",
        ["Decimation"] = "Demonology",
        ["Metamorphosis"] = "Demonology",
        ["Backdraft"] = "Destruction",
        ["Nether Protection"] = "Destruction",
    },
    HUNTER = {
        -- Self-only talent procs
        ["The Beast Within"] = "Beast Mastery",
        ["Master Marksman"] = "Marksmanship",
        ["Lock and Load"] = "Survival",
    },
    ROGUE = {
        -- Self-only talent procs
        ["Master of Subtlety"] = "Subtlety",
        ["Shadow Dance"] = "Subtlety",
        ["Blade Flurry"] = "Combat",
        ["Adrenaline Rush"] = "Combat",
        ["Cold Blood"] = "Assassination",
        ["Hunger for Blood"] = "Assassination",
    },
}

-- Spec detection debug mode (toggled with /cs specdebug)
local specDebugEnabled = false
local function SpecDebug(msg)
    if specDebugEnabled then
        print("|cFF00FF00[CS-SpecDebug]|r " .. msg)
    end
end

-- Buff names that are party/raid-wide or cast on others.
-- These are only matched if UnitBuff reports the caster is the unit being scanned.
local SPEC_BUFF_CASTERCHECK_BY_CLASS = {
    SHAMAN = {
        ["Elemental Oath"] = "Elemental",
        ["Totem of Wrath"] = "Elemental",
        ["Earth Shield"] = "Restoration",
        ["Ancestral Healing"] = "Restoration",
    },
    WARRIOR = {
        ["Rampage"] = "Fury",
    },
    HUNTER = {
        ["Trueshot Aura"] = "Marksmanship",
        ["Hunting Party"] = "Survival",
    },
    WARLOCK = {
        ["Demonic Pact"] = "Demonology",
    },
}

local function IsStandardClassToken(classToken)
    return type(classToken) == "string" and STANDARD_CLASS_SPECS[classToken] ~= nil
end

local function NormalizeSpecName(spec)
    if type(spec) ~= "string" then return nil end
    spec = spec:match("^%s*(.-)%s*$")
    if spec == "" then return nil end
    return spec
end

local function GetSpecFallbackForTab(classToken, tabIndex)
    local tabs = STANDARD_CLASS_SPECS[classToken]
    if not tabs then return nil end
    return tabs[tabIndex]
end

local function SourceRank(source)
    return SPEC_SOURCE_PRIORITY[source] or 0
end

local function ShouldReplaceSpec(entry, source)
    if not entry or not entry.spec then return true end
    local oldSource = entry.specSource
    local oldRank = SourceRank(oldSource)
    local newRank = SourceRank(source)

    if newRank > oldRank then return true end
    if newRank == oldRank then return true end

    local updatedAt = entry.specUpdatedAt or 0
    return (time() - updatedAt) >= SPEC_STALE_REPLACE_SEC
end

local function SetEntrySpec(entry, specName, source)
    if type(entry) ~= "table" then return end
    local spec = NormalizeSpecName(specName)
    if not spec then return end
    if not VALID_SPEC_NAMES[spec] then return end  -- reject any non-whitelisted name
    if not ShouldReplaceSpec(entry, source) then return end

    entry.spec = spec
    entry.specSource = source
    entry.specConfidence = SPEC_SOURCE_CONFIDENCE[source] or "low"
    entry.specUpdatedAt = time()
end

-- Settings (stored separately from the player DB)
local function DefaultSettings()
    return {
        quiet = false,           -- disable "New player scanned" chat prints
        printThrottleSec = 1.5,  -- minimum seconds between prints
        trackDamageToPlayer = true,  -- track damage dealt to you by other players
        burstWindowSec = 3,          -- sliding window (seconds) for peak burst DPS
        encounterTimeoutSec = 10,    -- idle timeout to expire per-attacker burst state
        includePeriodicDamage = true, -- include DoTs in damage tracking
        includeDamageShields = true,  -- include damage shields (thorns, etc.)
        inspectSpecEnabled = true,     -- inspect target talents for high-confidence spec detection
        inspectThrottleSec = 2.0,      -- seconds between inspect requests
        specEvidenceMinHits = 1,       -- combat-log votes required before setting low-confidence spec
    }
end

local function Now()
    return time()
end

-- Snapshot of where we are right now (zone / instance context).
-- Used for "first met" tracking; keep it cheap and resilient to client/server API differences.
local function GetMeetContext()
    local ctx = { t = Now() }

    if GetRealZoneText then
        local z = GetRealZoneText()
        if z and z ~= "" then ctx.zone = z end
    end
    if GetSubZoneText then
        local sz = GetSubZoneText()
        if sz and sz ~= "" then ctx.subzone = sz end
    end

    if IsInInstance then
        local inInstance, instanceType = IsInInstance()
        ctx.inInstance = inInstance and true or false
        if instanceType and instanceType ~= "" then
            ctx.instanceType = instanceType
        end
    else
        ctx.inInstance = false
        ctx.instanceType = "none"
    end

    if GetInstanceInfo then
        local name, infoType, difficultyID, difficultyName, maxPlayers = GetInstanceInfo()
        if name and name ~= "" then ctx.instanceName = name end
        if infoType and infoType ~= "" then ctx.instanceInfoType = infoType end
        if difficultyName and difficultyName ~= "" then ctx.difficultyName = difficultyName end
        if type(maxPlayers) == "number" and maxPlayers > 0 then ctx.maxPlayers = maxPlayers end
        if type(difficultyID) == "number" then ctx.difficultyID = difficultyID end
    end

    return ctx
end

local function FormatAgeSeconds(seconds)
    if not seconds or seconds < 0 then return "?" end
    if seconds < 60 then
        return string.format("%ds", seconds)
    end
    if seconds < 3600 then
        return string.format("%dm", math.floor(seconds / 60))
    end
    if seconds < 86400 then
        return string.format("%dh", math.floor(seconds / 3600))
    end
    return string.format("%dd", math.floor(seconds / 86400))
end

local function FormatMeetWhereFromMet(met)
    if type(met) ~= "table" then return "—" end

    if met.inInstance and met.instanceName and met.instanceName ~= "" then
        return met.instanceName
    end

    local zone = met.zone
    if not zone or zone == "" then
        return "—"
    end

    local sub = met.subzone
    if sub and sub ~= "" and sub ~= zone then
        return zone .. " - " .. sub
    end

    return zone
end

-- Normalize a "met" context snapshot into a coarse bucket for aggregation.
-- This is based on the instance type reported by IsInInstance()/GetInstanceInfo().
local function GetMeetBucketFromMet(met)
    if type(met) ~= "table" then
        return "Unknown"
    end

    local it = met.instanceType or met.instanceInfoType
    local inInst = met.inInstance

    if it == "party" then return "Dungeon" end
    if it == "raid" then return "Raid" end
    if it == "pvp" then return "Battleground" end
    if it == "arena" then return "Arena" end

    if it == "none" then return "World" end
    if inInst == false then return "World" end

    -- If we're in an instance but don't recognize the type, keep it explicit.
    if inInst == true then
        return "Instance"
    end

    return "Unknown"
end

local function FormatClassMeetBreakdown(counts)
    if type(counts) ~= "table" then return "Met: ?" end
    local w = counts.World or 0
    local d = counts.Dungeon or 0
    local r = counts.Raid or 0
    local bg = counts.Battleground or 0
    local a = counts.Arena or 0
    local inst = counts.Instance or 0
    local u = counts.Unknown or 0

    -- Compact, scan-friendly labels.
    local parts = {
        "W " .. w,
        "D " .. d,
        "BG " .. bg,
    }
    if r > 0 then table.insert(parts, "R " .. r) end
    if a > 0 then table.insert(parts, "A " .. a) end
    if inst > 0 then table.insert(parts, "I " .. inst) end
    if u > 0 then table.insert(parts, "? " .. u) end
    return "Met: " .. table.concat(parts, "  ")
end

local lastPrintAt = 0
local function MaybePrint(msg)
    if ClassScannerSettings and ClassScannerSettings.quiet then return end
    local throttle = (ClassScannerSettings and ClassScannerSettings.printThrottleSec) or 0
    local t = Now()
    if throttle > 0 and (t - (lastPrintAt or 0)) < throttle then
        return
    end
    lastPrintAt = t
    print(msg)
end

local function MakePlayerKey(name, realm)
    if not name or name == "" then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, source)
    if not name or not class or not race then return end

    -- Some APIs (notably battleground scoreboards on some clients/servers) return localized class strings.
    -- Normalize to class tokens to keep stats/UI consistent (and avoid duplicate class buckets like "MAGE" + "Mage").
    local canonClass = CanonicalizeClass(class)
    if canonClass then class = canonClass end

    local key = MakePlayerKey(name, realm)
    if not key then return end

    local entry = ClassScannerDB[key]
    if not entry then
        local faction = GetFactionFromRace(race)
        ClassScannerDB[key] = {
            name = name,
            realm = realm or "",
            class = class,
            race = race,
            faction = faction,
            level = (level and level > 0) and level or nil,
            seen = Now(),
            -- "met" is write-once (first time this player is observed).
            met = (function()
                local ctx = GetMeetContext()
                if source and source ~= "" then ctx.source = source end
                return ctx
            end)(),
        }
        entry = ClassScannerDB[key]
        MaybePrint(
            "New player scanned: " .. name ..
            " (" ..
            ((level and level > 0) and ("Lvl " .. level .. " ") or "") ..
            (localizedRace or race) .. " " .. (localizedClass or class) ..
            ")"
        )
        return entry
    end

    -- Refresh last-seen every time we get good info
    entry.seen = Now()

    -- Backfill / correct info if missing
    if not entry.class and class then entry.class = class end
    if not entry.race and race then entry.race = race end
    if not entry.faction and race then entry.faction = GetFactionFromRace(race) end

    -- Update level if we have a better one
    if level and level > 0 then
        if (not entry.level) or (entry.level < level) then
            entry.level = level
        end
    end

    return entry
end

local combatSpecEvidenceByKey = {}
local inspectState = {
    lastRequestAt = 0,
    pendingGuid = nil,
    pendingKey = nil,
}

local function ResolveSpecFromTalents(classToken, isInspect)
    if not IsStandardClassToken(classToken) then
        SpecDebug("ResolveSpecFromTalents: not a standard class token: " .. tostring(classToken))
        return nil
    end
    if not GetNumTalentTabs or not GetTalentTabInfo then
        SpecDebug("ResolveSpecFromTalents: talent API not available")
        return nil
    end

    local numTabs
    if isInspect then
        numTabs = GetNumTalentTabs(true)
    end
    if not numTabs or numTabs < 1 then
        numTabs = GetNumTalentTabs()
    end
    if not numTabs or numTabs < 1 then
        SpecDebug("ResolveSpecFromTalents: numTabs=" .. tostring(numTabs))
        return nil
    end

    local bestName, bestPoints, bestTab = nil, -1, nil
    for tab = 1, numTabs do
        local name, _, points
        if isInspect then
            name, _, points = GetTalentTabInfo(tab, true)
        end
        if not name then
            name, _, points = GetTalentTabInfo(tab)
        end

        local spent = tonumber(points) or 0
        SpecDebug("  Tab " .. tab .. ": " .. tostring(name) .. " = " .. spent .. " pts")
        if spent > bestPoints then
            bestPoints = spent
            bestName = name
            bestTab = tab
        end
    end

    if bestPoints <= 0 then
        SpecDebug("ResolveSpecFromTalents: no points spent")
        return nil
    end
    local result = (bestName and bestName ~= "") and bestName or GetSpecFallbackForTab(classToken, bestTab)
    SpecDebug("ResolveSpecFromTalents: resolved -> " .. tostring(result) .. " (" .. bestPoints .. " pts in tab " .. tostring(bestTab) .. ")")
    return result
end

local function ResolveSpecFromBuffs(unit, classToken)
    if not UnitBuff then return nil end
    local classMap = SPEC_BUFF_BY_CLASS[classToken]
    local classNameMap = SPEC_BUFF_NAMES_BY_CLASS[classToken]
    local casterCheckMap = SPEC_BUFF_CASTERCHECK_BY_CLASS[classToken]
    if not classMap and not classNameMap and not casterCheckMap then return nil end

    SpecDebug("Scanning buffs on " .. tostring(unit) .. " (class " .. classToken .. ")")
    for i = 1, 40 do
        local name, _, _, _, _, _, _, unitCaster, _, _, spellId = UnitBuff(unit, i)
        if not name then break end

        -- Check if caster is the unit itself
        local isSelfCast = unitCaster and UnitIsUnit(unitCaster, unit)

        -- Try by spell ID first (self-only IDs)
        local sid = tonumber(spellId)
        if sid and classMap and classMap[sid] then
            SpecDebug("Buff ID match: " .. name .. " (ID " .. sid .. ") -> " .. classMap[sid])
            return classMap[sid]
        end

        -- Fallback: match by buff name (self-only names)
        if classNameMap and classNameMap[name] then
            SpecDebug("Buff name match: " .. name .. " -> " .. classNameMap[name])
            return classNameMap[name]
        end

        -- Caster-checked buffs: only match if the unit cast it on themselves
        if isSelfCast and casterCheckMap and casterCheckMap[name] then
            SpecDebug("Buff caster-check match: " .. name .. " (caster=" .. tostring(unitCaster) .. ") -> " .. casterCheckMap[name])
            return casterCheckMap[name]
        end
    end

    SpecDebug("No buff match found on " .. tostring(unit))
    return nil
end

local function InferSpecFromCombatSpell(entry, key, classToken, spellId, spellName)
    if not entry or not key or not classToken then return end
    local classMap = SPEC_COMBAT_SPELLS[classToken]
    local classNameMap = SPEC_COMBAT_SPELL_NAMES[classToken]

    -- Try ID match first
    local sid = tonumber(spellId)
    local spec = sid and classMap and classMap[sid]
    -- Fallback: try name match
    if not spec and spellName and classNameMap then
        spec = classNameMap[spellName]
    end
    if not spec then return end

    SpecDebug("Combat spell match: " .. (spellName or "?") .. " (ID " .. tostring(spellId) .. ") -> " .. spec .. " for " .. key)

    local evidence = combatSpecEvidenceByKey[key]
    if not evidence then
        evidence = {}
        combatSpecEvidenceByKey[key] = evidence
    end
    evidence[spec] = (evidence[spec] or 0) + 1

    local bestSpec, bestVotes = nil, 0
    for s, count in pairs(evidence) do
        if count > bestVotes then
            bestSpec = s
            bestVotes = count
        end
    end

    local needed = (ClassScannerSettings and ClassScannerSettings.specEvidenceMinHits) or 1
    if bestSpec and bestVotes >= needed then
        SpecDebug("Spec committed: " .. bestSpec .. " (" .. bestVotes .. " votes) for " .. key)
        SetEntrySpec(entry, bestSpec, "combatlog")
    end
end

local function UpdateSelfSpecFromTalents()
    if not UnitExists("player") then return end
    local name, realm = UnitName("player")
    local localizedClass, class = UnitClass("player")
    local localizedRace, race = UnitRace("player")
    local level = UnitLevel("player")
    if not (name and class and race) then return end

    SpecDebug("UpdateSelfSpec: " .. tostring(name) .. " class=" .. tostring(class))
    local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, "talent")
    if not entry then
        SpecDebug("UpdateSelfSpec: ScanPlayer returned nil")
        return
    end

    local classToken = CanonicalizeClass(class)
    SpecDebug("UpdateSelfSpec: classToken=" .. tostring(classToken))
    local spec = ResolveSpecFromTalents(classToken, false)
    if spec then
        SpecDebug("UpdateSelfSpec: talent detected -> " .. spec)
        SetEntrySpec(entry, spec, "talent")
        return
    end

    -- Talent detection failed (Ascension returns 0 points) — try buff fallback
    SpecDebug("UpdateSelfSpec: talents returned nil, trying buff fallback on player")
    local buffSpec = ResolveSpecFromBuffs("player", classToken)
    if buffSpec then
        SpecDebug("UpdateSelfSpec: buff detected -> " .. buffSpec)
        SetEntrySpec(entry, buffSpec, "buff")
    else
        SpecDebug("UpdateSelfSpec: no spec detected from talents or buffs")
    end
end

local function TryRequestInspect(unit, entry)
    if not unit or not entry then return end
    if not (ClassScannerSettings and ClassScannerSettings.inspectSpecEnabled) then return end
    if not NotifyInspect or not CanInspect then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    if UnitIsUnit(unit, "player") then return end
    if not CanInspect(unit) then return end

    local guid = UnitGUID(unit)
    if not guid or guid == NULL_GUID then return end

    local t = GetTime()
    local throttle = (ClassScannerSettings and ClassScannerSettings.inspectThrottleSec) or 2
    if (t - (inspectState.lastRequestAt or 0)) < throttle then return end

    local key = MakePlayerKey(entry.name, entry.realm)
    if not key then return end

    inspectState.lastRequestAt = t
    inspectState.pendingGuid = guid
    inspectState.pendingKey = key
    NotifyInspect(unit)
end

local function TryUpdateSpecFromUnit(unit, entry)
    if not unit or not entry then return end
    local classToken = CanonicalizeClass(entry.class)
    if not IsStandardClassToken(classToken) then return end

    if UnitIsUnit(unit, "player") then
        local spec = ResolveSpecFromTalents(classToken, false)
        if spec then
            SetEntrySpec(entry, spec, "talent")
            return
        end
        -- Talent detection failed (e.g. Ascension returns 0 points)
        -- Fall through to buff detection
        SpecDebug("Talent detection failed for self, trying buffs")
    end

    local buffSpec = ResolveSpecFromBuffs(unit, classToken)
    if buffSpec then
        SetEntrySpec(entry, buffSpec, "buff")
    end

    if UnitIsUnit(unit, "target") and not UnitIsUnit(unit, "player") then
        TryRequestInspect(unit, entry)
    end
end

local function ScanGUID(guid, source)
    if not guid or not IsGuidString(guid) or guid == NULL_GUID then return end
    local localizedClass, englishClass, localizedRace, englishRace, sex, name, realm = GetPlayerInfoByGUID(guid)
    if name and englishClass and englishRace then
        -- Level is unknown from GUID alone.
        ScanPlayer(name, realm, englishClass, englishRace, localizedClass, localizedRace, nil, source)
    end
end

-- forward declaration (used by event handler)
local RefreshUI

-- Tooltip resolver queue (programmatic tooltip scanning / throttling)
local tip = CreateFrame("GameTooltip", "ClassScannerHiddenTooltip", UIParent, "GameTooltipTemplate")
tip:SetOwner(UIParent, "ANCHOR_NONE")
local tooltipQueue = {}
local tooltipResolving = false

local function ResolveUnitFromTooltip(unit, source)
    if not UnitExists(unit) then return end
    -- Prime tooltip-protected info for some units before using unit APIs
    tip:ClearLines()
    tip:SetUnit(unit)
    tip:Hide()
    -- Use unit APIs where possible; tooltip ensures tooltip-protected info is available for some units
    if UnitIsPlayer(unit) then
        local name, realm = UnitName(unit)
        local localizedClass, class = UnitClass(unit)
        local localizedRace, race = UnitRace(unit)
        local level = UnitLevel(unit)
        if name and class and race then
            local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, source)
            TryUpdateSpecFromUnit(unit, entry)
            return true
        end
    end
    return false
end

local function ProcessTooltipQueue()
    if tooltipResolving or #tooltipQueue == 0 then return end
    tooltipResolving = true
    local item = table.remove(tooltipQueue, 1)
    C_Timer.After(0.12, function()
        ResolveUnitFromTooltip(item.unit, item.source)
        tooltipResolving = false
        if #tooltipQueue > 0 then
            ProcessTooltipQueue()
        end
    end)
end

local function QueueUnitForTooltip(unit, source)
    if not unit then return end
    table.insert(tooltipQueue, { unit = unit, source = source })
    ProcessTooltipQueue()
end

-- Nameplate scanning (use C_NamePlate.GetNamePlates when available)
local function ScanNameplates()
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            local unit = plate.UnitFrame and plate.UnitFrame.unit
            if unit and UnitExists(unit) and UnitIsPlayer(unit) then
                -- Try to read level/class/race directly from the unit when available
                local name, realm = UnitName(unit)
                local localizedClass, class = UnitClass(unit)
                local localizedRace, race = UnitRace(unit)
                local level = UnitLevel(unit)
                if name and class and race then
                    local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, (level and level > 0) and level or nil, "nameplate")
                    TryUpdateSpecFromUnit(unit, entry)
                else
                    local guid = UnitGUID(unit)
                    if guid and guid ~= NULL_GUID then
                        ScanGUID(guid, "nameplate")
                        if not class then QueueUnitForTooltip(unit, "nameplate") end
                    end
                end
            end
        end
    else
        -- Fallback to legacy nameplate unit tokens
        for i = 1, 40 do
            local unit = "nameplate" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local name, realm = UnitName(unit)
                local localizedClass, class = UnitClass(unit)
                local localizedRace, race = UnitRace(unit)
                local level = UnitLevel(unit)
                if name and class and race then
                    local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, (level and level > 0) and level or nil, "nameplate")
                    TryUpdateSpecFromUnit(unit, entry)
                else
                    local guid = UnitGUID(unit)
                    if guid and guid ~= NULL_GUID then
                        ScanGUID(guid, "nameplate")
                        if not class then QueueUnitForTooltip(unit, "nameplate") end
                    end
                end
            end
        end
    end
end

-- Group / raid roster scanning
local function ScanGroup()
    if IsInRaid() then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local guid = UnitGUID(unit)
                if guid and guid ~= NULL_GUID then
                    ScanGUID(guid, "group")
                end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local guid = UnitGUID(unit)
                if guid and guid ~= NULL_GUID then
                    ScanGUID(guid, "group")
                end
            end
        end
        -- also scan player self
        if UnitExists("player") then
            local pguid = UnitGUID("player")
            if pguid and pguid ~= NULL_GUID then ScanGUID(pguid, "group") end
        end
    end
end

-- Battleground / battlefield scan
local function ScanBattleground()
    if GetNumBattlefieldScores and GetNumBattlefieldScores() > 0 then
        for i = 1, GetNumBattlefieldScores() do
            local name, killingBlows, honorableKills, deaths, honorGained, faction, rank, race, classToken = GetBattlefieldScore(i)
            if name then
                -- classToken may be localized on some clients/servers; ScanPlayer will normalize it.
                local playerName, realm = strsplit("-", name)
                ScanPlayer(playerName, realm or "", classToken or "Unknown", race or "Unknown", classToken, race, nil, "scoreboard")
            end
        end
    end
end

-- Periodic scanning ticker (lightweight)
local lastMouseoverScan = {}
local mouseoverSuppressionSec = 0.5 -- seconds to skip repeated mouseover/target scans

-- Combat damage tracking runtime state (not saved)
local playerGUID = nil
local petOwnerByGUID = {}   -- petGUID -> { ownerGUID, ownerName }
local attackerState = {}    -- attackerGUID -> { lastAt, windowEvents, windowSum }

local function FormatDamageNumber(n)
    if not n or n <= 0 then return "0" end
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fK", n / 1000)
    end
    return tostring(math.floor(n))
end

C_Timer.NewTicker(5, function()
    -- Expire stale attacker state to prevent unbounded memory growth
    local timeout = (ClassScannerSettings and ClassScannerSettings.encounterTimeoutSec) or 10
    local gtNow = GetTime()
    local expiredGuids = {}
    for guid, state in pairs(attackerState) do
        if gtNow - state.lastAt > timeout then
            table.insert(expiredGuids, guid)
        end
    end
    for _, guid in ipairs(expiredGuids) do
        attackerState[guid] = nil
    end
    -- Avoid running heavy logic in combat
    if InCombatLockdown() then return end
    ScanNameplates()
    ScanGroup()
    ScanBattleground()
end)

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            if not ClassScannerDB then
                ClassScannerDB = {}
            end
            if not ClassScannerSettings then
                ClassScannerSettings = DefaultSettings()
            else
                -- Backfill new defaults on upgrade
                for k, v in pairs(DefaultSettings()) do
                    if ClassScannerSettings[k] == nil then
                        ClassScannerSettings[k] = v
                    end
                end
            end

            -- Best-effort migration: normalize any legacy/localized class strings already stored in the DB.
            for _, data in pairs(ClassScannerDB) do
                if type(data) == "table" and data.class then
                    local canonClass = CanonicalizeClass(data.class)
                    if canonClass then
                        data.class = canonClass
                    end
                end
                if type(data) == "table" and data.spec then
                    local normalized = NormalizeSpecName(data.spec)
                    if normalized and VALID_SPEC_NAMES[normalized] then
                        data.spec = normalized
                    else
                        -- Wipe invalid/garbage spec entries (e.g. combat-log spell names).
                        data.spec = nil
                        data.specSource = nil
                        data.specConfidence = nil
                        data.specUpdatedAt = nil
                    end
                end
            end

            print("ClassScanner loaded!")
        end
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        UpdateSelfSpecFromTalents()
    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        UpdateSelfSpecFromTalents()
    elseif event == "INSPECT_READY" then
        local guid = ...
        if inspectState.pendingGuid and guid == inspectState.pendingGuid then
            local key = inspectState.pendingKey
            local entry = key and ClassScannerDB and ClassScannerDB[key]
            if entry then
                local classToken = CanonicalizeClass(entry.class)
                local spec = ResolveSpecFromTalents(classToken, true)
                if spec then
                    SetEntrySpec(entry, spec, "inspect")
                end
            end

            inspectState.pendingGuid = nil
            inspectState.pendingKey = nil
            if ClearInspectPlayer then ClearInspectPlayer() end
            RefreshUI()
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Ascension 3.3.5a uses standard WotLK combat log varargs (same as Skada).
        -- Do NOT use CombatLogGetCurrentEventInfo — it may not work correctly on this client.
        local timestamp, subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = ...

        -- Resolve player GUID lazily
        if not playerGUID then
            playerGUID = UnitGUID("player")
        end

        -- Scan GUIDs for player discovery (existing behavior)
        if sourceGUID and IsGuidString(sourceGUID) and sourceGUID ~= NULL_GUID then
            if sourceGUID:match("^Player%-") or sourceGUID:sub(1,2) == "0x" then
                ScanGUID(sourceGUID, "combatlog")
            end
        end
        if destGUID and IsGuidString(destGUID) and destGUID ~= NULL_GUID then
            if destGUID:match("^Player%-") or destGUID:sub(1,2) == "0x" then
                ScanGUID(destGUID, "combatlog")
            end
        end

        -- Low-confidence specialization inference from distinctive combat spells.
        if sourceName and sourceGUID and IsGuidString(sourceGUID) and sourceGUID ~= NULL_GUID then
            local spellId, spellName
            if subevent and (subevent:find("^SPELL_") or subevent:find("^RANGE_")) then
                spellId, spellName = select(9, ...)
                spellId = tonumber(spellId)
            end

            if (spellId and spellId > 0) or (spellName and spellName ~= "") then
                local sourcePlayer, sourceRealm = strsplit("-", sourceName)
                local sourceKey = MakePlayerKey(sourcePlayer, sourceRealm)
                if sourceKey then
                    local sourceEntry = ClassScannerDB[sourceKey]
                    if sourceEntry then
                        local sourceClass = CanonicalizeClass(sourceEntry.class)
                        if IsStandardClassToken(sourceClass) then
                            InferSpecFromCombatSpell(sourceEntry, sourceKey, sourceClass, spellId, spellName)
                        end
                    end
                end
            end
        end

        -- Pet ownership tracking via SPELL_SUMMON
        if subevent == "SPELL_SUMMON" then
            if sourceGUID and destGUID and sourceName then
                petOwnerByGUID[destGUID] = { ownerGUID = sourceGUID, ownerName = sourceName }
            end
        elseif subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
            if destGUID then
                petOwnerByGUID[destGUID] = nil
            end
        end

        -- Damage tracking: only if enabled, dest is us, source is a different entity
        if not (ClassScannerSettings and ClassScannerSettings.trackDamageToPlayer) then return end
        if not playerGUID or destGUID ~= playerGUID then return end
        if not sourceGUID or sourceGUID == NULL_GUID or sourceGUID == playerGUID then return end

        -- Extract payload from the remaining varargs (args 9+)
        -- Standard WotLK: timestamp(1), subevent(2), srcGUID(3), srcName(4), srcFlags(5), dstGUID(6), dstName(7), dstFlags(8), payload(9+)
        local amount, spellId, spellName, spellSchool, critical, kind

        if subevent == "SWING_DAMAGE" then
            -- SWING_DAMAGE payload: amount, overkill, school, resisted, blocked, absorbed, critical, glancing
            amount, _, _, _, _, _, critical = select(9, ...)
            kind = "SWING"
            spellName = "Melee"
        elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" then
            -- SPELL_DAMAGE payload: spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical, glancing
            spellId, spellName, spellSchool, amount, _, _, _, _, _, critical = select(9, ...)
            kind = (subevent == "RANGE_DAMAGE") and "RANGE" or "SPELL"
        elseif subevent == "SPELL_PERIODIC_DAMAGE" then
            if not (ClassScannerSettings and ClassScannerSettings.includePeriodicDamage) then return end
            spellId, spellName, spellSchool, amount, _, _, _, _, _, critical = select(9, ...)
            kind = "PERIODIC"
        elseif subevent == "DAMAGE_SHIELD" then
            if not (ClassScannerSettings and ClassScannerSettings.includeDamageShields) then return end
            spellId, spellName, spellSchool, amount, _, _, _, _, _, critical = select(9, ...)
            kind = "SHIELD"
        else
            return
        end

        if not amount or type(amount) ~= "number" or amount <= 0 then return end

        -- Pet-to-owner attribution
        local logicalGUID = sourceGUID
        local logicalName = sourceName
        local fromPet = false
        local petName = nil
        local petMapping = petOwnerByGUID[sourceGUID]
        if petMapping then
            logicalGUID = petMapping.ownerGUID
            logicalName = petMapping.ownerName
            fromPet = true
            petName = sourceName
        end

        -- Resolve DB key for logical attacker
        local attackerName, attackerRealm
        if logicalName then
            attackerName, attackerRealm = strsplit("-", logicalName)
        end
        local key = MakePlayerKey(attackerName, attackerRealm)
        if not key then return end

        ScanGUID(logicalGUID, "combatlog")
        local entry = ClassScannerDB[key]
        if not entry then
            ClassScannerDB[key] = {
                name = attackerName,
                realm = attackerRealm or "",
                class = "Unknown",
                race = "Unknown",
                faction = "Unknown",
                seen = Now(),
            }
            entry = ClassScannerDB[key]
        end

        -- Initialize combat stats
        if not entry.combat then
            entry.combat = {
                totalDamageToMe = 0,
                totalHitsToMe = 0,
                maxHit = { amount = 0 },
                maxBurstDps = { dps = 0 },
            }
        end

        entry.combat.totalDamageToMe = (entry.combat.totalDamageToMe or 0) + amount
        entry.combat.totalHitsToMe = (entry.combat.totalHitsToMe or 0) + 1

        -- Hardest hit tracking
        if amount > (entry.combat.maxHit.amount or 0) then
            entry.combat.maxHit = {
                amount = amount,
                t = Now(),
                kind = kind,
                spellId = spellId,
                spellName = spellName or "Melee",
                spellSchool = spellSchool,
                critical = critical and true or false,
                fromPet = fromPet,
                petName = petName,
            }
        end

        -- Burst DPS sliding window
        local burstWindow = (ClassScannerSettings and ClassScannerSettings.burstWindowSec) or 3
        local gtNow = GetTime()
        if not attackerState[logicalGUID] then
            attackerState[logicalGUID] = { lastAt = gtNow, windowEvents = {}, windowSum = 0 }
        end
        local state = attackerState[logicalGUID]
        state.lastAt = gtNow

        -- Reset window if encounter timed out
        local timeout = (ClassScannerSettings and ClassScannerSettings.encounterTimeoutSec) or 10
        if #state.windowEvents > 0 and (gtNow - state.windowEvents[#state.windowEvents].t) > timeout then
            state.windowEvents = {}
            state.windowSum = 0
        end

        table.insert(state.windowEvents, { t = gtNow, amount = amount })
        state.windowSum = state.windowSum + amount

        -- Prune events outside the window
        while #state.windowEvents > 0 and (gtNow - state.windowEvents[1].t) > burstWindow do
            state.windowSum = state.windowSum - state.windowEvents[1].amount
            table.remove(state.windowEvents, 1)
        end

        -- Update peak burst DPS
        local burstDps = state.windowSum / burstWindow
        if burstDps > (entry.combat.maxBurstDps.dps or 0) then
            entry.combat.maxBurstDps = {
                dps = burstDps,
                windowSec = burstWindow,
                damage = state.windowSum,
                t = Now(),
                fromPet = fromPet,
                petName = petName,
            }
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        local source = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        if UnitIsPlayer(unit) then
            -- Suppress repeated scans for the same GUID within a short window
            local guid = UnitGUID(unit)
            local keyid = guid
            if not keyid then
                -- fallback to name-realm composite when GUID missing
                local n, r = UnitName(unit)
                keyid = n and (n .. "-" .. (r or "")) or nil
            end

            if keyid then
                local last = lastMouseoverScan[keyid]
                if last and (Now() - last) < mouseoverSuppressionSec then
                    return
                end
                lastMouseoverScan[keyid] = Now()
            end

            local name, realm = UnitName(unit)
            local localizedClass, class = UnitClass(unit)
            local localizedRace, race = UnitRace(unit)
            local level = UnitLevel(unit)

            if name and class and race then
                -- good data available via Unit APIs
                local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, source)
                TryUpdateSpecFromUnit(unit, entry)
            else
                -- Missing class/race/level — route through tooltip queue (respects existing tooltip throttle)
                QueueUnitForTooltip(unit, source)
            end
        end
    end
end)

-- UI and Slash Command
local uiFrame
local filterFaction = "All"
local filterRace = "All"
local filterClass = "All"
local filterSpec = "All"
local filterLevel = "All"
local filterLocation = "All"
local filterLevelMin = nil  -- Custom min level (nil = no minimum)
local filterLevelMax = nil  -- Custom max level (nil = no maximum)
local currentPage = 1
local itemsPerPage = 100
local searchQuery = "" -- free-text search query
local searchDebounceTimer = nil -- timer for live search debounce
local sortMode = "most_seen" -- sort mode: most_seen, most_damage, hardest_hit, max_burst

local SPEC_FILTER_ITEMS = {
    "Arms", "Fury", "Protection",
    "Holy", "Retribution",
    "Beast Mastery", "Marksmanship", "Survival",
    "Assassination", "Combat", "Subtlety",
    "Discipline", "Shadow",
    "Blood", "Frost", "Unholy",
    "Elemental", "Enhancement", "Restoration", "Elemental/Enhancement",
    "Arcane", "Fire",
    "Affliction", "Demonology", "Destruction",
    "Balance", "Feral",
    "Unknown",
}

-- Class icon coordinates in the class icon texture atlas
-- WoW's CLASS_ICON texture (256x256, 4x4 grid):
-- SetTexCoord format: (left, right, top, bottom)
local CLASS_ICON_TCOORDS = {
    ["WARRIOR"]     = {0.000, 0.250, 0.000, 0.250},
    ["MAGE"]        = {0.250, 0.500, 0.000, 0.250},
    ["ROGUE"]       = {0.500, 0.750, 0.000, 0.250},
    ["DRUID"]       = {0.750, 1.000, 0.000, 0.250},
    ["HUNTER"]      = {0.000, 0.250, 0.250, 0.500},
    ["SHAMAN"]      = {0.250, 0.500, 0.250, 0.500},
    ["PRIEST"]      = {0.500, 0.750, 0.250, 0.500},
    ["WARLOCK"]     = {0.750, 1.000, 0.250, 0.500},
    ["PALADIN"]     = {0.000, 0.250, 0.500, 0.750},
    ["DEATHKNIGHT"] = {0.250, 0.500, 0.500, 0.750},
}

-- Use the standard class icon atlas texture
local CLASS_ICON_TEXTURE = "Interface\\WorldStateFrame\\Icons-Classes"

-- Faction icons
local FACTION_ICONS = {
    ["Alliance"] = "Interface\\PVPFrame\\PVP-Currency-Alliance",
    ["Horde"] = "Interface\\PVPFrame\\PVP-Currency-Horde",
}

-- Color utilities
local function CreateColor(r, g, b, a)
    return {r = r, g = g, b = b, a = a or 1}
end

local COLORS = {
    background = CreateColor(0.05, 0.05, 0.08, 0.95),
    headerBg = CreateColor(0.08, 0.08, 0.12, 1),
    statCardBg = CreateColor(0.12, 0.12, 0.18, 1),
    statCardBorder = CreateColor(0.3, 0.3, 0.4, 0.8),
    rowEven = CreateColor(0.1, 0.1, 0.14, 0.6),
    rowOdd = CreateColor(0.08, 0.08, 0.1, 0.4),
    rowHover = CreateColor(0.2, 0.2, 0.3, 0.8),
    accent = CreateColor(0.4, 0.6, 1, 1),
    textPrimary = CreateColor(1, 1, 1, 1),
    textSecondary = CreateColor(0.7, 0.7, 0.7, 1),
    textMuted = CreateColor(0.5, 0.5, 0.5, 1),
    gold = CreateColor(1, 0.84, 0, 1),
    green = CreateColor(0.2, 0.8, 0.2, 1),
}

local SPEC_COLORS = {
    ["Arms"] = CreateColor(0.78, 0.61, 0.43),
    ["Fury"] = CreateColor(0.9, 0.3, 0.3),
    ["Protection"] = CreateColor(0.55, 0.7, 0.92),

    ["Holy"] = CreateColor(1, 0.96, 0.65),
    ["Retribution"] = CreateColor(1, 0.55, 0.2),

    ["Beast Mastery"] = CreateColor(0.67, 0.83, 0.45),
    ["Marksmanship"] = CreateColor(0.39, 0.82, 0.55),
    ["Survival"] = CreateColor(0.29, 0.69, 0.42),

    ["Assassination"] = CreateColor(1, 0.22, 0.53),
    ["Combat"] = CreateColor(1, 0.86, 0.2),
    ["Subtlety"] = CreateColor(0.72, 0.46, 0.93),

    ["Discipline"] = CreateColor(0.75, 0.92, 1),
    ["Shadow"] = CreateColor(0.68, 0.5, 0.95),

    ["Blood"] = CreateColor(0.9, 0.16, 0.16),
    ["Frost"] = CreateColor(0.44, 0.82, 1),
    ["Unholy"] = CreateColor(0.38, 0.86, 0.4),

    ["Elemental"] = CreateColor(0.2, 0.64, 1),
    ["Enhancement"] = CreateColor(0.91, 0.69, 0.24),
    ["Restoration"] = CreateColor(0.18, 0.9, 0.51),

    ["Arcane"] = CreateColor(0.65, 0.52, 1),
    ["Fire"] = CreateColor(1, 0.38, 0.2),

    ["Affliction"] = CreateColor(0.6, 0.41, 0.9),
    ["Demonology"] = CreateColor(0.74, 0.31, 0.92),
    ["Destruction"] = CreateColor(1, 0.27, 0.47),

    ["Balance"] = CreateColor(1, 0.56, 0.73),
    ["Feral"] = CreateColor(1, 0.49, 0.04),
}

local function GetSpecColor(specName)
    local color = SPEC_COLORS[specName]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

local function UpdateList()
    if not uiFrame then return end

    -- 1. Filter and collect valid entries
    local validEntries = {}
    local classCounts = {}
    local classMeetCounts = {}
    local raceCounts = {}
    local specCounts = {}
    local classLevelSums = {}
    local classLevelCounts = {}
    local knownLevelCount = 0
    local levelSum = 0
    local minLevel = nil
    local maxLevel = nil
    local totalCount = 0

    for key, data in pairs(ClassScannerDB) do
        if type(data) == "table" then
            -- Keep class buckets consistent even if some entries were stored with localized class strings.
            local entryClass = CanonicalizeClass(data.class) or data.class
            if entryClass and entryClass ~= data.class then
                data.class = entryClass
            end

            local show = true

            if filterFaction ~= "All" and data.faction ~= filterFaction then show = false end
            if filterRace ~= "All" and CanonicalizeRace(data.race) ~= filterRace then show = false end
            if filterClass ~= "All" and data.class ~= filterClass then show = false end
            if filterSpec ~= "All" and ((data.spec or "Unknown") ~= filterSpec) then show = false end

            if filterLevel ~= "All" then
                local lvl = data.level
                if not lvl then
                    show = false
                else
                    if filterLevel == "80" and lvl ~= 80 then show = false end
                    if filterLevel == "70-79" and (lvl < 70 or lvl > 79) then show = false end
                    if filterLevel == "60-69" and (lvl < 60 or lvl > 69) then show = false end
                    if filterLevel == "1-59" and (lvl < 1 or lvl > 59) then show = false end
                    if filterLevel == "Custom" then
                        if filterLevelMin and lvl < filterLevelMin then show = false end
                        if filterLevelMax and lvl > filterLevelMax then show = false end
                    end
                end
            end

            if filterLocation ~= "All" then
                local bucket = GetMeetBucketFromMet(data.met)
                if bucket ~= filterLocation then show = false end
            end

            -- Free-text search (case-insensitive substring match against name, realm, class, race, met location, or key)
            if show and searchQuery and searchQuery ~= "" then
                local sq = searchQuery:lower()
                local name = (data.name or ""):lower()
                local realm = (data.realm or ""):lower()
                local class = (data.class or ""):lower()
                local spec = (data.spec or ""):lower()
                local specSource = (data.specSource or ""):lower()
                local race = (data.race or ""):lower()
                local metStr = ""
                if type(data.met) == "table" then
                    metStr = ((data.met.instanceName or "") .. " " .. (data.met.zone or "") .. " " .. (data.met.subzone or "")):lower()
                end
                local k = (key or ""):lower()
                if not (name:find(sq, 1, true) or realm:find(sq, 1, true) or class:find(sq, 1, true) or spec:find(sq, 1, true) or specSource:find(sq, 1, true) or race:find(sq, 1, true) or metStr:find(sq, 1, true) or k:find(sq, 1, true)) then
                    show = false
                end
            end

            if show then
                table.insert(validEntries, {key = key, data = data})
                local c = data.class or "Unknown"
                classCounts[c] = (classCounts[c] or 0) + 1

                -- Meet-context aggregation (based on first-met snapshot when available)
                local bucket = GetMeetBucketFromMet(data.met)
                if not classMeetCounts[c] then classMeetCounts[c] = {} end
                classMeetCounts[c][bucket] = (classMeetCounts[c][bucket] or 0) + 1

                local r = CanonicalizeRace(data.race) or "Unknown"
                raceCounts[r] = (raceCounts[r] or 0) + 1

                local spec = NormalizeSpecName(data.spec)
                if spec and spec ~= "Unknown" then
                    specCounts[spec] = (specCounts[spec] or 0) + 1
                end

                local lvl = data.level
                if lvl and lvl > 0 then
                    knownLevelCount = knownLevelCount + 1
                    levelSum = levelSum + lvl
                    if (not minLevel) or (lvl < minLevel) then minLevel = lvl end
                    if (not maxLevel) or (lvl > maxLevel) then maxLevel = lvl end

                    classLevelSums[c] = (classLevelSums[c] or 0) + lvl
                    classLevelCounts[c] = (classLevelCounts[c] or 0) + 1
                end
                totalCount = totalCount + 1
            end
        end
    end

    -- 2. Determine most detected class
    local mostDetectedClass = "None"
    local maxCount = 0
    for cls, count in pairs(classCounts) do
        if count > maxCount then
            maxCount = count
            mostDetectedClass = cls
        end
    end

    -- 2b. Determine most played race
    local mostPlayedRace = "None"
    local maxRaceCount = 0
    for race, count in pairs(raceCounts) do
        if count > maxRaceCount then
            maxRaceCount = count
            mostPlayedRace = race
        end
    end

    -- 2c. Determine top BG class and build breakdown
    local topBGClass = "None"
    local maxBGCount = 0
    local bgBreakdown = {}
    for cls, counts in pairs(classMeetCounts) do
        local bgCount = counts.Battleground or 0
        if bgCount > 0 then
            table.insert(bgBreakdown, {cls = cls, count = bgCount})
        end
        if bgCount > maxBGCount then
            maxBGCount = bgCount
            topBGClass = cls
        end
    end
    table.sort(bgBreakdown, function(a, b) return a.count > b.count end)

    -- 2f. Determine top spec and build breakdown
    local topSpec = "None"
    local maxSpecCount = 0
    local specBreakdown = {}
    for spec, count in pairs(specCounts) do
        table.insert(specBreakdown, {spec = spec, count = count})
        if count > maxSpecCount then
            maxSpecCount = count
            topSpec = spec
        end
    end
    table.sort(specBreakdown, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.spec < b.spec
    end)

    -- 2d. Level stats
    local avgLevel = nil
    if knownLevelCount > 0 then
        avgLevel = levelSum / knownLevelCount
    end

    -- 2e. Class counts sorted
    local classCountList = {}
    for cls, count in pairs(classCounts) do
        table.insert(classCountList, { cls = cls, count = count })
    end
    table.sort(classCountList, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        if a.cls == "Unknown" and b.cls ~= "Unknown" then return false end
        if b.cls == "Unknown" and a.cls ~= "Unknown" then return true end
        return (a.cls or "") < (b.cls or "")
    end)

    -- 3. Sort entries
    if sortMode == "most_damage" then
        table.sort(validEntries, function(a, b)
            local da = a.data.combat and a.data.combat.totalDamageToMe or 0
            local db = b.data.combat and b.data.combat.totalDamageToMe or 0
            if da ~= db then return da > db end
            return (a.data.name or a.key) < (b.data.name or b.key)
        end)
    elseif sortMode == "hardest_hit" then
        table.sort(validEntries, function(a, b)
            local da = a.data.combat and a.data.combat.maxHit and a.data.combat.maxHit.amount or 0
            local db = b.data.combat and b.data.combat.maxHit and b.data.combat.maxHit.amount or 0
            if da ~= db then return da > db end
            return (a.data.name or a.key) < (b.data.name or b.key)
        end)
    elseif sortMode == "max_burst" then
        table.sort(validEntries, function(a, b)
            local da = a.data.combat and a.data.combat.maxBurstDps and a.data.combat.maxBurstDps.dps or 0
            local db = b.data.combat and b.data.combat.maxBurstDps and b.data.combat.maxBurstDps.dps or 0
            if da ~= db then return da > db end
            return (a.data.name or a.key) < (b.data.name or b.key)
        end)
    else
        table.sort(validEntries, function(a, b)
            local da, db = a.data, b.data
            local ca, cb = (da.class or "Unknown"), (db.class or "Unknown")
            local countA = classCounts[ca] or 0
            local countB = classCounts[cb] or 0

            if countA ~= countB then
                return countA > countB
            end

            if ca ~= cb then
                return ca < cb
            end

            local sa, sb = (da.seen or 0), (db.seen or 0)
            if sa ~= sb then
                return sa > sb
            end

            local na, nb = (da.name or a.key), (db.name or b.key)
            return na < nb
        end)
    end

    -- Pagination
    local totalPages = math.ceil(#validEntries / itemsPerPage)
    if totalPages < 1 then totalPages = 1 end
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1 then currentPage = 1 end

    local startIndex = (currentPage - 1) * itemsPerPage + 1
    local endIndex = math.min(startIndex + itemsPerPage - 1, #validEntries)

    -- Update pagination controls
    if uiFrame.prevBtn then
        if currentPage <= 1 then uiFrame.prevBtn:Disable() else uiFrame.prevBtn:Enable() end
        if currentPage >= totalPages then uiFrame.nextBtn:Disable() else uiFrame.nextBtn:Enable() end
        uiFrame.pageText:SetText("Page " .. currentPage .. " / " .. totalPages)
    end

    -- Update stat cards
    if uiFrame.statCards then
        -- Total players card
        uiFrame.statCards.total.value:SetText(totalCount)

        -- Most detected class card
        local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[mostDetectedClass]
        if classColor then
            uiFrame.statCards.mostClass.value:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            uiFrame.statCards.mostClass.value:SetTextColor(1, 1, 1)
        end
        uiFrame.statCards.mostClass.value:SetText(mostDetectedClass)
        uiFrame.statCards.mostClass.subtext:SetText("(" .. maxCount .. " players)")

        -- Most played race card
        uiFrame.statCards.mostRace.value:SetText(mostPlayedRace)
        uiFrame.statCards.mostRace.subtext:SetText("(" .. maxRaceCount .. " players)")

        -- Top BG Class card
        local bgClassColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[topBGClass]
        if bgClassColor then
            uiFrame.statCards.topBGClass.value:SetTextColor(bgClassColor.r, bgClassColor.g, bgClassColor.b)
        else
            uiFrame.statCards.topBGClass.value:SetTextColor(1, 1, 1)
        end
        uiFrame.statCards.topBGClass.value:SetText(topBGClass)
        uiFrame.statCards.topBGClass.subtext:SetText("(" .. maxBGCount .. " in BG)")
        uiFrame.statCards.topBGClass.bgBreakdown = bgBreakdown

        -- Top spec card
        if uiFrame.statCards.topSpec then
            local specR, specG, specB = GetSpecColor(topSpec)
            uiFrame.statCards.topSpec.value:SetTextColor(specR, specG, specB)
            uiFrame.statCards.topSpec.value:SetText(topSpec)
            uiFrame.statCards.topSpec.subtext:SetText("(" .. maxSpecCount .. " players)")
            uiFrame.statCards.topSpec.specBreakdown = specBreakdown
        end

        -- Level spread card
        if avgLevel then
            uiFrame.statCards.levelSpread.value:SetText(string.format("%.1f", avgLevel))
            uiFrame.statCards.levelSpread.subtext:SetText((minLevel or "?") .. "-" .. (maxLevel or "?") .. " range")
        else
            uiFrame.statCards.levelSpread.value:SetText("?")
            uiFrame.statCards.levelSpread.subtext:SetText("No level data")
        end
    end

    -- Update class distribution bar
    if uiFrame.classBar and totalCount > 0 then
        local barWidth = uiFrame.classBar:GetWidth()
        local xOffset = 0

        -- Hide all segments first
        for _, seg in ipairs(uiFrame.classBar.segments) do
            seg:Hide()
        end

        -- Show and size segments based on class distribution
        for i, item in ipairs(classCountList) do
            local seg = uiFrame.classBar.segments[i]
            if seg and item.count > 0 then
                local pct = item.count / totalCount
                local segWidth = math.max(barWidth * pct, 2)
                seg:SetPoint("LEFT", uiFrame.classBar, "LEFT", xOffset, 0)
                seg:SetWidth(segWidth)
                seg:SetHeight(uiFrame.classBar:GetHeight())

                local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[item.cls]
                if classColor then
                    seg.texture:SetColorTexture(classColor.r, classColor.g, classColor.b, 1)
                else
                    seg.texture:SetColorTexture(0.5, 0.5, 0.5, 1)
                end

                seg.classInfo = {cls = item.cls, count = item.count, pct = pct * 100}
                seg:Show()
                xOffset = xOffset + segWidth
            end
        end

        -- Update class legend (show all classes)
        if uiFrame.classLegend then
            local legendText = ""
            for i, item in ipairs(classCountList) do
                local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[item.cls]
                local colorStr = classColor and ("|c" .. classColor.colorStr) or "|cffffffff"
                local pct = math.floor((item.count / totalCount) * 100 + 0.5)
                legendText = legendText .. colorStr .. item.cls .. "|r " .. pct .. "%"
                if i < #classCountList then
                    legendText = legendText .. "  "
                end
            end
            uiFrame.classLegend:SetText(legendText)
        end
    elseif uiFrame.classBar then
        -- Clear class distribution UI when no entries match
        for _, seg in ipairs(uiFrame.classBar.segments) do
            seg:Hide()
        end
        if uiFrame.classLegend then
            uiFrame.classLegend:SetText("")
        end
    end

    -- Update player rows
    if uiFrame.playerRows then
        -- Hide all rows first
        for _, row in ipairs(uiFrame.playerRows) do
            row:Hide()
        end

        if totalCount == 0 then
            uiFrame.emptyText:Show()
            uiFrame.emptyText:SetText("No players found matching filters.")
        else
            uiFrame.emptyText:Hide()

            local rowIndex = 0
            local lastClass = nil

            for i = startIndex, endIndex do
                local entry = validEntries[i]
                local data = entry.data
                local key = entry.key
                local currentClass = data.class or "Unknown"

                -- Class header row (only in default sort mode)
                if sortMode == "most_seen" and currentClass ~= lastClass then
                    rowIndex = rowIndex + 1
                    local row = uiFrame.playerRows[rowIndex]
                    if row then
                        row.isHeader = true
                        row.bg:SetColorTexture(COLORS.headerBg.r, COLORS.headerBg.g, COLORS.headerBg.b, COLORS.headerBg.a)

                        -- Class icon in header
                        local coords = CLASS_ICON_TCOORDS[currentClass]
                        if coords then
                            row.classIcon:SetTexture(CLASS_ICON_TEXTURE)
                            row.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                            row.classIcon:Show()
                        else
                            row.classIcon:Hide()
                        end

                        row.factionIcon:Hide()

                        local count = classCounts[currentClass] or 0
                        local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[currentClass]
                        if classColor then
                            row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
                        else
                            row.nameText:SetTextColor(1, 0.84, 0)
                        end
                        row.nameText:SetText(currentClass .. " (" .. count .. ")")

                        local clsKnown = classLevelCounts[currentClass] or 0
                        if clsKnown > 0 then
                            local clsAvg = (classLevelSums[currentClass] or 0) / clsKnown
                            row.infoText:SetText("Avg Level: " .. string.format("%.1f", clsAvg))
                        else
                            row.infoText:SetText("")
                        end
                        row.infoText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

                        if row.metText then
                            row.metText:SetText(FormatClassMeetBreakdown(classMeetCounts[currentClass]))
                            row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                        end

                        row.levelText:SetText("")
                        row.ageText:SetText("")
                        row.playerData = nil
                        row.headerClass = currentClass
                        row.headerMeetCounts = classMeetCounts[currentClass]
                        row:Show()
                    end
                    lastClass = currentClass
                end

                -- Player row
                rowIndex = rowIndex + 1
                local row = uiFrame.playerRows[rowIndex]
                if row then
                    row.isHeader = false

                    -- Alternating row colors
                    if rowIndex % 2 == 0 then
                        row.bg:SetColorTexture(COLORS.rowEven.r, COLORS.rowEven.g, COLORS.rowEven.b, COLORS.rowEven.a)
                    else
                        row.bg:SetColorTexture(COLORS.rowOdd.r, COLORS.rowOdd.g, COLORS.rowOdd.b, COLORS.rowOdd.a)
                    end

                    -- Class icon
                    local coords = CLASS_ICON_TCOORDS[data.class]
                    if coords then
                        row.classIcon:SetTexture(CLASS_ICON_TEXTURE)
                        row.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                        row.classIcon:Show()
                    else
                        row.classIcon:Hide()
                    end

                    -- Faction icon
                    local factionIcon = FACTION_ICONS[data.faction]
                    if factionIcon then
                        row.factionIcon:SetTexture(factionIcon)
                        row.factionIcon:Show()
                    else
                        row.factionIcon:Hide()
                    end

                    -- Level
                    if data.level and data.level > 0 then
                        row.levelText:SetText(data.level)
                        row.levelText:SetTextColor(COLORS.gold.r, COLORS.gold.g, COLORS.gold.b)
                    else
                        row.levelText:SetText("??")
                        row.levelText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                    end

                    -- Name
                    local displayName = data.name or key
                    if data.realm and data.realm ~= "" then
                        displayName = displayName .. "-" .. data.realm
                    end
                    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.class]
                    if classColor then
                        row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
                    else
                        row.nameText:SetTextColor(1, 1, 1)
                    end
                    row.nameText:SetText(displayName)

                    -- Race info
                    local raceText = CanonicalizeRace(data.race) or "Unknown"
                    local specText = data.spec or "Unknown"
                    row.infoText:SetText(raceText .. " - " .. specText)
                    row.infoText:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)

                    -- Met/Damage column
                    if row.metText then
                        if sortMode == "most_damage" then
                            local combat = data.combat
                            if combat and combat.totalDamageToMe and combat.totalDamageToMe > 0 then
                                row.metText:SetText("Dmg: " .. FormatDamageNumber(combat.totalDamageToMe))
                                row.metText:SetTextColor(1, 0.3, 0.3)
                            else
                                row.metText:SetText("No damage")
                                row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                            end
                        elseif sortMode == "hardest_hit" then
                            local combat = data.combat
                            if combat and combat.maxHit and combat.maxHit.amount and combat.maxHit.amount > 0 then
                                local mh = combat.maxHit
                                local txt = FormatDamageNumber(mh.amount)
                                if mh.spellName then txt = txt .. " (" .. mh.spellName .. ")" end
                                if mh.critical then txt = txt .. " crit" end
                                row.metText:SetText(txt)
                                row.metText:SetTextColor(1, 0.3, 0.3)
                            else
                                row.metText:SetText("No hits")
                                row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                            end
                        elseif sortMode == "max_burst" then
                            local combat = data.combat
                            if combat and combat.maxBurstDps and combat.maxBurstDps.dps and combat.maxBurstDps.dps > 0 then
                                row.metText:SetText(FormatDamageNumber(combat.maxBurstDps.dps) .. " DPS")
                                row.metText:SetTextColor(1, 0.3, 0.3)
                            else
                                row.metText:SetText("No burst")
                                row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                            end
                        else
                            row.metText:SetText(FormatMeetWhereFromMet(data.met))
                            row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                        end
                    end

                    -- Age
                    local age = data.seen and (Now() - data.seen) or nil
                    row.ageText:SetText(FormatAgeSeconds(age))
                    row.ageText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

                    row.playerData = data
                    row:Show()
                end
            end
        end
    end

    -- Update scroll content height
    if uiFrame.content then
        local visibleRows = 0
        for _, row in ipairs(uiFrame.playerRows) do
            if row:IsShown() then
                visibleRows = visibleRows + 1
            end
        end
        uiFrame.content:SetHeight(math.max(visibleRows * 24, 100))
    end
end

RefreshUI = function()
    if uiFrame and uiFrame:IsShown() then
        UpdateList()
    end
end

local function CreateDropdown(name, parent, items, onSelect, defaultText)
    local dropdown = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")

    local function OnClick(self)
        UIDropDownMenu_SetSelectedID(dropdown, self:GetID())
        onSelect(self.value)
    end

    local function Initialize(self, level)
        local info = UIDropDownMenu_CreateInfo()
        info.func = OnClick

        info.text = "All"
        info.value = "All"
        info.checked = (defaultText == "All")
        UIDropDownMenu_AddButton(info, level)

        for _, item in ipairs(items) do
            info.text = item
            info.value = item
            info.checked = (item == defaultText)
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(dropdown, Initialize)
    UIDropDownMenu_SetWidth(dropdown, 80)
    UIDropDownMenu_SetButtonWidth(dropdown, 124)
    UIDropDownMenu_JustifyText(dropdown, "LEFT")
    UIDropDownMenu_SetSelectedValue(dropdown, "All")
    UIDropDownMenu_SetText(dropdown, defaultText or "All")

    return dropdown
end

local function ClassScanner_ShowUI()
    if not uiFrame then
        -- Main frame with modern dark backdrop
        uiFrame = CreateFrame("Frame", "ClassScannerFrame", UIParent, "BackdropTemplate")
        uiFrame:SetWidth(720)
        uiFrame:SetHeight(680)
        uiFrame:SetPoint("CENTER")
        uiFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        uiFrame:SetBackdropColor(COLORS.background.r, COLORS.background.g, COLORS.background.b, COLORS.background.a)
        uiFrame:SetBackdropBorderColor(0.3, 0.3, 0.4, 0.8)
        uiFrame:EnableMouse(true)
        uiFrame:SetMovable(true)
        uiFrame:RegisterForDrag("LeftButton")
        uiFrame:SetScript("OnDragStart", uiFrame.StartMoving)
        uiFrame:SetScript("OnDragStop", uiFrame.StopMovingOrSizing)
        uiFrame:SetFrameStrata("HIGH")

        -- Header bar
        local header = CreateFrame("Frame", nil, uiFrame, "BackdropTemplate")
        header:SetHeight(40)
        header:SetPoint("TOPLEFT", 0, 0)
        header:SetPoint("TOPRIGHT", 0, 0)
        header:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = nil,
        })
        header:SetBackdropColor(COLORS.headerBg.r, COLORS.headerBg.g, COLORS.headerBg.b, 1)

        -- Title
        local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("LEFT", 15, 0)
        title:SetText("ClassScanner")
        title:SetTextColor(COLORS.accent.r, COLORS.accent.g, COLORS.accent.b)

        -- Close Button (custom styled)
        local closeBtn = CreateFrame("Button", nil, header)
        closeBtn:SetSize(30, 30)
        closeBtn:SetPoint("TOPRIGHT", -5, -5)
        closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
        closeBtn:SetScript("OnClick", function() uiFrame:Hide() end)

        -- Stats cards container
        local statsContainer = CreateFrame("Frame", nil, uiFrame)
        statsContainer:SetHeight(70)
        statsContainer:SetPoint("TOPLEFT", 10, -50)
        statsContainer:SetPoint("TOPRIGHT", -10, -50)

        uiFrame.statCards = {}

        -- Helper function to create stat cards
        local function CreateStatCard(parent, xOffset, label)
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetSize(110, 60)
            card:SetPoint("LEFT", parent, "LEFT", xOffset, 0)
            card:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                tile = false, edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            card:SetBackdropColor(COLORS.statCardBg.r, COLORS.statCardBg.g, COLORS.statCardBg.b, COLORS.statCardBg.a)
            card:SetBackdropBorderColor(COLORS.statCardBorder.r, COLORS.statCardBorder.g, COLORS.statCardBorder.b, COLORS.statCardBorder.a)

            local labelText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labelText:SetPoint("TOP", 0, -8)
            labelText:SetText(label)
            labelText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

            local valueText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            valueText:SetPoint("CENTER", 0, -2)
            valueText:SetText("0")
            valueText:SetTextColor(COLORS.textPrimary.r, COLORS.textPrimary.g, COLORS.textPrimary.b)

            local subText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            subText:SetPoint("BOTTOM", 0, 6)
            subText:SetText("")
            subText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

            card.label = labelText
            card.value = valueText
            card.subtext = subText
            return card
        end

        uiFrame.statCards.total = CreateStatCard(statsContainer, 0, "Total Players")
        uiFrame.statCards.total.value:SetTextColor(COLORS.green.r, COLORS.green.g, COLORS.green.b)

        uiFrame.statCards.mostClass = CreateStatCard(statsContainer, 115, "Most Detected")

        uiFrame.statCards.mostRace = CreateStatCard(statsContainer, 230, "Top Race")

        uiFrame.statCards.topBGClass = CreateStatCard(statsContainer, 345, "Top BG Class")
        uiFrame.statCards.topBGClass:EnableMouse(true)
        uiFrame.statCards.topBGClass:SetScript("OnEnter", function(self)
            if self.bgBreakdown and #self.bgBreakdown > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine("Battleground Breakdown", 1, 1, 1)
                for _, item in ipairs(self.bgBreakdown) do
                    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[item.cls]
                    local r, g, b = 1, 1, 1
                    if classColor then r, g, b = classColor.r, classColor.g, classColor.b end
                    GameTooltip:AddDoubleLine(item.cls, tostring(item.count), r, g, b, 1, 1, 1)
                end
                GameTooltip:Show()
            end
        end)
        uiFrame.statCards.topBGClass:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        uiFrame.statCards.topSpec = CreateStatCard(statsContainer, 460, "Top Spec")
        uiFrame.statCards.topSpec:EnableMouse(true)
        uiFrame.statCards.topSpec:SetScript("OnEnter", function(self)
            if self.specBreakdown and #self.specBreakdown > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine("Spec Breakdown", 1, 1, 1)
                for _, item in ipairs(self.specBreakdown) do
                    local r, g, b = GetSpecColor(item.spec)
                    GameTooltip:AddDoubleLine(item.spec, tostring(item.count), r, g, b, r, g, b)
                end
                GameTooltip:Show()
            end
        end)
        uiFrame.statCards.topSpec:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        uiFrame.statCards.levelSpread = CreateStatCard(statsContainer, 575, "Avg Level")
        uiFrame.statCards.levelSpread.value:SetTextColor(COLORS.gold.r, COLORS.gold.g, COLORS.gold.b)

        -- Class distribution bar
        local classBarLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classBarLabel:SetPoint("TOPLEFT", 15, -130)
        classBarLabel:SetText("Class Distribution")
        classBarLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)

        local classBar = CreateFrame("Frame", nil, uiFrame, "BackdropTemplate")
        classBar:SetHeight(16)
        classBar:SetPoint("TOPLEFT", 15, -148)
        classBar:SetPoint("TOPRIGHT", -15, -148)
        classBar:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = nil,
        })
        classBar:SetBackdropColor(0.15, 0.15, 0.2, 1)
        uiFrame.classBar = classBar

        -- Create segments for the bar (max 12 classes)
        classBar.segments = {}
        for i = 1, 12 do
            local seg = CreateFrame("Frame", nil, classBar)
            seg:SetHeight(16)
            seg.texture = seg:CreateTexture(nil, "ARTWORK")
            seg.texture:SetAllPoints()
            seg:EnableMouse(true)
            seg:SetScript("OnEnter", function(self)
                if self.classInfo then
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine(self.classInfo.cls, 1, 1, 1)
                    GameTooltip:AddLine(string.format("%d players (%.1f%%)", self.classInfo.count, self.classInfo.pct), 0.7, 0.7, 0.7)
                    GameTooltip:Show()
                end
            end)
            seg:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            seg:Hide()
            classBar.segments[i] = seg
        end

        -- Class legend
        local classLegend = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLegend:SetPoint("TOPLEFT", 15, -170)
        -- Explicit width and wrapping so long legend lines don't get cut off
        classLegend:SetWidth(uiFrame:GetWidth() - 30)
        classLegend:SetWordWrap(true)
        classLegend:SetJustifyH("LEFT")
        classLegend:SetText("")
        uiFrame.classLegend = classLegend

        -- Filter section (top "Filters" header removed; individual labels are placed above each control)

        -- Filter dropdowns (two rows for better layout)
        local factionDropdown = CreateDropdown("ClassScannerFactionDropdown", uiFrame, {"Alliance", "Horde"}, function(val)
            filterFaction = val
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        factionDropdown:SetPoint("TOPLEFT", -5, -205)
        UIDropDownMenu_SetWidth(factionDropdown, 90)
        local factionLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        factionLabel:SetPoint("BOTTOM", factionDropdown, "TOP", 0, 2)
        factionLabel:SetText("Faction")
        factionLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        factionLabel:SetJustifyH("CENTER")
        factionLabel:SetWidth((factionDropdown:GetWidth() and factionDropdown:GetWidth()) or 90)

        local raceDropdown = CreateDropdown(
            "ClassScannerRaceDropdown",
            uiFrame,
            {"Human", "Dwarf", "Night Elf", "Gnome", "Draenei", "Orc", "Undead", "Tauren", "Troll", "Blood Elf"},
            function(val)
                filterRace = val
                UIDropDownMenu_SetText(ClassScannerRaceDropdown, val)
                currentPage = 1
                UpdateList()
            end,
            "All"
        )
        raceDropdown:SetPoint("LEFT", factionDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(raceDropdown, 90)
        local raceLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        raceLabel:SetPoint("BOTTOM", raceDropdown, "TOP", 0, 2)
        raceLabel:SetText("Race")
        raceLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        raceLabel:SetJustifyH("CENTER")
        raceLabel:SetWidth((raceDropdown:GetWidth() and raceDropdown:GetWidth()) or 90)

        local classDropdown = CreateDropdown("ClassScannerClassDropdown", uiFrame, {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}, function(val)
            filterClass = val
            UIDropDownMenu_SetText(ClassScannerClassDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        classDropdown:SetPoint("LEFT", raceDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(classDropdown, 100)
        local classLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLabel:SetPoint("BOTTOM", classDropdown, "TOP", 0, 2)
        classLabel:SetText("Class")
        classLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        classLabel:SetJustifyH("CENTER")
        classLabel:SetWidth((classDropdown:GetWidth() and classDropdown:GetWidth()) or 100)

        local specDropdown = CreateDropdown("ClassScannerSpecDropdown", uiFrame, SPEC_FILTER_ITEMS, function(val)
            filterSpec = val
            UIDropDownMenu_SetText(ClassScannerSpecDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        specDropdown:SetPoint("LEFT", classDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(specDropdown, 100)
        local specLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        specLabel:SetPoint("BOTTOM", specDropdown, "TOP", 0, 2)
        specLabel:SetText("Spec")
        specLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        specLabel:SetJustifyH("CENTER")
        specLabel:SetWidth((specDropdown:GetWidth() and specDropdown:GetWidth()) or 100)

        local levelDropdown = CreateDropdown("ClassScannerLevelDropdown", uiFrame, {"80", "70-79", "60-69", "1-59", "Custom"}, function(val)
            filterLevel = val
            UIDropDownMenu_SetText(ClassScannerLevelDropdown, val)
            currentPage = 1
            if uiFrame.levelMinBox and uiFrame.levelMaxBox then
                if val == "Custom" then
                    uiFrame.levelMinBox:Show()
                    uiFrame.levelMaxBox:Show()
                    uiFrame.levelRangeLabel:Show()
                    uiFrame.levelDash:Show()
                    searchQuery = ""
                    if uiFrame.searchBox then uiFrame.searchBox:SetText("") end
                    if uiFrame.searchLabel then uiFrame.searchLabel:Hide() end
                    if uiFrame.searchBox then uiFrame.searchBox:Hide() end
                else
                    uiFrame.levelMinBox:Hide()
                    uiFrame.levelMaxBox:Hide()
                    uiFrame.levelRangeLabel:Hide()
                    uiFrame.levelDash:Hide()
                    if uiFrame.searchLabel then uiFrame.searchLabel:Show() end
                    if uiFrame.searchBox then uiFrame.searchBox:Show() end
                end
            end
            UpdateList()
        end, "All")
        levelDropdown:SetPoint("TOPLEFT", -5, -260)
        UIDropDownMenu_SetWidth(levelDropdown, 90)
        local levelLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelLabel:SetPoint("BOTTOM", levelDropdown, "TOP", 0, 2)
        levelLabel:SetText("Level")
        levelLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        levelLabel:SetJustifyH("CENTER")
        levelLabel:SetWidth((levelDropdown:GetWidth() and levelDropdown:GetWidth()) or 90)

        local locationDropdown = CreateDropdown("ClassScannerLocationDropdown", uiFrame, {"World", "Dungeon", "Raid", "Battleground", "Arena", "Instance", "Unknown"}, function(val)
            filterLocation = val
            UIDropDownMenu_SetText(ClassScannerLocationDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        locationDropdown:SetPoint("LEFT", levelDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(locationDropdown, 90)
        local locationLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        locationLabel:SetPoint("BOTTOM", locationDropdown, "TOP", 0, 2)
        locationLabel:SetText("Location")
        locationLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        locationLabel:SetJustifyH("CENTER")
        locationLabel:SetWidth((locationDropdown:GetWidth() and locationDropdown:GetWidth()) or 90)

        -- Reset button
        local resetBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        resetBtn:SetSize(70, 22)
        resetBtn:SetPoint("LEFT", locationDropdown, "RIGHT", 0, 2)
        resetBtn:SetText("Reset")
        resetBtn:SetScript("OnClick", function()
            filterFaction = "All"
            filterRace = "All"
            filterClass = "All"
            filterSpec = "All"
            filterLevel = "All"
            filterLocation = "All"
            filterLevelMin = nil
            filterLevelMax = nil
            searchQuery = ""
            currentPage = 1
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerRaceDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerClassDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerSpecDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerLevelDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerLocationDropdown, "All")
            if uiFrame.levelMinBox then
                uiFrame.levelMinBox:SetText("")
                uiFrame.levelMinBox:Hide()
            end
            if uiFrame.levelMaxBox then
                uiFrame.levelMaxBox:SetText("")
                uiFrame.levelMaxBox:Hide()
            end
            if uiFrame.levelRangeLabel then uiFrame.levelRangeLabel:Hide() end
            if uiFrame.levelDash then uiFrame.levelDash:Hide() end
            if uiFrame.searchLabel then uiFrame.searchLabel:Show() end
            if uiFrame.searchBox then uiFrame.searchBox:Show() end
            if uiFrame.searchBox then uiFrame.searchBox:SetText("") end
            sortMode = "most_seen"
            if uiFrame.sortDropdown then
                UIDropDownMenu_SetText(uiFrame.sortDropdown, "Most Seen")
            end
            UpdateList()
        end)

        -- Custom Level Range
        local levelRangeLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelRangeLabel:SetPoint("TOPLEFT", 20, -295)
        levelRangeLabel:SetText("Level Range:")
        levelRangeLabel:Hide()
        uiFrame.levelRangeLabel = levelRangeLabel

        -- Sort dropdown
        local sortDropdown = CreateFrame("Frame", "ClassScannerSortDropdown", uiFrame, "UIDropDownMenuTemplate")
        local sortItems = {"Most Seen", "Most Damage", "Hardest Hit", "Max Burst DPS"}
        local sortModeMap = {
            ["Most Seen"] = "most_seen",
            ["Most Damage"] = "most_damage",
            ["Hardest Hit"] = "hardest_hit",
            ["Max Burst DPS"] = "max_burst",
        }
        local function SortOnClick(self)
            UIDropDownMenu_SetSelectedID(sortDropdown, self:GetID())
            sortMode = sortModeMap[self.value] or "most_seen"
            UIDropDownMenu_SetText(sortDropdown, self.value)
            currentPage = 1
            UpdateList()
        end
        UIDropDownMenu_Initialize(sortDropdown, function(self, level)
            local info = UIDropDownMenu_CreateInfo()
            info.func = SortOnClick
            for _, item in ipairs(sortItems) do
                info.text = item
                info.value = item
                info.checked = (item == "Most Seen")
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetWidth(sortDropdown, 100)
        UIDropDownMenu_SetButtonWidth(sortDropdown, 140)
        UIDropDownMenu_JustifyText(sortDropdown, "LEFT")
        UIDropDownMenu_SetText(sortDropdown, "Most Seen")
        sortDropdown:SetPoint("LEFT", resetBtn, "RIGHT", 5, -2)
        local sortLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sortLabel:SetPoint("BOTTOM", sortDropdown, "TOP", 0, 2)
        sortLabel:SetText("Sort")
        sortLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        sortLabel:SetJustifyH("CENTER")
        uiFrame.sortDropdown = sortDropdown

        local levelMinBox = CreateFrame("EditBox", "ClassScannerLevelMinBox", uiFrame, "InputBoxTemplate")
        levelMinBox:SetSize(40, 20)
        levelMinBox:SetPoint("LEFT", levelRangeLabel, "RIGHT", 8, 0)
        levelMinBox:SetAutoFocus(false)
        levelMinBox:SetNumeric(true)
        levelMinBox:SetMaxLetters(3)
        levelMinBox:Hide()
        levelMinBox:SetScript("OnEnterPressed", function(self)
            filterLevelMin = tonumber(self:GetText())
            self:ClearFocus()
            currentPage = 1
            UpdateList()
        end)
        levelMinBox:SetScript("OnTabPressed", function(self)
            filterLevelMin = tonumber(self:GetText())
            self:ClearFocus()
            uiFrame.levelMaxBox:SetFocus()
        end)
        uiFrame.levelMinBox = levelMinBox

        local levelDash = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelDash:SetPoint("LEFT", levelMinBox, "RIGHT", 3, 0)
        levelDash:SetText("-")
        levelDash:Hide()
        uiFrame.levelDash = levelDash

        local levelMaxBox = CreateFrame("EditBox", "ClassScannerLevelMaxBox", uiFrame, "InputBoxTemplate")
        levelMaxBox:SetSize(40, 20)
        levelMaxBox:SetPoint("LEFT", levelDash, "RIGHT", 3, 0)
        levelMaxBox:SetAutoFocus(false)
        levelMaxBox:SetNumeric(true)
        levelMaxBox:SetMaxLetters(3)
        levelMaxBox:Hide()
        levelMaxBox:SetScript("OnEnterPressed", function(self)
            filterLevelMax = tonumber(self:GetText())
            self:ClearFocus()
            currentPage = 1
            UpdateList()
        end)
        levelMaxBox:SetScript("OnTabPressed", function(self)
            filterLevelMax = tonumber(self:GetText())
            self:ClearFocus()
        end)
        uiFrame.levelMaxBox = levelMaxBox

        -- Search box (free-text)
        local searchLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        searchLabel:SetPoint("TOPLEFT", 20, -295)
        searchLabel:SetText("Search:")
        searchLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        uiFrame.searchLabel = searchLabel

        local searchBox = CreateFrame("EditBox", "ClassScannerSearchBox", uiFrame, "InputBoxTemplate")
        searchBox:SetSize(220, 22)
        searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
        searchBox:SetAutoFocus(false)
        searchBox:SetScript("OnEnterPressed", function(self)
            local txt = self:GetText() or ""
            searchQuery = txt:match("^%s*(.-)%s*$")
            self:ClearFocus()
            currentPage = 1
            UpdateList()
        end)
        searchBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        -- Live search: debounce OnTextChanged to avoid running UpdateList every frame
        searchBox:SetScript("OnTextChanged", function(self)
            local txt = self:GetText() or ""
            local q = txt:match("^%s*(.-)%s*$")
            searchQuery = q
            currentPage = 1
            -- Cancel previous timer
            if searchDebounceTimer then
                searchDebounceTimer:Cancel()
                searchDebounceTimer = nil
            end
            -- Schedule UpdateList after 0.25s of inactivity
            searchDebounceTimer = C_Timer.NewTimer(0.25, function()
                UpdateList()
                searchDebounceTimer = nil
            end)
        end)
        uiFrame.searchBox = searchBox

        -- ScrollFrame for player list
        local scrollFrame = CreateFrame("ScrollFrame", "ClassScannerScrollFrame", uiFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 10, -320)
        scrollFrame:SetPoint("BOTTOMRIGHT", -30, 50)

        -- Content frame
        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetWidth(scrollFrame:GetWidth() - 20)
        content:SetHeight(1)
        scrollFrame:SetScrollChild(content)
        uiFrame.content = content

        -- Create player row pool
        uiFrame.playerRows = {}
        local ROW_HEIGHT = 24
        local MAX_ROWS = 150

        local function CreatePlayerRow(index)
            local row = CreateFrame("Frame", nil, content)
            row:SetHeight(ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
            row:SetPoint("TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))

            -- Background
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(0, 0, 0, 0)

            -- Class icon
            row.classIcon = row:CreateTexture(nil, "ARTWORK")
            row.classIcon:SetSize(18, 18)
            row.classIcon:SetPoint("LEFT", 5, 0)

            -- Faction icon
            row.factionIcon = row:CreateTexture(nil, "ARTWORK")
            row.factionIcon:SetSize(14, 14)
            row.factionIcon:SetPoint("LEFT", row.classIcon, "RIGHT", 4, 0)

            -- Level text
            row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.levelText:SetWidth(30)
            row.levelText:SetPoint("LEFT", row.factionIcon, "RIGHT", 4, 0)
            row.levelText:SetJustifyH("CENTER")

            -- Name text
            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameText:SetWidth(180)
            row.nameText:SetPoint("LEFT", row.levelText, "RIGHT", 8, 0)
            row.nameText:SetJustifyH("LEFT")

            -- Info text (race)
            row.infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.infoText:SetWidth(140)
            row.infoText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
            row.infoText:SetJustifyH("LEFT")

            -- Met text (where first met)
            row.metText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.metText:SetPoint("LEFT", row.infoText, "RIGHT", 10, 0)
            row.metText:SetJustifyH("LEFT")

            -- Age text
            row.ageText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.ageText:SetWidth(50)
            row.ageText:SetPoint("RIGHT", -10, 0)
            row.ageText:SetJustifyH("RIGHT")

            -- Constrain Met text to the space between race and age
            row.metText:ClearAllPoints()
            row.metText:SetPoint("LEFT", row.infoText, "RIGHT", 10, 0)
            row.metText:SetPoint("RIGHT", row.ageText, "LEFT", -10, 0)
            row.metText:SetJustifyH("LEFT")

            -- Hover effect
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if self.isHeader and self.headerClass then
                    self.bg:SetColorTexture(COLORS.rowHover.r, COLORS.rowHover.g, COLORS.rowHover.b, COLORS.rowHover.a)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(self.headerClass .. " — First Met Breakdown", 1, 1, 1)
                    GameTooltip:AddLine(" ")

                    local c = self.headerMeetCounts or {}
                    local function Add(label, value)
                        GameTooltip:AddDoubleLine(label, tostring(value or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                    end

                    Add("World", c.World)
                    Add("Dungeon", c.Dungeon)
                    Add("Battleground", c.Battleground)
                    Add("Raid", c.Raid)
                    Add("Arena", c.Arena)
                    if (c.Instance or 0) > 0 then Add("Other Instance", c.Instance) end
                    if (c.Unknown or 0) > 0 then Add("Unknown", c.Unknown) end

                    GameTooltip:Show()
                    return
                end

                if not self.isHeader and self.playerData then
                    self.bg:SetColorTexture(COLORS.rowHover.r, COLORS.rowHover.g, COLORS.rowHover.b, COLORS.rowHover.a)
                    -- Tooltip
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local data = self.playerData
                    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.class]
                    if classColor then
                        GameTooltip:AddLine(data.name or "Unknown", classColor.r, classColor.g, classColor.b)
                    else
                        GameTooltip:AddLine(data.name or "Unknown", 1, 1, 1)
                    end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddDoubleLine("Level:", data.level and tostring(data.level) or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Race:", CanonicalizeRace(data.race) or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Class:", data.class or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Spec:", data.spec or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    if data.specSource then
                        local confidence = data.specConfidence and (", " .. data.specConfidence) or ""
                        GameTooltip:AddDoubleLine("Spec Source:", tostring(data.specSource) .. confidence, 0.7, 0.7, 0.7, 1, 1, 1)
                    end
                    GameTooltip:AddDoubleLine("Faction:", data.faction or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    if data.realm and data.realm ~= "" then
                        GameTooltip:AddDoubleLine("Realm:", data.realm, 0.7, 0.7, 0.7, 1, 1, 1)
                    end
                    if data.seen then
                        local age = Now() - data.seen
                        GameTooltip:AddDoubleLine("Last Seen:", FormatAgeSeconds(age) .. " ago", 0.7, 0.7, 0.7, 1, 1, 1)
                    end

                    if data.met and type(data.met) == "table" then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddDoubleLine("First Met At:", FormatMeetWhereFromMet(data.met), 0.7, 0.7, 0.7, 1, 1, 1)
                        if data.met.t then
                            local mage = Now() - data.met.t
                            GameTooltip:AddDoubleLine("First Met:", FormatAgeSeconds(mage) .. " ago", 0.7, 0.7, 0.7, 1, 1, 1)
                        end

                        local it = data.met.instanceType or data.met.instanceInfoType
                        if it and it ~= "" then
                            local label = (data.met.inInstance and "Instance Type" or "Context")
                            GameTooltip:AddDoubleLine(label .. ":", tostring(it), 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                        if data.met.source then
                            GameTooltip:AddDoubleLine("Met Via:", tostring(data.met.source), 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                    end

                    -- Combat stats
                    if data.combat then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Combat Stats", 1, 0.3, 0.3)
                        if data.combat.totalDamageToMe and data.combat.totalDamageToMe > 0 then
                            GameTooltip:AddDoubleLine("Total Damage:", FormatDamageNumber(data.combat.totalDamageToMe) .. " (" .. (data.combat.totalHitsToMe or 0) .. " hits)", 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                        if data.combat.maxHit and data.combat.maxHit.amount and data.combat.maxHit.amount > 0 then
                            local mh = data.combat.maxHit
                            local hitStr = FormatDamageNumber(mh.amount) .. " - " .. (mh.spellName or "Melee")
                            if mh.critical then hitStr = hitStr .. " (crit)" end
                            if mh.fromPet and mh.petName then hitStr = hitStr .. " [pet: " .. mh.petName .. "]" end
                            GameTooltip:AddDoubleLine("Hardest Hit:", hitStr, 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                        if data.combat.maxBurstDps and data.combat.maxBurstDps.dps and data.combat.maxBurstDps.dps > 0 then
                            local mb = data.combat.maxBurstDps
                            local dpsStr = FormatDamageNumber(mb.dps) .. " DPS (" .. FormatDamageNumber(mb.damage) .. " in " .. (mb.windowSec or 3) .. "s)"
                            GameTooltip:AddDoubleLine("Max Burst:", dpsStr, 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                    end

                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function(self)
                if not self.isHeader then
                    local idx = 0
                    for i, r in ipairs(uiFrame.playerRows) do
                        if r == self then idx = i break end
                    end
                    if idx % 2 == 0 then
                        self.bg:SetColorTexture(COLORS.rowEven.r, COLORS.rowEven.g, COLORS.rowEven.b, COLORS.rowEven.a)
                    else
                        self.bg:SetColorTexture(COLORS.rowOdd.r, COLORS.rowOdd.g, COLORS.rowOdd.b, COLORS.rowOdd.a)
                    end
                else
                    self.bg:SetColorTexture(COLORS.headerBg.r, COLORS.headerBg.g, COLORS.headerBg.b, COLORS.headerBg.a)
                end
                GameTooltip:Hide()
            end)

            row:Hide()
            return row
        end

        for i = 1, MAX_ROWS do
            uiFrame.playerRows[i] = CreatePlayerRow(i)
        end

        -- Empty text
        local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyText:SetPoint("CENTER", 0, 0)
        emptyText:SetText("No players found.")
        emptyText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
        emptyText:Hide()
        uiFrame.emptyText = emptyText

        -- Pagination Controls
        local paginationBar = CreateFrame("Frame", nil, uiFrame)
        paginationBar:SetHeight(30)
        paginationBar:SetPoint("BOTTOMLEFT", 10, 10)
        paginationBar:SetPoint("BOTTOMRIGHT", -10, 10)

        local prevBtn = CreateFrame("Button", nil, paginationBar, "UIPanelButtonTemplate")
        prevBtn:SetSize(80, 24)
        prevBtn:SetPoint("LEFT", 5, 0)
        prevBtn:SetText("Previous")
        prevBtn:SetScript("OnClick", function()
            if currentPage > 1 then
                currentPage = currentPage - 1
                UpdateList()
            end
        end)
        uiFrame.prevBtn = prevBtn

        local nextBtn = CreateFrame("Button", nil, paginationBar, "UIPanelButtonTemplate")
        nextBtn:SetSize(80, 24)
        nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 10, 0)
        nextBtn:SetText("Next")
        nextBtn:SetScript("OnClick", function()
            currentPage = currentPage + 1
            UpdateList()
        end)
        uiFrame.nextBtn = nextBtn

        local pageText = paginationBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        pageText:SetPoint("LEFT", nextBtn, "RIGHT", 15, 0)
        pageText:SetText("Page 1 / 1")
        uiFrame.pageText = pageText

        -- Player count in pagination area
        local playerCountText = paginationBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        playerCountText:SetPoint("RIGHT", -10, 0)
        playerCountText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
        uiFrame.playerCountText = playerCountText
    end

    UpdateList()
    uiFrame:Show()
end

SLASH_CLASSSCANNER1 = "/cs"
SLASH_CLASSSCANNER2 = "/classscanner"

SlashCmdList["CLASSSCANNER"] = function(msg)
    if not ClassScannerSettings then
        ClassScannerSettings = DefaultSettings()
    end

    msg = (msg or "")
    msg = msg:match("^%s*(.-)%s*$")
    local cmd, arg = msg:match("^(%S+)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""

    local function PrintHelp()
        print("ClassScanner commands:")
        print("  /cs                - show UI")
        print("  /cs clear          - clear database")
        print("  /cs quiet          - toggle new-scan chat prints")
        print("  /cs throttle <sec> - set print throttle (e.g. 0, 0.5, 2)")
        print("  /cs refresh        - refresh UI if open")
        print("  /cs search <term>  - search DB (also sets UI search box if UI open)")
        print("  /cs topdmg [n]     - top N players by damage to you (default 10)")
        print("  /cs topclassdmg [n]- top N classes by damage to you (default 10)")
        print("  /cs dmg on|off     - toggle damage tracking")
        print("  /cs burst <sec>    - set burst DPS window (e.g. 3, 5)")
        print("  /cs dmgclear       - clear combat data (keeps scan data)")
        print("  /cs cleanspecs     - remove invalid spec entries from DB")
        print("  /cs specdebug      - toggle spec detection debug output")
        print("  /cs spectest       - dump your own talent info for diagnosis")
        print("  /cs help           - show this help")
    end

    if cmd == "" then
        ClassScanner_ShowUI()
        return
    end

    if cmd == "help" or cmd == "?" then
        PrintHelp()
        return
    end

    if cmd == "clear" then
        ClassScannerDB = {}
        print("ClassScanner database cleared.")
        if uiFrame and uiFrame:IsShown() then
            ClassScanner_ShowUI() -- Refresh UI if open
        end
        return
    end

    if cmd == "quiet" then
        ClassScannerSettings.quiet = not ClassScannerSettings.quiet
        print("ClassScanner quiet mode: " .. (ClassScannerSettings.quiet and "ON" or "OFF"))
        return
    end

    if cmd == "throttle" then
        local n = tonumber(arg)
        if not n or n < 0 then
            print("Usage: /cs throttle <seconds>")
            return
        end
        ClassScannerSettings.printThrottleSec = n
        print("ClassScanner print throttle: " .. n .. " sec")
        return
    end

    if cmd == "refresh" then
        RefreshUI()
        return
    end

    if cmd == "search" then
        local q = (arg or ""):match("^%s*(.-)%s*$")
        if q == "" then
            print("Usage: /cs search <term>")
            return
        end
        -- If UI is open, set the search box and refresh UI
        searchQuery = q
        if uiFrame and uiFrame:IsShown() and uiFrame.searchBox then
            uiFrame.searchBox:SetText(q)
            currentPage = 1
            UpdateList()
            return
        end

        -- Otherwise perform a quick console search and print matches
        local sq = q:lower()
        local matches = {}
        for key, data in pairs(ClassScannerDB) do
            if type(data) == "table" then
                local name = (data.name or ""):lower()
                local realm = (data.realm or ""):lower()
                local class = (data.class or ""):lower()
                local spec = (data.spec or ""):lower()
                local specSource = (data.specSource or ""):lower()
                local race = (data.race or ""):lower()
                local metStr = ""
                if type(data.met) == "table" then
                    metStr = ((data.met.instanceName or "") .. " " .. (data.met.zone or "") .. " " .. (data.met.subzone or "")):lower()
                end
                local k = (key or ""):lower()
                if name:find(sq, 1, true) or realm:find(sq, 1, true) or class:find(sq, 1, true) or spec:find(sq, 1, true) or specSource:find(sq, 1, true) or race:find(sq, 1, true) or metStr:find(sq, 1, true) or k:find(sq, 1, true) then
                    table.insert(matches, {key = key, data = data})
                end
            end
        end
        if #matches == 0 then
            print("No matches for '" .. q .. "'.")
            return
        end
        table.sort(matches, function(a, b)
            local na, nb = (a.data.name or a.key), (b.data.name or b.key)
            return na < nb
        end)
        print("Search results for '" .. q .. "' (showing up to 50):")
        for i = 1, math.min(50, #matches) do
            local e = matches[i]
            local d = e.data
            local disp = d.name or e.key
            if d.realm and d.realm ~= "" then disp = disp .. "-" .. d.realm end
            local lvl = (d.level and tostring(d.level)) or "?"
            local spec = d.spec and (" / " .. d.spec) or ""
            print(i .. ". " .. disp .. " — " .. (d.class or "Unknown") .. spec .. " L" .. lvl)
        end
        if #matches > 50 then print("...and " .. (#matches - 50) .. " more") end
        return
    end

    if cmd == "topdmg" then
        local n = tonumber(arg) or 10
        if n < 1 then n = 1 end
        local ranked = {}
        for key, data in pairs(ClassScannerDB) do
            if type(data) == "table" and data.combat and data.combat.totalDamageToMe and data.combat.totalDamageToMe > 0 then
                table.insert(ranked, { key = key, data = data })
            end
        end
        table.sort(ranked, function(a, b)
            return (a.data.combat.totalDamageToMe or 0) > (b.data.combat.totalDamageToMe or 0)
        end)
        if #ranked == 0 then
            print("No damage data recorded yet.")
            return
        end
        print("Top " .. math.min(n, #ranked) .. " players by damage to you:")
        for i = 1, math.min(n, #ranked) do
            local e = ranked[i]
            local d = e.data
            local disp = d.name or e.key
            if d.realm and d.realm ~= "" then disp = disp .. "-" .. d.realm end
            local cls = d.class or "Unknown"
            local dmg = FormatDamageNumber(d.combat.totalDamageToMe)
            local hitStr = ""
            if d.combat.maxHit and d.combat.maxHit.amount and d.combat.maxHit.amount > 0 then
                hitStr = " | Max Hit: " .. FormatDamageNumber(d.combat.maxHit.amount) .. " (" .. (d.combat.maxHit.spellName or "Melee") .. ")"
            end
            local burstStr = ""
            if d.combat.maxBurstDps and d.combat.maxBurstDps.dps and d.combat.maxBurstDps.dps > 0 then
                burstStr = " | Burst: " .. FormatDamageNumber(d.combat.maxBurstDps.dps) .. " DPS"
            end
            print(i .. ". " .. disp .. " [" .. cls .. "] — Dmg: " .. dmg .. hitStr .. burstStr)
        end
        return
    end

    if cmd == "topclassdmg" then
        local n = tonumber(arg) or 10
        if n < 1 then n = 1 end
        local classTotals = {}
        for _, data in pairs(ClassScannerDB) do
            if type(data) == "table" and data.combat and data.combat.totalDamageToMe and data.combat.totalDamageToMe > 0 then
                local cls = data.class or "Unknown"
                classTotals[cls] = (classTotals[cls] or 0) + data.combat.totalDamageToMe
            end
        end
        local ranked = {}
        for cls, total in pairs(classTotals) do
            table.insert(ranked, { cls = cls, total = total })
        end
        table.sort(ranked, function(a, b) return a.total > b.total end)
        if #ranked == 0 then
            print("No damage data recorded yet.")
            return
        end
        print("Top " .. math.min(n, #ranked) .. " classes by damage to you:")
        for i = 1, math.min(n, #ranked) do
            local item = ranked[i]
            print(i .. ". " .. item.cls .. " — " .. FormatDamageNumber(item.total))
        end
        return
    end

    if cmd == "dmg" then
        local toggle = (arg or ""):lower()
        if toggle == "on" then
            ClassScannerSettings.trackDamageToPlayer = true
            print("ClassScanner damage tracking: ON")
        elseif toggle == "off" then
            ClassScannerSettings.trackDamageToPlayer = false
            print("ClassScanner damage tracking: OFF")
        else
            print("Usage: /cs dmg on|off (currently " .. (ClassScannerSettings.trackDamageToPlayer and "ON" or "OFF") .. ")")
        end
        return
    end

    if cmd == "burst" then
        local n = tonumber(arg)
        if not n or n < 1 or n > 30 then
            print("Usage: /cs burst <1-30> (currently " .. (ClassScannerSettings.burstWindowSec or 3) .. "s)")
            return
        end
        ClassScannerSettings.burstWindowSec = n
        print("ClassScanner burst DPS window: " .. n .. "s")
        return
    end

    if cmd == "dmgclear" then
        local count = 0
        for _, data in pairs(ClassScannerDB) do
            if type(data) == "table" and data.combat then
                data.combat = nil
                count = count + 1
            end
        end
        -- Also reset runtime state
        attackerState = {}
        petOwnerByGUID = {}
        print("ClassScanner: cleared combat data from " .. count .. " players.")
        RefreshUI()
        return
    end

    if cmd == "cleanspecs" then
        local count = 0
        for _, data in pairs(ClassScannerDB) do
            if type(data) == "table" and data.spec and not VALID_SPEC_NAMES[data.spec] then
                data.spec = nil
                data.specSource = nil
                data.specConfidence = nil
                data.specUpdatedAt = nil
                count = count + 1
            end
        end
        print("ClassScanner: removed " .. count .. " invalid spec entr" .. (count == 1 and "y" or "ies") .. " from database.")
        RefreshUI()
        return
    end

    if cmd == "specdebug" then
        specDebugEnabled = not specDebugEnabled
        print("ClassScanner spec debug: " .. (specDebugEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        if specDebugEnabled then
            print("  Debug messages will appear as |cFF00FF00[CS-SpecDebug]|r in chat.")
            print("  Mouse over players, target them, or enter combat to see detection info.")
            -- Run self-detection immediately so the user sees output
            UpdateSelfSpecFromTalents()
        end
        return
    end

    if cmd == "spectest" then
        print("|cFF00FF00[CS-SpecTest]|r Talent info dump:")
        local localizedClass, class = UnitClass("player")
        local classToken = CanonicalizeClass(class)
        print("  Class: " .. tostring(class) .. " -> token: " .. tostring(classToken))
        print("  IsStandardClassToken: " .. tostring(IsStandardClassToken(classToken)))

        if GetNumTalentTabs then
            local numTabs = GetNumTalentTabs()
            print("  GetNumTalentTabs(): " .. tostring(numTabs))
            if numTabs and numTabs > 0 then
                for tab = 1, numTabs do
                    if GetTalentTabInfo then
                        local name, iconTexture, points, fileName = GetTalentTabInfo(tab)
                        print("    Tab " .. tab .. ": name=" .. tostring(name)
                            .. " points=" .. tostring(points)
                            .. " fileName=" .. tostring(fileName))
                    end
                end
            end
        else
            print("  GetNumTalentTabs: NOT AVAILABLE")
        end

        -- Show current player entry spec
        local name = UnitName("player")
        if name then
            local key = MakePlayerKey(name, select(2, UnitName("player")))
            local entry = key and ClassScannerDB and ClassScannerDB[key]
            if entry then
                print("  DB entry spec: " .. tostring(entry.spec)
                    .. " (source=" .. tostring(entry.specSource)
                    .. ", confidence=" .. tostring(entry.specConfidence) .. ")")
            else
                print("  DB entry: not found (key=" .. tostring(key) .. ")")
            end
        end

        -- Also dump target info if we have a target
        if UnitExists("target") and UnitIsPlayer("target") then
            print("|cFF00FF00[CS-SpecTest]|r Target buff scan:")
            local tName = UnitName("target")
            local _, tClass = UnitClass("target")
            local tToken = CanonicalizeClass(tClass)
            print("  Target: " .. tostring(tName) .. " class=" .. tostring(tToken))
            if UnitBuff then
                for i = 1, 40 do
                    local bName, _, _, _, _, _, _, _, _, _, bSpellId = UnitBuff("target", i)
                    if not bName then break end
                    print("    Buff " .. i .. ": " .. bName .. " (ID " .. tostring(bSpellId) .. ")")
                end
            end
        end
        return
    end

    print("ClassScanner: unknown command '" .. cmd .. "'.")
    PrintHelp()
end
