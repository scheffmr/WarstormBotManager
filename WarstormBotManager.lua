-- Warstorm Bot Manager Addon
-- UI is built programmatically here (no .xml). The frames PlayerbotManagerFrame
-- and PlayerbotManagerButtonFrame, and the PlayerbotManager_* / *_OnClick globals,
-- are kept because Bindings.xml references them by name.

PlayerbotManagerDB = PlayerbotManagerDB or {}

-- Classes and their addclass command tokens.
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

-- Formations and their command tokens.
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
    { label = "Drink",   command = "drink" },
    { label = "Skull",   command = nil },   -- rti skull + attack rti target
    { label = "CC",      command = "rti cc moon" },
}

-- Talent spec command tokens per class (Warstorm-specific); the whisper sent to a
-- bot is "talents spec " .. token, and the token is shown in the Presets UI.
-- DK tokens are unverified placeholders (see TODO below).
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
local skinChecks = {}
local tabButtons = {}
local contentFrames = {}
local tabHeights = {}   -- per-tab target window height; ShowTab resizes to fit
local closeButton
local autoLevelCheck   -- the "Re-init on level up" checkbox on the Bots tab

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
-- Command helpers
------------------------------------------------------------------------

function PlayerbotManager_AddBot(class)
    for _, classInfo in ipairs(classes) do
        if classInfo.name == class then
            SendChatMessage(".warstormbot bot addclass " .. classInfo.command, "SAY")
            return
        end
    end
    print("PlayerbotManager: unknown class '" .. tostring(class) .. "'")
end

function PlayerbotManager_SetFormation(formation)
    for _, formationInfo in ipairs(formations) do
        if formationInfo.name == formation then
            SendChatMessage("formation " .. formationInfo.command, "PARTY")
            return
        end
    end
    print("PlayerbotManager: unknown formation '" .. tostring(formation) .. "'")
end

function PlayerbotManager_SetCommand(command)
    -- Bot orders go to PARTY chat (no /p prefix).
    SendChatMessage(command, "PARTY")
end

------------------------------------------------------------------------
-- Trade payout
--
-- Warstorm bots buy green-or-better items you trade them, paying ~3x the
-- items' vendor value. As soon as you place/change items in the trade window,
-- this whispers the partner the payout: 3 x the summed vendor sell value of the
-- uncommon+ items you're offering, excluding locked / unlockable containers
-- (lockboxes, junkboxes). It fires on item change rather than on accept because
-- the bot often accepts the trade before you do.
--
-- 3.3.5a's GetItemInfo returns no sell price (that was added in 4.0.1), so the
-- value is read by scanning a hidden tooltip's money frame for each offered
-- item -- the same way the merchant "Sell Price" line is rendered. Verify the
-- numbers in game with `/wbm tradevalue` before relying on it.
------------------------------------------------------------------------

local TRADE_SLOTS = 6   -- slots 1..6 are tradeable; slot 7 is the no-trade slot

-- Lazily-built hidden tooltip used to read item sell price / locked status.
local tradeScanTip
local function EnsureScanTip()
    if not tradeScanTip then
        tradeScanTip = CreateFrame("GameTooltip", "PlayerbotManagerTradeScanTip",
            UIParent, "GameTooltipTemplate")
    end
    return tradeScanTip
end

-- Read the (stack) vendor sell value from the scan tooltip's money frame.
-- Returns copper, or 0 when the tooltip shows no money line.
local function ScanTipSellValue()
    local mf = _G["PlayerbotManagerTradeScanTipMoneyFrame1"]
    if not mf or not mf:IsShown() then return 0 end
    local function part(suffix)
        local b = _G["PlayerbotManagerTradeScanTipMoneyFrame1" .. suffix]
        return tonumber(b and b:GetText()) or 0
    end
    return part("GoldButton") * 10000 + part("SilverButton") * 100 + part("CopperButton")
end

