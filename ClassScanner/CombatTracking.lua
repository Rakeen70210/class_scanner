local addonName, CS = ...

local NULL_GUID = CS.NULL_GUID

local CanonicalizeClass = CS.CanonicalizeClass
local InferSpecFromCombatSpell = CS.InferSpecFromCombatSpell
local IsGuidString = CS.IsGuidString
local IsStandardClassToken = CS.IsStandardClassToken
local MakePlayerKey = CS.MakePlayerKey
local Now = CS.Now
local ScanGUID = CS.ScanGUID

local playerGUID = nil
local petOwnerByGUID = {}
local attackerState = {}

local function FormatDamageNumber(n)
    if not n or n <= 0 then return "0" end
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fK", n / 1000)
    end
    return tostring(math.floor(n))
end

local function ExpireCombatState()
    local timeout = (ClassScannerSettings and ClassScannerSettings.encounterTimeoutSec) or 10
    local now = GetTime()
    local expiredGuids = {}
    for guid, state in pairs(attackerState) do
        if now - state.lastAt > timeout then
            table.insert(expiredGuids, guid)
        end
    end
    for _, guid in ipairs(expiredGuids) do
        attackerState[guid] = nil
    end
end

local function EnsureCombatEntry(logicalGUID, logicalName)
    local attackerName, attackerRealm
    if logicalName then
        attackerName, attackerRealm = strsplit("-", logicalName)
    end
    local key = MakePlayerKey(attackerName, attackerRealm)
    if not key then return nil, nil end

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

    if not entry.combat then
        entry.combat = {
            totalDamageToMe = 0,
            totalHitsToMe = 0,
            maxHit = { amount = 0 },
            maxBurstDps = { dps = 0 },
        }
    end

    return key, entry
end

local function HandleCombatLog(...)
    local _, subevent, sourceGUID, sourceName, _, destGUID = ...

    if not playerGUID then
        playerGUID = UnitGUID("player")
    end

    if sourceGUID and IsGuidString(sourceGUID) and sourceGUID ~= NULL_GUID then
        if sourceGUID:match("^Player%-") or sourceGUID:sub(1, 2) == "0x" then
            ScanGUID(sourceGUID, "combatlog")
        end
    end
    if destGUID and IsGuidString(destGUID) and destGUID ~= NULL_GUID then
        if destGUID:match("^Player%-") or destGUID:sub(1, 2) == "0x" then
            ScanGUID(destGUID, "combatlog")
        end
    end

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

    if subevent == "SPELL_SUMMON" then
        local destGuid = select(6, ...)
        if sourceGUID and destGuid and sourceName then
            petOwnerByGUID[destGuid] = { ownerGUID = sourceGUID, ownerName = sourceName }
        end
    elseif subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
        local destGuid = select(6, ...)
        if destGuid then
            petOwnerByGUID[destGuid] = nil
        end
    end

    if not (ClassScannerSettings and ClassScannerSettings.trackDamageToPlayer) then return end
    if not playerGUID or destGUID ~= playerGUID then return end
    if not sourceGUID or sourceGUID == NULL_GUID or sourceGUID == playerGUID then return end

    local amount, spellId, spellName, spellSchool, critical, kind
    if subevent == "SWING_DAMAGE" then
        amount, _, _, _, _, _, critical = select(9, ...)
        kind = "SWING"
        spellName = "Melee"
    elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" then
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

    local key, entry = EnsureCombatEntry(logicalGUID, logicalName)
    if not key or not entry then return end

    entry.combat.totalDamageToMe = (entry.combat.totalDamageToMe or 0) + amount
    entry.combat.totalHitsToMe = (entry.combat.totalHitsToMe or 0) + 1

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

    local burstWindow = (ClassScannerSettings and ClassScannerSettings.burstWindowSec) or 3
    local now = GetTime()
    if not attackerState[logicalGUID] then
        attackerState[logicalGUID] = { lastAt = now, windowEvents = {}, windowSum = 0 }
    end
    local state = attackerState[logicalGUID]
    state.lastAt = now

    local timeout = (ClassScannerSettings and ClassScannerSettings.encounterTimeoutSec) or 10
    if #state.windowEvents > 0 and (now - state.windowEvents[#state.windowEvents].t) > timeout then
        state.windowEvents = {}
        state.windowSum = 0
    end

    table.insert(state.windowEvents, { t = now, amount = amount })
    state.windowSum = state.windowSum + amount

    while #state.windowEvents > 0 and (now - state.windowEvents[1].t) > burstWindow do
        state.windowSum = state.windowSum - state.windowEvents[1].amount
        table.remove(state.windowEvents, 1)
    end

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
end

local function ClearCombatData()
    local count = 0
    for _, data in pairs(ClassScannerDB or {}) do
        if type(data) == "table" and data.combat then
            data.combat = nil
            count = count + 1
        end
    end
    attackerState = {}
    petOwnerByGUID = {}
    return count
end

CS.SetPlayerGUID = function(guid)
    playerGUID = guid
end
CS.FormatDamageNumber = FormatDamageNumber
CS.ExpireCombatState = ExpireCombatState
CS.HandleCombatLog = HandleCombatLog
CS.ClearCombatData = ClearCombatData
