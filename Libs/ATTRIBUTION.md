# Vendored Library Attribution

BawrSpam vendors a small set of WoW Lua libraries to avoid a fetch step at install time. Sources, versions, and license terms:

## LibStub

- **Source:** https://www.wowace.com/projects/libstub
- **License:** Public Domain (per upstream README — no copyright claimed)
- **Purpose:** Lightweight library registration / version-resolution scaffold used by every Ace3 library.
- **Vendored at:** BSP-002 (initial scaffold)

## CallbackHandler-1.0

- **Source:** https://www.wowace.com/projects/callbackhandler
- **License:** All Rights Reserved per upstream `.toc` — explicit permission to use, modify, fork, and redistribute with WoW addons (standard WowAce vendoring permission)
- **Purpose:** Event/callback dispatcher used internally by AceDB-3.0 and other Ace3 libraries.
- **Vendored at:** BSP-002 (AceDB dependency)

## AceDB-3.0

- **Source:** https://www.wowace.com/projects/ace3
- **License:** All Rights Reserved per upstream `.toc` — explicit permission to use, modify, fork, and redistribute with WoW addons (standard WowAce vendoring permission)
- **Purpose:** SavedVariables wrapper providing `global` / `profile` / `char` scopes, defaults, and migration hooks.
- **Vendored at:** BSP-002 (DB layer)

## AceGUI-3.0

- **Source:** https://www.wowace.com/projects/ace3
- **License:** All Rights Reserved per upstream `.toc` — explicit permission to use, modify, fork, and redistribute with WoW addons (standard WowAce vendoring permission)
- **Purpose:** Widget toolkit (containers + controls) used inside the custom `HistoryPanel` frame for filter dropdowns, checkboxes, edit boxes, and labels.
- **Vendored at:** BSP-003 (HistoryPanel)

## LibDataBroker-1.1

- **Source:** https://github.com/tekkub/libdatabroker-1-1
- **License:** Public domain / unlicensed per upstream README.
- **Purpose:** LDB data-source object that LibDBIcon-1.0 binds to. BawrSpam registers a single LDB launcher (`type = "launcher"`) for the minimap button.
- **Vendored at:** BSP-003 (minimap button transitive dep)

## LibDBIcon-1.0

- **Source:** https://www.curseforge.com/wow/addons/libdbicon-1-0
- **License:** All Rights Reserved per upstream `.toc` — explicit permission to use, modify, fork, and redistribute with WoW addons (standard WowAce vendoring permission)
- **Purpose:** Minimap button registration and visibility/position management. Optional at runtime — BawrSpam falls through silently if not present (§10.3).
- **Vendored at:** BSP-003 (minimap button)

## Vendoring policy

- These libraries were copied verbatim from a co-located studio addon (Homestead) which had already vendored canonical WowAce releases.
- No modifications. Spot-check on initial vendor showed no studio-specific patches.
- Updates: re-vendor from WowAce when the upstream lib publishes a relevant fix. Track in `BawrSpam_Dev/BSpam_Tracker.md`.

## Libraries deferred to later plans

| Library | Required by | Will vendor when |
|---|---|---|
| AceConfig-3.0 (optional) | BSP-004 ConfigPanel — only if not custom-AceGUI | BSP-004 implementation start |

WagoAnalytics is intentionally NOT vendored (no telemetry in v1 personal-use).