-- True if the scan tooltip shows a "Locked" line (lockbox / unlockable container).
local function ScanTipLocked()
    for i = 1, (tradeScanTip:NumLines() or 0) do
        local fs = _G["PlayerbotManagerTradeScanTipTextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt and string.find(txt, LOCKED, 1, true) then
            return true
        end
    end
    return false
end

-- Format copper as "<g>g<s>s<c>c" (no spaces), omitting zero components (each
-- present component keeps its g/s/c suffix). Returns nil for a non-positive amount.
local function FormatPayout(copper)
    if not copper or copper <= 0 then return nil end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local msg = ""
    if g > 0 then msg = msg .. g .. "g" end
    if s > 0 then msg = msg .. s .. "s" end
    if c > 0 then msg = msg .. c .. "c" end
    return msg
end

-- Sum the vendor sell value of the uncommon-or-better, non-locked items the
-- player is currently offering in the open trade. Returns (copper, itemCount,
-- pending) -- `pending` is true when an offered item's data isn't cached yet
-- (GetItemInfo nil), so the caller can retry once it loads.
local function ComputeOfferedVendorValue()
    local tip = EnsureScanTip()
    local total, count, pending = 0, 0, false
    for i = 1, TRADE_SLOTS do
        local link = GetTradePlayerItemLink(i)
        if link then
            local _, _, quality = GetItemInfo(link)
            if not quality then
                pending = true   -- item not cached yet; value would be wrong now
            elseif quality >= 2 then   -- 2 = uncommon (green) or better
                -- ClearLines() doesn't hide the money frame, so a previous
                -- item's sell price can linger -- hide it so a no-sell-price
                -- item reads as 0 instead of the last item's value.
                local stale = _G["PlayerbotManagerTradeScanTipMoneyFrame1"]
                if stale then stale:Hide() end
                tip:SetOwner(UIParent, "ANCHOR_NONE")
                tip:ClearLines()
                tip:SetTradePlayerItem(i)
                if not ScanTipLocked() then
                    local v = ScanTipSellValue()
                    if v > 0 then
                        total = total + v
                        count = count + 1
                    end
                end
            end
        end
    end
    return total, count, pending
end

-- Name of the current trade partner (unit "NPC" during a trade), or nil.
local function TradePartnerName()
    local n = UnitName("NPC")
    if n and n ~= "" and n ~= UNKNOWN then return n end
    if TradeFrameRecipientNameText then
        local t = TradeFrameRecipientNameText:GetText()
        if t and t ~= "" then return t end
    end
    return nil
end

-- Whisper-state: collapse a burst of item-change events into one whisper, and
-- don't re-whisper an amount that hasn't changed within the same trade session.
local tradeDebounceToken
local lastTradePayoutMsg

-- Compute the current offer's payout and whisper it to the partner. No-op when
-- the toggle is off, there's no partner, nothing qualifying is on offer, or the
-- amount is unchanged since the last whisper this trade. When the offer has no
-- payout (empty/removed), it forgets the last amount so re-adding the same item
-- whispers again.
function PlayerbotManager_WhisperTradePayout()
    if PlayerbotManagerDB.tradeWhisper == false then return end
    local partner = TradePartnerName()
    if not partner then return end
    local total, count = ComputeOfferedVendorValue()
    local msg = FormatPayout(total * 3)
    if not msg then
        lastTradePayoutMsg = nil   -- offer empty: let a re-add re-whisper
        return
    end
    if msg == lastTradePayoutMsg then return end
    lastTradePayoutMsg = msg
    SendChatMessage(msg, "WHISPER", nil, partner)
    print("PlayerbotManager: trade payout -> " .. partner .. ": " .. msg ..
        " (3x vendor of " .. count .. " item(s)).")
end

-- Debounce: TRADE_PLAYER_ITEM_CHANGED fires once per slot, so wait for the burst
-- to settle before whispering. If an item's data isn't cached yet, retry a few
-- times (~0.4s apart) so the whisper isn't skipped while it loads.
local function ScheduleTradeWhisper(attempt)
    attempt = attempt or 1
    local token = {}
    tradeDebounceToken = token
    PlayerbotManager_After(0.4, function()
        if tradeDebounceToken ~= token then return end   -- superseded by a newer change
        local _, _, pending = ComputeOfferedVendorValue()
        if pending and attempt < 5 then
            ScheduleTradeWhisper(attempt + 1)
        else
            PlayerbotManager_WhisperTradePayout()
        end
    end)
end

-- Whisper the payout as soon as items are placed/changed in the trade window
-- (the bot can accept before you do, so accept-time is too late). TRADE_SHOW /
-- TRADE_CLOSED start a fresh session so the next trade re-whispers.
local tradeFrame = CreateFrame("Frame")
tradeFrame:RegisterEvent("TRADE_SHOW")
tradeFrame:RegisterEvent("TRADE_CLOSED")
tradeFrame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
tradeFrame:SetScript("OnEvent", function(self, event)
    if event == "TRADE_PLAYER_ITEM_CHANGED" then
        ScheduleTradeWhisper()
    else
        lastTradePayoutMsg = nil
    end
end)

------------------------------------------------------------------------
-- Lightweight OnUpdate scheduler (3.3.5a has no guaranteed C_Timer). Used to
-- space out the preset-apply chat commands.
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
            -- pcall so one failing callback can't abort the loop (and thus skip
            -- later-due items or the `applying` reset that follows an apply step).
            local ok, err = pcall(item.fn)
            if not ok then
                print("PlayerbotManager: scheduled task error: " .. tostring(err))
            end
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

