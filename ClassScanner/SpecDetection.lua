local addonName, CS = ...

local NULL_GUID = CS.NULL_GUID
local SPEC_SOURCE_PRIORITY = CS.SPEC_SOURCE_PRIORITY
local SPEC_SOURCE_CONFIDENCE = CS.SPEC_SOURCE_CONFIDENCE
local SPEC_STALE_REPLACE_SEC = CS.SPEC_STALE_REPLACE_SEC
local VALID_SPEC_NAMES = CS.VALID_SPEC_NAMES

local CanonicalizeClass = CS.CanonicalizeClass
local GetSpecFallbackForTab = CS.GetSpecFallbackForTab
local IsStandardClassToken = CS.IsStandardClassToken
local MakePlayerKey = CS.MakePlayerKey
local NormalizeSpecName = CS.NormalizeSpecName

-- Buff-based spec inference for quickly identifying obvious specs.
local SPEC_BUFF_BY_CLASS = {
    WARRIOR = {
        [71] = "Protection", -- Defensive Stance
        [2457] = "Arms", -- Battle Stance
        [2458] = "Fury", -- Berserker Stance
    },
    PRIEST = {
        [15473] = "Shadow", -- Shadowform
    },
    DRUID = {
        [24858] = "Balance", -- Moonkin Form
        [33891] = "Restoration", -- Tree of Life
        [5487] = "Feral", -- Bear Form
        [9634] = "Feral", -- Dire Bear Form
        [768] = "Feral", -- Cat Form
    },
    PALADIN = {
        [25780] = "Protection", -- Righteous Fury
    },
    DEATHKNIGHT = {
        [48266] = "Blood", -- Blood Presence
        [48263] = "Frost", -- Frost Presence
        [48265] = "Unholy", -- Unholy Presence
    },
    SHAMAN = {
        [52127] = "Restoration", -- Water Shield
    },
}

