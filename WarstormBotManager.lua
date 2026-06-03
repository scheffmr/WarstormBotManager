-- Warstorm Bot Manager Addon
-- UI is built programmatically here (no .xml). The frames PlayerbotManagerFrame
-- and PlayerbotManagerButtonFrame, and the PlayerbotManager_* / *_OnClick globals,
-- are kept because Bindings.xml references them by name.

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

-- Control grid definition: rows = roles, columns = actions.
-- An empty prefix means "all bots" -> the bare action is sent.
local roles = {
    { label = "all",    prefix = "" },
    { label = "tank",   prefix = "@tank " },
    { label = "heal",   prefix = "@heal " },
    { label = "dps",    prefix = "@dps " },
    { label = "melee",  prefix = "@melee " },
    { label = "ranged", prefix = "@ranged " },
}
local actions = { "attack", "stay", "follow", "flee" }

-- Footer actions on the Controls tab. command = nil means a custom OnClick.
local footer = {
    { label = "Summon",  command = "summon" },
    { label = "Release", command = "release" },
    { label = "Drink",   command = "say drink" },
    { label = "Skull",   command = nil },   -- rti skull + attack rti target
    { label = "CC",      command = "rti cc moon" },
}

-- Widgets collected for optional ElvUI skinning
local skinButtons = {}
local tabButtons = {}
local contentFrames = {}
local closeButton

-- Return the index of the entry whose .name matches, or nil if absent
local function IndexByName(list, name)
    for i, entry in ipairs(list) do
        if entry.name == name then
            return i
        end
    end
    return nil
end

-- Create a UIPanelButton, size it, label it, and register it for skinning
local function CreateButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(h)
    b:SetText(text)
    table.insert(skinButtons, b)
    return b
end

------------------------------------------------------------------------
-- Command helpers (channel conventions preserved from v1.0)
------------------------------------------------------------------------

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

------------------------------------------------------------------------
-- Selection cyclers
------------------------------------------------------------------------

local function RefreshClassText()
    if SelectedClassText then
        SelectedClassText:SetText(PlayerbotManagerDB.selectedClass)
    end
end

local function RefreshFormationText()
    if SelectedFormationText then
        SelectedFormationText:SetText(PlayerbotManagerDB.selectedFormation)
    end
end

function PlayerbotManager_PrevClass()
    local i = (PlayerbotManagerDB.selectedClassIndex or 1) - 1
    if i < 1 then i = #classes end
    PlayerbotManagerDB.selectedClassIndex = i
    PlayerbotManagerDB.selectedClass = classes[i].name
    RefreshClassText()
end

function PlayerbotManager_NextClass()
    local i = (PlayerbotManagerDB.selectedClassIndex or 1) + 1
    if i > #classes then i = 1 end
    PlayerbotManagerDB.selectedClassIndex = i
    PlayerbotManagerDB.selectedClass = classes[i].name
    RefreshClassText()
end

function PlayerbotManager_PrevFormation()
    local i = (PlayerbotManagerDB.selectedFormationIndex or 1) - 1
    if i < 1 then i = #formations end
    PlayerbotManagerDB.selectedFormationIndex = i
    PlayerbotManagerDB.selectedFormation = formations[i].name
    RefreshFormationText()
end

function PlayerbotManager_NextFormation()
    local i = (PlayerbotManagerDB.selectedFormationIndex or 1) + 1
    if i > #formations then i = 1 end
    PlayerbotManagerDB.selectedFormationIndex = i
    PlayerbotManagerDB.selectedFormation = formations[i].name
    RefreshFormationText()
end

------------------------------------------------------------------------
-- Tab switching
------------------------------------------------------------------------

function PlayerbotManager_ShowTab(index)
    PlayerbotManagerDB.selectedTab = index
    for i = 1, #contentFrames do
        if i == index then
            contentFrames[i]:Show()
            tabButtons[i]:Disable()   -- active tab shown as "pressed"/greyed
        else
            contentFrames[i]:Hide()
            tabButtons[i]:Enable()
        end
    end
end

------------------------------------------------------------------------
-- UI construction
------------------------------------------------------------------------

