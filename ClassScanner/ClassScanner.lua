local addonName, CS = ...

local CanonicalizeClass = CS.CanonicalizeClass
local DefaultSettings = CS.DefaultSettings
local FormatDamageNumber = CS.FormatDamageNumber
local GetMeetBucketFromMet = CS.GetMeetBucketFromMet
local NormalizeSpecName = CS.NormalizeSpecName
local RefreshUI = CS.RefreshUI
local SanitizeStoredSpec = CS.SanitizeStoredSpec

local function PrintCS(msg)
    print("|cFF33FF99ClassScanner|r: " .. tostring(msg))
end

local function CountDbPlayers(db)
    if type(db) ~= "table" then return 0 end
    local count = 0
    for _, data in pairs(db) do
        if type(data) == "table" then
            count = count + 1
        end
    end
    return count
end

local function DeepCopyTable(value, seen)
    local t = type(value)
    if t ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local out = {}
    seen[value] = out

    for k, v in pairs(value) do
        local kt = type(k)
        local vt = type(v)
        if kt ~= "function" and kt ~= "userdata" and kt ~= "thread" and vt ~= "function" and vt ~= "userdata" and vt ~= "thread" then
            out[DeepCopyTable(k, seen)] = DeepCopyTable(v, seen)
        end
    end

    return out
end

local function PruneDbForBackup(db)
    if type(db) ~= "table" then return db end
    if not ClassScannerSettings or not ClassScannerSettings.backupPruneCombat then
        return db
    end

    for _, data in pairs(db) do
        if type(data) == "table" then
            data.combat = nil
        end
    end
    return db
end

local function EnsureBackupStore()
    if not ClassScannerBackups or type(ClassScannerBackups) ~= "table" then
        ClassScannerBackups = {}
    end
end

local function NormalizeBackups()
    EnsureBackupStore()
    if type(ClassScannerBackups.list) ~= "table" then
        ClassScannerBackups.list = {}
    end
    if type(ClassScannerBackups.lastAutoTs) ~= "number" then
        ClassScannerBackups.lastAutoTs = 0
    end
end

local function PruneBackupsToMax()
    NormalizeBackups()
    local maxKeep = (ClassScannerSettings and tonumber(ClassScannerSettings.backupMax)) or 3
    if not maxKeep or maxKeep < 1 then maxKeep = 1 end
    if maxKeep > 10 then maxKeep = 10 end

    local list = ClassScannerBackups.list
    while #list > maxKeep do
        table.remove(list, 1)
    end
end

local function ValidateBackupEntry(entry)
    if type(entry) ~= "table" then return false, "bad entry" end
    if type(entry.ts) ~= "number" then return false, "missing ts" end
    if type(entry.db) ~= "table" then return false, "missing db" end
    return true
end

function CS.CreateBackup(reason)
    NormalizeBackups()

    local snapshot = DeepCopyTable(ClassScannerDB or {})
    snapshot = PruneDbForBackup(snapshot)
    local mvpSnapshot = DeepCopyTable(ClassScannerBGMVPRecords or {})
    local mvpHistorySnapshot = DeepCopyTable(ClassScannerBGMVPHistory or {})

    local entry = {
        ts = time(),
        reason = (reason and tostring(reason)) or "manual",
        version = tostring(CS.ADDON_VERSION or ""),
        playerCount = CountDbPlayers(snapshot),
        db = snapshot,
        bgmvpRecords = mvpSnapshot,
        bgmvpHistory = mvpHistorySnapshot,
    }

    table.insert(ClassScannerBackups.list, entry)
    PruneBackupsToMax()

    return #ClassScannerBackups.list, entry
end

function CS.ListBackups()
    NormalizeBackups()
    return ClassScannerBackups.list
end

function CS.GetBackupById(id)
    NormalizeBackups()
    local list = ClassScannerBackups.list
    if id == "latest" then
        return #list, list[#list]
    end
    local n = tonumber(id)
    if not n then return nil end
    return n, list[n]
end

function CS.RestoreBackup(id)
    NormalizeBackups()
    local idx, entry = CS.GetBackupById(id)
    if not entry then
        return false, "backup not found"
    end
    local ok, err = ValidateBackupEntry(entry)
    if not ok then
        return false, err
    end

    -- Safety swap: back up current state first.
    CS.CreateBackup("auto: pre-restore")

    ClassScannerDB = DeepCopyTable(entry.db)
    ClassScannerBGMVPRecords = DeepCopyTable(entry.bgmvpRecords or {})
    ClassScannerBGMVPHistory = DeepCopyTable(entry.bgmvpHistory or {})
    InitializeSavedVariables()
    return true, idx
