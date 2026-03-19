local addonName, CS = ...

local CanonicalizeClass = CS.CanonicalizeClass
local DefaultSettings = CS.DefaultSettings
local FormatDamageNumber = CS.FormatDamageNumber
local GetMeetBucketFromMet = CS.GetMeetBucketFromMet
local RefreshUI = CS.RefreshUI
local SanitizeStoredSpec = CS.SanitizeStoredSpec

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TALENT_UPDATE")
frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
frame:RegisterEvent("INSPECT_READY")

local function InitializeSavedVariables()
    if not ClassScannerDB then
        ClassScannerDB = {}
    end

    if not ClassScannerSettings then
        ClassScannerSettings = DefaultSettings()
    else
        for key, value in pairs(DefaultSettings()) do
            if ClassScannerSettings[key] == nil then
                ClassScannerSettings[key] = value
            end
        end
    end

    for _, data in pairs(ClassScannerDB) do
        if type(data) == "table" then
            if data.class then
                local canonClass = CanonicalizeClass(data.class)
                if canonClass then
                    data.class = canonClass
                end
            end

            SanitizeStoredSpec(data)

            if data.seenInBattleground == nil then
                local bucket = GetMeetBucketFromMet(data.met)
                if bucket == "Battleground" then
                    data.seenInBattleground = true
                elseif type(data.met) == "table" and data.met.source == "scoreboard" then
                    -- Best-effort backfill: scoreboard scans come from a battlefield context.
                    -- If we have explicit evidence this was an arena, do not mark as BG.
                    local it = data.met.instanceType or data.met.instanceInfoType
                    if it ~= "arena" then
                        data.seenInBattleground = true
                    end
                end
            end
        end
    end
end

C_Timer.NewTicker(5, function()
    CS.ExpireCombatState()
    CS.ExpireCombatSpecEvidence()
    if InCombatLockdown and InCombatLockdown() then return end
    CS.ScanNameplates()
    CS.ScanGroup()
    CS.ScanBattleground()
end)

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            InitializeSavedVariables()
            print("ClassScanner loaded!")
        end
    elseif event == "PLAYER_LOGIN" then
        CS.SetPlayerGUID(UnitGUID("player"))
        CS.UpdateSelfSpecFromTalents()
    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        CS.UpdateSelfSpecFromTalents()
    elseif event == "INSPECT_READY" then
        if CS.HandleInspectReady(...) then
            RefreshUI()
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Ascension 3.3.5a uses standard WotLK combat log varargs (same as Skada).
        -- Do NOT use CombatLogGetCurrentEventInfo on this client.
        CS.HandleCombatLog(...)
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        local source = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        CS.HandleObservedUnit(unit, source)
    end
end)

SLASH_CLASSSCANNER1 = "/cs"
SLASH_CLASSSCANNER2 = "/classscanner"

