# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A WoW 3.3.5a (WotLK) client addon for the **Warstorm.org** private server. It is a UI-only **remote control** for server-side playerbots — it implements no bot AI. Every control ultimately calls `SendChatMessage`; the server's bot system parses those messages and acts. Treat this as a clickable wrapper over chat commands the server already accepts.

There is no build, lint, or test tooling. "Running" it means copying the folder into a WoW `Interface/AddOns/` directory and launching the 3.3.5a client (Interface version `30300`). It is already located inside such a path here.

## Architecture

Two cooperating files plus key bindings:

- **`WarstormBotManager.toc`** — manifest. Declares `Interface: 30300`, `SavedVariables: PlayerbotManagerDB`, `OptionalDeps: ElvUI` (so ElvUI loads first when present), and the load order (`Bindings.xml`, `WarstormBotManager.lua`).
- **`WarstormBotManager.lua`** — everything: the `classes`/`formations`/`roles`/`actions`/`footer` data tables, the entire UI built programmatically (no `.xml`), the cyclers, persistence, command senders, and ElvUI skinning.
- **`Bindings.xml`** — keybindings that call the same global functions.

### UI is built in Lua, not XML

`BuildUI()` (called at file load) creates `PlayerbotManagerFrame` as a **tabbed window** (300 wide, **height auto-fits the active tab**): three tab buttons (`Team` / `Form` / `Ctrl`), each with its own content `Frame` in `contentFrames[i]`. Each `Build*Tab` **returns its required window height**; `BuildUI` stores those in `tabHeights[i]`, and `PlayerbotManager_ShowTab(i)` calls `SetHeight(tabHeights[i])` so the window shrinks/grows per tab (Team is tallest, Form shortest). The returned height is `80 + lowest-widget-bottom + padding` (80 = the -68 content top offset + 12 bottom margin); the Ctrl tab derives its height from `footerY` so it tracks the `roles` count. `ShowTab` shows one content frame and `Disable()`s its tab as the active indicator (it iterates `#contentFrames`, so adding a tab needs no change there — but the tab row width is hand-tuned: `tabW`/offsets in `BuildUI` are sized for 3 tabs). `Init` clamps a saved `selectedTab` into range (older builds had a 4th "Presets" tab). The **Ctrl** tab is a generated **role × action grid** — nested loop over `roles` (rows: all/tank/heal/dps/melee/ranged) and `actions` (cols: attack/stay/follow/flee) — plus a `footer` row (Summon/Release/Drink/Skull/CC). The minimap button is built by `BuildMinimapButton()`. Every button is created via the local `CreateButton` helper, which appends it to `skinButtons` for skinning; EditBoxes go in `skinEditBoxes`.

The grid command for a cell is `role.prefix .. action` (e.g. `@tank attack`; the `all` row uses an empty prefix → bare `attack`). To add a role or action, edit the `roles`/`actions` tables — do not hand-place buttons.

### Team tab (live add + builder + presets, merged)

`BuildTeamTab` is the merged **Bots + Presets** tab. It has a **team builder**: 4 rows of `[< Class >] [< Spec >]` cyclers (class includes a `NONE_CLASS` "(none)" sentinel so a row can be empty). `CollectBuilderMembers()` returns the non-empty rows as a `{class, spec}` list and is the single source for both **Add to Party** and **Save**. Below the rows: **Add to Party** / **Remove All**, a name `EditBox` + **Save**, a saved-preset cycler with **Apply** / **Delete** / **ReSpec**, and the **"Re-init bots on level up"** checkbox (`autoLevelCheck`). The old single class cycler (Add Class) is gone — adding bots always goes through the builder rows. Saved presets persist in `PlayerbotManagerDB.presets` = array of `{ name, members = { {class, spec}, ... } }`.

