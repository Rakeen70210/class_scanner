local addonName, CS = ...

local NULL_GUID = CS.NULL_GUID

local CanonicalizeClass = CS.CanonicalizeClass
local GetFactionFromRace = CS.GetFactionFromRace
local GetMeetContext = CS.GetMeetContext
local IsGuidString = CS.IsGuidString
local MakePlayerKey = CS.MakePlayerKey
local MaybePrint = CS.MaybePrint
local Now = CS.Now
local TryUpdateSpecFromUnit = CS.TryUpdateSpecFromUnit

local lastBattlefield = { t = 0, instanceType = nil, instanceName = nil }
local bgMvpState = {
    active = false,
    finalized = false,
    pendingFinalize = false,
    finalizeRequestedAt = nil,
    finalizeReason = nil,
    instanceName = nil,
    instanceType = nil,
    startedAt = nil,
    candidates = {},
}

local function EnsureBGMVPStore()
    if type(ClassScannerBGMVPRecords) ~= "table" then
        ClassScannerBGMVPRecords = {}
    end
end

local function NormalizeBattlegroundMVPRecords()
    EnsureBGMVPStore()
    for key, record in pairs(ClassScannerBGMVPRecords) do
        if type(record) ~= "table" or (record.role ~= "damage" and record.role ~= "healing") then
            ClassScannerBGMVPRecords[key] = nil
        end
    end
end

local function StartBattlegroundMvpSession(instanceName, instanceType)
    bgMvpState.active = true
    bgMvpState.finalized = false
    bgMvpState.pendingFinalize = false
    bgMvpState.finalizeRequestedAt = nil
    bgMvpState.finalizeReason = nil
    bgMvpState.instanceName = instanceName or bgMvpState.instanceName or "Battleground"
    bgMvpState.instanceType = instanceType or bgMvpState.instanceType or "pvp"
    bgMvpState.startedAt = Now()
    bgMvpState.candidates = {}
end

local function RequestBattlegroundMvpFinalize(reason)
    bgMvpState.pendingFinalize = true
    bgMvpState.finalizeRequestedAt = Now()
    bgMvpState.finalizeReason = reason
end

local function CompareMvpCandidate(a, b, field)
    local valueA = tonumber(a and a[field]) or 0
    local valueB = tonumber(b and b[field]) or 0
    if valueA ~= valueB then
        return valueA > valueB
    end

    local nameA = tostring(a and a.name or "") .. "-" .. tostring(a and a.realm or "")
    local nameB = tostring(b and b.name or "") .. "-" .. tostring(b and b.realm or "")
    if nameA ~= nameB then
        return nameA < nameB
    end

    return (a and a.lastSeenAt or 0) > (b and b.lastSeenAt or 0)
end

local function StoreBattlegroundMvpRecord(role, candidate)
    if not candidate then return end
    EnsureBGMVPStore()

    local playerKey = candidate.key or MakePlayerKey(candidate.name, candidate.realm or "")
    if not playerKey then return end

    local recordKey = role .. "|" .. playerKey
    local value = (role == "damage") and (candidate.damageDone or 0) or (candidate.healingDone or 0)
    local sourceEntry = ClassScannerDB and ClassScannerDB[playerKey] or nil

    ClassScannerBGMVPRecords[recordKey] = {
        recordKey = recordKey,
        role = role,
        playerKey = playerKey,
        name = candidate.name or (sourceEntry and sourceEntry.name) or "Unknown",
        realm = candidate.realm or (sourceEntry and sourceEntry.realm) or "",
        class = candidate.class or (sourceEntry and sourceEntry.class) or "Unknown",
        race = candidate.race or (sourceEntry and sourceEntry.race) or "Unknown",
        faction = candidate.faction or (sourceEntry and sourceEntry.faction) or GetFactionFromRace(candidate.race or (sourceEntry and sourceEntry.race)),
        spec = candidate.spec or (sourceEntry and sourceEntry.spec) or "Unknown",
        specSource = candidate.specSource or (sourceEntry and sourceEntry.specSource) or nil,
        specConfidence = candidate.specConfidence or (sourceEntry and sourceEntry.specConfidence) or nil,
        totalDamageDone = candidate.damageDone or 0,
        totalHealingDone = candidate.healingDone or 0,
        value = value,
        battlegroundName = bgMvpState.instanceName or lastBattlefield.instanceName or "Battleground",
        battlegroundType = bgMvpState.instanceType or lastBattlefield.instanceType or "pvp",
        recordedAt = Now(),
    }