-- Map our class display names to the UnitClass() token (locale-independent),
-- so specs can be matched to party members regardless of client language.
local classToken = {
    Warrior = "WARRIOR", Paladin = "PALADIN", Hunter = "HUNTER", Rogue = "ROGUE",
    Priest = "PRIEST", Shaman = "SHAMAN", Mage = "MAGE", Warlock = "WARLOCK",
    Druid = "DRUID", DK = "DEATHKNIGHT",
}

-- Group a member list's specs by class token, e.g. SHAMAN -> {resto pve, enh pve}.
local function BuildSpecQueue(members)
    local queue = {}        -- queue[token] = { spec, spec, ... }
    for _, m in ipairs(members or {}) do
        if m.class and m.class ~= NONE_CLASS then
            local token = classToken[m.class]
            if token and m.spec then
                queue[token] = queue[token] or {}
                table.insert(queue[token], m.spec)
            end
        end
    end
    return queue
end

-- Whisper one queued spec to each party bot of a matching class (consumes the
-- queue). Assignment within a class is order-independent; specs left unassigned
-- (fewer bots than queued) are reported. Returns the list of bot names whispered
-- (so the caller can wait for their "picking ..." confirmations).
--
-- `onlyNames` (optional set of party-member names) restricts whispers to those
-- members -- used by incremental Add so existing, already-specced bots aren't
-- re-specced; nil means every party member is eligible.
local function WhisperSpecs(queue, onlyNames)
    -- Assumption: every party member is a bot. On 3.3.5a there is no reliable
    -- client-side signal to tell bots from real players, so a spec whisper that
    -- reaches an actual player is harmless (cosmetic). Risk accepted by design.
    local whispered = {}
    for i = 1, GetNumPartyMembers() do
        local name = UnitName("party" .. i)
        if name and (not onlyNames or onlyNames[name]) then
            local _, token = UnitClass("party" .. i)
            local q = token and queue[token]
            if q and #q > 0 then
                SendChatMessage("talents spec " .. table.remove(q, 1), "WHISPER", nil, name)
                table.insert(whispered, name)
            end
        end
    end
    for _, left in pairs(queue) do
        for _, leftover in ipairs(left) do
            print("  (no bot for spec '" .. leftover .. "' -- a bot may not have spawned)")
        end
    end
    return whispered
end

------------------------------------------------------------------------
-- Spec-confirmation tracking
--
-- After whispering "talents spec ..." each bot replies in WHISPER with
-- "picking <spec>". We wait until every whispered bot confirms before sending
-- autogear; if some never reply within the timeout we warn and skip autogear,
-- so a half-specced group isn't geared for the wrong spec.
------------------------------------------------------------------------

local awaiting = nil   -- { remaining = {name=true,...}, count, onDone, token }

local confirmFrame = CreateFrame("Frame")
confirmFrame:RegisterEvent("CHAT_MSG_WHISPER")
confirmFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not awaiting or not sender then return end
    local short = string.match(sender, "^[^-]+") or sender   -- strip "-Realm" if present
    if awaiting.remaining[short] and message and string.find(string.lower(message), "picking") then
        awaiting.remaining[short] = nil
        awaiting.count = awaiting.count - 1
        if awaiting.count <= 0 then
            local cb = awaiting.onDone
            awaiting = nil
            cb(true, {})
        end
    end
end)