**Add to Party** (`PlayerbotManager_AddTeam(members)`) adds the builder rows to the **current** party *without* removing existing bots (the incremental path). It snapshots existing party-member names first, adds the bots, then after the settle whispers specs **only to the newly-joined members** (`WhisperSpecs(queue, onlyNames)` with `onlyNames` = the snapshot diff) so already-specced bots aren't re-specced. It folds the new bots into `lastApplied.members` so a level-up re-spec covers them. **Apply** (`PlayerbotManager_ApplyPreset`) is the full-reset path (below); **Save** stores the rows as a named preset.

`PlayerbotManager_ApplyPreset(preset)`: removes existing bots (`.warstormbot bot remove *` SAY + `LeaveParty()`, **only when already in a party** — `GetNumPartyMembers() > 0`), adds every bot via `AddBotsSpaced` (`PlayerbotManager_AddBot` → SAY `addclass`), then after a settle does **one party scan** that whispers `talents spec <token>` to each bot. **`AddBotsSpaced(list, baseDelay)` staggers the `addclass` sends ~0.4s apart** (`ADD_STEP`) and returns the last-add delay (so the spec scan is timed at `lastAdd + 2.5`): firing several `SendChatMessage` in one frame hits the chat throttle and the **last** message is silently dropped, so the last bot never spawns. Used by both Apply and Add to Party. Specs are grouped per class token into `queue[token]` (e.g. `SHAMAN → {resto pve, enh pve, ele pve}`); the scan pops one spec per matching party member via `UnitClass("party"..i)` (the locale-independent token, mapped from our display names by `classToken`). So with 3 shamans, all 3 chosen specs get applied — *which* bot gets which doesn't matter. Unassigned specs (a bot that didn't spawn) are printed as a warning.

**Autogear is gated on confirmation, not a fixed delay.** Each bot replies in WHISPER with `picking <spec>` once it switches spec. After whispering, `WhisperSpecs` returns the list of bots it whispered, and `PlayerbotManager_AwaitSpecConfirms(names, timeout, onDone)` waits (via a `CHAT_MSG_WHISPER` listener on `confirmFrame`, matched by sender name + the word "picking", realm-suffix stripped) until **every** whispered bot confirms — then it sends **`autogear` to PARTY** immediately. If some bot doesn't confirm within the timeout (6s), `WarnSpecMissing` prints which bots are missing and **autogear is NOT sent**, reminding the user to send `autogear` manually or `/wbm reinit`. This fixes bots that lag the autogear and get geared for the wrong spec. `AwaitSpecConfirms` uses a per-call `token` so a stale timeout can't fire a superseded callback; with zero whispers it completes immediately. Apply/AddTeam/Reinit all share this path. After autogear, `PlayerbotManager_SetGroupLoot` sets **Free For All loot with an Epic threshold** on its own frame (group updates during formation can otherwise revert the loot method): `SetLootMethod("freeforall")` then, ~0.5s later on a *separate* frame, `SetLootThreshold(4)`. Also exposed as `/wbm loot`. A module `applying` flag blocks overlapping applies (safety reset at ~13s covers the ~4s whisper + 6s confirm-timeout worst case).

Applying a preset (or Add to Party) records `PlayerbotManagerDB.lastApplied` (a `{name, members}` snapshot). On **`PLAYER_LEVEL_UP`**, `PlayerbotManager_OnLevelUp` (registered in `BuildUI`'s event frame, branched by `event` name) runs `PlayerbotManager_ReinitBots`: **per-bot** `.warstormbot bot init=epic <BotName>` to SAY for each party member (the server splits args on spaces, so the name is a separate token — a bare `init=epic` is a no-op and a glued-on name yields "usage: add/remove PLAYERNAME") → `WhisperSpecs(BuildSpecQueue(lastApplied.members))` → confirmation-gated `autogear` (PARTY) as above. `PlayerbotManager_ReinitBots` is shared by the level-up handler, the **ReSpec** button (Team tab), and the `/wbm reinit` command (manual trigger, ignores the toggle). Because `init=epic` is **rejected in combat** (and you're usually in combat right when you level up), `ReinitBots` defers when `UnitAffectingCombat("player")` is true: it sets `reinitPending` and the `PLAYER_REGEN_ENABLED` handler (registered in `BuildUI`) runs it once combat ends. It no-ops when not in a party; if no preset was ever applied it still does init + autogear (no specs to re-whisper, so no confirmation wait). The behaviour is gated by `PlayerbotManagerDB.autoLevelUp` (**default on**, seeded in `Init`). It is toggled by the **"Re-init bots on level up" checkbox on the Team tab** (`autoLevelCheck`, kept in sync by `PlayerbotManager_RefreshAutoLevelCheck`) or the slash command `/wbm levelup [on|off]`. `/wbm` with no args toggles the panel. The checkbox is collected in `skinChecks` and skinned via `S:HandleCheckBox`.