-- Distinctive combat-log spell IDs for low-confidence spec inference.
local SPEC_COMBAT_SPELLS = {
    WARRIOR = {
        [12294] = "Arms", -- Mortal Strike
        [46924] = "Arms", -- Bladestorm
        [23881] = "Fury", -- Bloodthirst
        [1680] = "Fury", -- Whirlwind
        [23922] = "Protection", -- Shield Slam
        [46968] = "Protection", -- Shockwave
    },
    PALADIN = {
        [20473] = "Holy", -- Holy Shock
        [53563] = "Holy", -- Beacon of Light
        [48827] = "Protection", -- Avenger's Shield
        [53595] = "Protection", -- Hammer of the Righteous
        [35395] = "Retribution", -- Crusader Strike
        [53385] = "Retribution", -- Divine Storm
    },
    HUNTER = {
        [19574] = "Beast Mastery", -- Bestial Wrath
        [19577] = "Beast Mastery", -- Intimidation
        [53209] = "Marksmanship", -- Chimera Shot
        [19434] = "Marksmanship", -- Aimed Shot
        [53301] = "Survival", -- Explosive Shot
        [3674] = "Survival", -- Black Arrow
    },
    ROGUE = {
        [1329] = "Assassination", -- Mutilate
        [32645] = "Assassination", -- Envenom
        [51690] = "Combat", -- Killing Spree
        [13877] = "Combat", -- Blade Flurry
        [36554] = "Subtlety", -- Shadowstep
        [51713] = "Subtlety", -- Shadow Dance
    },
    PRIEST = {
        [47540] = "Discipline", -- Penance
        [33206] = "Discipline", -- Pain Suppression
        [48089] = "Holy", -- Circle of Healing
        [47788] = "Holy", -- Guardian Spirit
        [34914] = "Shadow", -- Vampiric Touch
        [15407] = "Shadow", -- Mind Flay
    },
    DEATHKNIGHT = {
        [55050] = "Blood", -- Heart Strike
        [55233] = "Blood", -- Vampiric Blood
        [49184] = "Frost", -- Howling Blast
        [49143] = "Frost", -- Frost Strike
        [55090] = "Unholy", -- Scourge Strike
        [49206] = "Unholy", -- Summon Gargoyle
    },
    SHAMAN = {
        [51505] = "Elemental", -- Lava Burst
        [51490] = "Elemental", -- Thunderstorm
        [17364] = "Enhancement", -- Stormstrike
        [60103] = "Enhancement", -- Lava Lash
        [61295] = "Restoration", -- Riptide
        [974] = "Restoration", -- Earth Shield
    },
    MAGE = {
        [44425] = "Arcane", -- Arcane Barrage
        [42897] = "Arcane", -- Arcane Blast
        [44457] = "Fire", -- Living Bomb
        [42891] = "Fire", -- Pyroblast
        [44572] = "Frost", -- Deep Freeze
        [12472] = "Frost", -- Icy Veins
    },
    WARLOCK = {
        [47843] = "Affliction", -- Unstable Affliction
        [48181] = "Affliction", -- Haunt
        [47241] = "Demonology", -- Metamorphosis
        [47897] = "Demonology", -- Hand of Gul'dan
        [17962] = "Destruction", -- Conflagrate
        [50796] = "Destruction", -- Chaos Bolt
    },
    DRUID = {
        [53201] = "Balance", -- Starfall
        [50516] = "Balance", -- Typhoon
        [33876] = "Feral", -- Mangle (Cat)
        [33878] = "Feral", -- Mangle (Bear)
        [48438] = "Restoration", -- Wild Growth
        [18562] = "Restoration", -- Swiftmend
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
        ["Sword and Board"] = "Protection",
        ["Taste for Blood"] = "Arms",
    },
    PRIEST = {
        ["Shadowform"] = "Shadow",
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
        ["Eclipse"] = "Balance",
        ["Eclipse (Solar)"] = "Balance",
        ["Eclipse (Lunar)"] = "Balance",
        ["Savage Roar"] = "Feral",
        ["Survival Instincts"] = "Feral",
        ["Nature's Swiftness"] = "Restoration",
    },
    PALADIN = {
        ["Righteous Fury"] = "Protection",
        ["The Art of War"] = "Retribution",
        ["Infusion of Light"] = "Holy",
        ["Holy Shield"] = "Protection",
        ["Sheath of Light"] = "Retribution",
    },
    DEATHKNIGHT = {
        ["Blood Presence"] = "Blood",
        ["Frost Presence"] = "Frost",
        ["Unholy Presence"] = "Unholy",
        ["Bone Shield"] = "Unholy",
        ["Blade Barrier"] = "Blood",
        ["Killing Machine"] = "Frost",
        ["Freezing Fog"] = "Frost",
    },
    SHAMAN = {
        ["Water Shield"] = "Restoration",
        ["Elemental Focus"] = "Elemental",
        ["Elemental Mastery"] = "Elemental",
        ["Maelstrom Weapon"] = "Enhancement",
        ["Shamanistic Rage"] = "Enhancement",
        ["Spirit Weapons"] = "Enhancement",
        ["Flurry"] = "Enhancement",
        ["Tidal Waves"] = "Restoration",
    },
    MAGE = {
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
        ["Eradication"] = "Affliction",
        ["Nightfall"] = "Affliction",
        ["Molten Core"] = "Demonology",
        ["Decimation"] = "Demonology",
        ["Metamorphosis"] = "Demonology",
        ["Backdraft"] = "Destruction",
        ["Nether Protection"] = "Destruction",
    },
    HUNTER = {
        ["The Beast Within"] = "Beast Mastery",
        ["Master Marksman"] = "Marksmanship",
        ["Lock and Load"] = "Survival",
    },
    ROGUE = {
        ["Master of Subtlety"] = "Subtlety",
        ["Shadow Dance"] = "Subtlety",
        ["Blade Flurry"] = "Combat",
        ["Adrenaline Rush"] = "Combat",
        ["Cold Blood"] = "Assassination",
        ["Hunger for Blood"] = "Assassination",
    },
}

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

local specDebugEnabled = false
local combatSpecEvidenceByKey = {}
local inspectState = {
    lastRequestAt = 0,
    pendingGuid = nil,
    pendingKey = nil,
}

local function SpecDebug(msg)
    if specDebugEnabled then
        print("|cFF00FF00[CS-SpecDebug]|r " .. msg)
    end
end

local function SourceRank(source)
    return SPEC_SOURCE_PRIORITY[source] or 0
end

local function ShouldReplaceSpec(entry, source)
    if not entry or not entry.spec then return true end
    local oldRank = SourceRank(entry.specSource)
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
    if not VALID_SPEC_NAMES[spec] then return end
    if not ShouldReplaceSpec(entry, source) then return end

    entry.spec = spec
    entry.specSource = source
    entry.specConfidence = SPEC_SOURCE_CONFIDENCE[source] or "low"
    entry.specUpdatedAt = time()