end

local function FinalizeBattlegroundMvp(reason)
    if bgMvpState.finalized then
        return false
    end

    local candidates = {}
    for _, candidate in pairs(bgMvpState.candidates) do
        table.insert(candidates, candidate)
    end

    if #candidates == 0 then
        bgMvpState.active = false
        bgMvpState.finalized = true
        return false
    end

    table.sort(candidates, function(a, b)
        return CompareMvpCandidate(a, b, "damageDone")
    end)
    StoreBattlegroundMvpRecord("damage", candidates[1])

    table.sort(candidates, function(a, b)
        return CompareMvpCandidate(a, b, "healingDone")
    end)
    StoreBattlegroundMvpRecord("healing", candidates[1])

    bgMvpState.active = false
    bgMvpState.finalized = true
    bgMvpState.pendingFinalize = false
    bgMvpState.finalizeRequestedAt = nil
    bgMvpState.finalizeReason = nil
    bgMvpState.candidates = {}
    if CS and CS.RefreshUI then
        CS.RefreshUI()
    end
    return true
end

local function CaptureBattlegroundScoreboard()
    if not GetNumBattlefieldScores or GetNumBattlefieldScores() <= 0 then
        return
    end

    local function UnpackBattlefieldScore(index)
        -- Ascension/WotLK variants may include bonus honor before honor gained.
        -- Parse explicit fields so class/classToken and damage/healing do not shift.
        local name, _, _, _, _, _, _, race, className, classToken, damageDone, healingDone = GetBattlefieldScore(index)
        local classResolved = CanonicalizeClass(classToken) or CanonicalizeClass(className) or classToken or className or "Unknown"
        return name, race, classResolved, className, tonumber(damageDone) or 0, tonumber(healingDone) or 0
    end

    for i = 1, GetNumBattlefieldScores() do
        local name, race, classToken, className, damageDone, healingDone = UnpackBattlefieldScore(i)
        if name then
            local playerName, realm = strsplit("-", name)
            local key = MakePlayerKey(playerName, realm or "")
            if key then
                local entry = CS.ScanPlayer(playerName, realm or "", classToken or "Unknown", race or "Unknown", className or classToken, race, nil, "scoreboard")
                local candidate = bgMvpState.candidates[key]
                if not candidate then
                    candidate = {
                        key = key,
                        name = playerName,
                        realm = realm or "",
                        class = (entry and entry.class) or classToken or "Unknown",
                        race = (entry and entry.race) or race or "Unknown",
                        faction = (entry and entry.faction) or GetFactionFromRace(race),
                        spec = (entry and entry.spec) or "Unknown",
                        specSource = entry and entry.specSource or nil,
                        specConfidence = entry and entry.specConfidence or nil,
                        damageDone = 0,
                        healingDone = 0,
                        lastSeenAt = Now(),
                    }
                    bgMvpState.candidates[key] = candidate
                end

                if entry then
                    candidate.class = entry.class or candidate.class
                    candidate.race = entry.race or candidate.race
                    candidate.faction = entry.faction or candidate.faction
                    candidate.spec = entry.spec or candidate.spec or "Unknown"
                    candidate.specSource = entry.specSource or candidate.specSource
                    candidate.specConfidence = entry.specConfidence or candidate.specConfidence
                end

                candidate.damageDone = damageDone
                candidate.healingDone = healingDone
                candidate.lastSeenAt = Now()
            end
        end
    end
end