The per-class talent-spec tokens live in the `specs` table (e.g. `specs.Paladin = { "prot pve", ... }`). These are **Warstorm-specific**; the whisper sent is `"talents spec " .. token`. **DK tokens are placeholders** (`-- TODO: verify`) until a high-level DK can query them in game.

### Trade payout (whisper the bot its price)

Warstorm bots buy green-or-better items you trade them, paying ~3× the items' vendor value. The "Trade payout" section in `WarstormBotManager.lua` whispers the trade partner that payout the moment you place/change items in the trade window. It listens on `TRADE_PLAYER_ITEM_CHANGED` (it fires on item change rather than on `AcceptTrade`, because the bot often accepts the trade before you do), debounced via `ScheduleTradeWhisper` (~0.4s, with a retry while `GetItemInfo` is still uncached) and de-duped against `lastTradePayoutMsg` (reset on `TRADE_SHOW`/`TRADE_CLOSED`). `ComputeOfferedVendorValue` sums the vendor sell value of slots 1–6 for items of **quality ≥ 2** (green+), skipping any whose tooltip shows the `LOCKED` line (lockboxes / unlockable containers). **3.3.5a's `GetItemInfo` has no `sellPrice`** (added in 4.0.1), so value is read by scanning a hidden tooltip (`SetTradePlayerItem`) and reading its money frame (`ScanTipSellValue`); the money frame is hidden before each scan so a prior item's price can't linger. The whisper format is `"<g>g<s>s<c>c"` (no spaces, zero components omitted — `FormatPayout`). Gated by `PlayerbotManagerDB.tradeWhisper` (**default on**, seeded in `Init`), toggled by `/wbm tradewhisper [on|off]`; `/wbm tradevalue` prints the computed payout for the open trade without whispering.

**TODO:** the trade-payout toggle is slash-only — add a UI toggle (a checkbox like `autoLevelCheck`, collected in `skinChecks`, kept in sync by a `Refresh*` helper) and, while doing so, tidy up the Team-tab layout for it (the tab is already full at ~360px height, so this likely needs a small re-layout or a new home for trade-related settings). Not yet built.

### Scheduling (no C_Timer on 3.3.5a)

`PlayerbotManager_After(delay, fn)` is a self-contained scheduler: a single hidden frame with an `OnUpdate` that fires queued callbacks when their `GetTime()` target elapses. The preset apply uses it to space out chat commands (bots need time to spawn/join). **Do not** reach for `C_Timer` — it is not guaranteed on this client.

### ElvUI skinning

`PlayerbotManager_SkinElvUI()` runs on `PLAYER_LOGIN` (after ElvUI has loaded). If `ElvUI` is absent it no-ops and the default Blizzard `DialogBox` backdrop set in `BuildUI` remains. When present it grabs `local E = unpack(ElvUI); local S = E:GetModule("Skins", true)` and, inside a `pcall`, strips the backdrop, calls `f:CreateBackdrop("Transparent")`, `S:HandleButton` on every `skinButtons` entry, and `S:HandleCloseButton`. The whole block is `pcall`-guarded so an ElvUI API change can never break the panel.

### The command channel convention (most important thing to know)

