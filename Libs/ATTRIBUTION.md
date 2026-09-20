# Vendored Library Attribution

Sift vendors a small set of WoW Lua libraries to avoid a fetch step at install time. Sources, versions, and license terms:

## Foundry-1.0

- **Source:** https://github.com/Royaleint/Foundry.git
- **License:** MIT
- **Purpose:** SavedVariables layer (Foundry.DB), addon lifecycle, slash command registry, and event dispatch. Sift's core dependency — replaces AceDB-3.0 (BSP-062), AceAddon-3.0 (BSP-060), and related Ace3 modules.
- **Vendored at:** BSP-064 (FND-007 embedded-copy guard); consolidated to the v1.0.102 tag (SFT-076). Standalone Foundry-1.0 wins when installed; this embed is the fallback for distributions without a separate Foundry install.
- **Update policy:** Re-vendor from source tag when a new Foundry release is needed. Pin the tag — do not track HEAD.

## LibStub

- **Source:** https://www.wowace.com/projects/libstub
- **License:** Public Domain (per upstream README — no copyright claimed)
- **Purpose:** Lightweight library registration / version-resolution scaffold used by every Ace3 library.
- **Vendored at:** BSP-002 (initial scaffold)

## CallbackHandler-1.0

- **Source:** https://www.wowace.com/projects/callbackhandler
- **License:** All Rights Reserved per upstream `.toc` — explicit permission to use, modify, fork, and redistribute with WoW addons (standard WowAce vendoring permission)
- **Purpose:** Event/callback dispatcher used internally by LibDBIcon-1.0 and LibDataBroker-1.1.
- **Vendored at:** BSP-002 (AceDB dependency — remains after BSP-062 for LibDBIcon/LibDataBroker)

## LibDataBroker-1.1

- **Source:** https://github.com/tekkub/libdatabroker-1-1
- **License:** Public domain / unlicensed per upstream README.
- **Purpose:** LDB data-source object that LibDBIcon-1.0 binds to. Sift registers a single LDB launcher (`type = "launcher"`) for the minimap button.
- **Vendored at:** BSP-003 (minimap button transitive dep)

## LibDBIcon-1.0

- **Source:** https://www.curseforge.com/wow/addons/libdbicon-1-0
- **License:** All Rights Reserved per upstream `.toc` — explicit permission to use, modify, fork, and redistribute with WoW addons (standard WowAce vendoring permission)
- **Purpose:** Minimap button registration and visibility/position management. Optional at runtime — Sift falls through silently if not present (§10.3).
- **Vendored at:** BSP-003 (minimap button)

## Vendoring policy

- LibStub, CallbackHandler-1.0, and LibDBIcon-1.0 were copied verbatim from canonical WowAce releases; no modifications. Foundry-1.0 and LibDataBroker-1.1 are sourced from their own upstream repos (see each library's Source line above), also copied verbatim.
- Updates: re-vendor from each library's own source when the upstream publishes a relevant fix.

## Libraries removed

| Library | Removed when | Reason |
|---|---|---|
| AceGUI-3.0 | BSP-022 | ConfigPanel fully native (MinimalSliderWithSteppersTemplate / OptionsSliderTemplate / UICheckButtonTemplate / native multiLine EditBox in UIPanelScrollFrameTemplate). |
| AceDB-3.0 | BSP-062 | SavedVariables layer replaced by Foundry.DB (Foundry-1.0). |

WagoAnalytics is intentionally NOT vendored (no telemetry in v1 personal-use).
