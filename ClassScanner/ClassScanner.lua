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
    ["Human"] = "Alliance", ["Dwarf"] = "Alliance", ["NightElf"] = "Alliance", ["Gnome"] = "Alliance", ["Draenei"] = "Alliance",
    ["Orc"] = "Horde", ["Scourge"] = "Horde", ["Tauren"] = "Horde", ["Troll"] = "Horde", ["BloodElf"] = "Horde"
}

local function GetFactionFromRace(race)
    return RACES[race] or "Unknown"
end

local function ScanPlayer(name, class, race, localizedClass, localizedRace, level)
    if name and class and race then
        if not ClassScannerDB[name] then
            local faction = GetFactionFromRace(race)
            ClassScannerDB[name] = {
                class = class,
                race = race,
                faction = faction,
                level = level or 0,
                seen = time(),
                spec = "Unknown"
            }
            print("New player scanned: " .. name .. " (" .. (level and level > 0 and ("Lvl " .. level .. " ") or "") .. (localizedRace or race) .. " " .. (localizedClass or class) .. ")")
        else
            -- Update level if we have a better one
            if level and level > 0 and (not ClassScannerDB[name].level or ClassScannerDB[name].level == 0 or ClassScannerDB[name].level < level) then
                ClassScannerDB[name].level = level
            end
        end
    end
end

local function ScanGUID(guid)
    if not guid or guid == NULL_GUID then return end
    local localizedClass, englishClass, localizedRace, englishRace, sex, name, realm = GetPlayerInfoByGUID(guid)
    if name and englishClass and englishRace then
        ScanPlayer(name, englishClass, englishRace, localizedClass, localizedRace, 0)
    end
end

local function UpdateSpec(name)
    local maxPoints = 0
    local specName = "Unknown"
    -- Iterate over the 3 talent tabs
    for i=1, 3 do
        local name, icon, pointsSpent = GetTalentTabInfo(i, true)
        if pointsSpent and pointsSpent > maxPoints then
            maxPoints = pointsSpent
            specName = name
        end
    end
    
    if specName ~= "Unknown" and ClassScannerDB[name] then
        ClassScannerDB[name].spec = specName
        -- print("Spec detected for " .. name .. ": " .. specName)
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            if not ClassScannerDB then
                ClassScannerDB = {}
            end
            print("ClassScanner loaded!")
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = ...
        ScanGUID(sourceGUID)
        ScanGUID(destGUID)
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        if UnitIsPlayer(unit) then
            local name = UnitName(unit)
            local localizedClass, class = UnitClass(unit)
            local localizedRace, race = UnitRace(unit)
            local level = UnitLevel(unit)
            ScanPlayer(name, class, race, localizedClass, localizedRace, level)
            
            -- Try to inspect if it's target and we can inspect (same faction, range)
            if unit == "target" and CanInspect("target") then
                -- Only inspect if we don't have a spec yet or want to refresh
                if ClassScannerDB[name] and (not ClassScannerDB[name].spec or ClassScannerDB[name].spec == "Unknown") then
                    NotifyInspect("target")
                end
            end
        end
    elseif event == "INSPECT_TALENT_READY" then
        local name = UnitName("target")
        if name and ClassScannerDB[name] then
            UpdateSpec(name)
            if uiFrame and uiFrame:IsShown() then
                -- Refresh UI to show new spec
                -- We need to call UpdateList, but it's local. 
                -- We'll move UpdateList definition up or call a global/forward declared one.
                -- For now, let's just let the next refresh handle it or make UpdateList accessible.
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

local function UpdateList()
    if not uiFrame then return end
    
    local text = ""
    local count = 0
    for name, data in pairs(ClassScannerDB) do
        local show = true
        
        if filterFaction ~= "All" and data.faction ~= filterFaction then show = false end
        if filterRace ~= "All" and data.race ~= filterRace then show = false end
        if filterClass ~= "All" and data.class ~= filterClass then show = false end
        
        if filterLevel ~= "All" then
            local lvl = data.level or 0
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
            text = text .. levelStr .. color .. name .. "|r - " .. (data.race or "Unknown") .. " " .. (data.class or "Unknown") .. specStr .. "\n"
            count = count + 1
        end
    end
    
    if count == 0 then
        text = "No players found matching filters."
    end

    uiFrame.text:SetText(text)
    uiFrame.content:SetHeight(uiFrame.text:GetStringHeight())
end

-- Forward declaration for UpdateList usage in OnEvent
local function RefreshUI()
    if uiFrame and uiFrame:IsShown() then
        UpdateList()
    end
end

-- Hook RefreshUI into OnEvent
local oldScript = frame:GetScript("OnEvent")
frame:SetScript("OnEvent", function(self, event, ...)
    oldScript(self, event, ...)
    if event == "INSPECT_TALENT_READY" then
        RefreshUI()
    end
end)

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

        local raceDropdown = CreateDropdown("ClassScannerRaceDropdown", uiFrame, {"Human", "Dwarf", "NightElf", "Gnome", "Draenei", "Orc", "Scourge", "Tauren", "Troll", "BloodElf"}, function(val)
            filterRace = val
            UIDropDownMenu_SetText(ClassScannerRaceDropdown, val)
            UpdateList()
        end, "All")
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
    if msg == "clear" then
        ClassScannerDB = {}
        print("ClassScanner database cleared.")
        if uiFrame and uiFrame:IsShown() then
            ClassScanner_ShowUI() -- Refresh UI if open
        end
    else
        ClassScanner_ShowUI()
    end
end