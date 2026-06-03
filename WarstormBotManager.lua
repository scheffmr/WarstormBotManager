-- Warstorm Bot Manager Addon
-- UI is built programmatically here (no .xml). The frames PlayerbotManagerFrame
-- and PlayerbotManagerButtonFrame, and the PlayerbotManager_* / *_OnClick globals,
-- are kept because Bindings.xml references them by name.

-- Global variables
PlayerbotManagerDB = PlayerbotManagerDB or {}

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

-- Talent spec command tokens per class (Warstorm-specific). The whisper sent to
-- a bot is "talents spec " .. token. The token is also shown in the Presets UI.
-- DK tokens are PLACEHOLDERS (could not be queried yet) -- verify in game.
local specs = {
    Warrior = { "arms pve", "fury pve", "prot pve", "arms pvp", "fury pvp", "prot pvp" },
    Paladin = { "holy pve", "prot pve", "ret pve", "holy pvp", "prot pvp", "ret pvp" },
    Hunter  = { "bm pve", "mm pve", "surv pve", "bm pvp", "mm pvp", "surv pvp" },
    Rogue   = { "as pve", "combat pve", "subtlety pve", "as pvp", "combat pvp", "subtlety pvp" },
    Priest  = { "disc pve", "holy pve", "shadow pve", "disc pvp", "holy pvp", "shadow pvp" },
    Shaman  = { "ele pve", "enh pve", "resto pve", "ele pvp", "enh pvp", "resto pvp" },
    Mage    = { "arcane pve", "fire pve", "frost pve", "frostfire pve", "arcane pvp", "fire pvp", "frost pvp" },
    Warlock = { "affli pve", "demo pve", "destro pve", "affli pvp", "demo pvp", "destro pvp" },
    Druid   = { "balance pve", "bear pve", "resto pve", "cat pve", "balance pvp", "cat pvp", "resto pvp" },
    -- TODO: verify DK tokens once a high-level Death Knight is available.
    DK      = { "blood pve", "frost pve", "unholy pve", "blood pvp", "frost pvp", "unholy pvp" },
}

-- Sentinel for an empty builder slot, so a preset may hold fewer than 4 bots.
local NONE_CLASS = "(none)"

-- Widgets collected for optional ElvUI skinning
local skinButtons = {}
local skinEditBoxes = {}
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
-- Lightweight scheduler (3.3.5a has no guaranteed C_Timer, so we run our
-- own OnUpdate queue). Used to space out the preset-apply chat commands.
------------------------------------------------------------------------

local pending = {}   -- list of { at = <GetTime target>, fn = <callback> }
local scheduler = CreateFrame("Frame")
scheduler:SetScript("OnUpdate", function()
    if #pending == 0 then return end
    local now = GetTime()
    local i = 1
    while i <= #pending do
        if now >= pending[i].at then
            local item = table.remove(pending, i)
            item.fn()
        else
            i = i + 1
        end
    end
end)

-- Run fn after `delay` seconds.
function PlayerbotManager_After(delay, fn)
    table.insert(pending, { at = GetTime() + delay, fn = fn })
end

------------------------------------------------------------------------
-- Team composition presets
------------------------------------------------------------------------

-- Names of the bots currently in the party (the player is not in party1-4).
local function PartyBotNames()
    local names = {}
    for i = 1, GetNumPartyMembers() do
        local n = UnitName("party" .. i)
        if n then names[n] = true end
    end
    return names
end

local applying = false