SlashCmdList["CLASSSCANNER"] = function(msg)
    if not ClassScannerSettings then
        ClassScannerSettings = DefaultSettings()
    end

    msg = (msg or ""):match("^%s*(.-)%s*$")
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
        CS.ClassScanner_ShowUI()
        return
    end

    if cmd == "help" or cmd == "?" then
        PrintHelp()
        return
    end

    if cmd == "clear" then
        ClassScannerDB = {}
        print("ClassScanner database cleared.")
        RefreshUI()
        return
    end

    if cmd == "quiet" then
        ClassScannerSettings.quiet = not ClassScannerSettings.quiet
        print("ClassScanner quiet mode: " .. (ClassScannerSettings.quiet and "ON" or "OFF"))
        return
    end

    if cmd == "throttle" then
        local value = tonumber(arg)
        if not value or value < 0 then
            print("Usage: /cs throttle <seconds>")
            return
        end
        ClassScannerSettings.printThrottleSec = value
        print("ClassScanner print throttle: " .. value .. " sec")
        return
    end

    if cmd == "refresh" then
        RefreshUI()
        return
    end

    if cmd == "search" then
        local query = (arg or ""):match("^%s*(.-)%s*$")
        if query == "" then
            print("Usage: /cs search <term>")
            return
        end

        CS.SetSearchQuery(query)
        if CS.IsUIShown() then
            return
        end

        local sq = query:lower()
        local matches = {}
        for key, data in pairs(ClassScannerDB or {}) do
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
                local entryKey = (key or ""):lower()
                if name:find(sq, 1, true) or realm:find(sq, 1, true) or class:find(sq, 1, true) or spec:find(sq, 1, true) or specSource:find(sq, 1, true) or race:find(sq, 1, true) or metStr:find(sq, 1, true) or entryKey:find(sq, 1, true) then
                    table.insert(matches, { key = key, data = data })
                end
            end
        end

        if #matches == 0 then
            print("No matches for '" .. query .. "'.")
            return
        end

        table.sort(matches, function(a, b)
            local nameA, nameB = (a.data.name or a.key), (b.data.name or b.key)
            return nameA < nameB
        end)

        print("Search results for '" .. query .. "' (showing up to 50):")
        for i = 1, math.min(50, #matches) do
            local entry = matches[i]
            local data = entry.data
            local displayName = data.name or entry.key
            if data.realm and data.realm ~= "" then displayName = displayName .. "-" .. data.realm end
            local level = (data.level and tostring(data.level)) or "?"
            local spec = data.spec and (" / " .. data.spec) or ""
            print(i .. ". " .. displayName .. " — " .. (data.class or "Unknown") .. spec .. " L" .. level)
        end
        if #matches > 50 then
            print("...and " .. (#matches - 50) .. " more")
        end
        return
    end

    if cmd == "topdmg" then
        local count = tonumber(arg) or 10
        if count < 1 then count = 1 end
        local ranked = {}
        for key, data in pairs(ClassScannerDB or {}) do
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
        print("Top " .. math.min(count, #ranked) .. " players by damage to you:")
        for i = 1, math.min(count, #ranked) do
            local entry = ranked[i]
            local data = entry.data
            local displayName = data.name or entry.key
            if data.realm and data.realm ~= "" then displayName = displayName .. "-" .. data.realm end
            local class = data.class or "Unknown"
            local damage = FormatDamageNumber(data.combat.totalDamageToMe)
            local hitText = ""
            if data.combat.maxHit and data.combat.maxHit.amount and data.combat.maxHit.amount > 0 then
                hitText = " | Max Hit: " .. FormatDamageNumber(data.combat.maxHit.amount) .. " (" .. (data.combat.maxHit.spellName or "Melee") .. ")"
            end
            local burstText = ""
            if data.combat.maxBurstDps and data.combat.maxBurstDps.dps and data.combat.maxBurstDps.dps > 0 then
                burstText = " | Burst: " .. FormatDamageNumber(data.combat.maxBurstDps.dps) .. " DPS"
            end
            print(i .. ". " .. displayName .. " [" .. class .. "] — Dmg: " .. damage .. hitText .. burstText)
        end
        return
    end

    if cmd == "topclassdmg" then
        local count = tonumber(arg) or 10
        if count < 1 then count = 1 end
        local classTotals = {}
        for _, data in pairs(ClassScannerDB or {}) do
            if type(data) == "table" and data.combat and data.combat.totalDamageToMe and data.combat.totalDamageToMe > 0 then
                local class = data.class or "Unknown"
                classTotals[class] = (classTotals[class] or 0) + data.combat.totalDamageToMe
            end
        end
        local ranked = {}
        for class, total in pairs(classTotals) do
            table.insert(ranked, { cls = class, total = total })
        end
        table.sort(ranked, function(a, b)
            return a.total > b.total
        end)
        if #ranked == 0 then
            print("No damage data recorded yet.")
            return
        end
        print("Top " .. math.min(count, #ranked) .. " classes by damage to you:")
        for i = 1, math.min(count, #ranked) do
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
        local value = tonumber(arg)
        if not value or value < 1 or value > 30 then
            print("Usage: /cs burst <1-30> (currently " .. (ClassScannerSettings.burstWindowSec or 3) .. "s)")
            return
        end
        ClassScannerSettings.burstWindowSec = value
        print("ClassScanner burst DPS window: " .. value .. "s")
        return
    end

    if cmd == "dmgclear" then
        local count = CS.ClearCombatData()
        print("ClassScanner: cleared combat data from " .. count .. " players.")
        RefreshUI()
        return
    end

    if cmd == "cleanspecs" then
        local count = CS.CleanInvalidSpecs()
        print("ClassScanner: removed " .. count .. " invalid spec entr" .. (count == 1 and "y" or "ies") .. " from database.")
        RefreshUI()
        return
    end

    if cmd == "specdebug" then
        local enabled = CS.ToggleSpecDebug()
        print("ClassScanner spec debug: " .. (enabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        if enabled then
            print("  Debug messages will appear as |cFF00FF00[CS-SpecDebug]|r in chat.")
            print("  Mouse over players, target them, or enter combat to see detection info.")
            CS.UpdateSelfSpecFromTalents()
        end
        return
    end

    if cmd == "spectest" then
        CS.RunSpecTest()
        return
    end

    print("ClassScanner: unknown command '" .. cmd .. "'.")
    PrintHelp()
end