end

local function NormalizeResetScope(scope)
    if type(scope) ~= "table" then
        return nil
    end

    local kind = type(scope.kind) == "string" and scope.kind or nil
    if not kind or kind == "" then
        return nil
    end

    if kind == "full_reset" or kind == "all_specs" or kind == "battleground_data" or kind == "world_data" then
        return { kind = kind }
    end

    if kind == "spec_value" then
        local spec = NormalizeSpecName(scope.spec)
        if not spec or spec == "Unknown" then
            return nil
        end
        return {
            kind = kind,
            spec = spec,
        }
    end

    if kind == "class_value" then
        local classToken = CanonicalizeClass(scope.class)
        if not classToken then
            return nil
        end
        return {
            kind = kind,
            class = classToken,
        }
    end

    return nil
end

local function DescribeResetScope(scope)
    local normalized = NormalizeResetScope(scope)
    if not normalized then
        return nil
    end

    if normalized.kind == "full_reset" then
        return {
            actionLabel = "Full Reset",
            confirmText = "Fully reset ClassScanner data?\n\nThis removes all player records from the database. A backup will be created first.",
            backupReason = "auto: full reset",
            resultLabel = "all ClassScanner data",
        }
    end

    if normalized.kind == "all_specs" then
        return {
            actionLabel = "Top Spec Data",
            confirmText = "Reset Top Spec data?\n\nThis clears detected specialization fields for matching players. A backup will be created first.",
            backupReason = "auto: reset top spec data",
            resultLabel = "Top Spec data",
        }
    end

    if normalized.kind == "spec_value" then
        return {
            actionLabel = normalized.spec .. " Spec Data",
            confirmText = "Reset " .. normalized.spec .. " spec data?\n\nThis clears detected specialization fields for players currently mapped to that spec. A backup will be created first.",
            backupReason = "auto: reset spec data (" .. normalized.spec .. ")",
            resultLabel = normalized.spec .. " spec data",
        }
    end

    if normalized.kind == "battleground_data" then
        return {
            actionLabel = "Battleground Data",
            confirmText = "Reset Battleground data?\n\nThis removes battleground evidence from matching players. Entries first met in Battlegrounds will be removed because that data cannot be cleared more narrowly. A backup will be created first.",
            backupReason = "auto: reset battleground data",
            resultLabel = "Battleground data",
        }
    end

    if normalized.kind == "world_data" then
        return {
            actionLabel = "World Data",
            confirmText = "Reset World data?\n\nThis removes player entries first met in the open world. A backup will be created first.",
            backupReason = "auto: reset world data",
            resultLabel = "World data",
        }
    end

    if normalized.kind == "class_value" then
        return {
            actionLabel = normalized.class .. " Class Data",
            confirmText = "Reset " .. normalized.class .. " class data?\n\nThis removes player entries for that class because class counts are derived directly from the roster. A backup will be created first.",
            backupReason = "auto: reset class data (" .. normalized.class .. ")",
            resultLabel = normalized.class .. " class data",
        }
    end

    return nil
end

local function ClearEntrySpecFields(entry)
    if type(entry) ~= "table" then
        return false
    end

    local changed = false
    if entry.spec ~= nil then
        entry.spec = nil
        changed = true
    end
    if entry.specSource ~= nil then
        entry.specSource = nil
        changed = true
    end
    if entry.specConfidence ~= nil then
        entry.specConfidence = nil
        changed = true
    end
    if entry.specUpdatedAt ~= nil then
        entry.specUpdatedAt = nil
        changed = true
    end

    return changed
end

function CS.DescribeResetScope(scope)
    local normalized = NormalizeResetScope(scope)
    local description = DescribeResetScope(normalized)
    if not normalized or not description then
        return nil
    end

    local out = {}
    for key, value in pairs(description) do
        out[key] = value
    end
    out.scope = normalized
    return out
end

