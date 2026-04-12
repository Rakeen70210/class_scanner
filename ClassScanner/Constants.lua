local addonName, CS = ...

CS.NULL_GUID = "0x0000000000000000"

-- Battleground MVP match history (stored in SavedVariables)
CS.BG_MVP_HISTORY_MAX = 200
CS.BG_MVP_HISTORY_DEFAULT_WINDOW = 50

CS.RACES = {
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
    ["Scourge"] = "Horde",
}

CS.STANDARD_CLASS_SPECS = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE = { "Assassination", "Combat", "Subtlety" },
    PRIEST = { "Discipline", "Holy", "Shadow" },
    DEATHKNIGHT = { "Blood", "Frost", "Unholy" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" },
    MAGE = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID = { "Balance", "Feral", "Restoration" },
}

local validSpecNames = {}
for _, specs in pairs(CS.STANDARD_CLASS_SPECS) do
    for _, specName in ipairs(specs) do
        validSpecNames[specName] = true
    end
end
CS.VALID_SPEC_NAMES = validSpecNames

CS.SPEC_SOURCE_PRIORITY = {
    combatlog = 1,
    buff = 2,
    inspect = 3,
    talent = 4,
}

CS.SPEC_SOURCE_CONFIDENCE = {
    combatlog = "low",
    buff = "medium",
    inspect = "high",
    talent = "high",
}

CS.SPEC_STALE_REPLACE_SEC = 3600

CS.SPEC_FILTER_ITEMS = {
    "Arms", "Fury", "Protection",
    "Holy", "Retribution",
    "Beast Mastery", "Marksmanship", "Survival",
    "Assassination", "Combat", "Subtlety",
    "Discipline", "Shadow",
    "Blood", "Frost", "Unholy",
    "Elemental", "Enhancement", "Restoration", "Elemental/Enhancement",
    "Arcane", "Fire",
    "Affliction", "Demonology", "Destruction",
    "Balance", "Feral",
    "Unknown",
}

CS.CLASS_ICON_TCOORDS = {
    ["WARRIOR"] = { 0.000, 0.250, 0.000, 0.250 },
    ["MAGE"] = { 0.250, 0.500, 0.000, 0.250 },
    ["ROGUE"] = { 0.500, 0.750, 0.000, 0.250 },
    ["DRUID"] = { 0.750, 1.000, 0.000, 0.250 },
    ["HUNTER"] = { 0.000, 0.250, 0.250, 0.500 },
    ["SHAMAN"] = { 0.250, 0.500, 0.250, 0.500 },
    ["PRIEST"] = { 0.500, 0.750, 0.250, 0.500 },
    ["WARLOCK"] = { 0.750, 1.000, 0.250, 0.500 },
    ["PALADIN"] = { 0.000, 0.250, 0.500, 0.750 },
    ["DEATHKNIGHT"] = { 0.250, 0.500, 0.500, 0.750 },
}

CS.CLASS_ICON_TEXTURE = "Interface\\WorldStateFrame\\Icons-Classes"

CS.FACTION_ICONS = {
    ["Alliance"] = "Interface\\PVPFrame\\PVP-Currency-Alliance",
    ["Horde"] = "Interface\\PVPFrame\\PVP-Currency-Horde",
}

local function CreateColor(r, g, b, a)
    return { r = r, g = g, b = b, a = a or 1 }
end

CS.COLORS = {
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

CS.SPEC_COLORS = {
    ["Arms"] = CreateColor(0.78, 0.61, 0.43),
    ["Fury"] = CreateColor(0.9, 0.3, 0.3),
    ["Protection"] = CreateColor(0.55, 0.7, 0.92),
    ["Holy"] = CreateColor(1, 0.96, 0.65),
    ["Retribution"] = CreateColor(1, 0.55, 0.2),
    ["Beast Mastery"] = CreateColor(0.67, 0.83, 0.45),
    ["Marksmanship"] = CreateColor(0.39, 0.82, 0.55),
    ["Survival"] = CreateColor(0.29, 0.69, 0.42),
    ["Assassination"] = CreateColor(1, 0.22, 0.53),
    ["Combat"] = CreateColor(1, 0.86, 0.2),
    ["Subtlety"] = CreateColor(0.72, 0.46, 0.93),
    ["Discipline"] = CreateColor(0.75, 0.92, 1),
    ["Shadow"] = CreateColor(0.68, 0.5, 0.95),
    ["Blood"] = CreateColor(0.9, 0.16, 0.16),
    ["Frost"] = CreateColor(0.44, 0.82, 1),
    ["Unholy"] = CreateColor(0.38, 0.86, 0.4),
    ["Elemental"] = CreateColor(0.2, 0.64, 1),
    ["Enhancement"] = CreateColor(0.91, 0.69, 0.24),
    ["Restoration"] = CreateColor(0.18, 0.9, 0.51),
    ["Arcane"] = CreateColor(0.65, 0.52, 1),
    ["Fire"] = CreateColor(1, 0.38, 0.2),
    ["Affliction"] = CreateColor(0.6, 0.41, 0.9),
    ["Demonology"] = CreateColor(0.74, 0.31, 0.92),
    ["Destruction"] = CreateColor(1, 0.27, 0.47),
    ["Balance"] = CreateColor(1, 0.56, 0.73),
    ["Feral"] = CreateColor(1, 0.49, 0.04),
}