-- Wait up to `timeout` seconds for every name in `names` (array) to whisper
-- "picking ...". onDone(allConfirmed, missing) fires exactly once: immediately
-- when all confirm, or at the timeout with the still-missing names.
function PlayerbotManager_AwaitSpecConfirms(names, timeout, onDone)
    local remaining, count = {}, 0
    for _, n in ipairs(names or {}) do
        if not remaining[n] then remaining[n] = true; count = count + 1 end
    end
    if count == 0 then onDone(true, {}); return end
    local token = {}
    awaiting = { remaining = remaining, count = count, onDone = onDone, token = token }
    PlayerbotManager_After(timeout, function()
        -- Only fire if this same await is still pending (a newer one supersedes it).
        if awaiting and awaiting.token == token then
            local missing = {}
            for n in pairs(awaiting.remaining) do table.insert(missing, n) end
            awaiting = nil
            onDone(false, missing)
        end
    end)
end

-- Shared warning when not every bot confirmed its spec in time.
local function WarnSpecMissing(missing)
    print("PlayerbotManager: WARNING - " .. #missing .. " bot(s) did not confirm their spec: " ..
        table.concat(missing, ", "))
    print("  autogear was NOT sent. Once the bots settle, send it manually:")
    print("  type 'autogear' in party chat, or run /wbm reinit.")
end

local applying = false
local reinitPending = false   -- a re-init was requested during combat; run it on regen

-- Send `addclass` for each member, spaced out in time. Firing several
-- SendChatMessage calls in one frame hits the chat throttle and the last
-- message(s) get silently dropped -- so the last bot never spawns. Staggering
-- them ~0.4s apart keeps every command. Returns the delay after which the last
-- add has been sent, so the caller can time the follow-up steps.
local ADD_STEP = 0.4
local function AddBotsSpaced(list, baseDelay)
    for i, m in ipairs(list) do
        local cls = m.class
        PlayerbotManager_After(baseDelay + (i - 1) * ADD_STEP, function()
            PlayerbotManager_AddBot(cls)
        end)
    end
    return baseDelay + math.max(0, #list - 1) * ADD_STEP
end

-- Apply a preset: remove existing bots, add all the preset's bots, then in
-- one party scan whisper each class's chosen specs to that class's bots, set the
-- group to Free For All / Epic loot, and finally send `autogear` to PARTY.
function PlayerbotManager_ApplyPreset(preset)
    if not preset then return end
    if applying then
        print("PlayerbotManager: a preset is already being applied, please wait.")
        return
    end

    -- Collect the non-empty slots (copy, so the remembered comp is independent).
    local members = {}
    for _, m in ipairs(preset.members or {}) do
        if m.class and m.class ~= NONE_CLASS then
            table.insert(members, { class = m.class, spec = m.spec })
        end
    end
    if #members == 0 then
        print("PlayerbotManager: preset '" .. tostring(preset.name) .. "' has no bots.")
        return
    end

    -- Remember this comp so PLAYER_LEVEL_UP can re-apply the same specs.
    PlayerbotManagerDB.lastApplied = { name = preset.name, members = members }

    applying = true
    -- Safety net: if some apply step unexpectedly errors before the regular
    -- reset (in the confirm callback), don't leave `applying` stuck true -- that
    -- would block every future apply until /reload. Fires after the worst-case
    -- sequence (whisper at ~4s + 6s confirm timeout = ~10s).
    PlayerbotManager_After(13, function() applying = false end)
    print("PlayerbotManager: applying preset '" .. preset.name .. "' (" .. #members .. " bots)...")

    -- 1) Clear any existing group first (only when grouped; bots are party members).
    local hadParty = GetNumPartyMembers() > 0
    if hadParty then
        SendChatMessage(".warstormbot bot remove *", "SAY")
        LeaveParty()
    end

    -- 2) Add every bot, staggered (after a short settle if a group was just
    --    cleared) so the chat throttle can't drop the last addclass.
    local lastAdd = AddBotsSpaced(members, hadParty and 1 or 0)

    -- 3) Once they've joined (last add + a settle), assign specs by class, wait
    --    for every bot to confirm ("picking ..."), then gear -- so autogear can't
    --    race ahead of a bot that hasn't switched spec yet.
    PlayerbotManager_After(lastAdd + 2.5, function()
        local whispered = WhisperSpecs(BuildSpecQueue(members))
        PlayerbotManager_AwaitSpecConfirms(whispered, 6, function(allOk, missing)
            if allOk then
                SendChatMessage("autogear", "PARTY")
                print("PlayerbotManager: preset '" .. preset.name .. "' applied (all bots confirmed, autogear sent).")
            else
                WarnSpecMissing(missing)
            end
            applying = false
        end)
        -- 4) Set loot last, on its own frame: group updates during formation can
        --    otherwise revert the loot method.
        PlayerbotManager_After(2, function()
            PlayerbotManager_SetGroupLoot()
        end)
    end)