local function UpdateBattlegroundMvpState(inInstance, instanceType, instanceName)
    if not inInstance and bgMvpState.finalized then
        bgMvpState.finalized = false
    end

    if inInstance and instanceType == "pvp" then
        if not bgMvpState.active and not bgMvpState.finalized then
            StartBattlegroundMvpSession(instanceName, instanceType)
        else
            bgMvpState.instanceName = instanceName or bgMvpState.instanceName
            bgMvpState.instanceType = instanceType or bgMvpState.instanceType
        end
    elseif bgMvpState.active and not inInstance and lastBattlefield.instanceType == "pvp" then
        RequestBattlegroundMvpFinalize("zone_exit")
    end

    if not bgMvpState.active then
        return
    end

    local shouldTrack = false
    if inInstance and (instanceType == "pvp" or instanceType == "arena") then
        shouldTrack = true
    elseif lastBattlefield.instanceType == "pvp" then
        shouldTrack = true
    end

    if shouldTrack then
        CaptureBattlegroundScoreboard()
    end

    if GetBattlefieldWinner and GetBattlefieldWinner() then
        RequestBattlegroundMvpFinalize("winner")
    end

    if bgMvpState.pendingFinalize then
        CaptureBattlegroundScoreboard()

        local hasCandidates = false
        for _ in pairs(bgMvpState.candidates) do
            hasCandidates = true
            break
        end

        local elapsed = bgMvpState.finalizeRequestedAt and (Now() - bgMvpState.finalizeRequestedAt) or 0
        if hasCandidates or elapsed >= 8 then
            FinalizeBattlegroundMvp(bgMvpState.finalizeReason or "pending")
        end
    end
end

local function UpdateBattlefieldCache()
    if not IsInInstance then return end
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "pvp" or instanceType == "arena") then
        lastBattlefield.t = Now()
        lastBattlefield.instanceType = instanceType
        if GetInstanceInfo then
            local name = GetInstanceInfo()
            if name and name ~= "" then
                lastBattlefield.instanceName = name
            end
        end
    end
end

local function MaybeMarkSeenInBattleground(entry)
    if not entry or entry.seenInBattleground then return end
    if not IsInInstance then return end
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "pvp" then
        entry.seenInBattleground = true
    end
end

local tip = CreateFrame("GameTooltip", "ClassScannerHiddenTooltip", UIParent, "GameTooltipTemplate")
tip:SetOwner(UIParent, "ANCHOR_NONE")

local tooltipQueue = {}
local tooltipResolving = false
local lastObservedScan = {}
local observedUnitSuppressionSec = 0.5
local pendingLevelUnits = {}
local levelRetryIntervalSec = 1
local levelRetryExpireSec = 8
local maxLevelRetryAttempts = 5

local function MakeObservedUnitKey(unit)
    local guid = UnitGUID(unit)
    if guid and guid ~= NULL_GUID then
        return guid
    end

    local name, realm = UnitName(unit)
    if name then
        return name .. "-" .. (realm or "")
    end

    return nil
end

local function QueueUnitForLevelRetry(unit, source)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end

    local keyid = MakeObservedUnitKey(unit)
    if not keyid then return end

    local pending = pendingLevelUnits[keyid]
    if pending then
        pending.unit = unit
        pending.source = source or pending.source
        return
    end

    local now = Now()
    pendingLevelUnits[keyid] = {
        unit = unit,
        source = source,
        attempts = 0,
        nextAt = now,
        expiresAt = now + levelRetryExpireSec,
    }
end

local function ClearUnitLevelRetryByUnit(unit)
    local keyid = unit and MakeObservedUnitKey(unit) or nil
    if keyid then
        pendingLevelUnits[keyid] = nil
    end
end

local function ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, source)
    if not ClassScannerDB then return nil end
    if not name or not class or not race then return nil end

    local canonClass = CanonicalizeClass(class)
    if canonClass then class = canonClass end

    local key = MakePlayerKey(name, realm)
    if not key then return nil end

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

        MaybeMarkSeenInBattleground(entry)
        return entry
    end

    entry.seen = Now()

    if not entry.class and class then entry.class = class end
    if not entry.race and race then entry.race = race end
    if not entry.faction and race then entry.faction = GetFactionFromRace(race) end

    if level and level > 0 then
        if (not entry.level) or (entry.level < level) then
            entry.level = level
        end
    end

    MaybeMarkSeenInBattleground(entry)

    return entry