end

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

    SpecDebug("Scanning buffs on " .. tostring(unit) .. " (class " .. tostring(classToken) .. ")")
    for i = 1, 40 do
        local name, _, _, _, _, _, _, unitCaster, _, _, spellId = UnitBuff(unit, i)
        if not name then break end

        local isSelfCast = unitCaster and UnitIsUnit(unitCaster, unit)

        local sid = tonumber(spellId)
        if sid and classMap and classMap[sid] then
            SpecDebug("Buff ID match: " .. name .. " (ID " .. sid .. ") -> " .. classMap[sid])
            return classMap[sid]
        end

        if classNameMap and classNameMap[name] then
            SpecDebug("Buff name match: " .. name .. " -> " .. classNameMap[name])
            return classNameMap[name]
        end

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

    local sid = tonumber(spellId)
    local spec = sid and classMap and classMap[sid]
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
    for specName, count in pairs(evidence) do
        if count > bestVotes then
            bestSpec = specName
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
    local entry = CS.ScanPlayer(name, realm, class, race, localizedClass, localizedRace, level, "talent")
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

    local now = GetTime()
    local throttle = (ClassScannerSettings and ClassScannerSettings.inspectThrottleSec) or 2
    if (now - (inspectState.lastRequestAt or 0)) < throttle then return end

    local key = MakePlayerKey(entry.name, entry.realm)
    if not key then return end

    inspectState.lastRequestAt = now
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

local function HandleInspectReady(guid)
    if not inspectState.pendingGuid or guid ~= inspectState.pendingGuid then
        return false
    end

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
    return true
end

local function SanitizeStoredSpec(entry)
    if type(entry) ~= "table" or not entry.spec then return false end
    local normalized = NormalizeSpecName(entry.spec)
    if normalized and VALID_SPEC_NAMES[normalized] then
        entry.spec = normalized
        return false
    end

    entry.spec = nil
    entry.specSource = nil
    entry.specConfidence = nil
    entry.specUpdatedAt = nil
    return true
end

local function CleanInvalidSpecs()
    local count = 0
    for _, data in pairs(ClassScannerDB or {}) do
        if SanitizeStoredSpec(data) then
            count = count + 1
        end
    end
    return count
end

local function ToggleSpecDebug()
    specDebugEnabled = not specDebugEnabled
    return specDebugEnabled
end

local function RunSpecTest()
    print("|cFF00FF00[CS-SpecTest]|r Talent info dump:")
    local _, class = UnitClass("player")
    local classToken = CanonicalizeClass(class)
    print("  Class: " .. tostring(class) .. " -> token: " .. tostring(classToken))
    print("  IsStandardClassToken: " .. tostring(IsStandardClassToken(classToken)))

    if GetNumTalentTabs then
        local numTabs = GetNumTalentTabs()
        print("  GetNumTalentTabs(): " .. tostring(numTabs))
        if numTabs and numTabs > 0 then
            for tab = 1, numTabs do
                if GetTalentTabInfo then
                    local name, _, points, fileName = GetTalentTabInfo(tab)
                    print("    Tab " .. tab .. ": name=" .. tostring(name)
                        .. " points=" .. tostring(points)
                        .. " fileName=" .. tostring(fileName))
                end
            end
        end
    else
        print("  GetNumTalentTabs: NOT AVAILABLE")
    end

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

    if UnitExists("target") and UnitIsPlayer("target") then
        print("|cFF00FF00[CS-SpecTest]|r Target buff scan:")
        local tName = UnitName("target")
        local _, tClass = UnitClass("target")
        local tToken = CanonicalizeClass(tClass)
        print("  Target: " .. tostring(tName) .. " class=" .. tostring(tToken))
        if UnitBuff then
            for i = 1, 40 do
                local buffName, _, _, _, _, _, _, _, _, _, buffSpellId = UnitBuff("target", i)
                if not buffName then break end
                print("    Buff " .. i .. ": " .. buffName .. " (ID " .. tostring(buffSpellId) .. ")")
            end
        end
    end
end

CS.SetEntrySpec = SetEntrySpec
CS.ResolveSpecFromTalents = ResolveSpecFromTalents
CS.InferSpecFromCombatSpell = InferSpecFromCombatSpell
CS.UpdateSelfSpecFromTalents = UpdateSelfSpecFromTalents
CS.TryUpdateSpecFromUnit = TryUpdateSpecFromUnit
CS.HandleInspectReady = HandleInspectReady
CS.SanitizeStoredSpec = SanitizeStoredSpec
CS.CleanInvalidSpecs = CleanInvalidSpecs
CS.ToggleSpecDebug = ToggleSpecDebug
CS.IsSpecDebugEnabled = function()
    return specDebugEnabled
end
CS.RunSpecTest = RunSpecTest
