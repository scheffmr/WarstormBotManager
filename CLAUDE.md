# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A WoW 3.3.5a (WotLK) client addon for the **Warstorm.org** private server. It is a UI-only **remote control** for server-side playerbots — it implements no bot AI. Every control ultimately calls `SendChatMessage`; the server's bot system parses those messages and acts. Treat this as a clickable wrapper over chat commands the server already accepts.

There is no build, lint, or test tooling. "Running" it means copying the folder into a WoW `Interface/AddOns/` directory and launching the 3.3.5a client (Interface version `30300`). It is already located inside such a path here.

## Architecture

Three cooperating files plus key bindings:

- **`WarstormBotManager.toc`** — manifest. Declares `Interface: 30300` and `SavedVariables: PlayerbotManagerDB`, and the load order (`bindings.xml`, `WarstormBotManager.xml`, `WarstormBotManager.lua`).
- **`WarstormBotManager.xml`** — all UI. A draggable minimap button (`PlayerbotManagerButtonFrame`) toggles the main panel (`PlayerbotManagerFrame`, ~40 buttons). Each button's `<OnClick>` either calls a `PlayerbotManager_*` Lua function or inlines a `SendChatMessage` directly.
- **`WarstormBotManager.lua`** — logic. Holds the `classes` and `formations` tables, the prev/next cyclers, persistence, and the command-sending helpers.
- **`Bindings.xml`** — keybindings that call the same global functions.

### The command channel convention (most important thing to know)

Commands split across two chat channels by purpose:

- **Server admin/management → `SAY`**, prefixed `.warstormbot bot ...`
  - e.g. `.warstormbot bot addclass <class>`, `.warstormbot bot remove *`, `.warstormbot bot init=epic`
- **Bot behavior orders → `PARTY`**, sent raw (no prefix)
  - `PlayerbotManager_SetCommand(cmd)` sends `cmd` verbatim to PARTY; `PlayerbotManager_SetFormation` sends `formation <name>`.

Behavior commands frequently use role prefixes the server understands: `@tank`, `@heal`, `@dps`, `@melee`, `@ranged` (e.g. `@tank attack`, `@heal follow`). When adding a button, pick the channel that matches the command's nature.

### State

All persistent state lives in the `PlayerbotManagerDB` SavedVariable: minimap `buttonPos`, plus `selectedClass`/`selectedClassIndex` and `selectedFormation`/`selectedFormationIndex` driven by the cyclers. `PlayerbotManager_Init` (fired on `PLAYER_LOGIN`) seeds defaults (Druid / Shield) and refreshes the on-panel FontStrings.

## Naming caveat

Files and the TOC say "Warstorm", but every frame, global function, SavedVariable, and binding is named `PlayerbotManager*` / `PLAYERBOTMANAGER_*`. Keep new code consistent with the **`PlayerbotManager` prefix** for runtime identifiers — globals are looked up by those exact names from XML.

## Conventions established while fixing earlier bugs

Several latent bugs have been fixed; keep new code consistent with the resulting conventions:

- **TOC filenames must match on-disk case** (`Bindings.xml`, not `bindings.xml`). The Windows loader is case-insensitive, but this addon also runs on a case-sensitive (Linux) filesystem where a mismatch silently fails to load.
- **The Lua is loaded once, via the TOC** — do not add a `<Script>` tag for it in the XML (a stale one pointing at a nonexistent `PlayerbotManager.lua` used to risk aborting frame creation).
- **Frame/FontString `name=` values must be globally unique.** XML names become globals; duplicates silently overwrite each other. (Resolved cases: `CmdDpsAttack` and `FormationLabel` were previously both colliding under reused names.)
- **Derive cycler index from the saved name, not a hard-coded number.** `PlayerbotManager_Init` uses the `IndexByName` helper so `selectedClass`/`selectedFormation` and their indices can't drift if the `classes`/`formations` tables are reordered.
- **Event registration and initial `Hide` live in the XML `OnLoad`, not in `Init`.** `Init` is the `PLAYER_LOGIN` handler — don't re-register the event there.
- **Lookups over `classes`/`formations` `print` a warning on no-match** rather than silently doing nothing; preserve that feedback.
- **Minimap button position** is saved to `PlayerbotManagerDB.buttonPos` on drag and restored in `Init` (the default `{0,0}` is treated as "untouched" and skipped).