end

local function ScanGUID(guid, source)
    if not guid or not IsGuidString(guid) or guid == NULL_GUID then return end
    local localizedClass, englishClass, localizedRace, englishRace, _, name, realm = GetPlayerInfoByGUID(guid)
    if name and englishClass and englishRace then
        ScanPlayer(name, realm, englishClass, englishRace, localizedClass, localizedRace, nil, source)
    end
end

local function ResolveUnitFromTooltip(unit, source)
    if not UnitExists(unit) then return false end
    tip:ClearLines()
    tip:SetUnit(unit)
    tip:Hide()
    if UnitIsPlayer(unit) then
        local name, realm = UnitName(unit)
        local localizedClass, class = UnitClass(unit)
        local localizedRace, race = UnitRace(unit)
        local level = UnitLevel(unit)
        if name and class and race then
            local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, source)
            TryUpdateSpecFromUnit(unit, entry)
            if level and level > 0 then
                ClearUnitLevelRetryByUnit(unit)
            else
                QueueUnitForLevelRetry(unit, source)
            end
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

local function ScanUnitForLevel(unit, source)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return false end

    local name, realm = UnitName(unit)
    local localizedClass, class = UnitClass(unit)
    local localizedRace, race = UnitRace(unit)
    local level = UnitLevel(unit)

    if name and class and race then
        local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, (level and level > 0) and level or nil, source)
        TryUpdateSpecFromUnit(unit, entry)
        if level and level > 0 then
            ClearUnitLevelRetryByUnit(unit)
        else
            QueueUnitForLevelRetry(unit, source)
        end
        return true
    end

    local guid = UnitGUID(unit)
    if guid and guid ~= NULL_GUID then
        ScanGUID(guid, source)
    end
    QueueUnitForTooltip(unit, source)
    QueueUnitForLevelRetry(unit, source)
    return false
end

local function ProcessPendingLevelRetries()
    local now = Now()

    for keyid, pending in pairs(pendingLevelUnits) do
        local unit = pending.unit
        if pending.expiresAt <= now or pending.attempts >= maxLevelRetryAttempts then
            pendingLevelUnits[keyid] = nil
        elseif unit and UnitExists(unit) and UnitIsPlayer(unit) and now >= (pending.nextAt or 0) then
            pending.attempts = pending.attempts + 1
            pending.nextAt = now + levelRetryIntervalSec
            ScanUnitForLevel(unit, pending.source or "retry")

            local refreshedKey = MakeObservedUnitKey(unit)
            if refreshedKey and refreshedKey ~= keyid then
                pendingLevelUnits[keyid] = nil
                if pendingLevelUnits[refreshedKey] == nil then
                    pendingLevelUnits[refreshedKey] = pending
                end
            end
        elseif not (unit and UnitExists(unit) and UnitIsPlayer(unit)) then
            pendingLevelUnits[keyid] = nil
        end
    end
end

local function ScanNameplates()
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            local unit = plate.UnitFrame and plate.UnitFrame.unit
            if unit and UnitExists(unit) and UnitIsPlayer(unit) then
                ScanUnitForLevel(unit, "nameplate")
            end
        end
    else
        for i = 1, 40 do
            local unit = "nameplate" .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                ScanUnitForLevel(unit, "nameplate")
            end
        end
    end
end

local function ScanGroup()
    if IsInRaid() then
        local count = GetNumGroupMembers()
        for i = 1, count do
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
        if UnitExists("player") then
            local playerGuid = UnitGUID("player")
            if playerGuid and playerGuid ~= NULL_GUID then
                ScanGUID(playerGuid, "group")
            end
        end
    end
end