Commands split across two chat channels by purpose:

- **Server admin/management → `SAY`**, prefixed `.warstormbot bot ...`
  - e.g. `.warstormbot bot addclass <class>`, `.warstormbot bot remove *`, `.warstormbot bot init=epic`
- **Bot behavior orders → `PARTY`**, sent raw (no prefix)
  - `PlayerbotManager_SetCommand(cmd)` sends `cmd` verbatim to PARTY; `PlayerbotManager_SetFormation` sends `formation <name>`; `autogear` is a PARTY command.
- **Per-bot configuration → `WHISPER`** to a specific bot by name
  - `talents spec <token>` is whispered to one bot (`SendChatMessage(msg, "WHISPER", nil, botName)`), since spec is per-bot. The Presets apply uses this.

Behavior commands frequently use role prefixes the server understands: `@tank`, `@heal`, `@dps`, `@melee`, `@ranged` (e.g. `@tank attack`, `@heal follow`). When adding a button, pick the channel that matches the command's nature.

### State

All persistent state lives in the `PlayerbotManagerDB` SavedVariable: minimap `buttonAngle` (degrees around the minimap ring), `selectedTab`, `presets` (saved team compositions), `lastApplied` (the last-applied/added comp, re-used on level up), `autoLevelUp`, plus `selectedFormation`/`selectedFormationIndex` driven by the formation cycler. (The old `selectedClass`/`selectedClassIndex` are gone — the single class cycler was removed when the Bots and Presets tabs merged.) `PlayerbotManager_Init` (fired on `PLAYER_LOGIN`) seeds the formation default (Shield), re-places the button via `PlayerbotManager_PositionButton` (after ElvUI has sized the minimap), and opens the last-used tab. The minimap button uses the standard LibDBIcon-style angle math (`Minimap:GetCenter()` + cursor angle, size/scale independent) — not a fixed-offset formula — so it tracks the real minimap center under ElvUI.

## Naming caveat

Files and the TOC say "Warstorm", but every frame, global function, SavedVariable, and binding is named `PlayerbotManager*` / `PLAYERBOTMANAGER_*`. Keep new code consistent with the **`PlayerbotManager` prefix** for runtime identifiers. `Bindings.xml` calls `PlayerbotManagerButtonFrame_OnClick` and `PlayerbotManager_SetCommand` by name, and `PlayerbotManagerFrame` / `PlayerbotManagerButtonFrame` are referenced as globals — these names must not change.

## Conventions established while fixing earlier bugs

Keep new code consistent with these conventions:

- **TOC filenames must match on-disk case** (`Bindings.xml`). The Windows loader is case-insensitive, but this addon also runs on a case-sensitive (Linux) filesystem where a mismatch silently fails to load.
- **Build UI in Lua, not XML.** The old `WarstormBotManager.xml` was removed; add new widgets via `CreateFrame` / `CreateButton` inside the `Build*Tab` / `BuildUI` functions so they're laid out, wired, and skinned consistently. Created buttons go through `CreateButton` so they land in `skinButtons`.
- **Derive cycler index from the saved name, not a hard-coded number.** `PlayerbotManager_Init` uses the `IndexByName` helper so `selectedFormation` and its index can't drift if the `formations` table is reordered.
- **Init runs on `PLAYER_LOGIN`** (registered in `BuildUI`'s event frame) and also triggers `PlayerbotManager_SkinElvUI` — don't re-register the event inside `Init`.
- **Lookups over `classes`/`formations` `print` a warning on no-match** rather than silently doing nothing; preserve that feedback.
- **Minimap button position** is saved to `PlayerbotManagerDB.buttonPos` on drag and restored in `Init` (the default `{0,0}` is treated as "untouched" and skipped).
- **Keep ElvUI calls inside the `pcall`** in `PlayerbotManager_SkinElvUI`, and guard on `if ElvUI then` — the addon must stay fully functional with ElvUI absent or after an ElvUI API change.