function CS.ResetGranularData(scope)
    local descriptor = CS.DescribeResetScope(scope)
    if not descriptor then
        return false, "invalid reset scope"
    end

    local normalized = descriptor.scope
    local deletes = {}
    local updates = {}

    for key, data in pairs(ClassScannerDB or {}) do
        if type(data) == "table" then
            if normalized.kind == "full_reset" then
                deletes[key] = true
            elseif normalized.kind == "all_specs" then
                if data.spec ~= nil or data.specSource ~= nil or data.specConfidence ~= nil or data.specUpdatedAt ~= nil then
                    updates[key] = "clear_spec"
                end
            elseif normalized.kind == "spec_value" then
                if NormalizeSpecName(data.spec) == normalized.spec then
                    updates[key] = "clear_spec"
                end
            elseif normalized.kind == "battleground_data" then
                local bucket = GetMeetBucketFromMet(data.met)
                if bucket == "Battleground" then
                    deletes[key] = true
                elseif data.seenInBattleground then
                    updates[key] = "clear_bg_flag"
                end
            elseif normalized.kind == "world_data" then
                if GetMeetBucketFromMet(data.met) == "World" then
                    deletes[key] = true
                end
            elseif normalized.kind == "class_value" then
                if CanonicalizeClass(data.class) == normalized.class then
                    deletes[key] = true
                end
            end
        end
    end

    local changedCount = 0
    for _ in pairs(deletes) do
        changedCount = changedCount + 1
    end
    for key in pairs(updates) do
        if not deletes[key] then
            changedCount = changedCount + 1
        end
    end

    local mvpClearCount = 0
    if normalized.kind == "full_reset" or normalized.kind == "battleground_data" then
        local mvpRecords = ClassScannerBGMVPRecords or {}
        for _ in pairs(mvpRecords) do
            mvpClearCount = mvpClearCount + 1
        end

        local history = ClassScannerBGMVPHistory or {}
        if type(history) == "table" then
            mvpClearCount = mvpClearCount + #history
        end
    end

    if mvpClearCount > 0 then
        changedCount = changedCount + mvpClearCount
    end

    if changedCount == 0 then
        return true, {
            changedCount = 0,
            actionLabel = descriptor.actionLabel,
            resultLabel = descriptor.resultLabel,
        }
    end

    local backupId = CS.CreateBackup(descriptor.backupReason)

    for key in pairs(deletes) do
        ClassScannerDB[key] = nil
    end

    for key, action in pairs(updates) do
        if not deletes[key] then
            local entry = ClassScannerDB[key]
            if action == "clear_spec" then
                ClearEntrySpecFields(entry)
            elseif action == "clear_bg_flag" and type(entry) == "table" then
                entry.seenInBattleground = nil
            end
        end
    end

    if normalized.kind == "full_reset" or normalized.kind == "battleground_data" then
        if CS.ClearBattlegroundMVPRecords then
            CS.ClearBattlegroundMVPRecords()
        end
        if CS.ClearBattlegroundMVPHistory then
            CS.ClearBattlegroundMVPHistory()
        end
    end

    return true, {
        changedCount = changedCount,
        backupId = backupId,
        actionLabel = descriptor.actionLabel,
        resultLabel = descriptor.resultLabel,
    }
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TALENT_UPDATE")
frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("UNIT_LEVEL")
frame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
frame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

local function InitializeSavedVariables()
    if not ClassScannerDB then
        ClassScannerDB = {}
    end

    if not ClassScannerBGMVPRecords then
        ClassScannerBGMVPRecords = {}
    end

    if not ClassScannerBGMVPHistory then
        ClassScannerBGMVPHistory = {}
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

    NormalizeBackups()
    if CS and CS.NormalizeBattlegroundMVPRecords then
        CS.NormalizeBattlegroundMVPRecords()
    end
    if CS and CS.NormalizeBattlegroundMVPHistory then
        CS.NormalizeBattlegroundMVPHistory()
    end
end

C_Timer.NewTicker(1, function()
    CS.ProcessPendingLevelRetries()
    CS.ScanNameplates()
end)