end

-- Set Free For All loot with an Epic threshold (4). Method and threshold are set
-- on separate frames; setting both together can drop the method change.
function PlayerbotManager_SetGroupLoot()
    if GetNumPartyMembers() == 0 or not IsPartyLeader() then return end
    SetLootMethod("freeforall")
    PlayerbotManager_After(0.5, function()
        if IsPartyLeader() then
            SetLootThreshold(4)   -- 2=uncommon 3=rare 4=epic 5=legendary
        end
    end)
end

-- Re-init the current bots: per-bot `.warstormbot bot init=epic <Name>` to SAY
-- (the name must be a separate, space-delimited token), then re-apply the last
-- comp's specs and autogear. Shared by the level-up handler, the ReSpec button,
-- and /wbm reinit.
function PlayerbotManager_ReinitBots()
    if GetNumPartyMembers() == 0 then
        print("PlayerbotManager: no bots in the party to re-init.")
        return
    end
    -- init=epic is rejected while in combat; defer until PLAYER_REGEN_ENABLED.
    if UnitAffectingCombat("player") then
        reinitPending = true
        print("PlayerbotManager: in combat -- bots will re-init when combat ends.")
        return
    end
    reinitPending = false
    -- Assumption: every party member is a bot (see WhisperSpecs). init=epic for a
    -- real player is rejected server-side, so a misfire here is harmless too.
    for i = 1, GetNumPartyMembers() do
        local n = UnitName("party" .. i)
        if n then
            SendChatMessage(".warstormbot bot init=epic " .. n, "SAY")
        end
    end
    local last = PlayerbotManagerDB.lastApplied
    PlayerbotManager_After(3, function()
        if last and last.members then
            local whispered = WhisperSpecs(BuildSpecQueue(last.members))
            PlayerbotManager_AwaitSpecConfirms(whispered, 6, function(allOk, missing)
                if allOk then
                    SendChatMessage("autogear", "PARTY")
                    print("PlayerbotManager: bots re-initialised (all confirmed, autogear sent).")
                else
                    WarnSpecMissing(missing)
                end
            end)
        else
            -- No remembered comp -> no specs to re-whisper, just gear.
            PlayerbotManager_After(1, function()
                SendChatMessage("autogear", "PARTY")
                print("PlayerbotManager: bots re-initialised.")
            end)
        end
    end)
end

