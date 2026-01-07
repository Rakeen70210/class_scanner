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
                ScanGUID(v)
            end
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        if UnitIsPlayer(unit) then
            local name, realm = UnitName(unit)
            local localizedClass, class = UnitClass(unit)
            local localizedRace, race = UnitRace(unit)
            local level = UnitLevel(unit)
            ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level)
        end
    end
end)

-- UI and Slash Command
local uiFrame
local filterFaction = "All"
local filterRace = "All"
local filterClass = "All"
local filterLevel = "All"
local currentPage = 1
local itemsPerPage = 100

local function UpdateList()
    if not uiFrame then return end
    
    local text = ""
    
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
        -- Safety: ignore any non-table entries (shouldn't happen, but protects UI).
        if type(data) == "table" then
            local show = true
            
            if filterFaction ~= "All" and data.faction ~= filterFaction then show = false end
            if filterRace ~= "All" and data.race ~= filterRace then show = false end
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

    -- 2d. Level stats (known levels only)
    local avgLevel = nil
    if knownLevelCount > 0 then
        avgLevel = levelSum / knownLevelCount
    end

    -- 2e. Class counts summary (sorted by frequency)
    local classCountList = {}
    for cls, count in pairs(classCounts) do
        table.insert(classCountList, { cls = cls, count = count })
    end
    table.sort(classCountList, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        -- Put Unknown last when tied
        if a.cls == "Unknown" and b.cls ~= "Unknown" then return false end
        if b.cls == "Unknown" and a.cls ~= "Unknown" then return true end
        return (a.cls or "") < (b.cls or "")
    end)

    -- 3. Sort entries
    table.sort(validEntries, function(a, b)
        local da, db = a.data, b.data
        
        -- Sort by Class Count (Descending)
        local ca, cb = (da.class or "Unknown"), (db.class or "Unknown")
        local countA = classCounts[ca] or 0
        local countB = classCounts[cb] or 0
        
        if countA ~= countB then
            return countA > countB
        end
        
        -- Sort by Class Name (Alphabetical)
        if ca ~= cb then
            return ca < cb
        end

        -- Sort by Seen (Newest first)
        local sa, sb = (da.seen or 0), (db.seen or 0)
        if sa ~= sb then
            return sa > sb
        end
        
        -- Sort by Name
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

    -- Update UI Controls if they exist
    if uiFrame and uiFrame.prevBtn then
        if currentPage <= 1 then uiFrame.prevBtn:Disable() else uiFrame.prevBtn:Enable() end
        if currentPage >= totalPages then uiFrame.nextBtn:Disable() else uiFrame.nextBtn:Enable() end
        uiFrame.pageText:SetText("Page " .. currentPage .. " / " .. totalPages .. " (" .. #validEntries .. ")")
    end

    -- 4. Generate Text
    -- Add Statistics Header
    if totalCount > 0 then
        text = text .. "|cff00ff00Total Players: " .. totalCount .. "|r\n"
        text = text .. "|cff00ff00Most Detected: " .. mostDetectedClass .. " (" .. maxCount .. ")|r\n"
        text = text .. "|cff00ff00Most Played Race: " .. mostPlayedRace .. " (" .. maxRaceCount .. ")|r\n"

        if knownLevelCount > 0 and minLevel and maxLevel and avgLevel then
            text = text
                .. "|cff00ff00Level Spread: " .. minLevel .. "-" .. maxLevel .. "|r"
                .. " |cff999999(avg " .. string.format("%.1f", avgLevel) .. ", known " .. knownLevelCount .. "/" .. totalCount .. ")|r\n\n"
        else
            text = text .. "|cff00ff00Level Spread: ?|r |cff999999(no level data in current filters)|r\n\n"
        end

        -- Class counts summary (helps when the list is long/truncated)
        if #classCountList > 0 then
            text = text .. "|cff00ff00Class Counts:|r "
            local lineLen = 0
            for i = 1, #classCountList do
                local item = classCountList[i]
                local cls = item.cls or "Unknown"
                local cnt = item.count or 0

                local clsColor = "|cffffffff"
                if cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls] then
                    clsColor = "|c" .. RAID_CLASS_COLORS[cls].colorStr
                end

                local chunk = clsColor .. cls .. "|r " .. cnt
                if i < #classCountList then
                    chunk = chunk .. ", "
                end

                -- Soft-wrap the header line so it doesn't become unreadable.
                -- (Approximate; WoW font widths vary, but this is good enough.)
                if (lineLen + #chunk) > 85 then
                    text = text .. "\n  "
                    lineLen = 0
                end

                text = text .. chunk
                lineLen = lineLen + #chunk
            end
            text = text .. "\n\n"
        end
    end

    local lastClass = nil
    for i = startIndex, endIndex do
        local entry = validEntries[i]
        local data = entry.data
        local key = entry.key
        
        local currentClass = data.class or "Unknown"
        if currentClass ~= lastClass then
            if lastClass then
                text = text .. "\n"
            end
            local count = classCounts[currentClass] or 0
            text = text .. "|cffFFD700--- " .. currentClass .. " (" .. count .. ") ---|r\n"

            local clsKnown = classLevelCounts[currentClass] or 0
            if clsKnown > 0 then
                local clsAvg = (classLevelSums[currentClass] or 0) / clsKnown
                text = text .. "|cff999999Avg Level: " .. string.format("%.1f", clsAvg) .. " (known " .. clsKnown .. ")|r\n"
            else
                text = text .. "|cff999999Avg Level: ? (no level data)|r\n"
            end
            lastClass = currentClass
        end

        local color = "|cffffffff"
        if data.class and RAID_CLASS_COLORS[data.class] then
            color = "|c" .. RAID_CLASS_COLORS[data.class].colorStr
        end
        
        local levelStr = (data.level and data.level > 0) and ("[" .. data.level .. "] ") or "[??] "
        local displayName = data.name or key
        if data.realm and data.realm ~= "" then
            displayName = displayName .. "-" .. data.realm
        end

        local age = data.seen and (Now() - data.seen) or nil
        local seenStr = "|cff999999" .. FormatAgeSeconds(age) .. "|r"

        text = text
            .. levelStr .. color .. displayName .. "|r"
            .. " - " .. (CanonicalizeRace(data.race) or "Unknown") .. " " .. (data.class or "Unknown")
            .. "  " .. seenStr
            .. "\n"
    end
    
    if totalCount == 0 then
        text = "No players found matching filters."
    end

    uiFrame.text:SetText(text)
    uiFrame.content:SetHeight(uiFrame.text:GetStringHeight())
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
        uiFrame = CreateFrame("Frame", "ClassScannerFrame", UIParent)
        uiFrame:SetWidth(500)
        uiFrame:SetHeight(500)
        uiFrame:SetPoint("CENTER")
        uiFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        uiFrame:EnableMouse(true)
        uiFrame:SetMovable(true)
        uiFrame:RegisterForDrag("LeftButton")
        uiFrame:SetScript("OnDragStart", uiFrame.StartMoving)
        uiFrame:SetScript("OnDragStop", uiFrame.StopMovingOrSizing)

        -- Title
        local title = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -15)
        title:SetText("ClassScanner Results")

        -- Close Button
        local closeBtn = CreateFrame("Button", nil, uiFrame, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -5, -5)

        -- Filters
        local factionDropdown = CreateDropdown("ClassScannerFactionDropdown", uiFrame, {"Alliance", "Horde"}, function(val)
            filterFaction = val
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        factionDropdown:SetPoint("TOPLEFT", 0, -40)

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
        raceDropdown:SetPoint("LEFT", factionDropdown, "RIGHT", -10, 0)

        local classDropdown = CreateDropdown("ClassScannerClassDropdown", uiFrame, {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}, function(val)
            filterClass = val
            UIDropDownMenu_SetText(ClassScannerClassDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        classDropdown:SetPoint("LEFT", raceDropdown, "RIGHT", -10, 0)

        local levelDropdown = CreateDropdown("ClassScannerLevelDropdown", uiFrame, {"80", "70-79", "60-69", "1-59"}, function(val)
            filterLevel = val
            UIDropDownMenu_SetText(ClassScannerLevelDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        levelDropdown:SetPoint("LEFT", classDropdown, "RIGHT", -10, 0)

        -- ScrollFrame
        local scrollFrame = CreateFrame("ScrollFrame", "ClassScannerScrollFrame", uiFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 20, -80)
        scrollFrame:SetPoint("BOTTOMRIGHT", -40, 45)

        -- Pagination Controls
        local prevBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        prevBtn:SetSize(80, 22)
        prevBtn:SetPoint("BOTTOMLEFT", 20, 15)
        prevBtn:SetText("Previous")
        prevBtn:SetScript("OnClick", function()
            if currentPage > 1 then
                currentPage = currentPage - 1
                UpdateList()
            end
        end)
        uiFrame.prevBtn = prevBtn

        local nextBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        nextBtn:SetSize(80, 22)
        nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 10, 0)
        nextBtn:SetText("Next")
        nextBtn:SetScript("OnClick", function()
            currentPage = currentPage + 1
            UpdateList()
        end)
        uiFrame.nextBtn = nextBtn

        local pageText = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        pageText:SetPoint("LEFT", nextBtn, "RIGHT", 10, 0)
        pageText:SetText("Page 1 / 1")
        uiFrame.pageText = pageText

        -- Content Frame
        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetSize(440, 1) 
        scrollFrame:SetScrollChild(content)
        
        uiFrame.content = content
        uiFrame.text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        uiFrame.text:SetPoint("TOPLEFT", 0, 0)
        uiFrame.text:SetWidth(440)
        uiFrame.text:SetJustifyH("LEFT")
        uiFrame.text:SetJustifyV("TOP")
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

    print("ClassScanner: unknown command '" .. cmd .. "'.")
    PrintHelp()
end