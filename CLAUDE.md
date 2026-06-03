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

`BuildUI()` (called at file load) creates `PlayerbotManagerFrame` as a **tabbed window** (~290×280): three tab buttons (`Bots` / `Formation` / `Controls`), each with its own content `Frame` in `contentFrames[i]`. `PlayerbotManager_ShowTab(i)` shows one content frame and `Disable()`s its tab as the active indicator. The **Controls** tab is a generated **role × action grid** — nested loop over `roles` (rows: all/tank/heal/dps/melee/ranged) and `actions` (cols: attack/stay/follow/flee) — plus a `footer` row (Summon/Release/Drink/Skull/CC). The minimap button is built by `BuildMinimapButton()`. Every button is created via the local `CreateButton` helper, which appends it to `skinButtons` for skinning.

The grid command for a cell is `role.prefix .. action` (e.g. `@tank attack`; the `all` row uses an empty prefix → bare `attack`). To add a role or action, edit the `roles`/`actions` tables — do not hand-place buttons.

### ElvUI skinning

`PlayerbotManager_SkinElvUI()` runs on `PLAYER_LOGIN` (after ElvUI has loaded). If `ElvUI` is absent it no-ops and the default Blizzard `DialogBox` backdrop set in `BuildUI` remains. When present it grabs `local E = unpack(ElvUI); local S = E:GetModule("Skins", true)` and, inside a `pcall`, strips the backdrop, calls `f:CreateBackdrop("Transparent")`, `S:HandleButton` on every `skinButtons` entry, and `S:HandleCloseButton`. The whole block is `pcall`-guarded so an ElvUI API change can never break the panel.

### The command channel convention (most important thing to know)

Commands split across two chat channels by purpose:

- **Server admin/management → `SAY`**, prefixed `.warstormbot bot ...`
  - e.g. `.warstormbot bot addclass <class>`, `.warstormbot bot remove *`, `.warstormbot bot init=epic`
- **Bot behavior orders → `PARTY`**, sent raw (no prefix)
  - `PlayerbotManager_SetCommand(cmd)` sends `cmd` verbatim to PARTY; `PlayerbotManager_SetFormation` sends `formation <name>`.

Behavior commands frequently use role prefixes the server understands: `@tank`, `@heal`, `@dps`, `@melee`, `@ranged` (e.g. `@tank attack`, `@heal follow`). When adding a button, pick the channel that matches the command's nature.

### State

All persistent state lives in the `PlayerbotManagerDB` SavedVariable: minimap `buttonPos`, `selectedTab`, plus `selectedClass`/`selectedClassIndex` and `selectedFormation`/`selectedFormationIndex` driven by the cyclers. `PlayerbotManager_Init` (fired on `PLAYER_LOGIN`) seeds defaults (Druid / Shield), restores the button position, and opens the last-used tab.

## Naming caveat

Files and the TOC say "Warstorm", but every frame, global function, SavedVariable, and binding is named `PlayerbotManager*` / `PLAYERBOTMANAGER_*`. Keep new code consistent with the **`PlayerbotManager` prefix** for runtime identifiers. `Bindings.xml` calls `PlayerbotManagerButtonFrame_OnClick` and `PlayerbotManager_SetCommand` by name, and `PlayerbotManagerFrame` / `PlayerbotManagerButtonFrame` are referenced as globals — these names must not change.

## Conventions established while fixing earlier bugs

Keep new code consistent with these conventions:

- **TOC filenames must match on-disk case** (`Bindings.xml`). The Windows loader is case-insensitive, but this addon also runs on a case-sensitive (Linux) filesystem where a mismatch silently fails to load.
- **Build UI in Lua, not XML.** The old `WarstormBotManager.xml` was removed; add new widgets via `CreateFrame` / `CreateButton` inside the `Build*Tab` / `BuildUI` functions so they're laid out, wired, and skinned consistently. Created buttons go through `CreateButton` so they land in `skinButtons`.
- **Derive cycler index from the saved name, not a hard-coded number.** `PlayerbotManager_Init` uses the `IndexByName` helper so `selectedClass`/`selectedFormation` and their indices can't drift if the `classes`/`formations` tables are reordered.
- **Init runs on `PLAYER_LOGIN`** (registered in `BuildUI`'s event frame) and also triggers `PlayerbotManager_SkinElvUI` — don't re-register the event inside `Init`.
- **Lookups over `classes`/`formations` `print` a warning on no-match** rather than silently doing nothing; preserve that feedback.
- **Minimap button position** is saved to `PlayerbotManagerDB.buttonPos` on drag and restored in `Init` (the default `{0,0}` is treated as "untouched" and skipped).
- **Keep ElvUI calls inside the `pcall`** in `PlayerbotManager_SkinElvUI`, and guard on `if ElvUI then` — the addon must stay fully functional with ElvUI absent or after an ElvUI API change.