-- Apply a preset: remove existing bots, then for each member add the class and
-- whisper its spec to the newly-joined bot, finally send `autogear` to PARTY.
-- Steps are spaced out via PlayerbotManager_After to allow bots to spawn/join.
function PlayerbotManager_ApplyPreset(preset)
    if not preset then return end
    if applying then
        print("PlayerbotManager: a preset is already being applied, please wait.")
        return
    end

    -- Collect the non-empty slots.
    local members = {}
    for _, m in ipairs(preset.members or {}) do
        if m.class and m.class ~= NONE_CLASS then
            table.insert(members, m)
        end
    end
    if #members == 0 then
        print("PlayerbotManager: preset '" .. tostring(preset.name) .. "' has no bots.")
        return
    end

    applying = true
    print("PlayerbotManager: applying preset '" .. preset.name .. "' (" .. #members .. " bots)...")

    -- 1) Start from a clean group.
    SendChatMessage(".warstormbot bot remove *", "SAY")
    LeaveParty()

    local STEP = 3          -- seconds between actions (spawn/join latency)
    local t = 2             -- initial wait after remove/leave

    for _, m in ipairs(members) do
        local class, spec = m.class, m.spec
        PlayerbotManager_After(t, function()
            local before = PartyBotNames()
            print(string.format("  adding %s (%s)...", class, spec or "no spec"))
            PlayerbotManager_AddBot(class)
            -- After it joins, find the new party member and set its spec.
            PlayerbotManager_After(STEP, function()
                if not spec then return end
                local target
                for i = 1, GetNumPartyMembers() do
                    local n = UnitName("party" .. i)
                    if n and not before[n] then target = n break end
                end
                if target then
                    SendChatMessage("talents spec " .. spec, "WHISPER", nil, target)
                else
                    print("  (could not find new bot to set spec '" .. spec .. "')")
                end
            end)
        end)
        t = t + STEP * 2    -- room for add + spec before the next bot
    end

    -- 2) Gear everything; the mod picks tactics from the spec (replaces `co`).
    PlayerbotManager_After(t + 1, function()
        SendChatMessage("autogear", "PARTY")
        print("PlayerbotManager: preset '" .. preset.name .. "' applied (autogear sent).")
        applying = false
    end)
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

------------------------------------------------------------------------
-- Presets tab (builder + saved-preset browser)
------------------------------------------------------------------------

-- Builder state: 4 rows, classIndex 0 = empty slot, else index into `classes`.
local builderRows = {}      -- builderRows[i] = { classIndex, specIndex, classFS, specFS }
local presetIndex = 1       -- selected saved preset
local presetSelFS           -- FontString showing the selected preset's name
local presetNameEdit        -- name EditBox

local function RowClassName(row)
    if row.classIndex == 0 then return NONE_CLASS end
    return classes[row.classIndex].name
end

local function RowSpecToken(row)
    if row.classIndex == 0 then return nil end
    local list = specs[classes[row.classIndex].name]
    return list and list[row.specIndex] or nil
end

local function RefreshBuilderRow(i)
    local row = builderRows[i]
    row.classFS:SetText(RowClassName(row))
    row.specFS:SetText(RowSpecToken(row) or "-")
end

local function CycleRowClass(i, dir)
    local row = builderRows[i]
    row.classIndex = row.classIndex + dir
    if row.classIndex < 0 then row.classIndex = #classes
    elseif row.classIndex > #classes then row.classIndex = 0 end
    row.specIndex = 1
    RefreshBuilderRow(i)
end

local function CycleRowSpec(i, dir)
    local row = builderRows[i]
    if row.classIndex == 0 then return end
    local list = specs[classes[row.classIndex].name]
    if not list or #list == 0 then return end
    row.specIndex = row.specIndex + dir
    if row.specIndex < 1 then row.specIndex = #list
    elseif row.specIndex > #list then row.specIndex = 1 end
    RefreshBuilderRow(i)
end

local function RefreshPresetSel()
    if not presetSelFS then return end
    local presets = PlayerbotManagerDB.presets
    if not presets or #presets == 0 then
        presetIndex = 1
        presetSelFS:SetText("(no presets)")
        return
    end
    if presetIndex < 1 then presetIndex = #presets end
    if presetIndex > #presets then presetIndex = 1 end
    presetSelFS:SetText(presets[presetIndex].name)
end

