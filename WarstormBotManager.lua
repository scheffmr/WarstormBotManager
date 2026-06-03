-- Warstorm Bot Manager Addon

-- Global variables
PlayerbotManagerDB = PlayerbotManagerDB or { buttonPos = { x = 0, y = 0 } }

-- List of classes and their command names
local classes = {
    { name = "Warrior", command = "warrior" },
    { name = "Paladin", command = "paladin" },
    { name = "Hunter", command = "hunter" },
    { name = "Rogue", command = "rogue" },
    { name = "Priest", command = "priest" },
    { name = "Shaman", command = "shaman" },
    { name = "Mage", command = "mage" },
    { name = "Warlock", command = "warlock" },
    { name = "Druid", command = "druid" },
    { name = "DK", command = "dk" }
}

-- List of formations and their command names
local formations = {
    { name = "Shield", command = "shield" },
    { name = "Chaos", command = "chaos" },
    { name = "Circle", command = "circle" },
    { name = "Line", command = "line" },
    { name = "Melee", command = "melee" },
    { name = "Near", command = "near" },
    { name = "Queue", command = "queue" },
    { name = "Arrow", command = "arrow" }
}

-- Return the index of the entry whose .name matches, or nil if absent
local function IndexByName(list, name)
    for i, entry in ipairs(list) do
        if entry.name == name then
            return i
        end
    end
    return nil
end

function PlayerbotManager_Init()
    -- Initialize class selection. Derive the index from the saved name so the
    -- two can never drift apart if the classes table is reordered.
    PlayerbotManagerDB.selectedClass = PlayerbotManagerDB.selectedClass or "Druid"
    PlayerbotManagerDB.selectedClassIndex = IndexByName(classes, PlayerbotManagerDB.selectedClass)
    if not PlayerbotManagerDB.selectedClassIndex then
        PlayerbotManagerDB.selectedClassIndex = 1
        PlayerbotManagerDB.selectedClass = classes[1].name
    end
    if SelectedClassText then
        SelectedClassText:SetText(PlayerbotManagerDB.selectedClass)
    end
    -- Initialize formation selection (same name-derived index)
    PlayerbotManagerDB.selectedFormation = PlayerbotManagerDB.selectedFormation or "Shield"
    PlayerbotManagerDB.selectedFormationIndex = IndexByName(formations, PlayerbotManagerDB.selectedFormation)
    if not PlayerbotManagerDB.selectedFormationIndex then
        PlayerbotManagerDB.selectedFormationIndex = 1
        PlayerbotManagerDB.selectedFormation = formations[1].name
    end
    if SelectedFormationText then
        SelectedFormationText:SetText(PlayerbotManagerDB.selectedFormation)
    end
    -- Restore the saved minimap button position (skip the untouched default)
    local pos = PlayerbotManagerDB.buttonPos
    if PlayerbotManagerButtonFrame and pos and (pos.x ~= 0 or pos.y ~= 0) then
        PlayerbotManagerButtonFrame:ClearAllPoints()
        PlayerbotManagerButtonFrame:SetPoint("TOPLEFT", Minimap, "TOPLEFT", pos.x, pos.y)
    end
end

function PlayerbotManagerButtonFrame_BeingDragged()
    local buttonFrame = PlayerbotManagerButtonFrame
    local xpos, ypos = GetCursorPosition()
    local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()

    xpos = xmin - xpos / Minimap:GetEffectiveScale() + 70
    ypos = ypos / Minimap:GetEffectiveScale() - ymin - 70

    local angle = math.deg(math.atan2(ypos, xpos))
    local x, y = -80 * cos(angle), 80 * sin(angle)
    buttonFrame:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 53 - x, y - 5)
    PlayerbotManagerDB.buttonPos = { x = 53 - x, y = y - 5 }
end

function PlayerbotManagerButtonFrame_OnClick()
    if PlayerbotManagerFrame then
        if PlayerbotManagerFrame:IsVisible() then
            PlayerbotManagerFrame:Hide()
        else
            PlayerbotManagerFrame:Show()
        end
    else
        print("PlayerbotManager: Error - Control frame not found!")
    end