-- Add the given members (each { class, spec }) as bots to the CURRENT party
-- without removing existing bots, whisper each NEW bot its spec once it joins,
-- wait for confirmations, then autogear. Specs target only the newly-joined
-- party members (snapshot diff) so existing bots aren't re-specced. Used by the
-- "Add to Party" button on the Team tab.
function PlayerbotManager_AddTeam(members)
    local list = {}
    for _, m in ipairs(members or {}) do
        if m.class and m.class ~= NONE_CLASS then
            table.insert(list, { class = m.class, spec = m.spec })
        end
    end
    if #list == 0 then
        print("PlayerbotManager: add at least one class to the team first.")
        return
    end
    if applying then
        print("PlayerbotManager: busy applying a team, please wait.")
        return
    end
    applying = true
    PlayerbotManager_After(13, function() applying = false end)   -- safety (see ApplyPreset)

    -- Snapshot the current bots so we spec only the new arrivals.
    local before = {}
    for i = 1, GetNumPartyMembers() do
        local n = UnitName("party" .. i)
        if n then before[n] = true end
    end

    print("PlayerbotManager: adding " .. #list .. " bot(s) to the party...")
    -- Staggered so the chat throttle can't drop the last addclass.
    local lastAdd = AddBotsSpaced(list, 0)

    -- Fold the new bots into lastApplied so a level-up re-spec covers them too.
    local la = PlayerbotManagerDB.lastApplied
    if not la or not la.members then la = { name = "(team)", members = {} } end
    for _, m in ipairs(list) do
        table.insert(la.members, { class = m.class, spec = m.spec })
    end
    PlayerbotManagerDB.lastApplied = la

    PlayerbotManager_After(lastAdd + 2.5, function()
        local newNames = {}
        for i = 1, GetNumPartyMembers() do
            local n = UnitName("party" .. i)
            if n and not before[n] then newNames[n] = true end
        end
        local whispered = WhisperSpecs(BuildSpecQueue(list), newNames)
        PlayerbotManager_AwaitSpecConfirms(whispered, 6, function(allOk, missing)
            if allOk then
                SendChatMessage("autogear", "PARTY")
                print("PlayerbotManager: bots added (all confirmed specs, autogear sent).")
            else
                WarnSpecMissing(missing)
            end
            applying = false
        end)
        PlayerbotManager_After(2, function() PlayerbotManager_SetGroupLoot() end)
    end)
end

-- Level-up handler: gated by the autoLevelUp toggle; no-op when solo.
function PlayerbotManager_OnLevelUp()
    if PlayerbotManagerDB.autoLevelUp == false then return end   -- toggle (default on)
    if GetNumPartyMembers() == 0 then return end
    PlayerbotManager_ReinitBots()
end

------------------------------------------------------------------------
-- Selection cyclers
------------------------------------------------------------------------

local function RefreshFormationText()
    if SelectedFormationText then
        SelectedFormationText:SetText(PlayerbotManagerDB.selectedFormation)
    end
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
    -- Resize the window to the active tab's content (tabs differ a lot in height).
    if PlayerbotManagerFrame and tabHeights[index] then
        PlayerbotManagerFrame:SetHeight(tabHeights[index])
    end
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

-- Sync the Team-tab checkbox with the stored setting (default on).
function PlayerbotManager_RefreshAutoLevelCheck()
    if autoLevelCheck then
        autoLevelCheck:SetChecked(PlayerbotManagerDB.autoLevelUp ~= false)
    end
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

    -- +80 frame chrome; lowest widget (Set/Check bottom ~90) plus padding.
    return 180
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

    -- Frame height derived from the footer row (22 tall) so it tracks `roles`:
    -- +80 frame chrome, footer bottom = |footerY| + 22, plus padding.
    return 80 + math.abs(footerY) + 22 + 6
end

------------------------------------------------------------------------
-- Team tab (live add + builder + saved-preset browser, merged)
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

-- The non-empty builder rows as a { class, spec } member list (the live "team").
local function CollectBuilderMembers()
    local members = {}
    for i = 1, 4 do
        local row = builderRows[i]
        if row.classIndex ~= 0 then
            table.insert(members, { class = RowClassName(row), spec = RowSpecToken(row) })
        end
    end
    return members
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
    local members = CollectBuilderMembers()
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
    presetNameEdit:ClearFocus()   -- drop the cursor/focus once it's saved
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

local function BuildTeamTab(content)
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

    -- Live actions: add the configured rows to the CURRENT party, or clear it.
    local add = CreateButton(content, "Add to Party", 120, 22)
    add:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -126)
    add:SetScript("OnClick", function()
        PlayerbotManager_AddTeam(CollectBuilderMembers())
    end)

    local removeAll = CreateButton(content, "Remove All", 120, 22)
    removeAll:SetPoint("TOPLEFT", content, "TOPLEFT", 128, -126)
    removeAll:SetScript("OnClick", function()
        SendChatMessage(".warstormbot bot remove *", "SAY")
        LeaveParty()
    end)

    -- Save the configured rows as a named preset.
    local nameLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -156)
    nameLabel:SetText("Name:")

    presetNameEdit = CreateFrame("EditBox", "PlayerbotManagerPresetNameEdit", content, "InputBoxTemplate")
    presetNameEdit:SetPoint("TOPLEFT", content, "TOPLEFT", 44, -152)
    presetNameEdit:SetWidth(130)
    presetNameEdit:SetHeight(18)
    presetNameEdit:SetAutoFocus(false)
    presetNameEdit:SetMaxLetters(24)
    presetNameEdit:SetFontObject(ChatFontNormal)
    presetNameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    presetNameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    table.insert(skinEditBoxes, presetNameEdit)

    local save = CreateButton(content, "Save", 64, 20)
    save:SetPoint("TOPLEFT", content, "TOPLEFT", 180, -155)
    save:SetScript("OnClick", SavePreset)

    -- Saved presets: [<] Name [>]  then  Apply (full reset) / Delete / ReSpec
    local savedLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    savedLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -180)
    savedLabel:SetText("Saved preset:")

    local pp = CreateButton(content, "<", 18, 18)
    pp:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -196)
    pp:SetScript("OnClick", function() presetIndex = presetIndex - 1; RefreshPresetSel() end)

    presetSelFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    presetSelFS:SetPoint("TOPLEFT", content, "TOPLEFT", 24, -199)
    presetSelFS:SetWidth(150)
    presetSelFS:SetJustifyH("CENTER")

    local pn = CreateButton(content, ">", 18, 18)
    pn:SetPoint("TOPLEFT", content, "TOPLEFT", 176, -196)
    pn:SetScript("OnClick", function() presetIndex = presetIndex + 1; RefreshPresetSel() end)

    local apply = CreateButton(content, "Apply", 70, 24)
    apply:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -220)
    apply:SetScript("OnClick", ApplySelectedPreset)

    local del = CreateButton(content, "Delete", 66, 24)
    del:SetPoint("TOPLEFT", content, "TOPLEFT", 78, -220)
    del:SetScript("OnClick", DeleteSelectedPreset)

    local respec = CreateButton(content, "ReSpec", 90, 24)
    respec:SetPoint("TOPLEFT", content, "TOPLEFT", 150, -220)
    respec:SetScript("OnClick", PlayerbotManager_ReinitBots)

    -- Toggle: re-init bots (init=epic + re-spec + autogear) automatically on level up.
    autoLevelCheck = CreateFrame("CheckButton", "PlayerbotManagerAutoLevelCheck", content, "UICheckButtonTemplate")
    autoLevelCheck:SetWidth(24)
    autoLevelCheck:SetHeight(24)
    autoLevelCheck:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -250)
    local chkLabel = _G["PlayerbotManagerAutoLevelCheckText"]
    if chkLabel then
        chkLabel:SetFontObject(GameFontNormalSmall)
        chkLabel:SetText("Re-init bots on level up")
    end
    autoLevelCheck:SetScript("OnClick", function(self)
        PlayerbotManagerDB.autoLevelUp = self:GetChecked() and true or false
    end)
    table.insert(skinChecks, autoLevelCheck)

    RefreshPresetSel()

    -- Window height: content starts at frame -68, bottom margin 12 (so +80), plus
    -- the lowest widget here (checkbox bottom ~274) and a little padding.
    return 360