-- Refreshed from PlayerbotManager_Init once SavedVariables are loaded.
function PlayerbotManager_RefreshPresetUI()
    RefreshPresetSel()
end

local function SavePreset()
    local name = presetNameEdit:GetText()
    if not name or name == "" then
        print("PlayerbotManager: enter a preset name first.")
        return
    end
    local members = {}
    for i = 1, 4 do
        local row = builderRows[i]
        if row.classIndex ~= 0 then
            table.insert(members, { class = RowClassName(row), spec = RowSpecToken(row) })
        end
    end
    if #members == 0 then
        print("PlayerbotManager: add at least one bot to the preset.")
        return
    end
    PlayerbotManagerDB.presets = PlayerbotManagerDB.presets or {}
    local replaced = false
    for _, p in ipairs(PlayerbotManagerDB.presets) do
        if p.name == name then p.members = members; replaced = true; break end
    end
    if not replaced then
        table.insert(PlayerbotManagerDB.presets, { name = name, members = members })
        presetIndex = #PlayerbotManagerDB.presets
    end
    RefreshPresetSel()
    print("PlayerbotManager: saved preset '" .. name .. "' (" .. #members .. " bots).")
end

local function ApplySelectedPreset()
    local presets = PlayerbotManagerDB.presets
    if not presets or #presets == 0 then
        print("PlayerbotManager: no presets saved.")
        return
    end
    PlayerbotManager_ApplyPreset(presets[presetIndex])
end

local function DeleteSelectedPreset()
    local presets = PlayerbotManagerDB.presets
    if not presets or #presets == 0 then return end
    local removed = table.remove(presets, presetIndex)
    print("PlayerbotManager: deleted preset '" .. removed.name .. "'.")
    RefreshPresetSel()
end

local function BuildPresetsTab(content)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", content, "TOP", 0, -4)
    title:SetText("Build Team (up to 4 bots)")

    -- 4 builder rows: [<] Class [>]   [<] Spec [>]
    for i = 1, 4 do
        local rowY = -24 - (i - 1) * 26
        local row = { classIndex = 0, specIndex = 1 }

        local cp = CreateButton(content, "<", 18, 18)
        cp:SetPoint("TOPLEFT", content, "TOPLEFT", 2, rowY)
        cp:SetScript("OnClick", function() CycleRowClass(i, -1) end)

        row.classFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.classFS:SetPoint("TOPLEFT", content, "TOPLEFT", 22, rowY - 3)
        row.classFS:SetWidth(74)
        row.classFS:SetJustifyH("CENTER")

        local cn = CreateButton(content, ">", 18, 18)
        cn:SetPoint("TOPLEFT", content, "TOPLEFT", 98, rowY)
        cn:SetScript("OnClick", function() CycleRowClass(i, 1) end)

        local sp = CreateButton(content, "<", 18, 18)
        sp:SetPoint("TOPLEFT", content, "TOPLEFT", 124, rowY)
        sp:SetScript("OnClick", function() CycleRowSpec(i, -1) end)

        row.specFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.specFS:SetPoint("TOPLEFT", content, "TOPLEFT", 144, rowY - 3)
        row.specFS:SetWidth(96)
        row.specFS:SetJustifyH("CENTER")

        local sn = CreateButton(content, ">", 18, 18)
        sn:SetPoint("TOPLEFT", content, "TOPLEFT", 242, rowY)
        sn:SetScript("OnClick", function() CycleRowSpec(i, 1) end)

        builderRows[i] = row
        RefreshBuilderRow(i)
    end

    -- Name + Save
    local nameLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -136)
    nameLabel:SetText("Name:")

    presetNameEdit = CreateFrame("EditBox", "PlayerbotManagerPresetNameEdit", content, "InputBoxTemplate")
    presetNameEdit:SetPoint("TOPLEFT", content, "TOPLEFT", 44, -132)
    presetNameEdit:SetWidth(146)
    presetNameEdit:SetHeight(18)
    presetNameEdit:SetAutoFocus(false)
    presetNameEdit:SetMaxLetters(24)
    presetNameEdit:SetFontObject(ChatFontNormal)
    presetNameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    presetNameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    table.insert(skinEditBoxes, presetNameEdit)

    local save = CreateButton(content, "Save", 56, 20)
    save:SetPoint("TOPLEFT", content, "TOPLEFT", 196, -135)
    save:SetScript("OnClick", SavePreset)

    -- Saved presets: [<] Name [>]  Apply  Delete
    local savedLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    savedLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -166)
    savedLabel:SetText("Saved preset:")

    local pp = CreateButton(content, "<", 18, 18)
    pp:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -182)
    pp:SetScript("OnClick", function() presetIndex = presetIndex - 1; RefreshPresetSel() end)

    presetSelFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    presetSelFS:SetPoint("TOPLEFT", content, "TOPLEFT", 24, -185)
    presetSelFS:SetWidth(150)
    presetSelFS:SetJustifyH("CENTER")

    local pn = CreateButton(content, ">", 18, 18)
    pn:SetPoint("TOPLEFT", content, "TOPLEFT", 176, -182)
    pn:SetScript("OnClick", function() presetIndex = presetIndex + 1; RefreshPresetSel() end)

    local apply = CreateButton(content, "Apply", 80, 24)
    apply:SetPoint("TOPLEFT", content, "TOPLEFT", 24, -212)
    apply:SetScript("OnClick", ApplySelectedPreset)

    local del = CreateButton(content, "Delete", 70, 24)
    del:SetPoint("TOPLEFT", content, "TOPLEFT", 116, -212)
    del:SetScript("OnClick", DeleteSelectedPreset)

    RefreshPresetSel()