end

function PlayerbotManagerButtonFrame_OnEnter()
    GameTooltip:SetOwner(PlayerbotManagerButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("Warstorm Bot Manager\nClick to open bot controls")
    GameTooltip:Show()
end

function PlayerbotManager_PrevClass()
    if not PlayerbotManagerDB.selectedClassIndex then
        PlayerbotManagerDB.selectedClassIndex = 9
    end
    PlayerbotManagerDB.selectedClassIndex = PlayerbotManagerDB.selectedClassIndex - 1
    if PlayerbotManagerDB.selectedClassIndex < 1 then
        PlayerbotManagerDB.selectedClassIndex = #classes
    end
    PlayerbotManagerDB.selectedClass = classes[PlayerbotManagerDB.selectedClassIndex].name
    if SelectedClassText then
        SelectedClassText:SetText(PlayerbotManagerDB.selectedClass)
    end
end

function PlayerbotManager_NextClass()
    if not PlayerbotManagerDB.selectedClassIndex then
        PlayerbotManagerDB.selectedClassIndex = 9
    end
    PlayerbotManagerDB.selectedClassIndex = PlayerbotManagerDB.selectedClassIndex + 1
    if PlayerbotManagerDB.selectedClassIndex > #classes then
        PlayerbotManagerDB.selectedClassIndex = 1
    end
    PlayerbotManagerDB.selectedClass = classes[PlayerbotManagerDB.selectedClassIndex].name
    if SelectedClassText then
        SelectedClassText:SetText(PlayerbotManagerDB.selectedClass)
    end
end

function PlayerbotManager_AddBot(class)
    -- Use the command field from the classes table
    for _, classInfo in ipairs(classes) do
        if classInfo.name == class then
            SendChatMessage(".warstormbot bot addclass " .. classInfo.command, "SAY")
            return
        end
    end
    print("PlayerbotManager: unknown class '" .. tostring(class) .. "'")
end

function PlayerbotManager_PrevFormation()
    if not PlayerbotManagerDB.selectedFormationIndex then
        PlayerbotManagerDB.selectedFormationIndex = 1
    end
    PlayerbotManagerDB.selectedFormationIndex = PlayerbotManagerDB.selectedFormationIndex - 1
    if PlayerbotManagerDB.selectedFormationIndex < 1 then
        PlayerbotManagerDB.selectedFormationIndex = #formations
    end
    PlayerbotManagerDB.selectedFormation = formations[PlayerbotManagerDB.selectedFormationIndex].name
    if SelectedFormationText then
        SelectedFormationText:SetText(PlayerbotManagerDB.selectedFormation)
    end
end

function PlayerbotManager_NextFormation()
    if not PlayerbotManagerDB.selectedFormationIndex then
        PlayerbotManagerDB.selectedFormationIndex = 1
    end
    PlayerbotManagerDB.selectedFormationIndex = PlayerbotManagerDB.selectedFormationIndex + 1
    if PlayerbotManagerDB.selectedFormationIndex > #formations then
        PlayerbotManagerDB.selectedFormationIndex = 1
    end
    PlayerbotManagerDB.selectedFormation = formations[PlayerbotManagerDB.selectedFormationIndex].name
    if SelectedFormationText then
        SelectedFormationText:SetText(PlayerbotManagerDB.selectedFormation)
    end
end

function PlayerbotManager_SetFormation(formation)
    -- Use the command field from the formations table
    for _, formationInfo in ipairs(formations) do
        if formationInfo.name == formation then
            SendChatMessage("formation " .. formationInfo.command, "PARTY")
            return
        end
    end
    print("PlayerbotManager: unknown formation '" .. tostring(formation) .. "'")
end

function PlayerbotManager_SetCommand(command)
    -- Send command to party chat without /p prefix
    SendChatMessage(command, "PARTY")
end