end

local function BuildUI()
    -- Main window
    local f = CreateFrame("Frame", "PlayerbotManagerFrame", UIParent)
    f:SetWidth(300)
    f:SetHeight(360)   -- placeholder; ShowTab resizes to the active tab on first show
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

    -- Tabs (3 across; the Team tab merges the old Bots + Presets tabs)
    local tabLabels = { "Team", "Form", "Ctrl" }
    local tabW = 88
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

    tabHeights[1] = BuildTeamTab(contentFrames[1])
    tabHeights[2] = BuildFormationTab(contentFrames[2])
    tabHeights[3] = BuildControlsTab(contentFrames[3])

    -- Event handling: init + skin on login; re-init bots on level up; run a
    -- combat-deferred re-init when combat ends.
    f:RegisterEvent("PLAYER_LOGIN")
    f:RegisterEvent("PLAYER_LEVEL_UP")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LEVEL_UP" then
            PlayerbotManager_OnLevelUp()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if reinitPending then
                reinitPending = false
                PlayerbotManager_ReinitBots()
            end
        else  -- PLAYER_LOGIN
            PlayerbotManager_Init()
            PlayerbotManager_SkinElvUI()
        end
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
    -- Formation selection: derive index from the saved name so the two can't drift.
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

    -- Auto re-init bots on level up: default ON (post to party when grouped)
    if PlayerbotManagerDB.autoLevelUp == nil then
        PlayerbotManagerDB.autoLevelUp = true
    end
    PlayerbotManager_RefreshAutoLevelCheck()

    -- Whisper the bot its payout when you trade it items: default ON.
    if PlayerbotManagerDB.tradeWhisper == nil then
        PlayerbotManagerDB.tradeWhisper = true
    end

    -- Populate the saved-preset selector now that SavedVariables are loaded
    PlayerbotManager_RefreshPresetUI()

    -- Open on the last-used tab (clamp: the old 4-tab layout could have saved 4)
    local tab = PlayerbotManagerDB.selectedTab or 1
    if tab < 1 or tab > #contentFrames then tab = 1 end
    PlayerbotManager_ShowTab(tab)
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
        if S.HandleCheckBox then
            for _, c in ipairs(skinChecks) do
                S:HandleCheckBox(c)
            end
        end
        if closeButton then
            S:HandleCloseButton(closeButton, f.backdrop)
        end
    end)