local function BuildBotsTab(content)
    local label = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOP", content, "TOP", 0, -8)
    label:SetText("Add Class")

    local prev = CreateButton(content, "<", 28, 26)
    prev:SetPoint("TOP", content, "TOP", -75, -30)
    prev:SetScript("OnClick", PlayerbotManager_PrevClass)

    SelectedClassText = content:CreateFontString("SelectedClassText", "OVERLAY", "GameFontHighlightLarge")
    SelectedClassText:SetPoint("TOP", content, "TOP", 0, -34)
    SelectedClassText:SetWidth(110)

    local next = CreateButton(content, ">", 28, 26)
    next:SetPoint("TOP", content, "TOP", 75, -30)
    next:SetScript("OnClick", PlayerbotManager_NextClass)

    local add = CreateButton(content, "Add", 80, 26)
    add:SetPoint("TOP", content, "TOP", 0, -64)
    add:SetScript("OnClick", function()
        PlayerbotManager_AddBot(PlayerbotManagerDB.selectedClass)
    end)

    local removeAll = CreateButton(content, "Remove All", 100, 26)
    removeAll:SetPoint("TOP", content, "TOP", -55, -100)
    removeAll:SetScript("OnClick", function()
        SendChatMessage(".warstormbot bot remove *", "SAY")
        LeaveParty()
    end)

    local respec = CreateButton(content, "ReSpec", 90, 26)
    respec:SetPoint("TOP", content, "TOP", 55, -100)
    respec:SetScript("OnClick", function()
        SendChatMessage(".warstormbot bot init=epic", "SAY")
    end)
end

local function BuildFormationTab(content)
    local label = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOP", content, "TOP", 0, -8)
    label:SetText("Bot Formation (Optional Placement)")

    local prev = CreateButton(content, "<", 28, 26)
    prev:SetPoint("TOP", content, "TOP", -75, -30)
    prev:SetScript("OnClick", PlayerbotManager_PrevFormation)

    SelectedFormationText = content:CreateFontString("SelectedFormationText", "OVERLAY", "GameFontHighlightLarge")
    SelectedFormationText:SetPoint("TOP", content, "TOP", 0, -34)
    SelectedFormationText:SetWidth(110)

    local next = CreateButton(content, ">", 28, 26)
    next:SetPoint("TOP", content, "TOP", 75, -30)
    next:SetScript("OnClick", PlayerbotManager_NextFormation)

    local set = CreateButton(content, "Set", 80, 26)
    set:SetPoint("TOP", content, "TOP", -45, -64)
    set:SetScript("OnClick", function()
        PlayerbotManager_SetFormation(PlayerbotManagerDB.selectedFormation)
    end)

    local check = CreateButton(content, "Check", 80, 26)
    check:SetPoint("TOP", content, "TOP", 45, -64)
    check:SetScript("OnClick", function()
        PlayerbotManager_SetCommand("formation")
    end)
end

local function BuildControlsTab(content)
    local colX = { 46, 100, 154, 208 }   -- x of each action column
    local cellW, cellH = 50, 20

    -- column headers
    for c, action in ipairs(actions) do
        local h = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", content, "TOPLEFT", colX[c], -2)
        h:SetWidth(cellW)
        h:SetText(action)
    end

    -- grid rows
    for r, role in ipairs(roles) do
        local rowY = -16 - (r - 1) * (cellH + 2)

        local rl = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rl:SetPoint("TOPLEFT", content, "TOPLEFT", 4, rowY - 4)
        rl:SetWidth(40)
        rl:SetText(role.label)

        for c, action in ipairs(actions) do
            local cmd = role.prefix .. action
            -- short glyph keeps cells readable in the narrow column
            local b = CreateButton(content, action:sub(1, 3), cellW, cellH)
            b:SetNormalFontObject(GameFontNormalSmall)
            b:SetPoint("TOPLEFT", content, "TOPLEFT", colX[c], rowY)
            b:SetScript("OnClick", function()
                PlayerbotManager_SetCommand(cmd)
            end)
        end
    end

    -- footer action row
    local footerY = -16 - (#roles) * (cellH + 2) - 6
    local fW = 50
    for i, item in ipairs(footer) do
        local b = CreateButton(content, item.label, fW, 22)
        b:SetNormalFontObject(GameFontNormalSmall)
        b:SetPoint("TOPLEFT", content, "TOPLEFT", 4 + (i - 1) * (fW + 1), footerY)
        if item.command then
            local cmd = item.command
            b:SetScript("OnClick", function() PlayerbotManager_SetCommand(cmd) end)
        elseif item.label == "Skull" then
            b:SetScript("OnClick", function()
                PlayerbotManager_SetCommand("rti skull")
                PlayerbotManager_SetCommand("attack rti target")
            end)
        end
    end
end

local function BuildUI()
    -- Main window
    local f = CreateFrame("Frame", "PlayerbotManagerFrame", UIParent)
    f:SetWidth(290)
    f:SetHeight(280)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    -- Default (non-ElvUI) backdrop; replaced by ElvUI skin when present
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:Hide()

    local title = f:CreateFontString("PlayerbotManagerTitle", "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("Warstorm Bot Manager")

    closeButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeButton:SetScript("OnClick", function() f:Hide() end)

    -- Tabs
    local tabLabels = { "Bots", "Formation", "Controls" }
    local tabW = 86
    for i, name in ipairs(tabLabels) do
        local tab = CreateButton(f, name, tabW, 22)
        tab:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * (tabW + 2), -40)
        tab:SetScript("OnClick", function() PlayerbotManager_ShowTab(i) end)
        tabButtons[i] = tab

        local content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -68)
        content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
        content:Hide()
        contentFrames[i] = content
    end

    BuildBotsTab(contentFrames[1])
    BuildFormationTab(contentFrames[2])
    BuildControlsTab(contentFrames[3])

    -- Event handling: init + skin once everything (incl. ElvUI) has loaded
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        PlayerbotManager_Init()
        PlayerbotManager_SkinElvUI()
    end)
