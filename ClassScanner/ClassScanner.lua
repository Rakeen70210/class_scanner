local addonName, addonTable = ...

-- Initialize the database
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")



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

-- Settings (stored separately from the player DB)
local function DefaultSettings()
    return {
        quiet = false,           -- disable "New player scanned" chat prints
        printThrottleSec = 1.5,  -- minimum seconds between prints
    }
end

local function Now()
    return time()
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

local function ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level)
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
        }
        MaybePrint(
            "New player scanned: " .. name ..
            " (" ..
            ((level and level > 0) and ("Lvl " .. level .. " ") or "") ..
            (localizedRace or race) .. " " .. (localizedClass or class) ..
            ")"
        )
        return
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
end

local function ScanGUID(guid)
    if not guid or not IsGuidString(guid) or guid == NULL_GUID then return end
    local localizedClass, englishClass, localizedRace, englishRace, sex, name, realm = GetPlayerInfoByGUID(guid)
    if name and englishClass and englishRace then
        -- Level is unknown from GUID alone.
        ScanPlayer(name, realm, englishClass, englishRace, localizedClass, localizedRace, nil)
    end
end

-- forward declaration (used by event handler)
local RefreshUI

-- Tooltip resolver queue (programmatic tooltip scanning / throttling)
local tip = CreateFrame("GameTooltip", "ClassScannerHiddenTooltip", UIParent, "GameTooltipTemplate")
tip:SetOwner(UIParent, "ANCHOR_NONE")
local tooltipQueue = {}
local tooltipResolving = false

local function ResolveUnitFromTooltip(unit)
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
            ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level)
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
        ResolveUnitFromTooltip(item.unit)
        tooltipResolving = false
        if #tooltipQueue > 0 then
            ProcessTooltipQueue()
        end
    end)
end

local function QueueUnitForTooltip(unit)
    if not unit then return end
    table.insert(tooltipQueue, { unit = unit })
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
                    ScanPlayer(name, realm, class, race, localizedClass, localizedRace, (level and level > 0) and level or nil)
                else
                    local guid = UnitGUID(unit)
                    if guid and guid ~= NULL_GUID then
                        ScanGUID(guid)
                        if not class then QueueUnitForTooltip(unit) end
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
                    ScanPlayer(name, realm, class, race, localizedClass, localizedRace, (level and level > 0) and level or nil)
                else
                    local guid = UnitGUID(unit)
                    if guid and guid ~= NULL_GUID then
                        ScanGUID(guid)
                        if not class then QueueUnitForTooltip(unit) end
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
                    ScanGUID(guid)
                end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local guid = UnitGUID(unit)
                if guid and guid ~= NULL_GUID then
                    ScanGUID(guid)
                end
            end
        end
        -- also scan player self
        if UnitExists("player") then
            local pguid = UnitGUID("player")
            if pguid and pguid ~= NULL_GUID then ScanGUID(pguid) end
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
                ScanPlayer(playerName, realm or "", classToken or "Unknown", race or "Unknown", classToken, race, nil)
            end
        end
    end
end

-- Periodic scanning ticker (lightweight)
local lastMouseoverScan = {}
local mouseoverSuppressionSec = 0.5 -- seconds to skip repeated mouseover/target scans
C_Timer.NewTicker(5, function()
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
            end

            print("ClassScanner loaded!")
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Be robust across clients/servers: some pass a variable argument list,
        -- others require CombatLogGetCurrentEventInfo(). We'll scan for GUID-like strings.
        local args
        if CombatLogGetCurrentEventInfo then
            args = { CombatLogGetCurrentEventInfo() }
        else
            args = { ... }
        end

        for i = 1, #args do
            local v = args[i]
            if IsGuidString(v) and v ~= NULL_GUID then
                -- Only scan player GUIDs to reduce noise
                if v:match("^Player%-") or v:sub(1,2) == "0x" then
                    ScanGUID(v)
                end
            end
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
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
                ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level)
            else
                -- Missing class/race/level — route through tooltip queue (respects existing tooltip throttle)
                QueueUnitForTooltip(unit)
            end
        end
    end
end)

-- UI and Slash Command
local uiFrame
local filterFaction = "All"
local filterRace = "All"
local filterClass = "All"
local filterLevel = "All"
local filterLevelMin = nil  -- Custom min level (nil = no minimum)
local filterLevelMax = nil  -- Custom max level (nil = no maximum)
local currentPage = 1
local itemsPerPage = 100
local searchQuery = "" -- free-text search query
local searchDebounceTimer = nil -- timer for live search debounce

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