end

------------------------------------------------------------------------
-- Slash command: /wbm (panel toggle, reinit, loot, level-up toggle)
------------------------------------------------------------------------

SLASH_WARSTORMBOTMANAGER1 = "/wbm"
SlashCmdList["WARSTORMBOTMANAGER"] = function(msg)
    msg = string.lower(msg or "")
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")

    if msg == "" then
        PlayerbotManagerButtonFrame_OnClick()        -- toggle the panel
    elseif msg == "reinit" then
        PlayerbotManager_ReinitBots()                -- manual re-init now
    elseif msg == "loot" then
        PlayerbotManager_SetGroupLoot()              -- Free For All + Epic threshold
    elseif msg == "levelup" then
        PlayerbotManagerDB.autoLevelUp = not PlayerbotManagerDB.autoLevelUp
        PlayerbotManager_RefreshAutoLevelCheck()
        print("PlayerbotManager: auto re-init on level up " ..
            (PlayerbotManagerDB.autoLevelUp and "ENABLED" or "DISABLED") .. ".")
    elseif msg == "levelup on" then
        PlayerbotManagerDB.autoLevelUp = true
        PlayerbotManager_RefreshAutoLevelCheck()
        print("PlayerbotManager: auto re-init on level up ENABLED.")
    elseif msg == "levelup off" then
        PlayerbotManagerDB.autoLevelUp = false
        PlayerbotManager_RefreshAutoLevelCheck()
        print("PlayerbotManager: auto re-init on level up DISABLED.")
    elseif msg == "tradewhisper" or msg == "tradewhisper on" or msg == "tradewhisper off" then
        if msg == "tradewhisper on" then
            PlayerbotManagerDB.tradeWhisper = true
        elseif msg == "tradewhisper off" then
            PlayerbotManagerDB.tradeWhisper = false
        else
            PlayerbotManagerDB.tradeWhisper = (PlayerbotManagerDB.tradeWhisper == false)
        end
        print("PlayerbotManager: trade payout whisper " ..
            (PlayerbotManagerDB.tradeWhisper ~= false and "ENABLED" or "DISABLED") .. ".")
    elseif msg == "tradevalue" then
        local total, count = ComputeOfferedVendorValue()
        if count == 0 then
            print("PlayerbotManager: no green+ tradeable items found (open a trade and place items first).")
        else
            print("PlayerbotManager: " .. count .. " item(s), vendor " ..
                (FormatPayout(total) or "0c") .. ", 3x payout = " ..
                (FormatPayout(total * 3) or "0c") .. ".")
        end
    else
        print("PlayerbotManager commands:")
        print("  /wbm  -  toggle the bot manager panel")
        print("  /wbm reinit  -  re-init the current bots now (init=epic + re-spec + autogear)")
        print("  /wbm loot  -  set the group to Free For All / Epic threshold")
        print("  /wbm levelup [on|off]  -  auto re-init bots on level up (currently " ..
            (PlayerbotManagerDB.autoLevelUp ~= false and "on" or "off") .. ")")
        print("  /wbm tradewhisper [on|off]  -  whisper the bot its payout when you trade it items (currently " ..
            (PlayerbotManagerDB.tradeWhisper ~= false and "on" or "off") .. ")")
        print("  /wbm tradevalue  -  print the 3x payout for items in the open trade (no whisper)")
    end
end

-- Build the UI at load time; Init/skin run on PLAYER_LOGIN.
-- Minimap button first: it's the entry point, so build it independently of the panel.
BuildMinimapButton()
BuildUI()