local function ScanBattleground()
    UpdateBattlefieldCache()

    local inInstance, instanceType
    if IsInInstance then
        inInstance, instanceType = IsInInstance()
    end

    -- Request live score data only while inside an active battlefield.
    -- Calling this after being ported out can wipe cached scores.
    if inInstance and (instanceType == "pvp" or instanceType == "arena") and RequestBattlefieldScoreData then
        RequestBattlefieldScoreData()
    end

    local shouldMarkBattleground = false
    if inInstance and instanceType == "pvp" then
        shouldMarkBattleground = true
    elseif inInstance and instanceType == "arena" then
        shouldMarkBattleground = false
    elseif lastBattlefield.instanceType == "pvp" then
        -- We were just in a BG; scores may persist briefly after port-out.
        shouldMarkBattleground = true
    elseif lastBattlefield.instanceType == "arena" then
        shouldMarkBattleground = false
    else
        -- Best-effort default: this function is only called for battlefield scoreboards.
        shouldMarkBattleground = true
    end

    if GetNumBattlefieldScores and GetNumBattlefieldScores() > 0 then
        local function UnpackBattlefieldScore(index)
            local name, _, _, _, _, _, _, race, className, classToken = GetBattlefieldScore(index)
            local classResolved = CanonicalizeClass(classToken) or CanonicalizeClass(className) or classToken or className or "Unknown"
            return name, race, classResolved, className
        end

        for i = 1, GetNumBattlefieldScores() do
            local name, race, classToken, className = UnpackBattlefieldScore(i)
            if name then
                local playerName, realm = strsplit("-", name)
                local entry = ScanPlayer(playerName, realm or "", classToken or "Unknown", race or "Unknown", className or classToken, race, nil, "scoreboard")
                if entry and shouldMarkBattleground then
                    entry.seenInBattleground = true
                end
            end
        end
    end

    UpdateBattlegroundMvpState(inInstance, instanceType, lastBattlefield.instanceName)
end

local function HandleObservedUnit(unit, source)
    if not UnitIsPlayer(unit) then return end

    local guid = UnitGUID(unit)
    local keyid = guid
    if not keyid then
        local name, realm = UnitName(unit)
        keyid = name and (name .. "-" .. (realm or "")) or nil
    end

    if keyid then
        local last = lastObservedScan[keyid]
        if last and (Now() - last) < observedUnitSuppressionSec then
            return
        end
        lastObservedScan[keyid] = Now()
    end

    local name, realm = UnitName(unit)
    local localizedClass, class = UnitClass(unit)
    local localizedRace, race = UnitRace(unit)
    local level = UnitLevel(unit)

    if name and class and race then
        local entry = ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, source)
        TryUpdateSpecFromUnit(unit, entry)
        if level and level > 0 then
            ClearUnitLevelRetryByUnit(unit)
        else
            QueueUnitForLevelRetry(unit, source)
        end
    else
        QueueUnitForTooltip(unit, source)
        QueueUnitForLevelRetry(unit, source)
    end
end

CS.ScanPlayer = ScanPlayer
CS.ScanGUID = ScanGUID
CS.QueueUnitForTooltip = QueueUnitForTooltip
CS.ProcessPendingLevelRetries = ProcessPendingLevelRetries
CS.ScanNameplates = ScanNameplates
CS.ScanGroup = ScanGroup
CS.ScanBattleground = ScanBattleground
CS.HandleObservedUnit = HandleObservedUnit
CS.NormalizeBattlegroundMVPRecords = NormalizeBattlegroundMVPRecords
CS.GetBattlegroundMVPRecords = function()
    EnsureBGMVPStore()
    return ClassScannerBGMVPRecords
end
CS.ClearBattlegroundMVPRecords = function()
    EnsureBGMVPStore()
    local count = 0
    for key in pairs(ClassScannerBGMVPRecords) do
        ClassScannerBGMVPRecords[key] = nil
        count = count + 1
    end
    bgMvpState = {
        active = false,
        finalized = false,
        pendingFinalize = false,
        finalizeRequestedAt = nil,
        finalizeReason = nil,
        instanceName = nil,
        instanceType = nil,
        startedAt = nil,
        candidates = {},
    }
    return count
end