end

local function BuildUI()
    -- Main window
    local f = CreateFrame("Frame", "PlayerbotManagerFrame", UIParent)
    f:SetWidth(300)
    f:SetHeight(335)
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

    -- Tabs (4 across; labels shortened to fit)
    local tabLabels = { "Bots", "Form", "Ctrl", "Presets" }
    local tabW = 68
    for i, name in ipairs(tabLabels) do
        local tab = CreateButton(f, name, tabW, 22)
        tab:SetPoint("TOPLEFT", f, "TOPLEFT", 11 + (i - 1) * (tabW + 1), -40)
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
    BuildPresetsTab(contentFrames[4])

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

-- Place the button on a ring around the *true* minimap centre using the saved
-- angle (degrees, default 225 = lower-left). Size-/scale-independent, so it
-- works with ElvUI's resized minimap on 3.3.5a.
function PlayerbotManager_PositionButton()
    if not PlayerbotManagerButtonFrame then return end
    local angle = math.rad(PlayerbotManagerDB.buttonAngle or 225)
    local rx = (Minimap:GetWidth() / 2) + 5
    local ry = (Minimap:GetHeight() / 2) + 5
    PlayerbotManagerButtonFrame:ClearAllPoints()
    PlayerbotManagerButtonFrame:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * rx, math.sin(angle) * ry)
end

function PlayerbotManagerButtonFrame_BeingDragged()
    -- Cursor position -> angle around the minimap centre (both in the same
    -- coordinate space once the cursor is divided by the minimap's scale).
    local scale = Minimap:GetEffectiveScale()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    PlayerbotManagerDB.buttonAngle = math.deg(math.atan2(cy - my, cx - mx))
    PlayerbotManager_PositionButton()
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
    PlayerbotManager_PositionButton()
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

    -- Re-place the minimap button now that ElvUI has finished sizing the minimap
    PlayerbotManagerDB.buttonPos = nil   -- drop the old, broken x/y format
    PlayerbotManager_PositionButton()

    -- Populate the saved-preset selector now that SavedVariables are loaded
    PlayerbotManager_RefreshPresetUI()

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
        if S.HandleEditBox then
            for _, e in ipairs(skinEditBoxes) do
                S:HandleEditBox(e)
            end
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
