# Sift

A personal chat-spam filter for World of Warcraft with recoverable history. Sift hides spam from your chat, and you can read anything it blocked in the History panel and restore it.

Open History with `/sift` or the minimap button.

Supports Retail, Classic Era, TBC Anniversary, MoP Classic, and WoW Forever.

## Installation

Available on CurseForge. For a manual install:

1. Clone or download this repository.
2. Place the `Sift/` folder in your WoW client's `Interface/AddOns/` folder, so it lands at `Interface/AddOns/Sift/` (each client has its own AddOns folder). Foundry-1.0 and the other vendored libraries (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) ship embedded inside `Sift/Libs/`, so no separate install is needed; see `Libs/ATTRIBUTION.md`. A standalone install of [Foundry-1.0](https://www.curseforge.com/wow/addons/foundry-1-0) takes priority over the embedded copy if installed and enabled.
3. Enable in your addon list and `/reload`.

## Commands

| Command | Description |
|---------|-------------|
| `/sift` | Toggle the History panel |
| `/sift history` | Toggle the History panel |
| `/sift config` | Open the Config panel |
| `/sift options` | Open the Config panel |
| `/sift allow <name>` | Always-allow a sender from your History (Name-Realm, or the full name on WoW Forever) |
| `/sift export` | Export your allowlist |
| `/sift import` | Import an allowlist |
| `/sift clearhistory` | Confirm and clear all history |
| `/sift clearblocked` | Confirm and clear the blocked-senders list |
| `/sift rebuildstats` | Rebuild this character's stat counts from retained history |

## Privacy

- All history is **local-only**, stored per-character in `SiftDB`. Sift itself sends nothing off your machine.
- No telemetry, no cloud sync, nothing downloaded while you play.
- The allowlist and blocked list are similarly local.

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
