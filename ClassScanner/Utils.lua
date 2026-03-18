local addonName, CS = ...

local RACES = CS.RACES
local SPEC_COLORS = CS.SPEC_COLORS
local STANDARD_CLASS_SPECS = CS.STANDARD_CLASS_SPECS

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

    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        return class
    end

    local upper = class:upper()
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[upper] then
        return upper
    end

    local map = BuildLocalizedClassToToken()
    if map[class] then return map[class] end
    if map[upper] then return map[upper] end

    return nil
end

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

local function DefaultSettings()
    return {
        quiet = false, -- disable "New player scanned" chat prints
        printThrottleSec = 1.5, -- minimum seconds between prints
        trackDamageToPlayer = true, -- track damage dealt to you by other players
        burstWindowSec = 3, -- sliding window (seconds) for peak burst DPS
        encounterTimeoutSec = 10, -- idle timeout to expire per-attacker burst state
        includePeriodicDamage = true, -- include DoTs in damage tracking
        includeDamageShields = true, -- include damage shields (thorns, etc.)
        inspectSpecEnabled = true, -- inspect target talents for high-confidence spec detection
        inspectThrottleSec = 2.0, -- seconds between inspect requests
        specEvidenceMinHits = 1, -- combat-log votes required before setting low-confidence spec
        combatSpecEvidenceWindowSec = 60, -- seconds of inactivity before combat-log spec votes reset
        combatSpecExpireSec = 180, -- seconds before a combat-log (low confidence) spec expires
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
    local now = Now()
    if throttle > 0 and (now - (lastPrintAt or 0)) < throttle then
        return
    end
    lastPrintAt = now
    print(msg)
end

local function MakePlayerKey(name, realm)
    if not name or name == "" then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function GetSpecColor(specName)
    local color = SPEC_COLORS[specName]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

CS.IsGuidString = IsGuidString
CS.GetFactionFromRace = GetFactionFromRace
CS.CanonicalizeRace = CanonicalizeRace
CS.CanonicalizeClass = CanonicalizeClass
CS.IsStandardClassToken = IsStandardClassToken
CS.NormalizeSpecName = NormalizeSpecName
CS.GetSpecFallbackForTab = GetSpecFallbackForTab
CS.DefaultSettings = DefaultSettings
CS.Now = Now
CS.GetMeetContext = GetMeetContext
CS.FormatAgeSeconds = FormatAgeSeconds
CS.FormatMeetWhereFromMet = FormatMeetWhereFromMet
CS.GetMeetBucketFromMet = GetMeetBucketFromMet
CS.FormatClassMeetBreakdown = FormatClassMeetBreakdown
CS.MaybePrint = MaybePrint
CS.MakePlayerKey = MakePlayerKey
CS.GetSpecColor = GetSpecColor
