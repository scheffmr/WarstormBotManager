# Warstorm Bot Manager

A lightweight World of Warcraft **3.3.5a (WotLK)** addon for controlling the
server-side **playerbots** on the [Warstorm.org](https://warstorm.org) private server.

The addon implements no bot AI — it is a clickable front-end that sends the chat
commands the server's bot system already understands. Every button ultimately calls
`SendChatMessage`; management commands go to `SAY` (prefixed `.warstormbot bot ...`)
and behavior orders go to `PARTY`.

## Features

- **Minimap button** — drag to reposition (right-click drag), click to toggle the panel.
- **Tabbed window** with three sections:
  - **Bots** — pick a class with the `< >` cycler and **Add** it; **Remove All**; **ReSpec** (`init=epic`).
  - **Formation** — cycle through 8 formations (Shield, Chaos, Circle, Line, Melee, Near, Queue, Arrow), **Set** and **Check**.
  - **Controls** — a **role × action grid**: rows `all / tank / heal / dps / melee / ranged`, columns `attack / stay / follow / flee`, plus a footer of **Summon / Release / Drink / Skull (RTI) / CC (Moon)**.
- **Key bindings** for toggle, summon, attack, follow, stay, and RTSC save/go (see *Key Bindings* in the game options).
- **ElvUI theming** — if [ElvUI](https://www.tukui.org/) is installed, the panel is automatically skinned to match; otherwise it uses the default Blizzard dialog style.
- **Persistence** — selected class, formation, last-used tab, and minimap button position are saved between sessions.

## Installation

1. Download or clone this repository.
2. Copy the `WarstormBotManager` folder into your WoW client's
   `Interface/AddOns/` directory.
3. Restart the client (or `/reload`) and enable the addon at the character select screen.

## Usage

Click the minimap button to open the panel, or bind a key under
**Game Menu → Key Bindings → Warstorm Bot Manager**. Bot management commands
(`addclass`, `remove`, `init=epic`) are sent in `SAY`; movement/targeting orders
are sent in `PARTY`, so you must be in a party with your bots for those to take effect.

## Credits

Original addon by **Moroes**, published on the Warstorm forums:
<https://forum.warstorm.org/showthread.php?tid=3>

This repository is a maintained and redesigned version (Lua-built tabbed UI,
role × action control grid, and ElvUI skinning).

## License

Released under the [MIT License](LICENSE) — you are free to use, modify, and
redistribute it.
