local addonName, addonTable = ...

-- Initialize the database
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("INSPECT_TALENT_READY")

local NULL_GUID = "0x0000000000000000"

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
            spec = "Unknown"
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
    if not guid or guid == NULL_GUID then return end
    local localizedClass, englishClass, localizedRace, englishRace, sex, name, realm = GetPlayerInfoByGUID(guid)
    if name and englishClass and englishRace then
        -- Level is unknown from GUID alone.
        ScanPlayer(name, realm, englishClass, englishRace, localizedClass, localizedRace, nil)
    end
end

local function UpdateSpec(playerKey)
    local maxPoints = 0
    local specName = "Unknown"
    -- Iterate over the 3 talent tabs
    for i=1, 3 do
        local tabName, icon, pointsSpent = GetTalentTabInfo(i, true)
        if pointsSpent and pointsSpent > maxPoints then
            maxPoints = pointsSpent
            specName = tabName
        end
    end
    
    if specName ~= "Unknown" and playerKey and ClassScannerDB[playerKey] then
        ClassScannerDB[playerKey].spec = specName
        -- print("Spec detected for " .. name .. ": " .. specName)
    end
end

local lastInspectKey
local lastInspectGuid

-- forward declaration (used by event handler)
local RefreshUI

local function RequestInspectTarget(playerKey)
    lastInspectKey = playerKey
    lastInspectGuid = UnitGUID("target")
    NotifyInspect("target")
end

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
        -- WotLK signature includes hideCaster and raidFlags; keep GUID extraction correct.
        local timestamp, eventType, hideCaster,
            sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
            destGUID, destName, destFlags, destRaidFlags = ...
        ScanGUID(sourceGUID)
        ScanGUID(destGUID)
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        if UnitIsPlayer(unit) then
            local name, realm = UnitName(unit)
            local localizedClass, class = UnitClass(unit)
            local localizedRace, race = UnitRace(unit)
            local level = UnitLevel(unit)
            ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level)
            local key = MakePlayerKey(name, realm)
            
            -- Try to inspect if it's target and we can inspect (same faction, range)
            if unit == "target" and CanInspect("target") then
                -- Only inspect if we don't have a spec yet or want to refresh
                if key and ClassScannerDB[key] and (not ClassScannerDB[key].spec or ClassScannerDB[key].spec == "Unknown") then
                    RequestInspectTarget(key)
                end
            end
        end
    elseif event == "INSPECT_TALENT_READY" then
        if lastInspectKey and ClassScannerDB[lastInspectKey] then
            UpdateSpec(lastInspectKey)
        end
        if ClearInspectPlayer then
            ClearInspectPlayer()
        end
        lastInspectKey = nil
        lastInspectGuid = nil

        if RefreshUI then
            RefreshUI()
        end
    end
end)

-- UI and Slash Command
local uiFrame
local filterFaction = "All"
local filterRace = "All"
local filterClass = "All"
local filterLevel = "All"

local function UpdateList()
    if not uiFrame then return end
    
    local text = ""
    local count = 0

    local keys = {}
    for key, data in pairs(ClassScannerDB) do
        -- Safety: ignore any non-table entries (shouldn't happen, but protects UI).
        if type(data) == "table" then
            table.insert(keys, key)
        end
    end
    table.sort(keys, function(a, b)
        local da, db = ClassScannerDB[a], ClassScannerDB[b]
        local sa, sb = (da and da.seen) or 0, (db and db.seen) or 0
        if sa ~= sb then
            return sa > sb
        end
        local na, nb = (da and da.name) or a, (db and db.name) or b
        return na < nb
    end)

    for _, key in ipairs(keys) do
        local data = ClassScannerDB[key]
        local show = true
        
        if filterFaction ~= "All" and data.faction ~= filterFaction then show = false end
        if filterRace ~= "All" and data.race ~= filterRace then show = false end
        if filterClass ~= "All" and data.class ~= filterClass then show = false end
        
        if filterLevel ~= "All" then
            local lvl = data.level
            if not lvl then
                show = false
            end
            if filterLevel == "80" and lvl ~= 80 then show = false end
            if filterLevel == "70-79" and (lvl < 70 or lvl > 79) then show = false end
            if filterLevel == "60-69" and (lvl < 60 or lvl > 69) then show = false end
            if filterLevel == "1-59" and (lvl < 1 or lvl > 59) then show = false end
        end
        
        if show then
            local color = "|cffffffff"
            if data.class and RAID_CLASS_COLORS[data.class] then
                color = "|c" .. RAID_CLASS_COLORS[data.class].colorStr
            end
            
            local levelStr = (data.level and data.level > 0) and ("[" .. data.level .. "] ") or "[??] "
            local specStr = (data.spec and data.spec ~= "Unknown") and (" (" .. data.spec .. ")") or ""
            local displayName = data.name or key
            if data.realm and data.realm ~= "" then
                displayName = displayName .. "-" .. data.realm
            end

            local age = data.seen and (Now() - data.seen) or nil
            local seenStr = "|cff999999" .. FormatAgeSeconds(age) .. "|r"

            text = text
                .. levelStr .. color .. displayName .. "|r"
                .. " - " .. (data.race or "Unknown") .. " " .. (data.class or "Unknown") .. specStr
                .. "  " .. seenStr
                .. "\n"
            count = count + 1
        end
    end
    
    if count == 0 then
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
            UpdateList()
        end,
            "All"
        )
        raceDropdown:SetPoint("LEFT", factionDropdown, "RIGHT", -10, 0)

        local classDropdown = CreateDropdown("ClassScannerClassDropdown", uiFrame, {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}, function(val)
            filterClass = val
            UIDropDownMenu_SetText(ClassScannerClassDropdown, val)
            UpdateList()
        end, "All")
        classDropdown:SetPoint("LEFT", raceDropdown, "RIGHT", -10, 0)

        local levelDropdown = CreateDropdown("ClassScannerLevelDropdown", uiFrame, {"80", "70-79", "60-69", "1-59"}, function(val)
            filterLevel = val
            UIDropDownMenu_SetText(ClassScannerLevelDropdown, val)
            UpdateList()
        end, "All")
        levelDropdown:SetPoint("LEFT", classDropdown, "RIGHT", -10, 0)

        -- ScrollFrame
        local scrollFrame = CreateFrame("ScrollFrame", "ClassScannerScrollFrame", uiFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 20, -80)
        scrollFrame:SetPoint("BOTTOMRIGHT", -40, 20)

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