local function UpdateList()
    if not uiFrame then return end

    -- 1. Filter and collect valid entries
    local validEntries = {}
    local classCounts = {}
    local raceCounts = {}
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

            -- Free-text search (case-insensitive substring match against name, realm, class, race, or key)
            if show and searchQuery and searchQuery ~= "" then
                local sq = searchQuery:lower()
                local name = (data.name or ""):lower()
                local realm = (data.realm or ""):lower()
                local class = (data.class or ""):lower()
                local race = (data.race or ""):lower()
                local k = (key or ""):lower()
                if not (name:find(sq, 1, true) or realm:find(sq, 1, true) or class:find(sq, 1, true) or race:find(sq, 1, true) or k:find(sq, 1, true)) then
                    show = false
                end
            end

            if show then
                table.insert(validEntries, {key = key, data = data})
                local c = data.class or "Unknown"
                classCounts[c] = (classCounts[c] or 0) + 1

                local r = CanonicalizeRace(data.race) or "Unknown"
                raceCounts[r] = (raceCounts[r] or 0) + 1

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

                -- Class header row
                if currentClass ~= lastClass then
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

                        row.levelText:SetText("")
                        row.ageText:SetText("")
                        row.playerData = nil
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
                    row.infoText:SetText(CanonicalizeRace(data.race) or "Unknown")
                    row.infoText:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)

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
        uiFrame:SetWidth(600)
        uiFrame:SetHeight(650)
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
            card:SetSize(135, 60)
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

        uiFrame.statCards.mostClass = CreateStatCard(statsContainer, 145, "Most Detected")

        uiFrame.statCards.mostRace = CreateStatCard(statsContainer, 290, "Top Race")

        uiFrame.statCards.levelSpread = CreateStatCard(statsContainer, 435, "Avg Level")
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
        levelDropdown:SetPoint("LEFT", classDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(levelDropdown, 80)
        local levelLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelLabel:SetPoint("BOTTOM", levelDropdown, "TOP", 0, 2)
        levelLabel:SetText("Level")
        levelLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        levelLabel:SetJustifyH("CENTER")
        levelLabel:SetWidth((levelDropdown:GetWidth() and levelDropdown:GetWidth()) or 80)

        -- Reset button
        local resetBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        resetBtn:SetSize(70, 22)
        resetBtn:SetPoint("TOPLEFT", levelDropdown, "TOPRIGHT", 12, 0)
        resetBtn:SetText("Reset")
        resetBtn:SetScript("OnClick", function()
            filterFaction = "All"
            filterRace = "All"
            filterClass = "All"
            filterLevel = "All"
            filterLevelMin = nil
            filterLevelMax = nil
            searchQuery = ""
            currentPage = 1
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerRaceDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerClassDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerLevelDropdown, "All")
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
            UpdateList()
        end)

        -- Custom Level Range
        local levelRangeLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelRangeLabel:SetPoint("TOPLEFT", 20, -235)
        levelRangeLabel:SetText("Level Range:")
        levelRangeLabel:Hide()
        uiFrame.levelRangeLabel = levelRangeLabel

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
        searchLabel:SetPoint("TOPLEFT", 20, -235)
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
        scrollFrame:SetPoint("TOPLEFT", 10, -260)
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
            row.infoText:SetWidth(100)
            row.infoText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
            row.infoText:SetJustifyH("LEFT")

            -- Age text
            row.ageText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.ageText:SetWidth(50)
            row.ageText:SetPoint("RIGHT", -10, 0)
            row.ageText:SetJustifyH("RIGHT")

            -- Hover effect
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
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
                    GameTooltip:AddDoubleLine("Faction:", data.faction or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    if data.realm and data.realm ~= "" then
                        GameTooltip:AddDoubleLine("Realm:", data.realm, 0.7, 0.7, 0.7, 1, 1, 1)
                    end
                    if data.seen then
                        local age = Now() - data.seen
                        GameTooltip:AddDoubleLine("Last Seen:", FormatAgeSeconds(age) .. " ago", 0.7, 0.7, 0.7, 1, 1, 1)
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
                local race = (data.race or ""):lower()
                local k = (key or ""):lower()
                if name:find(sq, 1, true) or realm:find(sq, 1, true) or class:find(sq, 1, true) or race:find(sq, 1, true) or k:find(sq, 1, true) then
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
            print(i .. ". " .. disp .. " — " .. (d.class or "Unknown") .. " L" .. lvl)
        end
        if #matches > 50 then print("...and " .. (#matches - 50) .. " more") end
        return
    end

    print("ClassScanner: unknown command '" .. cmd .. "'.")
    PrintHelp()
end