C_Timer.NewTicker(5, function()
    CS.ExpireCombatState()
    CS.ExpireCombatSpecEvidence()
    if InCombatLockdown and InCombatLockdown() then return end
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

        -- Periodic auto-backup (bounded)
        NormalizeBackups()
        local days = (ClassScannerSettings and tonumber(ClassScannerSettings.backupAutoDays)) or 7
        if not days or days < 0 then days = 0 end
        local age = time() - (ClassScannerBackups.lastAutoTs or 0)
        if days > 0 and age >= (days * 86400) then
            CS.CreateBackup("auto: login")
            ClassScannerBackups.lastAutoTs = time()
        end
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
    elseif event == "UNIT_LEVEL" then
        local unit = ...
        if unit and UnitExists(unit) and UnitIsPlayer(unit) then
            CS.HandleObservedUnit(unit, "unitlevel")
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        local unit = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        local source = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
        CS.HandleObservedUnit(unit, source)
    elseif event == "UPDATE_BATTLEFIELD_SCORE" or event == "UPDATE_BATTLEFIELD_STATUS" or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        CS.ScanBattleground()
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
        print("  /cs topclassburst [n]- top N classes by burst DPS to you (BG-flagged players, default 10)")
        print("  /cs dmg on|off     - toggle damage tracking")
        print("  /cs burst <sec>    - set burst DPS window (e.g. 3, 5)")
        print("  /cs dmgclear       - clear combat data (keeps scan data)")
        print("  /cs cleanspecs     - remove invalid spec entries from DB")
        print("  /cs backup [reason]- create a DB backup (SavedVariables)")
        print("  /cs backups        - list backups")
        print("  /cs restore <id|latest> confirm - restore DB backup (overwrites current DB)")
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
        CS.CreateBackup("auto: pre-clear")
        ClassScannerDB = {}
        if CS.ClearBattlegroundMVPRecords then
            CS.ClearBattlegroundMVPRecords()
        else
            ClassScannerBGMVPRecords = {}
        end
        PrintCS("database cleared (backup created).")
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

    if cmd == "topclassburst" then
        local count = tonumber(arg) or 10
        if count < 1 then count = 1 end

        local classPeaks = {}
        for key, data in pairs(ClassScannerDB or {}) do
            if type(data) == "table" and data.seenInBattleground and data.combat and data.combat.maxBurstDps and data.combat.maxBurstDps.dps and data.combat.maxBurstDps.dps > 0 then
                local class = data.class or "Unknown"
                local displayName = data.name or key
                if data.realm and data.realm ~= "" then displayName = displayName .. "-" .. data.realm end
                local existing = classPeaks[class]
                if (not existing) or (data.combat.maxBurstDps.dps > existing.dps) then
                    classPeaks[class] = {
                        cls = class,
                        dps = data.combat.maxBurstDps.dps,
                        player = displayName,
                        windowSec = data.combat.maxBurstDps.windowSec,
                    }
                end
            end
        end

        local ranked = {}
        for _, item in pairs(classPeaks) do
            table.insert(ranked, item)
        end
        table.sort(ranked, function(a, b)
            return (a.dps or 0) > (b.dps or 0)
        end)

        if #ranked == 0 then
            print("No battleground-flagged burst data recorded yet.")
            return
        end

        print("Top " .. math.min(count, #ranked) .. " classes by burst DPS to you (BG-flagged players):")
        for i = 1, math.min(count, #ranked) do
            local item = ranked[i]
            local windowSec = item.windowSec or ClassScannerSettings.burstWindowSec or 3
            print(i .. ". " .. item.cls .. " — " .. FormatDamageNumber(item.dps) .. " DPS | By: " .. item.player .. " | Window: " .. tostring(windowSec) .. "s")
        end
        print("(Heuristic: includes players ever seen in a battleground; burst may be recorded outside battlegrounds.)")
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
        CS.CreateBackup("auto: pre-dmgclear")
        local count = CS.ClearCombatData()
        PrintCS("cleared combat data from " .. count .. " players (backup created).")
        RefreshUI()
        return
    end

    if cmd == "cleanspecs" then
        CS.CreateBackup("auto: pre-cleanspecs")
        local count = CS.CleanInvalidSpecs()
        PrintCS("removed " .. count .. " invalid spec entr" .. (count == 1 and "y" or "ies") .. " from database (backup created).")
        RefreshUI()
        return
    end

    if cmd == "backup" then
        local reason = (arg and arg ~= "") and arg or "manual"
        local id, entry = CS.CreateBackup(reason)
        PrintCS("backup #" .. id .. " created (" .. (entry.reason or "") .. "), players=" .. tostring(entry.playerCount or 0))
        return
    end

    if cmd == "backups" then
        local list = CS.ListBackups()
        if not list or #list == 0 then
            PrintCS("no backups yet. Use /cs backup")
            return
        end
        PrintCS("backups (oldest->newest):")
        for i = 1, #list do
            local b = list[i]
            local age = time() - (b.ts or time())
            PrintCS("  [" .. i .. "] " .. CS.FormatAgeSeconds(age) .. " ago | players=" .. tostring(b.playerCount or "?") .. " | " .. tostring(b.reason or "") .. " | v" .. tostring(b.version or ""))
        end
        return
    end

    if cmd == "restore" then
        local which, confirm = (arg or ""):match("^(%S+)%s*(.-)$")
        which = which or ""
        confirm = (confirm or ""):lower()
        if which == "" then
            print("Usage: /cs restore <id|latest> confirm")
            return
        end
        if confirm ~= "confirm" then
            PrintCS("restore is destructive. Re-run with: /cs restore " .. which .. " confirm")
            return
        end
        local ok, info = CS.RestoreBackup(which)
        if not ok then
            PrintCS("restore failed: " .. tostring(info))
            return
        end
        PrintCS("restored backup #" .. tostring(info) .. ". Reloading UI...")
        ReloadUI()
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
