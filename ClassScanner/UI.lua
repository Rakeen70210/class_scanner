local addonName, CS = ...

local CLASS_ICON_TCOORDS = CS.CLASS_ICON_TCOORDS
local CLASS_ICON_TEXTURE = CS.CLASS_ICON_TEXTURE
local COLORS = CS.COLORS
local FACTION_ICONS = CS.FACTION_ICONS
local SPEC_FILTER_ITEMS = CS.SPEC_FILTER_ITEMS

local CanonicalizeClass = CS.CanonicalizeClass
local CanonicalizeRace = CS.CanonicalizeRace
local FormatAgeSeconds = CS.FormatAgeSeconds
local FormatClassMeetBreakdown = CS.FormatClassMeetBreakdown
local FormatDamageNumber = CS.FormatDamageNumber
local FormatMeetWhereFromMet = CS.FormatMeetWhereFromMet
local GetMeetBucketFromMet = CS.GetMeetBucketFromMet
local GetSpecColor = CS.GetSpecColor
local NormalizeSpecName = CS.NormalizeSpecName
local Now = CS.Now

local BG_MVP_HISTORY_DEFAULT_WINDOW = CS.BG_MVP_HISTORY_DEFAULT_WINDOW or 50

local uiFrame
local currentView = "players"
local filterFaction = "All"
local filterRace = "All"
local filterClass = "All"
local filterSpec = "All"
local filterLevel = "All"
local filterLocation = "All"
local filterLevelMin = nil
local filterLevelMax = nil
local currentPage = 1
local itemsPerPage = 100
local searchQuery = ""
local searchDebounceTimer = nil
local sortMode = "most_seen"
local mvpCurrentPage = 1
local mvpItemsPerPage = 10
local mvpWindowSize = BG_MVP_HISTORY_DEFAULT_WINDOW
local dataResetMenu

local function MakeMvpRecordKey(record)
    return tostring(record and record.role or "") .. "|" .. tostring(record and record.playerKey or "")
end

local function MakeMvpHistoryRecordKey(record)
    return tostring(record and record.role or "") .. "|" .. tostring(record and record.matchIndex or "") .. "|" .. tostring(record and record.rank or "")
end

local function GetSortedMvpRecords()
    local records = CS.GetBattlegroundMVPRecords and CS.GetBattlegroundMVPRecords() or {}
    local sorted = { damage = {}, healing = {} }

    for _, record in pairs(records) do
        if type(record) == "table" and (record.role == "damage" or record.role == "healing") then
            table.insert(sorted[record.role], record)
        end
    end

    local function SortRecords(list)
        table.sort(list, function(a, b)
            local valueA = tonumber(a.value or (a.role == "damage" and a.totalDamageDone or a.totalHealingDone)) or 0
            local valueB = tonumber(b.value or (b.role == "damage" and b.totalDamageDone or b.totalHealingDone)) or 0
            if valueA ~= valueB then
                return valueA > valueB
            end
            local tsA = a.recordedAt or 0
            local tsB = b.recordedAt or 0
            if tsA ~= tsB then
                return tsA > tsB
            end
            return MakeMvpRecordKey(a) < MakeMvpRecordKey(b)
        end)
    end

    SortRecords(sorted.damage)
    SortRecords(sorted.healing)
    return sorted
end

local function GetBGMVPHistory()
    local history = CS.GetBattlegroundMVPHistory and CS.GetBattlegroundMVPHistory() or {}
    if type(history) ~= "table" then
        return {}
    end
    return history
end

local function GetBGMVPHistoryWindowed(maxMatches)
    local history = GetBGMVPHistory()
    local out = {}
    local total = #history
    if total <= 0 then return out end

    local n = tonumber(maxMatches)
    if not n or n <= 0 then
        n = total
    end
    if n > total then n = total end

    local startIndex = total - n + 1
    for i = startIndex, total do
        table.insert(out, history[i])
    end
    return out
end

