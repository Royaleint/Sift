# Sift

Sift quietly hides gold-selling, boosting and carry spam from your chat. Filtering is on by default, and anything it hides, you can still read.

Works on Retail, Classic Era, TBC Anniversary, MoP Classic and WoW Forever.

Everything stays on your computer. No telemetry, no online updates.

## What it hides

- **Gold selling**, **Boosting** and **Carrying**, each with its own switch: Active, Paused (logged to History but left in chat), or Off.
- **My Keywords**: words and phrases you add yourself.

Sift covers public channels, say, yell, emotes, whispers, Battle.net whispers, and AFK/DND auto-replies. You can also block a player yourself with **Block (Sift)** on their right-click menu.

## Getting a message back

Every blocked message goes to the History panel (the most recent 300 per character by default; you can change this in Config). Open History, pick a message, and choose:

- **Restore** to undo the block. The message does not reappear in chat, but it stays readable in History.
- **Restore + Always allow** to also add that player to your Allowlist.

## Chat bubbles

Sift can hide the chat bubble above a blocked Say or Yell message. It is off by default; turn on **Filter bubbles** in Config under Surfaces.

## Installation

Available on CurseForge. For a manual install:

1. Clone or download this repository.
2. Place the `Sift/` folder in your WoW client's `Interface/AddOns/` folder, so it lands at `Interface/AddOns/Sift/`. Foundry-1.0 and the other libraries Sift uses ship embedded inside `Sift/Libs/`, so no separate install is needed. A standalone install of [Foundry-1.0](https://www.curseforge.com/wow/addons/foundry-1-0) takes priority over the embedded copy if installed and enabled.
3. Enable it in your addon list and `/reload`.

## Opening Sift

- **Minimap button**: left-click opens History; right-click opens the pause menu and settings. You can hide the button in Config under UI.
- **Game settings**: the AddOns settings page for Sift has an "Open Sift Config..." button.
- **Slash commands**:

| Command | What it does |
|---------|--------------|
| `/sift` or `/sift history` | Open or close History |
| `/sift config` or `/sift options` | Open Config |
| `/sift allow <name>` | Always allow a sender from your History (Name-Realm, or the full name on WoW Forever) |
| `/sift export` / `/sift import` | Export or import your Allowlist |
| `/sift clearhistory` | Clear History (asks first) |
| `/sift clearblocked` | Clear the Blocked list (asks first) |
| `/sift rebuildstats` | Rebuild this character's stat counts from the History it still has |

## Privacy

Everything stays on your computer. Sift sends nothing out, and there is no telemetry, online updates, or cloud sync. History is kept per character. Your Allowlist and Blocked list are shared across your characters.

## License

Sift is licensed **All Rights Reserved** with explicit addon permissions
for personal in-game use, private local modification, and contribution forks.
Redistribution, repackaging, commercial use, relicensing, or reuse of
Sift code or data in another project requires prior written
permission. See `LICENSE`.

Vendored libraries under `Libs/` retain their upstream terms; see
`Libs/ATTRIBUTION.md`.

---

## Attribution

Inspired by funkydude's BadBoy (https://github.com/funkydude/BadBoy), a long-running chat-spam filter for WoW. Sift is an independent, original implementation.

Vendored libraries (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) retain their original licenses and authorship; see `Libs/ATTRIBUTION.md`.
