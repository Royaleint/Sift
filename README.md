# BawrSpam

> **Version:** 1.0.0 | TOC: 120005 | WoW Retail 12.0.5+
> **Status:** Personal-use only — public release pending.

A personal chat-spam filter for World of Warcraft Retail with recoverable history. Blocks RMT, boost-service, casino, and phishing spam in chat, and lets you review or restore anything it blocks.

## Features

- **Chat Filter** — Blocks spam in CHANNEL, WHISPER, SAY, and YELL channels before it reaches your chat frame. Trusted senders (party, raid, guild, friends, Battle.net friends) are never filtered.
- **Chat Bubble Suppression** — Optional CVar toggle that hides world chat bubbles for blocked SAY/YELL spam. CVar restores on the next non-blocked event and on logout — your bubble setting isn't permanently altered.
- **Repeat-Sender Throttle** — Catches the same sender repeating the same cleansed message across surfaces (CHANNEL/WHISPER/YELL/SAY) without re-running the full scoring path.
- **Recoverable History** — Every block lands in a per-character history table you can review, restore, or always-allow from. Stored locally; never transmitted.
- **History Panel** — Master/detail UI with category chips, surface/time/outcome/sort filters, FauxScroll list, and surface-aware Restore / Always-allow actions.
- **Config Panel** — Eight-section options panel covering Detection, Categories, Surfaces, Allowlist, Blocked, History, UI, and Dev. Slash subcommands hit the same surfaces.
- **Unit Tooltip Annotation** — Hover any player and see "BawrSpam: blocked N spam messages (last Xm ago)" if you've blocked them before.
- **Minimap Launcher** — LibDBIcon button toggles the history panel.

## Installation

Personal-use only — not published to CurseForge or Wago.

1. Clone or download this repository.
2. Place the `BawrSpam/` folder in `World of Warcraft/_retail_/Interface/AddOns/BawrSpam/`.
3. Install [Foundry-1.0](https://www.curseforge.com/wow/addons/foundry-1-0) separately (TOC dependency, not vendored).
4. Place the vendored libraries (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) in `World of Warcraft/_retail_/Interface/AddOns/` — see `Libs/ATTRIBUTION.md`.
5. Enable in your addon list and `/reload`.

## Commands

| Command | Description |
|---------|-------------|
| `/bawrspam` | Toggle the History panel |
| `/bawrspam history` | Toggle the History panel |
| `/bawrspam config` | Open the Config panel (Detection section) |
| `/bawrspam options` | Open the Config panel (Detection section) |
| `/bawrspam allow` | Always-allow the selected sender from history |
| `/bawrspam export` | Open the export dialog (allowlist + blocked) |
| `/bawrspam import` | Open the import dialog |
| `/bawrspam clearhistory` | Confirm and clear all history |
| `/bawrspam clearblocked` | Confirm and clear the blocked-senders list |
| `/bawrspam test` | Synthetic block test (devMode only) |

## How It Works

BawrSpam scores incoming messages against a private hand-curated pattern set across six categories (RMT, Boosting, Casino, Phishing, Commercial, Anti). Each message is cleansed through a 9-stage normalization pipeline (homoglyph swaps, zero-width strip, leet-to-letter, etc.) before scoring, so common evasion tricks don't bypass the filter. Messages over the block threshold are suppressed and logged to history; everything else passes through untouched.

Trust short-circuits run before scoring. Party, raid, guild, friends, and Battle.net friends are never filtered. Senders on your personal allowlist are also never filtered.

The pattern data shipped in `PatternData.lua` is XOR-encoded so the addon files don't expose the underlying spam strings to ban evasion. The build tool that generates this file is in the private dev repo and is not shipped publicly.

## Privacy

- All history is **local-only**, stored per-character in `BawrSpamDB`. Nothing is transmitted off your machine.
- No telemetry. No remote pattern updates. No cloud sync.
- The allowlist and blocked list are similarly local.

## Known Limitations

- **Pattern corpus is small at v1.0** — ships with 30 hand-curated rules; expected to grow toward 100+ via personal dogfood observation.
- **No LFG listing scanning** — premade-group listing text is Kstring-protected on Midnight (unreadable to addons), and Blizzard filters advertisement listings natively, so BawrSpam covers chat surfaces only.
- **No mail-spam scanning** — chat surfaces only. Mail scanning is a v2.0 candidate.

## License

BawrSpam is licensed **All Rights Reserved** with explicit addon permissions
for personal in-game use, private local modification, and contribution forks.
Redistribution, repackaging, commercial use, relicensing, or reuse of
BawrSpam code/pattern data in another project requires prior written
permission. See `LICENSE`.

Vendored libraries under `Libs/` retain their upstream terms; see
`Libs/ATTRIBUTION.md`.

---

## Attribution

Inspired by funkydude's BadBoy (https://github.com/funkydude/BadBoy) — a long-running chat-spam filter for WoW. BawrSpam is an independent original-work implementation; no code, patterns, or data are imported from BadBoy or any other addon. The category model, scoring approach, cleanse pipeline, and pattern corpus are all original work, written from observed in-game spam by the author.

Vendored libraries (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) retain their original licenses and authorship; see `Libs/ATTRIBUTION.md`.