end

------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------

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

local function BuildMinimapButton()
    local b = CreateFrame("Button", "PlayerbotManagerButtonFrame", Minimap)
    b:SetWidth(32)
    b:SetHeight(32)
    b:SetPoint("TOP", Minimap, "TOP", 0, 0)
    -- Render above the minimap's own textures, otherwise the icon is hidden
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    b:EnableMouse(true)
    b:RegisterForDrag("RightButton")
    b:SetNormalTexture("Interface\\Icons\\Ability_rogue_shadowstrikes")
    b:SetPushedTexture("Interface\\Icons\\Ability_rogue_shadowstrikes")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints(b)
    b.dragme = false
    b:SetScript("OnDragStart", function() b.dragme = true end)
    b:SetScript("OnDragStop", function() b.dragme = false end)
    b:SetScript("OnUpdate", function()
        if b.dragme then
            PlayerbotManagerButtonFrame_BeingDragged()
        end
    end)
    b:SetScript("OnClick", PlayerbotManagerButtonFrame_OnClick)
    b:SetScript("OnEnter", PlayerbotManagerButtonFrame_OnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

------------------------------------------------------------------------
-- Init + ElvUI skinning
------------------------------------------------------------------------

function PlayerbotManager_Init()
    -- Class selection: derive index from the saved name so the two can't drift.
    PlayerbotManagerDB.selectedClass = PlayerbotManagerDB.selectedClass or "Druid"
    PlayerbotManagerDB.selectedClassIndex = IndexByName(classes, PlayerbotManagerDB.selectedClass)
    if not PlayerbotManagerDB.selectedClassIndex then
        PlayerbotManagerDB.selectedClassIndex = 1
        PlayerbotManagerDB.selectedClass = classes[1].name
    end
    RefreshClassText()

    -- Formation selection (same name-derived index)
    PlayerbotManagerDB.selectedFormation = PlayerbotManagerDB.selectedFormation or "Shield"
    PlayerbotManagerDB.selectedFormationIndex = IndexByName(formations, PlayerbotManagerDB.selectedFormation)
    if not PlayerbotManagerDB.selectedFormationIndex then
        PlayerbotManagerDB.selectedFormationIndex = 1
        PlayerbotManagerDB.selectedFormation = formations[1].name
    end
    RefreshFormationText()

    -- Restore the saved minimap button position (skip the untouched default)
    local pos = PlayerbotManagerDB.buttonPos
    if PlayerbotManagerButtonFrame and pos and (pos.x ~= 0 or pos.y ~= 0) then
        PlayerbotManagerButtonFrame:ClearAllPoints()
        PlayerbotManagerButtonFrame:SetPoint("TOPLEFT", Minimap, "TOPLEFT", pos.x, pos.y)
    end

    -- Open on the last-used tab
    PlayerbotManager_ShowTab(PlayerbotManagerDB.selectedTab or 1)
end

function PlayerbotManager_SkinElvUI()
    if not ElvUI then return end
    local ok, E = pcall(unpack, ElvUI)
    if not ok or not E then return end
    local S = E:GetModule("Skins", true)
    if not S then return end

    pcall(function()
        local f = PlayerbotManagerFrame
        f:SetBackdrop(nil)
        if f.StripTextures then f:StripTextures() end
        if f.CreateBackdrop then f:CreateBackdrop("Transparent") end
        for _, b in ipairs(skinButtons) do
            S:HandleButton(b)
        end
        if closeButton then
            S:HandleCloseButton(closeButton, f.backdrop)
        end
    end)
end

-- Build the UI at load time; Init/skin run on PLAYER_LOGIN.
-- Minimap button first: it's the entry point, so build it independently of the panel.
BuildMinimapButton()
BuildUI()
