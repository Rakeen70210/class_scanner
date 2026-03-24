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

local uiFrame
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
local dataResetMenu

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

local function UpdateList()
    if not uiFrame then return end

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
    for classKey, counts in pairs(classMeetCounts) do
        local bgCount = counts.Battleground or 0
        if bgCount > 0 then
            table.insert(bgBreakdown, { cls = classKey, count = bgCount })
        end
        if bgCount > maxBGCount then
            maxBGCount = bgCount
            topBGClass = classKey
        end
    end
    table.sort(bgBreakdown, function(a, b) return a.count > b.count end)

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

        local closeBtn = CreateFrame("Button", nil, header)
        closeBtn:SetSize(30, 30)
        closeBtn:SetPoint("TOPRIGHT", -5, -5)
        closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
        closeBtn:SetScript("OnClick", function()
            uiFrame:Hide()
        end)

        local statsContainer = CreateFrame("Frame", nil, uiFrame)
        statsContainer:SetHeight(70)
        statsContainer:SetPoint("TOPLEFT", 10, -50)
        statsContainer:SetPoint("TOPRIGHT", -10, -50)

        uiFrame.statCards = {}

        local function CreateStatCard(parent, xOffset, label)
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetSize(110, 60)
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
        uiFrame.statCards.mostClass = CreateStatCard(statsContainer, 115, "Most Detected")
        uiFrame.statCards.mostRace = CreateStatCard(statsContainer, 230, "Top Race")

        uiFrame.statCards.topBGClass = CreateStatCard(statsContainer, 345, "Top BG Class")
        uiFrame.statCards.topBGClass:EnableMouse(true)
        uiFrame.statCards.topBGClass:SetScript("OnEnter", function(self)
            if self.bgBreakdown and #self.bgBreakdown > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine("Battleground Breakdown", 1, 1, 1)
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

        uiFrame.statCards.topSpec = CreateStatCard(statsContainer, 460, "Top Spec")
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

        uiFrame.statCards.levelSpread = CreateStatCard(statsContainer, 575, "Avg Level")
        uiFrame.statCards.levelSpread.value:SetTextColor(COLORS.gold.r, COLORS.gold.g, COLORS.gold.b)

        local classBarLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classBarLabel:SetPoint("TOPLEFT", 15, -130)
        classBarLabel:SetText("Class Distribution")
        classBarLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)

        local classBar = CreateFrame("Frame", nil, uiFrame, "BackdropTemplate")
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

        local classLegend = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLegend:SetPoint("TOPLEFT", 15, -170)
        classLegend:SetWidth(uiFrame:GetWidth() - 30)
        classLegend:SetWordWrap(true)
        classLegend:SetJustifyH("LEFT")
        classLegend:SetText("")
        uiFrame.classLegend = classLegend

        local factionDropdown = CreateDropdown("ClassScannerFactionDropdown", uiFrame, { "Alliance", "Horde" }, function(val)
            filterFaction = val
            UIDropDownMenu_SetText(ClassScannerFactionDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        factionDropdown:SetPoint("TOPLEFT", -5, -205)
        UIDropDownMenu_SetWidth(factionDropdown, 90)
        local factionLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        factionLabel:SetPoint("BOTTOM", factionDropdown, "TOP", 0, 2)
        factionLabel:SetText("Faction")
        factionLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        factionLabel:SetJustifyH("CENTER")
        factionLabel:SetWidth((factionDropdown:GetWidth() and factionDropdown:GetWidth()) or 90)

        local raceDropdown = CreateDropdown("ClassScannerRaceDropdown", uiFrame, { "Human", "Dwarf", "Night Elf", "Gnome", "Draenei", "Orc", "Undead", "Tauren", "Troll", "Blood Elf" }, function(val)
            filterRace = val
            UIDropDownMenu_SetText(ClassScannerRaceDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        raceDropdown:SetPoint("LEFT", factionDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(raceDropdown, 90)
        local raceLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        raceLabel:SetPoint("BOTTOM", raceDropdown, "TOP", 0, 2)
        raceLabel:SetText("Race")
        raceLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        raceLabel:SetJustifyH("CENTER")
        raceLabel:SetWidth((raceDropdown:GetWidth() and raceDropdown:GetWidth()) or 90)

        local classDropdown = CreateDropdown("ClassScannerClassDropdown", uiFrame, { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }, function(val)
            filterClass = val
            UIDropDownMenu_SetText(ClassScannerClassDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        classDropdown:SetPoint("LEFT", raceDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(classDropdown, 100)
        local classLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        classLabel:SetPoint("BOTTOM", classDropdown, "TOP", 0, 2)
        classLabel:SetText("Class")
        classLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        classLabel:SetJustifyH("CENTER")
        classLabel:SetWidth((classDropdown:GetWidth() and classDropdown:GetWidth()) or 100)

        local specDropdown = CreateDropdown("ClassScannerSpecDropdown", uiFrame, SPEC_FILTER_ITEMS, function(val)
            filterSpec = val
            UIDropDownMenu_SetText(ClassScannerSpecDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        specDropdown:SetPoint("LEFT", classDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(specDropdown, 100)
        local specLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        specLabel:SetPoint("BOTTOM", specDropdown, "TOP", 0, 2)
        specLabel:SetText("Spec")
        specLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        specLabel:SetJustifyH("CENTER")
        specLabel:SetWidth((specDropdown:GetWidth() and specDropdown:GetWidth()) or 100)

        local levelDropdown = CreateDropdown("ClassScannerLevelDropdown", uiFrame, { "80", "70-79", "60-69", "1-59", "Custom" }, function(val)
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
        local levelLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelLabel:SetPoint("BOTTOM", levelDropdown, "TOP", 0, 2)
        levelLabel:SetText("Level")
        levelLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        levelLabel:SetJustifyH("CENTER")
        levelLabel:SetWidth((levelDropdown:GetWidth() and levelDropdown:GetWidth()) or 90)

        local locationDropdown = CreateDropdown("ClassScannerLocationDropdown", uiFrame, { "World", "Dungeon", "Raid", "Battleground", "Arena", "Instance", "Unknown" }, function(val)
            filterLocation = val
            UIDropDownMenu_SetText(ClassScannerLocationDropdown, val)
            currentPage = 1
            UpdateList()
        end, "All")
        locationDropdown:SetPoint("LEFT", levelDropdown, "RIGHT", -15, 0)
        UIDropDownMenu_SetWidth(locationDropdown, 90)
        local locationLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        locationLabel:SetPoint("BOTTOM", locationDropdown, "TOP", 0, 2)
        locationLabel:SetText("Location")
        locationLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        locationLabel:SetJustifyH("CENTER")
        locationLabel:SetWidth((locationDropdown:GetWidth() and locationDropdown:GetWidth()) or 90)

        local resetBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
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

        local dataResetBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        dataResetBtn:SetSize(90, 22)
        dataResetBtn:SetPoint("LEFT", resetBtn, "RIGHT", 5, 0)
        dataResetBtn:SetText("Data Reset")
        dataResetBtn:SetScript("OnClick", function(self)
            OpenDataResetMenu(self)
        end)

        local backupBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
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

        local levelRangeLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelRangeLabel:SetPoint("TOPLEFT", 20, -295)
        levelRangeLabel:SetText("Level Range:")
        levelRangeLabel:Hide()
        uiFrame.levelRangeLabel = levelRangeLabel

        local sortDropdown = CreateFrame("Frame", "ClassScannerSortDropdown", uiFrame, "UIDropDownMenuTemplate")
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
        local sortLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sortLabel:SetPoint("BOTTOM", sortDropdown, "TOP", 0, 2)
        sortLabel:SetText("Sort")
        sortLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        sortLabel:SetJustifyH("CENTER")
        uiFrame.sortDropdown = sortDropdown

        local levelMinBox = CreateFrame("EditBox", "ClassScannerLevelMinBox", uiFrame, "InputBoxTemplate")
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

        local levelDash = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        levelDash:SetPoint("LEFT", levelMinBox, "RIGHT", 3, 0)
        levelDash:SetText("-")
        levelDash:Hide()
        uiFrame.levelDash = levelDash

        local levelMaxBox = CreateFrame("EditBox", "ClassScannerLevelMaxBox", uiFrame, "InputBoxTemplate")
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

        local searchLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        searchLabel:SetPoint("TOPLEFT", 20, -295)
        searchLabel:SetText("Search:")
        searchLabel:SetTextColor(COLORS.textSecondary.r, COLORS.textSecondary.g, COLORS.textSecondary.b)
        uiFrame.searchLabel = searchLabel

        local searchBox = CreateFrame("EditBox", "ClassScannerSearchBox", uiFrame, "InputBoxTemplate")
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

        local scrollFrame = CreateFrame("ScrollFrame", "ClassScannerScrollFrame", uiFrame, "UIPanelScrollFrameTemplate")
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

        local paginationBar = CreateFrame("Frame", nil, uiFrame)
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
    end

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
CS.IsUIShown = function()
    return uiFrame and uiFrame:IsShown()
end