local function BuildBGMVPHistoryWinners(windowedHistory)
    local damage = {}
    local healing = {}
    for idx = 1, #windowedHistory do
        local match = windowedHistory[idx]
        if type(match) == "table" then
            local function AddWinners(role, list, target)
                if type(list) ~= "table" then return end
                for i = 1, math.min(3, #list) do
                    local w = list[i]
                    if type(w) == "table" then
                        table.insert(target, {
                            role = role,
                            matchIndex = idx,
                            match = match,
                            rank = tonumber(w.rank) or i,
                            playerKey = w.playerKey,
                            name = w.name,
                            realm = w.realm,
                            class = w.class,
                            faction = w.faction,
                            spec = w.spec,
                            totalDamageDone = w.totalDamageDone or 0,
                            totalHealingDone = w.totalHealingDone or 0,
                            killingBlows = w.killingBlows or 0,
                            honorableKills = w.honorableKills or 0,
                            deaths = w.deaths or 0,
                            honorGained = w.honorGained or 0,
                            bonusHonor = w.bonusHonor or 0,
                        })
                    end
                end
            end

            AddWinners("damage", match.damageTop, damage)
            AddWinners("healing", match.healingTop, healing)
        end
    end

    local function SortWinners(list)
        table.sort(list, function(a, b)
            local ta = (a.match and a.match.recordedAt) or 0
            local tb = (b.match and b.match.recordedAt) or 0
            if ta ~= tb then
                return ta > tb
            end
            local ra = tonumber(a.rank) or 99
            local rb = tonumber(b.rank) or 99
            if ra ~= rb then
                return ra < rb
            end
            return MakeMvpHistoryRecordKey(a) < MakeMvpHistoryRecordKey(b)
        end)
    end

    SortWinners(damage)
    SortWinners(healing)
    return { damage = damage, healing = healing }
end

local function ComputeBGMVPLeaderboards(windowedHistory)
    local byClass = {
        damage = {},
        healing = {},
    }
    local bySpec = {
        damage = {},
        healing = {},
    }

    local function AddEntry(role, entry, isWin)
        if type(entry) ~= "table" then return end

        local cls = CanonicalizeClass(entry.class) or entry.class or "Unknown"
        local spec = NormalizeSpecName(entry.spec) or "Unknown"
        local value = (role == "damage") and (tonumber(entry.totalDamageDone) or 0) or (tonumber(entry.totalHealingDone) or 0)

        local classBucket = byClass[role]
        if classBucket then
            local c = classBucket[cls]
            if not c then
                c = { key = cls, wins = 0, peak = 0 }
                classBucket[cls] = c
            end
            if isWin then
                c.wins = (c.wins or 0) + 1
            end
            if value > (c.peak or 0) then
                c.peak = value
            end
        end

        if spec ~= "Unknown" then
            local specKey = tostring(cls) .. " / " .. tostring(spec)
            local specBucket = bySpec[role]
            local s = specBucket[specKey]
            if not s then
                s = { key = specKey, wins = 0, peak = 0 }
                specBucket[specKey] = s
            end
            if isWin then
                s.wins = (s.wins or 0) + 1
            end
            if value > (s.peak or 0) then
                s.peak = value
            end
        end
    end

    for i = 1, #windowedHistory do
        local match = windowedHistory[i]
        if type(match) == "table" then
            if type(match.damageTop) == "table" then
                for j = 1, math.min(3, #match.damageTop) do
                    AddEntry("damage", match.damageTop[j], j == 1)
                end
            end
            if type(match.healingTop) == "table" then
                for j = 1, math.min(3, #match.healingTop) do
                    AddEntry("healing", match.healingTop[j], j == 1)
                end
            end
        end
    end

    local function RankBuckets(bucket)
        local ranked = {}
        for _, v in pairs(bucket or {}) do
            table.insert(ranked, v)
        end
        table.sort(ranked, function(a, b)
            local wa = tonumber(a.wins) or 0
            local wb = tonumber(b.wins) or 0
            if wa ~= wb then
                return wa > wb
            end
            local pa = tonumber(a.peak) or 0
            local pb = tonumber(b.peak) or 0
            if pa ~= pb then
                return pa > pb
            end
            return tostring(a.key or "") < tostring(b.key or "")
        end)
        return ranked
    end

    return {
        byClass = {
            damage = RankBuckets(byClass.damage),
            healing = RankBuckets(byClass.healing),
        },
        bySpec = {
            damage = RankBuckets(bySpec.damage),
            healing = RankBuckets(bySpec.healing),
        },
    }
end

local function FormatMvpValue(record)
    if not record then return "0" end
    local value = (record.role == "damage") and (record.totalDamageDone or 0) or (record.totalHealingDone or 0)
    return FormatDamageNumber(value)
end

local function ShowCurrentView()
    if not uiFrame then return end
    local isMvp = (currentView == "bg_mvp")
    local isPlayers = (currentView == "players")

    if uiFrame.mvpOverlay then
        uiFrame.mvpOverlay:SetShown(isMvp)
    end
    if uiFrame.playersOverlay then
        uiFrame.playersOverlay:SetShown(isPlayers)
    end

    if uiFrame.playersTabBtn then
        if isPlayers then
            uiFrame.playersTabBtn:Disable()
        else
            uiFrame.playersTabBtn:Enable()
        end
    end
    if uiFrame.mvpTabBtn then
        if isMvp then
            uiFrame.mvpTabBtn:Disable()
        else
            uiFrame.mvpTabBtn:Enable()
        end
    end
end

local function PrintCS(msg)
    print("|cFF33FF99ClassScanner|r: " .. tostring(msg))
end

local function FormatResetResultMessage(result)
    if not result then
        return "data reset failed."
    end

    if (result.changedCount or 0) <= 0 then
        return "no matching entries found for " .. tostring(result.resultLabel or "that reset") .. "."
    end

    local suffix = ""
    if result.backupId then
        suffix = " (backup #" .. tostring(result.backupId) .. " created)"
    end

    return "reset " .. tostring(result.resultLabel or "data") .. " on " .. tostring(result.changedCount or 0)
        .. " entr" .. ((result.changedCount == 1) and "y" or "ies") .. suffix .. "."
end

local function RunGranularReset(scope)
    if not (CS and CS.ResetGranularData) then
        PrintCS("granular reset API unavailable.")
        return
    end

    local ok, result = CS.ResetGranularData(scope)
    if not ok then
        PrintCS("data reset failed: " .. tostring(result))
        return
    end

    PrintCS(FormatResetResultMessage(result))
    if CS and CS.RefreshUI then
        CS.RefreshUI()
    end
end

if not StaticPopupDialogs["CLASSSCANNER_CONFIRM_DATA_RESET"] then
    StaticPopupDialogs["CLASSSCANNER_CONFIRM_DATA_RESET"] = {
        text = "%s",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function(self, data)
            local scope = data or self.data
            RunGranularReset(scope)
        end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = STATICPOPUP_NUMDIALOGS,
    }
end

local function ShowGranularResetConfirmation(scope)
    if not (CS and CS.DescribeResetScope) then
        PrintCS("reset descriptions unavailable.")
        return
    end

    local descriptor = CS.DescribeResetScope(scope)
    if not descriptor then
        PrintCS("invalid reset scope.")
        return
    end

    StaticPopup_Show("CLASSSCANNER_CONFIRM_DATA_RESET", descriptor.confirmText, nil, descriptor.scope)
end

local function BuildDataResetMenuItems()
    local items = {
        {
            text = "Full Reset",
            notCheckable = true,
            func = function()
                ShowGranularResetConfirmation({ kind = "full_reset" })
            end,
        },
        {
            text = "Reset Top Spec Data",
            notCheckable = true,
            func = function()
                ShowGranularResetConfirmation({ kind = "all_specs" })
            end,
        },
        {
            text = "Reset Battleground Data",
            notCheckable = true,
            func = function()
                ShowGranularResetConfirmation({ kind = "battleground_data" })
            end,
        },
        {
            text = "Reset World Data",
            notCheckable = true,
            func = function()
                ShowGranularResetConfirmation({ kind = "world_data" })
            end,
        },
    }

    if filterClass ~= "All" then
        table.insert(items, {
            text = "Reset Current Class Data (" .. filterClass .. ")",
            notCheckable = true,
            func = function()
                ShowGranularResetConfirmation({
                    kind = "class_value",
                    class = filterClass,
                })
            end,
        })
    end

    if filterSpec ~= "All" and filterSpec ~= "Unknown" then
        table.insert(items, {
            text = "Reset Current Spec Data (" .. filterSpec .. ")",
            notCheckable = true,
            func = function()
                ShowGranularResetConfirmation({
                    kind = "spec_value",
                    spec = filterSpec,
                })
            end,
        })
    end

    return items
end

local function OpenDataResetMenu(anchorFrame)
    if not dataResetMenu then return end
    EasyMenu(BuildDataResetMenuItems(), dataResetMenu, anchorFrame, 0, 0, "MENU", 2)
end

local function UpdateBGMVPList()
    if not uiFrame or not uiFrame.mvpOverlay then return end

    local historyWindowed = GetBGMVPHistoryWindowed(mvpWindowSize)
    local winners = BuildBGMVPHistoryWinners(historyWindowed)
    local damageRecords = winners.damage or {}
    local healingRecords = winners.healing or {}

    local maxRows = math.max(#damageRecords, #healingRecords)
    local totalPages = math.max(1, math.ceil(maxRows / mvpItemsPerPage))
    if mvpCurrentPage < 1 then mvpCurrentPage = 1 end
    if mvpCurrentPage > totalPages then mvpCurrentPage = totalPages end

    local startIndex = ((mvpCurrentPage - 1) * mvpItemsPerPage) + 1
    local endIndex = startIndex + mvpItemsPerPage - 1

    local function Slice(list)
        local out = {}
        for i = startIndex, math.min(endIndex, #list) do
            table.insert(out, list[i])
        end
        return out
    end

    local damagePage = Slice(damageRecords)
    local healingPage = Slice(healingRecords)

    local leaderboards = ComputeBGMVPLeaderboards(historyWindowed)
    if uiFrame.mvpStatCards then
        local function ApplyCard(card, ranked, title)
            if not card then return end
            if card.label then card.label:SetText(title) end
            local top = ranked and ranked[1]
            if top then
                card.value:SetText(tostring(top.key or "None"))
                card.subtext:SetText("Wins: " .. tostring(top.wins or 0) .. " | Peak: " .. FormatDamageNumber(top.peak or 0))
                card.ranked = ranked
            else
                card.value:SetText("None")
                card.subtext:SetText("Wins: 0 | Peak: 0")
                card.ranked = nil
            end
        end

        ApplyCard(uiFrame.mvpStatCards.topDamageClass, leaderboards.byClass.damage, "Top Damage Class")
        ApplyCard(uiFrame.mvpStatCards.topHealingClass, leaderboards.byClass.healing, "Top Healing Class")
        ApplyCard(uiFrame.mvpStatCards.topDamageSpec, leaderboards.bySpec.damage, "Top Damage Spec")
        ApplyCard(uiFrame.mvpStatCards.topHealingSpec, leaderboards.bySpec.healing, "Top Healing Spec")
    end

    local function UpdateSection(section, records, titleText, totalCount)
        if not section then return end
        if section.title then
            section.title:SetText(titleText .. " (" .. tostring(totalCount or #records) .. ")")
        end

        for i, row in ipairs(section.rows or {}) do
            local record = records[i]
            if record then
                local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[record.class]
                local playerName = record.name or "Unknown"
                if record.realm and record.realm ~= "" then
                    playerName = playerName .. "-" .. record.realm
                end

                local rankPrefix = "#" .. tostring(record.rank or "?") .. " "
                row.nameText:SetText(rankPrefix .. playerName)

                if classColor then
                    row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
                else
                    row.nameText:SetTextColor(1, 1, 1)
                end

                local coords = CLASS_ICON_TCOORDS[record.class]
                if coords then
                    row.classIcon:SetTexture(CLASS_ICON_TEXTURE)
                    row.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                    row.classIcon:Show()
                else
                    row.classIcon:Hide()
                end

                local factionIcon = FACTION_ICONS[record.faction]
                if factionIcon then
                    row.factionIcon:SetTexture(factionIcon)
                    row.factionIcon:Show()
                else
                    row.factionIcon:Hide()
                end

                row.specText:SetText(record.spec or "Unknown")
                row.totalText:SetText("D: " .. FormatDamageNumber(record.totalDamageDone or 0) .. "  H: " .. FormatDamageNumber(record.totalHealingDone or 0))

                local kb = tonumber(record.killingBlows) or 0
                local deaths = tonumber(record.deaths) or 0
                local match = record.match or {}
                local age = match.recordedAt and (Now() - match.recordedAt) or nil
                local bgName = match.battlegroundName or "Battleground"
                row.bgText:SetText("KB " .. tostring(kb) .. " / D " .. tostring(deaths) .. "  |  " .. bgName .. " (" .. FormatAgeSeconds(age) .. ")")

                row.recordData = record
                row:Show()
            else
                row:Hide()
            end
        end
    end

    UpdateSection(uiFrame.mvpSections and uiFrame.mvpSections.damage, damagePage, "Top Damage", #damageRecords)
    UpdateSection(uiFrame.mvpSections and uiFrame.mvpSections.healing, healingPage, "Top Healing", #healingRecords)

    local rowHeight = 24
    local sectionTitleHeight = 24
    local sectionGap = 16
    local damageRowsShown = math.max(#damagePage, 1)
    local healingRowsShown = math.max(#healingPage, 1)
    local damageBlockHeight = sectionTitleHeight + (damageRowsShown * rowHeight)
    local healingTopOffset = -10 - damageBlockHeight - sectionGap

    if uiFrame.mvpSections and uiFrame.mvpSections.healing then
        uiFrame.mvpSections.healing:ClearAllPoints()
        uiFrame.mvpSections.healing:SetPoint("TOPLEFT", 0, healingTopOffset)
        uiFrame.mvpSections.healing:SetPoint("TOPRIGHT", 0, healingTopOffset)
    end

    if uiFrame.mvpEmptyText then
        uiFrame.mvpEmptyText:SetShown(#damageRecords == 0 and #healingRecords == 0)
        if #damageRecords == 0 and #healingRecords == 0 then
            uiFrame.mvpEmptyText:SetText("No battleground MVP history recorded yet.")
        else
            uiFrame.mvpEmptyText:SetText("")
        end
    end

    if uiFrame.mvpPageText then
        uiFrame.mvpPageText:SetText("Page " .. mvpCurrentPage .. " / " .. totalPages)
    end
    if uiFrame.mvpPrevBtn then
        if mvpCurrentPage <= 1 then uiFrame.mvpPrevBtn:Disable() else uiFrame.mvpPrevBtn:Enable() end
    end
    if uiFrame.mvpNextBtn then
        if mvpCurrentPage >= totalPages then uiFrame.mvpNextBtn:Disable() else uiFrame.mvpNextBtn:Enable() end
    end

    if uiFrame.mvpContent then
        local totalHeight = 10 + damageBlockHeight + sectionGap + sectionTitleHeight + (healingRowsShown * rowHeight) + 40
        uiFrame.mvpContent:SetHeight(math.max(totalHeight, 260))
    end
end

local function UpdateList()
    if not uiFrame then return end

    if currentView == "bg_mvp" then
        return UpdateBGMVPList()
    end

    local validEntries = {}
    local classCounts = {}
    local classMeetCounts = {}
    local raceCounts = {}
    local specCounts = {}
    local classLevelSums = {}
    local classLevelCounts = {}
    local knownLevelCount = 0
    local levelSum = 0
    local minLevel = nil
    local maxLevel = nil
    local totalCount = 0

    for key, data in pairs(ClassScannerDB or {}) do
        if type(data) == "table" then
            local entryClass = CanonicalizeClass(data.class) or data.class
            if entryClass and entryClass ~= data.class then
                data.class = entryClass
            end

            local show = true

            if filterFaction ~= "All" and data.faction ~= filterFaction then show = false end
            if filterRace ~= "All" and CanonicalizeRace(data.race) ~= filterRace then show = false end
            if filterClass ~= "All" and data.class ~= filterClass then show = false end
            if filterSpec ~= "All" and ((data.spec or "Unknown") ~= filterSpec) then show = false end

            if filterLevel ~= "All" then
                local level = data.level
                if not level then
                    show = false
                else
                    if filterLevel == "80" and level ~= 80 then show = false end
                    if filterLevel == "70-79" and (level < 70 or level > 79) then show = false end
                    if filterLevel == "60-69" and (level < 60 or level > 69) then show = false end
                    if filterLevel == "1-59" and (level < 1 or level > 59) then show = false end
                    if filterLevel == "Custom" then
                        if filterLevelMin and level < filterLevelMin then show = false end
                        if filterLevelMax and level > filterLevelMax then show = false end
                    end
                end
            end

            if filterLocation ~= "All" then
                local bucket = GetMeetBucketFromMet(data.met)
                if filterLocation == "Battleground" then
                    if bucket ~= "Battleground" and not data.seenInBattleground then
                        show = false
                    end
                else
                    if bucket ~= filterLocation then show = false end
                end
            end

            if show and searchQuery and searchQuery ~= "" then
                local sq = searchQuery:lower()
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
                if not (name:find(sq, 1, true) or realm:find(sq, 1, true) or class:find(sq, 1, true) or spec:find(sq, 1, true) or specSource:find(sq, 1, true) or race:find(sq, 1, true) or metStr:find(sq, 1, true) or entryKey:find(sq, 1, true)) then
                    show = false
                end
            end

            if show then
                table.insert(validEntries, { key = key, data = data })
                local classKey = data.class or "Unknown"
                classCounts[classKey] = (classCounts[classKey] or 0) + 1

                local bucket
                if filterLocation == "Battleground" then
                    -- While viewing the BG-only list, treat all visible entries as BG for breakdown/stats.
                    bucket = "Battleground"
                else
                    bucket = GetMeetBucketFromMet(data.met)
                end
                if not classMeetCounts[classKey] then classMeetCounts[classKey] = {} end
                classMeetCounts[classKey][bucket] = (classMeetCounts[classKey][bucket] or 0) + 1

                local raceKey = CanonicalizeRace(data.race) or "Unknown"
                raceCounts[raceKey] = (raceCounts[raceKey] or 0) + 1

                local specName = NormalizeSpecName(data.spec)
                if specName and specName ~= "Unknown" then
                    specCounts[specName] = (specCounts[specName] or 0) + 1
                end

                local level = data.level
                if level and level > 0 then
                    knownLevelCount = knownLevelCount + 1
                    levelSum = levelSum + level
                    if (not minLevel) or (level < minLevel) then minLevel = level end
                    if (not maxLevel) or (level > maxLevel) then maxLevel = level end

                    classLevelSums[classKey] = (classLevelSums[classKey] or 0) + level
                    classLevelCounts[classKey] = (classLevelCounts[classKey] or 0) + 1
                end

                totalCount = totalCount + 1
            end
        end
    end

    local mostDetectedClass = "None"
    local maxCount = 0
    for classKey, count in pairs(classCounts) do
        if count > maxCount then
            maxCount = count
            mostDetectedClass = classKey
        end
    end

    local mostPlayedRace = "None"
    local maxRaceCount = 0
    for raceKey, count in pairs(raceCounts) do
        if count > maxRaceCount then
            maxRaceCount = count
            mostPlayedRace = raceKey
        end
    end

    local topBGClass = "None"
    local maxBGCount = 0
    local bgBreakdown = {}
    local bgClassCounts = {}
    for _, entry in ipairs(validEntries) do
        local data = entry.data
        if data.seenInBattleground then
            local classKey = data.class or "Unknown"
            bgClassCounts[classKey] = (bgClassCounts[classKey] or 0) + 1
        end
    end
    for classKey, count in pairs(bgClassCounts) do
        table.insert(bgBreakdown, { cls = classKey, count = count })
        if count > maxBGCount then
            maxBGCount = count
            topBGClass = classKey
        end
    end
    table.sort(bgBreakdown, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return (a.cls or "") < (b.cls or "")
    end)

    local topBGBurstClass = "None"
    local topBGBurstDps = 0
    local bgBurstBreakdown = {}
    local bgBurstByClass = {}

    for _, entry in ipairs(validEntries) do
        local data = entry.data
        local burst = data.combat and data.combat.maxBurstDps
        local burstDps = burst and burst.dps or 0
        if data.seenInBattleground and burstDps > 0 then
            local classKey = data.class or "Unknown"
            local displayName = data.name or entry.key
            if data.realm and data.realm ~= "" then
                displayName = displayName .. "-" .. data.realm
            end

            local existing = bgBurstByClass[classKey]
            if (not existing) or (burstDps > existing.dps) then
                bgBurstByClass[classKey] = {
                    cls = classKey,
                    dps = burstDps,
                    player = displayName,
                    windowSec = burst.windowSec,
                }
            end
        end
    end

    for _, item in pairs(bgBurstByClass) do
        table.insert(bgBurstBreakdown, item)
    end
    table.sort(bgBurstBreakdown, function(a, b)
        if a.dps ~= b.dps then
            return a.dps > b.dps
        end
        return (a.cls or "") < (b.cls or "")
    end)
    if #bgBurstBreakdown > 0 then
        topBGBurstClass = bgBurstBreakdown[1].cls or "None"
        topBGBurstDps = bgBurstBreakdown[1].dps or 0
    end

    local topSpec = "None"
    local maxSpecCount = 0
    local specBreakdown = {}
    for specName, count in pairs(specCounts) do
        table.insert(specBreakdown, { spec = specName, count = count })
        if count > maxSpecCount then
            maxSpecCount = count
            topSpec = specName
        end
    end
    table.sort(specBreakdown, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.spec < b.spec
    end)

    local avgLevel = nil
    if knownLevelCount > 0 then
        avgLevel = levelSum / knownLevelCount
    end

    local classCountList = {}
    for classKey, count in pairs(classCounts) do
        table.insert(classCountList, { cls = classKey, count = count })
    end
    table.sort(classCountList, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        if a.cls == "Unknown" and b.cls ~= "Unknown" then return false end
        if b.cls == "Unknown" and a.cls ~= "Unknown" then return true end
        return (a.cls or "") < (b.cls or "")
    end)

    if sortMode == "most_damage" then
        table.sort(validEntries, function(a, b)
            local damageA = a.data.combat and a.data.combat.totalDamageToMe or 0
            local damageB = b.data.combat and b.data.combat.totalDamageToMe or 0
            if damageA ~= damageB then return damageA > damageB end
            return (a.data.name or a.key) < (b.data.name or b.key)
        end)
    elseif sortMode == "hardest_hit" then
        table.sort(validEntries, function(a, b)
            local hitA = a.data.combat and a.data.combat.maxHit and a.data.combat.maxHit.amount or 0
            local hitB = b.data.combat and b.data.combat.maxHit and b.data.combat.maxHit.amount or 0
            if hitA ~= hitB then return hitA > hitB end
            return (a.data.name or a.key) < (b.data.name or b.key)
        end)
    elseif sortMode == "max_burst" then
        table.sort(validEntries, function(a, b)
            local burstA = a.data.combat and a.data.combat.maxBurstDps and a.data.combat.maxBurstDps.dps or 0
            local burstB = b.data.combat and b.data.combat.maxBurstDps and b.data.combat.maxBurstDps.dps or 0
            if burstA ~= burstB then return burstA > burstB end
            return (a.data.name or a.key) < (b.data.name or b.key)
        end)
    else
        table.sort(validEntries, function(a, b)
            local dataA, dataB = a.data, b.data
            local classA = dataA.class or "Unknown"
            local classB = dataB.class or "Unknown"
            local countA = classCounts[classA] or 0
            local countB = classCounts[classB] or 0

            if countA ~= countB then
                return countA > countB
            end
            if classA ~= classB then
                return classA < classB
            end

            local seenA, seenB = (dataA.seen or 0), (dataB.seen or 0)
            if seenA ~= seenB then
                return seenA > seenB
            end

            local nameA, nameB = (dataA.name or a.key), (dataB.name or b.key)
            return nameA < nameB
        end)
    end

    local totalPages = math.ceil(#validEntries / itemsPerPage)
    if totalPages < 1 then totalPages = 1 end
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1 then currentPage = 1 end

    local startIndex = (currentPage - 1) * itemsPerPage + 1
    local endIndex = math.min(startIndex + itemsPerPage - 1, #validEntries)

    if uiFrame.prevBtn then
        if currentPage <= 1 then uiFrame.prevBtn:Disable() else uiFrame.prevBtn:Enable() end
        if currentPage >= totalPages then uiFrame.nextBtn:Disable() else uiFrame.nextBtn:Enable() end
        uiFrame.pageText:SetText("Page " .. currentPage .. " / " .. totalPages)
    end

    if uiFrame.playerCountText then
        uiFrame.playerCountText:SetText(totalCount .. " players")
    end

    if uiFrame.statCards then
        uiFrame.statCards.total.value:SetText(totalCount)

        local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[mostDetectedClass]
        if classColor then
            uiFrame.statCards.mostClass.value:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            uiFrame.statCards.mostClass.value:SetTextColor(1, 1, 1)
        end
        uiFrame.statCards.mostClass.value:SetText(mostDetectedClass)
        uiFrame.statCards.mostClass.subtext:SetText("(" .. maxCount .. " players)")

        uiFrame.statCards.mostRace.value:SetText(mostPlayedRace)
        uiFrame.statCards.mostRace.subtext:SetText("(" .. maxRaceCount .. " players)")

        local bgClassColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[topBGClass]
        if bgClassColor then
            uiFrame.statCards.topBGClass.value:SetTextColor(bgClassColor.r, bgClassColor.g, bgClassColor.b)
        else
            uiFrame.statCards.topBGClass.value:SetTextColor(1, 1, 1)
        end
        uiFrame.statCards.topBGClass.value:SetText(topBGClass)
        uiFrame.statCards.topBGClass.subtext:SetText("(" .. maxBGCount .. " in BG)")
        uiFrame.statCards.topBGClass.bgBreakdown = bgBreakdown

        if uiFrame.statCards.topBGBurst then
            local bgBurstColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[topBGBurstClass]
            if bgBurstColor then
                uiFrame.statCards.topBGBurst.value:SetTextColor(bgBurstColor.r, bgBurstColor.g, bgBurstColor.b)
            else
                uiFrame.statCards.topBGBurst.value:SetTextColor(1, 1, 1)
            end
            uiFrame.statCards.topBGBurst.value:SetText(topBGBurstClass)
            if topBGBurstDps > 0 then
                uiFrame.statCards.topBGBurst.subtext:SetText(FormatDamageNumber(topBGBurstDps) .. " DPS")
            else
                uiFrame.statCards.topBGBurst.subtext:SetText("No burst data")
            end
            uiFrame.statCards.topBGBurst.bgBurstBreakdown = bgBurstBreakdown
        end

        if uiFrame.statCards.topSpec then
            local specR, specG, specB = GetSpecColor(topSpec)
            uiFrame.statCards.topSpec.value:SetTextColor(specR, specG, specB)
            uiFrame.statCards.topSpec.value:SetText(topSpec)
            uiFrame.statCards.topSpec.subtext:SetText("(" .. maxSpecCount .. " players)")
            uiFrame.statCards.topSpec.specBreakdown = specBreakdown
        end

        if avgLevel then
            uiFrame.statCards.levelSpread.value:SetText(string.format("%.1f", avgLevel))
            uiFrame.statCards.levelSpread.subtext:SetText((minLevel or "?") .. "-" .. (maxLevel or "?") .. " range")
        else
            uiFrame.statCards.levelSpread.value:SetText("?")
            uiFrame.statCards.levelSpread.subtext:SetText("No level data")
        end
    end

    if uiFrame.classBar and totalCount > 0 then
        local barWidth = uiFrame.classBar:GetWidth()
        local xOffset = 0

        for _, segment in ipairs(uiFrame.classBar.segments) do
            segment:Hide()
        end

        for i, item in ipairs(classCountList) do
            local segment = uiFrame.classBar.segments[i]
            if segment and item.count > 0 then
                local pct = item.count / totalCount
                local segWidth = math.max(barWidth * pct, 2)
                segment:SetPoint("LEFT", uiFrame.classBar, "LEFT", xOffset, 0)
                segment:SetWidth(segWidth)
                segment:SetHeight(uiFrame.classBar:GetHeight())

                local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[item.cls]
                if classColor then
                    segment.texture:SetColorTexture(classColor.r, classColor.g, classColor.b, 1)
                else
                    segment.texture:SetColorTexture(0.5, 0.5, 0.5, 1)
                end

                segment.classInfo = { cls = item.cls, count = item.count, pct = pct * 100 }
                segment:Show()
                xOffset = xOffset + segWidth
            end
        end

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
        for _, segment in ipairs(uiFrame.classBar.segments) do
            segment:Hide()
        end
        if uiFrame.classLegend then
            uiFrame.classLegend:SetText("")
        end
    end

    if uiFrame.playerRows then
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

                if sortMode == "most_seen" and currentClass ~= lastClass then
                    rowIndex = rowIndex + 1
                    local row = uiFrame.playerRows[rowIndex]
                    if row then
                        row.isHeader = true
                        row.bg:SetColorTexture(COLORS.headerBg.r, COLORS.headerBg.g, COLORS.headerBg.b, COLORS.headerBg.a)

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

                        local knownCount = classLevelCounts[currentClass] or 0
                        if knownCount > 0 then
                            local classAvg = (classLevelSums[currentClass] or 0) / knownCount
                            row.infoText:SetText("Avg Level: " .. string.format("%.1f", classAvg))
                        else
                            row.infoText:SetText("")
                        end
                        row.infoText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

                        if row.metText then
                            row.metText:SetText(FormatClassMeetBreakdown(classMeetCounts[currentClass]))
                            row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                        end

                        row.levelText:SetText("")
                        row.ageText:SetText("")
                        row.playerData = nil
                        row.headerClass = currentClass
                        row.headerMeetCounts = classMeetCounts[currentClass]
                        row:Show()
                    end
                    lastClass = currentClass
                end

                rowIndex = rowIndex + 1
                local row = uiFrame.playerRows[rowIndex]
                if row then
                    row.isHeader = false

                    if rowIndex % 2 == 0 then
                        row.bg:SetColorTexture(COLORS.rowEven.r, COLORS.rowEven.g, COLORS.rowEven.b, COLORS.rowEven.a)
                    else
                        row.bg:SetColorTexture(COLORS.rowOdd.r, COLORS.rowOdd.g, COLORS.rowOdd.b, COLORS.rowOdd.a)
                    end

                    local coords = CLASS_ICON_TCOORDS[data.class]
                    if coords then
                        row.classIcon:SetTexture(CLASS_ICON_TEXTURE)
                        row.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                        row.classIcon:Show()
                    else
                        row.classIcon:Hide()
                    end

                    local factionIcon = FACTION_ICONS[data.faction]
                    if factionIcon then
                        row.factionIcon:SetTexture(factionIcon)
                        row.factionIcon:Show()
                    else
                        row.factionIcon:Hide()
                    end

                    if data.level and data.level > 0 then
                        row.levelText:SetText(data.level)
                        row.levelText:SetTextColor(COLORS.gold.r, COLORS.gold.g, COLORS.gold.b)
                    else
                        row.levelText:SetText("??")
                        row.levelText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                    end

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

                    local raceText = CanonicalizeRace(data.race) or "Unknown"
                    local specText = data.spec or "Unknown"
                    row.infoText:SetText(raceText .. " - " .. specText)
                    row.infoText:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)

                    if row.metText then
                        if sortMode == "most_damage" then
                            local combat = data.combat
                            if combat and combat.totalDamageToMe and combat.totalDamageToMe > 0 then
                                row.metText:SetText("Dmg: " .. FormatDamageNumber(combat.totalDamageToMe))
                                row.metText:SetTextColor(1, 0.3, 0.3)
                            else
                                row.metText:SetText("No damage")
                                row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                            end
                        elseif sortMode == "hardest_hit" then
                            local combat = data.combat
                            if combat and combat.maxHit and combat.maxHit.amount and combat.maxHit.amount > 0 then
                                local maxHit = combat.maxHit
                                local text = FormatDamageNumber(maxHit.amount)
                                if maxHit.spellName then text = text .. " (" .. maxHit.spellName .. ")" end
                                if maxHit.critical then text = text .. " crit" end
                                row.metText:SetText(text)
                                row.metText:SetTextColor(1, 0.3, 0.3)
                            else
                                row.metText:SetText("No hits")
                                row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                            end
                        elseif sortMode == "max_burst" then
                            local combat = data.combat
                            if combat and combat.maxBurstDps and combat.maxBurstDps.dps and combat.maxBurstDps.dps > 0 then
                                row.metText:SetText(FormatDamageNumber(combat.maxBurstDps.dps) .. " DPS")
                                row.metText:SetTextColor(1, 0.3, 0.3)
                            else
                                row.metText:SetText("No burst")
                                row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                            end
                        else
                            row.metText:SetText(FormatMeetWhereFromMet(data.met))
                            row.metText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
                        end
                    end

                    local age = data.seen and (Now() - data.seen) or nil
                    row.ageText:SetText(FormatAgeSeconds(age))
                    row.ageText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

                    row.playerData = data
                    row:Show()
                end
            end
        end
    end

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

local function RefreshUI()
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
        uiFrame = CreateFrame("Frame", "ClassScannerFrame", UIParent, "BackdropTemplate")
        uiFrame:SetWidth(720)
        uiFrame:SetHeight(680)
        uiFrame:SetPoint("CENTER")
        uiFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        uiFrame:SetBackdropColor(COLORS.background.r, COLORS.background.g, COLORS.background.b, COLORS.background.a)
        uiFrame:SetBackdropBorderColor(0.3, 0.3, 0.4, 0.8)
        uiFrame:EnableMouse(true)
        uiFrame:SetMovable(true)
        uiFrame:RegisterForDrag("LeftButton")
        uiFrame:SetScript("OnDragStart", uiFrame.StartMoving)
        uiFrame:SetScript("OnDragStop", uiFrame.StopMovingOrSizing)
        uiFrame:SetFrameStrata("HIGH")

        dataResetMenu = CreateFrame("Frame", "ClassScannerDataResetMenu", uiFrame, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(dataResetMenu, function() end, "MENU")

        local header = CreateFrame("Frame", nil, uiFrame, "BackdropTemplate")
        header:SetHeight(40)
        header:SetPoint("TOPLEFT", 0, 0)
        header:SetPoint("TOPRIGHT", 0, 0)
        header:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = nil,
        })
        header:SetBackdropColor(COLORS.headerBg.r, COLORS.headerBg.g, COLORS.headerBg.b, 1)

        local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("LEFT", 15, 0)
        title:SetText("ClassScanner")
        title:SetTextColor(COLORS.accent.r, COLORS.accent.g, COLORS.accent.b)

        local playersTabBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
        playersTabBtn:SetSize(72, 22)
        playersTabBtn:SetPoint("LEFT", title, "RIGHT", 16, 0)
        playersTabBtn:SetText("Players")
        playersTabBtn:SetScript("OnClick", function()
            currentView = "players"
            ShowCurrentView()
            UpdateList()
        end)

        local mvpTabBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
        mvpTabBtn:SetSize(72, 22)
        mvpTabBtn:SetPoint("LEFT", playersTabBtn, "RIGHT", 6, 0)
        mvpTabBtn:SetText("BG MVP")
        mvpTabBtn:SetScript("OnClick", function()
            currentView = "bg_mvp"
            mvpCurrentPage = 1
            ShowCurrentView()
            UpdateList()
        end)

        uiFrame.playersTabBtn = playersTabBtn
        uiFrame.mvpTabBtn = mvpTabBtn

        local closeBtn = CreateFrame("Button", nil, header)
        closeBtn:SetSize(30, 30)
        closeBtn:SetPoint("TOPRIGHT", -5, -5)
        closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
        closeBtn:SetScript("OnClick", function()
            uiFrame:Hide()
        end)

        local playersOverlay = CreateFrame("Frame", nil, uiFrame)
        playersOverlay:SetPoint("TOPLEFT", 0, -40)
        playersOverlay:SetPoint("BOTTOMRIGHT", 0, 0)
        uiFrame.playersOverlay = playersOverlay

        local statsContainer = CreateFrame("Frame", nil, playersOverlay)
        statsContainer:SetHeight(70)
        statsContainer:SetPoint("TOPLEFT", 10, -50)
        statsContainer:SetPoint("TOPRIGHT", -10, -50)

        uiFrame.statCards = {}

        local function CreateStatCard(parent, xOffset, label)
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetSize(99, 60)
            card:SetPoint("LEFT", parent, "LEFT", xOffset, 0)
            card:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                tile = false,
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 },
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
        uiFrame.statCards.mostClass = CreateStatCard(statsContainer, 100, "Most Detected")
        uiFrame.statCards.mostRace = CreateStatCard(statsContainer, 200, "Top Race")

        uiFrame.statCards.topBGClass = CreateStatCard(statsContainer, 300, "Most Seen In BG")
        uiFrame.statCards.topBGClass:EnableMouse(true)
        uiFrame.statCards.topBGClass:SetScript("OnEnter", function(self)
            if self.bgBreakdown and #self.bgBreakdown > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine("Ever Seen In BG", 1, 1, 1)
                for _, item in ipairs(self.bgBreakdown) do
                    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[item.cls]
                    local r, g, b = 1, 1, 1
                    if classColor then r, g, b = classColor.r, classColor.g, classColor.b end
                    GameTooltip:AddDoubleLine(item.cls, tostring(item.count), r, g, b, 1, 1, 1)
                end
                GameTooltip:Show()
            end
        end)
        uiFrame.statCards.topBGClass:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        uiFrame.statCards.topBGBurst = CreateStatCard(statsContainer, 400, "Top BG Burst")
        uiFrame.statCards.topBGBurst:EnableMouse(true)
        uiFrame.statCards.topBGBurst:SetScript("OnEnter", function(self)
            if self.bgBurstBreakdown and #self.bgBurstBreakdown > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine("BG Burst by Class", 1, 1, 1)
                for i = 1, math.min(10, #self.bgBurstBreakdown) do
                    local item = self.bgBurstBreakdown[i]
                    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[item.cls]
                    local r, g, b = 1, 1, 1
                    if classColor then r, g, b = classColor.r, classColor.g, classColor.b end
                    GameTooltip:AddDoubleLine(item.cls, FormatDamageNumber(item.dps) .. " DPS", r, g, b, 1, 1, 1)
                    GameTooltip:AddLine("  " .. tostring(item.player or "Unknown") .. " (" .. tostring(item.windowSec or 3) .. "s)", 0.75, 0.75, 0.75)
                end
                GameTooltip:Show()
            end
        end)
        uiFrame.statCards.topBGBurst:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        uiFrame.statCards.topSpec = CreateStatCard(statsContainer, 500, "Top Spec")
        uiFrame.statCards.topSpec:EnableMouse(true)
        uiFrame.statCards.topSpec:SetScript("OnEnter", function(self)
            if self.specBreakdown and #self.specBreakdown > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine("Spec Breakdown", 1, 1, 1)
                for _, item in ipairs(self.specBreakdown) do
                    local r, g, b = GetSpecColor(item.spec)
                    GameTooltip:AddDoubleLine(item.spec, tostring(item.count), r, g, b, r, g, b)
                end
                GameTooltip:Show()
            end
        end)
        uiFrame.statCards.topSpec:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        uiFrame.statCards.topSpec:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                ShowGranularResetConfirmation({ kind = "all_specs" })
            end
        end)

        uiFrame.statCards.levelSpread = CreateStatCard(statsContainer, 600, "Avg Level")
        uiFrame.statCards.levelSpread.value:SetTextColor(COLORS.gold.r, COLORS.gold.g, COLORS.gold.b)

        local classBarLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classBarLabel:SetPoint("TOPLEFT", 15, -130)
        classBarLabel:SetText("Class Distribution")
        classBarLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)

        local classBar = CreateFrame("Frame", nil, playersOverlay, "BackdropTemplate")
        classBar:SetHeight(16)
        classBar:SetPoint("TOPLEFT", 15, -148)
        classBar:SetPoint("TOPRIGHT", -15, -148)
        classBar:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = nil,
        })
        classBar:SetBackdropColor(0.15, 0.15, 0.2, 1)
        uiFrame.classBar = classBar

        classBar.segments = {}
        for i = 1, 12 do
            local segment = CreateFrame("Frame", nil, classBar)
            segment:SetHeight(16)
            segment.texture = segment:CreateTexture(nil, "ARTWORK")
            segment.texture:SetAllPoints()
            segment:EnableMouse(true)
            segment:SetScript("OnEnter", function(self)
                if self.classInfo then
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine(self.classInfo.cls, 1, 1, 1)
                    GameTooltip:AddLine(string.format("%d players (%.1f%%)", self.classInfo.count, self.classInfo.pct), 0.7, 0.7, 0.7)
                    GameTooltip:Show()
                end
            end)
            segment:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            segment:Hide()
            classBar.segments[i] = segment
        end

        local classLegend = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLegend:SetPoint("TOPLEFT", 15, -170)
        classLegend:SetWidth(uiFrame:GetWidth() - 30)
        classLegend:SetWordWrap(true)
        classLegend:SetJustifyH("LEFT")
        classLegend:SetText("")
        uiFrame.classLegend = classLegend

        local factionDropdown = CreateDropdown("ClassScannerFactionDropdown", playersOverlay, { "Alliance", "Horde" }, function(val)
            filterFaction = val
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        factionDropdown:SetPoint("TOPLEFT", -5, -205)
        UIDropDownMenu_SetWidth(factionDropdown, 90)
        local factionLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        factionLabel:SetPoint("BOTTOM", factionDropdown, "TOP", 0, 2)
        factionLabel:SetText("Faction")
        factionLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        factionLabel:SetJustifyH("CENTER")
        factionLabel:SetWidth((factionDropdown:GetWidth() and factionDropdown:GetWidth()) or 90)

        local raceDropdown = CreateDropdown("ClassScannerRaceDropdown", playersOverlay, { "Human", "Dwarf", "Night Elf", "Gnome", "Draenei", "Orc", "Undead", "Tauren", "Troll", "Blood Elf" }, function(val)
            filterRace = val
            UIDropDownMenu_SetText(ClassScannerRaceDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        raceDropdown:SetPoint("LEFT", factionDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(raceDropdown, 90)
        local raceLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        raceLabel:SetPoint("BOTTOM", raceDropdown, "TOP", 0, 2)
        raceLabel:SetText("Race")
        raceLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        raceLabel:SetJustifyH("CENTER")
        raceLabel:SetWidth((raceDropdown:GetWidth() and raceDropdown:GetWidth()) or 90)

        local classDropdown = CreateDropdown("ClassScannerClassDropdown", playersOverlay, { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }, function(val)
            filterClass = val
            UIDropDownMenu_SetText(ClassScannerClassDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        classDropdown:SetPoint("LEFT", raceDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(classDropdown, 100)
        local classLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLabel:SetPoint("BOTTOM", classDropdown, "TOP", 0, 2)
        classLabel:SetText("Class")
        classLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        classLabel:SetJustifyH("CENTER")
        classLabel:SetWidth((classDropdown:GetWidth() and classDropdown:GetWidth()) or 100)

        local specDropdown = CreateDropdown("ClassScannerSpecDropdown", playersOverlay, SPEC_FILTER_ITEMS, function(val)
            filterSpec = val
            UIDropDownMenu_SetText(ClassScannerSpecDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        specDropdown:SetPoint("LEFT", classDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(specDropdown, 100)
        local specLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        specLabel:SetPoint("BOTTOM", specDropdown, "TOP", 0, 2)
        specLabel:SetText("Spec")
        specLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        specLabel:SetJustifyH("CENTER")
        specLabel:SetWidth((specDropdown:GetWidth() and specDropdown:GetWidth()) or 100)

        local levelDropdown = CreateDropdown("ClassScannerLevelDropdown", playersOverlay, { "80", "70-79", "60-69", "1-59", "Custom" }, function(val)
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
        levelDropdown:SetPoint("TOPLEFT", -5, -260)
        UIDropDownMenu_SetWidth(levelDropdown, 90)
        local levelLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelLabel:SetPoint("BOTTOM", levelDropdown, "TOP", 0, 2)
        levelLabel:SetText("Level")
        levelLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        levelLabel:SetJustifyH("CENTER")
        levelLabel:SetWidth((levelDropdown:GetWidth() and levelDropdown:GetWidth()) or 90)

        local locationDropdown = CreateDropdown("ClassScannerLocationDropdown", playersOverlay, { "World", "Dungeon", "Raid", "Battleground", "Arena", "Instance", "Unknown" }, function(val)
            filterLocation = val
            UIDropDownMenu_SetText(ClassScannerLocationDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        locationDropdown:SetPoint("LEFT", levelDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(locationDropdown, 90)
        local locationLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        locationLabel:SetPoint("BOTTOM", locationDropdown, "TOP", 0, 2)
        locationLabel:SetText("Location")
        locationLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        locationLabel:SetJustifyH("CENTER")
        locationLabel:SetWidth((locationDropdown:GetWidth() and locationDropdown:GetWidth()) or 90)

        local resetBtn = CreateFrame("Button", nil, playersOverlay, "UIPanelButtonTemplate")
        resetBtn:SetSize(70, 22)
        resetBtn:SetPoint("LEFT", locationDropdown, "RIGHT", 0, 2)
        resetBtn:SetText("Reset")
        resetBtn:SetScript("OnClick", function()
            filterFaction = "All"
            filterRace = "All"
            filterClass = "All"
            filterSpec = "All"
            filterLevel = "All"
            filterLocation = "All"
            filterLevelMin = nil
            filterLevelMax = nil
            searchQuery = ""
            currentPage = 1
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerRaceDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerClassDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerSpecDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerLevelDropdown, "All")
            UIDropDownMenu_SetText(ClassScannerLocationDropdown, "All")
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
            sortMode = "most_seen"
            if uiFrame.sortDropdown then
                UIDropDownMenu_SetText(uiFrame.sortDropdown, "Most Seen")
            end
            UpdateList()
        end)

        local dataResetBtn = CreateFrame("Button", nil, playersOverlay, "UIPanelButtonTemplate")
        dataResetBtn:SetSize(90, 22)
        dataResetBtn:SetPoint("LEFT", resetBtn, "RIGHT", 5, 0)
        dataResetBtn:SetText("Data Reset")
        dataResetBtn:SetScript("OnClick", function(self)
            OpenDataResetMenu(self)
        end)

        local backupBtn = CreateFrame("Button", nil, playersOverlay, "UIPanelButtonTemplate")
        backupBtn:SetSize(70, 22)
        backupBtn:SetPoint("LEFT", dataResetBtn, "RIGHT", 5, 0)
        backupBtn:SetText("Backup")
        backupBtn:SetScript("OnClick", function()
            if CS and CS.CreateBackup then
                local id, entry = CS.CreateBackup("ui")
                print("|cFF33FF99ClassScanner|r: backup #" .. tostring(id) .. " created (players=" .. tostring(entry and entry.playerCount or "?") .. ")")
            else
                print("|cFF33FF99ClassScanner|r: backup unavailable")
            end
        end)

        local levelRangeLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelRangeLabel:SetPoint("TOPLEFT", 20, -295)
        levelRangeLabel:SetText("Level Range:")
        levelRangeLabel:Hide()
        uiFrame.levelRangeLabel = levelRangeLabel

        local sortDropdown = CreateFrame("Frame", "ClassScannerSortDropdown", playersOverlay, "UIDropDownMenuTemplate")
        local sortItems = { "Most Seen", "Most Damage", "Hardest Hit", "Max Burst DPS" }
        local sortModeMap = {
            ["Most Seen"] = "most_seen",
            ["Most Damage"] = "most_damage",
            ["Hardest Hit"] = "hardest_hit",
            ["Max Burst DPS"] = "max_burst",
        }
        local function SortOnClick(self)
            UIDropDownMenu_SetSelectedID(sortDropdown, self:GetID())
            sortMode = sortModeMap[self.value] or "most_seen"
            UIDropDownMenu_SetText(sortDropdown, self.value)
            currentPage = 1
            UpdateList()
        end
        UIDropDownMenu_Initialize(sortDropdown, function(self, level)
            local info = UIDropDownMenu_CreateInfo()
            info.func = SortOnClick
            for _, item in ipairs(sortItems) do
                info.text = item
                info.value = item
                info.checked = (item == "Most Seen")
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetWidth(sortDropdown, 100)
        UIDropDownMenu_SetButtonWidth(sortDropdown, 140)
        UIDropDownMenu_JustifyText(sortDropdown, "LEFT")
        UIDropDownMenu_SetText(sortDropdown, "Most Seen")
        sortDropdown:SetPoint("LEFT", backupBtn, "RIGHT", 5, -2)
        local sortLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sortLabel:SetPoint("BOTTOM", sortDropdown, "TOP", 0, 2)
        sortLabel:SetText("Sort")
        sortLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        sortLabel:SetJustifyH("CENTER")
        uiFrame.sortDropdown = sortDropdown

        local levelMinBox = CreateFrame("EditBox", "ClassScannerLevelMinBox", playersOverlay, "InputBoxTemplate")
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

        local levelDash = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelDash:SetPoint("LEFT", levelMinBox, "RIGHT", 3, 0)
        levelDash:SetText("-")
        levelDash:Hide()
        uiFrame.levelDash = levelDash

        local levelMaxBox = CreateFrame("EditBox", "ClassScannerLevelMaxBox", playersOverlay, "InputBoxTemplate")
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

        local searchLabel = playersOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        searchLabel:SetPoint("TOPLEFT", 20, -295)
        searchLabel:SetText("Search:")
        searchLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        uiFrame.searchLabel = searchLabel

        local searchBox = CreateFrame("EditBox", "ClassScannerSearchBox", playersOverlay, "InputBoxTemplate")
        searchBox:SetSize(220, 22)
        searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
        searchBox:SetAutoFocus(false)
        searchBox:SetScript("OnEnterPressed", function(self)
            local text = self:GetText() or ""
            searchQuery = text:match("^%s*(.-)%s*$")
            self:ClearFocus()
            currentPage = 1
            UpdateList()
        end)
        searchBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        searchBox:SetScript("OnTextChanged", function(self)
            local text = self:GetText() or ""
            searchQuery = text:match("^%s*(.-)%s*$")
            currentPage = 1
            if searchDebounceTimer then
                searchDebounceTimer:Cancel()
                searchDebounceTimer = nil
            end
            searchDebounceTimer = C_Timer.NewTimer(0.25, function()
                UpdateList()
                searchDebounceTimer = nil
            end)
        end)
        uiFrame.searchBox = searchBox

        local scrollFrame = CreateFrame("ScrollFrame", "ClassScannerScrollFrame", playersOverlay, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 10, -320)
        scrollFrame:SetPoint("BOTTOMRIGHT", -30, 50)

        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetWidth(scrollFrame:GetWidth() - 20)
        content:SetHeight(1)
        scrollFrame:SetScrollChild(content)
        uiFrame.content = content

        uiFrame.playerRows = {}
        local ROW_HEIGHT = 24
        local MAX_ROWS = 150

        local function CreatePlayerRow(index)
            local row = CreateFrame("Frame", nil, content)
            row:SetHeight(ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
            row:SetPoint("TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(0, 0, 0, 0)

            row.classIcon = row:CreateTexture(nil, "ARTWORK")
            row.classIcon:SetSize(18, 18)
            row.classIcon:SetPoint("LEFT", 5, 0)

            row.factionIcon = row:CreateTexture(nil, "ARTWORK")
            row.factionIcon:SetSize(14, 14)
            row.factionIcon:SetPoint("LEFT", row.classIcon, "RIGHT", 4, 0)

            row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.levelText:SetWidth(30)
            row.levelText:SetPoint("LEFT", row.factionIcon, "RIGHT", 4, 0)
            row.levelText:SetJustifyH("CENTER")

            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameText:SetWidth(180)
            row.nameText:SetPoint("LEFT", row.levelText, "RIGHT", 8, 0)
            row.nameText:SetJustifyH("LEFT")

            row.infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.infoText:SetWidth(140)
            row.infoText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
            row.infoText:SetJustifyH("LEFT")

            row.metText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.metText:SetPoint("LEFT", row.infoText, "RIGHT", 10, 0)
            row.metText:SetJustifyH("LEFT")

            row.ageText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.ageText:SetWidth(50)
            row.ageText:SetPoint("RIGHT", -10, 0)
            row.ageText:SetJustifyH("RIGHT")

            row.metText:ClearAllPoints()
            row.metText:SetPoint("LEFT", row.infoText, "RIGHT", 10, 0)
            row.metText:SetPoint("RIGHT", row.ageText, "LEFT", -10, 0)
            row.metText:SetJustifyH("LEFT")

            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if self.isHeader and self.headerClass then
                    self.bg:SetColorTexture(COLORS.rowHover.r, COLORS.rowHover.g, COLORS.rowHover.b, COLORS.rowHover.a)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(self.headerClass .. " — First Met Breakdown", 1, 1, 1)
                    GameTooltip:AddLine(" ")

                    local counts = self.headerMeetCounts or {}
                    local function Add(label, value)
                        GameTooltip:AddDoubleLine(label, tostring(value or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                    end

                    Add("World", counts.World)
                    Add("Dungeon", counts.Dungeon)
                    Add("Battleground", counts.Battleground)
                    Add("Raid", counts.Raid)
                    Add("Arena", counts.Arena)
                    if (counts.Instance or 0) > 0 then Add("Other Instance", counts.Instance) end
                    if (counts.Unknown or 0) > 0 then Add("Unknown", counts.Unknown) end

                    GameTooltip:Show()
                    return
                end

                if not self.isHeader and self.playerData then
                    self.bg:SetColorTexture(COLORS.rowHover.r, COLORS.rowHover.g, COLORS.rowHover.b, COLORS.rowHover.a)
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
                    GameTooltip:AddDoubleLine("Spec:", data.spec or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    if data.specSource then
                        local confidence = data.specConfidence and (", " .. data.specConfidence) or ""
                        GameTooltip:AddDoubleLine("Spec Source:", tostring(data.specSource) .. confidence, 0.7, 0.7, 0.7, 1, 1, 1)
                    end
                    GameTooltip:AddDoubleLine("Faction:", data.faction or "Unknown", 0.7, 0.7, 0.7, 1, 1, 1)
                    if data.realm and data.realm ~= "" then
                        GameTooltip:AddDoubleLine("Realm:", data.realm, 0.7, 0.7, 0.7, 1, 1, 1)
                    end
                    if data.seen then
                        local age = Now() - data.seen
                        GameTooltip:AddDoubleLine("Last Seen:", FormatAgeSeconds(age) .. " ago", 0.7, 0.7, 0.7, 1, 1, 1)
                    end

                    if data.met and type(data.met) == "table" then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddDoubleLine("First Met At:", FormatMeetWhereFromMet(data.met), 0.7, 0.7, 0.7, 1, 1, 1)
                        if data.met.t then
                            local metAge = Now() - data.met.t
                            GameTooltip:AddDoubleLine("First Met:", FormatAgeSeconds(metAge) .. " ago", 0.7, 0.7, 0.7, 1, 1, 1)
                        end

                        local instanceType = data.met.instanceType or data.met.instanceInfoType
                        if instanceType and instanceType ~= "" then
                            local label = data.met.inInstance and "Instance Type" or "Context"
                            GameTooltip:AddDoubleLine(label .. ":", tostring(instanceType), 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                        if data.met.source then
                            GameTooltip:AddDoubleLine("Met Via:", tostring(data.met.source), 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                    end

                    if data.combat then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Combat Stats", 1, 0.3, 0.3)
                        if data.combat.totalDamageToMe and data.combat.totalDamageToMe > 0 then
                            GameTooltip:AddDoubleLine("Total Damage:", FormatDamageNumber(data.combat.totalDamageToMe) .. " (" .. (data.combat.totalHitsToMe or 0) .. " hits)", 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                        if data.combat.maxHit and data.combat.maxHit.amount and data.combat.maxHit.amount > 0 then
                            local maxHit = data.combat.maxHit
                            local hitText = FormatDamageNumber(maxHit.amount) .. " - " .. (maxHit.spellName or "Melee")
                            if maxHit.critical then hitText = hitText .. " (crit)" end
                            if maxHit.fromPet and maxHit.petName then hitText = hitText .. " [pet: " .. maxHit.petName .. "]" end
                            GameTooltip:AddDoubleLine("Hardest Hit:", hitText, 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                        if data.combat.maxBurstDps and data.combat.maxBurstDps.dps and data.combat.maxBurstDps.dps > 0 then
                            local maxBurst = data.combat.maxBurstDps
                            local burstText = FormatDamageNumber(maxBurst.dps) .. " DPS (" .. FormatDamageNumber(maxBurst.damage) .. " in " .. (maxBurst.windowSec or 3) .. "s)"
                            GameTooltip:AddDoubleLine("Max Burst:", burstText, 0.7, 0.7, 0.7, 1, 1, 1)
                        end
                    end

                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function(self)
                if not self.isHeader then
                    local idx = 0
                    for i, otherRow in ipairs(uiFrame.playerRows) do
                        if otherRow == self then idx = i break end
                    end
                    if idx % 2 == 0 then
                        self.bg:SetColorTexture(COLORS.rowEven.r, COLORS.rowEven.g, COLORS.rowEven.b, COLORS.rowEven.a)
                    else
                        self.bg:SetColorTexture(COLORS.rowOdd.r, COLORS.rowOdd.g, COLORS.rowOdd.b, COLORS.rowOdd.a)
                    end
                else
                    self.bg:SetColorTexture(COLORS.headerBg.r, COLORS.headerBg.g, COLORS.headerBg.b, COLORS.headerBg.a)
                end
                GameTooltip:Hide()
            end)

            row:Hide()
            return row
        end

        for i = 1, MAX_ROWS do
            uiFrame.playerRows[i] = CreatePlayerRow(i)
        end

        local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyText:SetPoint("CENTER", 0, 0)
        emptyText:SetText("No players found.")
        emptyText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
        emptyText:Hide()
        uiFrame.emptyText = emptyText

        local paginationBar = CreateFrame("Frame", nil, playersOverlay)
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

        local playerCountText = paginationBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        playerCountText:SetPoint("RIGHT", -10, 0)
        playerCountText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
        uiFrame.playerCountText = playerCountText

        local mvpOverlay = CreateFrame("Frame", nil, uiFrame, "BackdropTemplate")
        mvpOverlay:SetPoint("TOPLEFT", 10, -50)
        mvpOverlay:SetPoint("BOTTOMRIGHT", -10, 50)
        mvpOverlay:EnableMouse(true)
        mvpOverlay:SetFrameLevel(uiFrame:GetFrameLevel() + 10)
        mvpOverlay:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = nil,
        })
        mvpOverlay:SetBackdropColor(COLORS.background.r, COLORS.background.g, COLORS.background.b, COLORS.background.a)
        mvpOverlay:Hide()
        uiFrame.mvpOverlay = mvpOverlay

        -- MVP history window selector
        local mvpWindowDropdown = CreateDropdown("ClassScannerMvpWindowDropdown", mvpOverlay, { "25", "50", "100" }, function(val)
            mvpWindowSize = tonumber(val) or BG_MVP_HISTORY_DEFAULT_WINDOW
            mvpCurrentPage = 1
            UpdateList()
        end, "50")
        mvpWindowDropdown:SetPoint("TOPLEFT", -5, 8)
        UIDropDownMenu_SetWidth(mvpWindowDropdown, 70)
        local mvpWindowLabel = mvpOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        mvpWindowLabel:SetPoint("BOTTOM", mvpWindowDropdown, "TOP", 0, 2)
        mvpWindowLabel:SetText("Window")
        mvpWindowLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        mvpWindowLabel:SetJustifyH("CENTER")
        mvpWindowLabel:SetWidth((mvpWindowDropdown:GetWidth() and mvpWindowDropdown:GetWidth()) or 70)
        uiFrame.mvpWindowDropdown = mvpWindowDropdown

        -- Leaderboard stat cards
        uiFrame.mvpStatCards = {}
        local mvpStatsContainer = CreateFrame("Frame", nil, mvpOverlay)
        mvpStatsContainer:SetHeight(70)
        mvpStatsContainer:SetPoint("TOPLEFT", 140, -2)
        mvpStatsContainer:SetPoint("TOPRIGHT", -10, -2)

        local function CreateMvpStatCard(parent, xOffset, label)
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetSize(130, 60)
            card:SetPoint("LEFT", parent, "LEFT", xOffset, 0)
            card:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                tile = false,
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 },
            })
            card:SetBackdropColor(COLORS.statCardBg.r, COLORS.statCardBg.g, COLORS.statCardBg.b, COLORS.statCardBg.a)
            card:SetBackdropBorderColor(COLORS.statCardBorder.r, COLORS.statCardBorder.g, COLORS.statCardBorder.b, COLORS.statCardBorder.a)

            local labelText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labelText:SetPoint("TOP", 0, -8)
            labelText:SetText(label)
            labelText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

            local valueText = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            valueText:SetPoint("CENTER", 0, -2)
            valueText:SetText("None")
            valueText:SetTextColor(COLORS.textPrimary.r, COLORS.textPrimary.g, COLORS.textPrimary.b)

            local subText = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            subText:SetPoint("BOTTOM", 0, 6)
            subText:SetText("Wins: 0 | Peak: 0")
            subText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)

            card.label = labelText
            card.value = valueText
            card.subtext = subText
            card:EnableMouse(true)
            card:SetScript("OnEnter", function(self)
                if self.ranked and #self.ranked > 0 then
                    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                    GameTooltip:AddLine(self.label and self.label:GetText() or "Leaderboard", 1, 1, 1)
                    for i = 1, math.min(10, #self.ranked) do
                        local item = self.ranked[i]
                        local key = tostring(item.key or "")
                        local wins = tostring(item.wins or 0)
                        local peak = FormatDamageNumber(item.peak or 0)
                        GameTooltip:AddDoubleLine(i .. ". " .. key, "Wins " .. wins .. " | Peak " .. peak, 0.85, 0.85, 0.85, 1, 1, 1)
                    end
                    GameTooltip:Show()
                end
            end)
            card:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            return card
        end

        uiFrame.mvpStatCards.topDamageClass = CreateMvpStatCard(mvpStatsContainer, 0, "Top Damage Class")
        uiFrame.mvpStatCards.topHealingClass = CreateMvpStatCard(mvpStatsContainer, 135, "Top Healing Class")
        uiFrame.mvpStatCards.topDamageSpec = CreateMvpStatCard(mvpStatsContainer, 270, "Top Damage Spec")
        uiFrame.mvpStatCards.topHealingSpec = CreateMvpStatCard(mvpStatsContainer, 405, "Top Healing Spec")

        local mvpScroll = CreateFrame("ScrollFrame", nil, mvpOverlay, "UIPanelScrollFrameTemplate")
        mvpScroll:SetPoint("TOPLEFT", 0, -70)
        mvpScroll:SetPoint("BOTTOMRIGHT", -20, 28)
        
        local mvpContent = CreateFrame("Frame", nil, mvpScroll)
        mvpContent:SetWidth(680)
        mvpContent:SetHeight(1)
        mvpScroll:SetScrollChild(mvpContent)
        uiFrame.mvpContent = mvpContent

        uiFrame.mvpSections = {}

        local function CreateMvpRow(parent, index)
            local row = CreateFrame("Frame", nil, parent)
            row:SetHeight(24)
            row:SetPoint("TOPLEFT", 0, -24 - ((index - 1) * 24))
            row:SetPoint("TOPRIGHT", 0, -24 - ((index - 1) * 24))

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(COLORS.rowOdd.r, COLORS.rowOdd.g, COLORS.rowOdd.b, COLORS.rowOdd.a)

            row.classIcon = row:CreateTexture(nil, "ARTWORK")
            row.classIcon:SetSize(18, 18)
            row.classIcon:SetPoint("LEFT", 5, 0)

            row.factionIcon = row:CreateTexture(nil, "ARTWORK")
            row.factionIcon:SetSize(14, 14)
            row.factionIcon:SetPoint("LEFT", row.classIcon, "RIGHT", 4, 0)

            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameText:SetWidth(180)
            row.nameText:SetPoint("LEFT", row.factionIcon, "RIGHT", 8, 0)
            row.nameText:SetJustifyH("LEFT")

            row.specText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.specText:SetWidth(110)
            row.specText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
            row.specText:SetJustifyH("LEFT")

            row.totalText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.totalText:SetWidth(150)
            row.totalText:SetPoint("LEFT", row.specText, "RIGHT", 10, 0)
            row.totalText:SetJustifyH("LEFT")

            row.bgText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.bgText:SetPoint("LEFT", row.totalText, "RIGHT", 10, 0)
            row.bgText:SetJustifyH("LEFT")
            row.bgText:SetWordWrap(false)
            row.bgText:SetPoint("RIGHT", -8, 0)

            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                local record = self.recordData
                if type(record) ~= "table" then return end
                local match = record.match or {}
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")

                local header = (record.role == "damage") and "Top Damage" or "Top Healing"
                GameTooltip:AddLine(header .. " #" .. tostring(record.rank or "?"), 1, 1, 1)
                local name = tostring(record.name or "Unknown")
                if record.realm and record.realm ~= "" then
                    name = name .. "-" .. record.realm
                end
                GameTooltip:AddLine(name .. " [" .. tostring(record.class or "Unknown") .. "]", 0.9, 0.9, 0.9)
                GameTooltip:AddLine("Spec: " .. tostring(record.spec or "Unknown"), 0.75, 0.75, 0.75)

                GameTooltip:AddDoubleLine("Damage:", FormatDamageNumber(record.totalDamageDone or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine("Healing:", FormatDamageNumber(record.totalHealingDone or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine("Killing Blows:", tostring(record.killingBlows or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine("Honorable Kills:", tostring(record.honorableKills or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine("Deaths:", tostring(record.deaths or 0), 0.7, 0.7, 0.7, 1, 1, 1)
                if (record.honorGained or 0) > 0 or (record.bonusHonor or 0) > 0 then
                    GameTooltip:AddDoubleLine("Honor:", tostring(record.honorGained or 0) .. " (+" .. tostring(record.bonusHonor or 0) .. ")", 0.7, 0.7, 0.7, 1, 1, 1)
                end

                local bg = tostring(match.battlegroundName or "Battleground")
                local age = match.recordedAt and (Now() - match.recordedAt) or nil
                GameTooltip:AddDoubleLine("Battleground:", bg, 0.7, 0.7, 0.7, 1, 1, 1)
                if age then
                    GameTooltip:AddDoubleLine("Recorded:", FormatAgeSeconds(age) .. " ago", 0.7, 0.7, 0.7, 1, 1, 1)
                end
                if match.finalizeReason then
                    GameTooltip:AddDoubleLine("Finalized:", tostring(match.finalizeReason), 0.7, 0.7, 0.7, 1, 1, 1)
                end

                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            row:Hide()
            return row
        end

        local function CreateMvpSection(titleText, offsetY)
            local section = CreateFrame("Frame", nil, mvpContent)
            section:SetPoint("TOPLEFT", 0, offsetY)
            section:SetPoint("TOPRIGHT", 0, offsetY)

            local title = section:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            title:SetPoint("TOPLEFT", 0, 0)
            title:SetText(titleText)
            title:SetTextColor(COLORS.accent.r, COLORS.accent.g, COLORS.accent.b)
            section.title = title

            local rows = {}
            for i = 1, mvpItemsPerPage do
                rows[i] = CreateMvpRow(section, i)
            end
            section.rows = rows
            section:SetHeight(24 * (mvpItemsPerPage + 1))
            return section
        end

        uiFrame.mvpSections.damage = CreateMvpSection("Top Damage", -10)
        uiFrame.mvpSections.healing = CreateMvpSection("Top Healing", -250)

        local mvpEmptyText = mvpContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mvpEmptyText:SetPoint("TOPLEFT", 0, -40)
        mvpEmptyText:SetText("No battleground MVP history recorded yet.")
        mvpEmptyText:SetTextColor(COLORS.textMuted.r, COLORS.textMuted.g, COLORS.textMuted.b)
        uiFrame.mvpEmptyText = mvpEmptyText

        local mvpPaginationBar = CreateFrame("Frame", nil, mvpOverlay)
        mvpPaginationBar:SetHeight(26)
        mvpPaginationBar:SetPoint("BOTTOMLEFT", 0, 0)
        mvpPaginationBar:SetPoint("BOTTOMRIGHT", -20, 0)

        local mvpPrevBtn = CreateFrame("Button", nil, mvpPaginationBar, "UIPanelButtonTemplate")
        mvpPrevBtn:SetSize(80, 22)
        mvpPrevBtn:SetPoint("LEFT", 5, 0)
        mvpPrevBtn:SetText("Previous")
        mvpPrevBtn:SetScript("OnClick", function()
            mvpCurrentPage = mvpCurrentPage - 1
            if mvpCurrentPage < 1 then mvpCurrentPage = 1 end
            UpdateList()
        end)
        uiFrame.mvpPrevBtn = mvpPrevBtn

        local mvpNextBtn = CreateFrame("Button", nil, mvpPaginationBar, "UIPanelButtonTemplate")
        mvpNextBtn:SetSize(80, 22)
        mvpNextBtn:SetPoint("LEFT", mvpPrevBtn, "RIGHT", 10, 0)
        mvpNextBtn:SetText("Next")
        mvpNextBtn:SetScript("OnClick", function()
            mvpCurrentPage = mvpCurrentPage + 1
            UpdateList()
        end)
        uiFrame.mvpNextBtn = mvpNextBtn

        local mvpPageText = mvpPaginationBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        mvpPageText:SetPoint("LEFT", mvpNextBtn, "RIGHT", 15, 0)
        mvpPageText:SetText("Page 1 / 1")
        uiFrame.mvpPageText = mvpPageText
    end

    ShowCurrentView()

    UpdateList()
    uiFrame:Show()
end

local function SetSearchQuery(query)
    local trimmed = (query or ""):match("^%s*(.-)%s*$")
    searchQuery = trimmed
    currentPage = 1
    if searchDebounceTimer then
        searchDebounceTimer:Cancel()
        searchDebounceTimer = nil
    end
    if uiFrame and uiFrame.searchBox and uiFrame.searchBox:GetText() ~= trimmed then
        uiFrame.searchBox:SetText(trimmed)
    end
    RefreshUI()
end

CS.UpdateList = UpdateList
CS.RefreshUI = RefreshUI
CS.ClassScanner_ShowUI = ClassScanner_ShowUI
CS.SetSearchQuery = SetSearchQuery
CS.SetCurrentView = function(view)
    if view == "players" or view == "bg_mvp" then
        currentView = view
        ShowCurrentView()
        RefreshUI()
    end
end
CS.IsUIShown = function()
    return uiFrame and uiFrame:IsShown()
end
