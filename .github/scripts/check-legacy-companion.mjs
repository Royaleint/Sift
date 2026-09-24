#!/usr/bin/env node
// check-legacy-companion.mjs: release-safety check for the BawrSpam companion.
//
// Verifies the code-free BawrSpam companion folder ships correctly alongside
// Sift in the packaged zip:
//   - it is present as its own top-level folder, not nested inside Sift/;
//   - no Sift TOC declares BawrSpamDB (the double-declaration this companion
//     exists to remove);
//   - each companion TOC's Interface line matches its corresponding Sift TOC;
//   - the companion's TOC set covers every legacy TOC name the last BawrSpam
//     release shipped, so an old file left on a player's disk can never sit
//     uncovered and shadow the companion;
//   - every companion TOC is data-only (no file lines).
//
// Usage:  node check-legacy-companion.mjs [releaseDir]     (default: .release)
// Requires: `unzip` on PATH (preinstalled on GitHub ubuntu runners).
//
// Per-flavour name derivation: the last two BawrSpam releases' published
// zips (fetched read-only via `gh release download`, not re-derived from
// .pkgmeta) each ship exactly one TOC, BawrSpam.toc -- enable-toc-creation
// never split it then, and Sift's own zip today still ships one Sift.toc the
// same way. The legacy name list below is that one observed name. If a
// future release ever does split per flavour, this list -- and the
// suffix-matching below -- need to grow with it.
const LEGACY_TOC_NAMES = ["BawrSpam.toc"];

import { execFileSync } from "node:child_process";
import { readdirSync, existsSync } from "node:fs";
import path from "node:path";

const releaseDir = process.argv[2] ?? ".release";
const failures = [];

function fail(msg) {
  failures.push(msg);
  console.error(`::error::${msg}`);
}

if (!existsSync(releaseDir)) {
  console.error(`::error::release dir '${releaseDir}' does not exist, run the packager (build-only is fine) before this check`);
  process.exit(1);
}

const zips = readdirSync(releaseDir).filter((f) => f.endsWith(".zip"));
if (!zips.length) {
  console.error(`::error::no .zip files found in '${releaseDir}'`);
  process.exit(1);
}

function readEntry(zipPath, entry) {
  return execFileSync("unzip", ["-p", zipPath, entry], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
}

function tocInterface(text) {
  const line = text.split(/\r?\n/).find((l) => /^## Interface:/.test(l));
  return line ? line.replace(/^## Interface:\s*/, "").trim() : null;
}

function tocSavedVariables(text) {
  const line = text.split(/\r?\n/).find((l) => /^## SavedVariables:/.test(l));
  if (!line) return [];
  return line.replace(/^## SavedVariables:\s*/, "").split(",").map((g) => g.trim()).filter(Boolean);
}

// Every non-blank, non-comment line in a TOC is a file reference. A
// data-only companion TOC must have none.
function tocFileLines(text) {
  return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l !== "" && !l.startsWith("#"));
}

function flavorSuffix(entry, prefix) {
  const stem = path.basename(entry).replace(/\.toc$/i, "");
  return stem.startsWith(prefix) ? stem.slice(prefix.length) : null;
}

for (const zipName of zips) {
  const zipPath = path.join(releaseDir, zipName);
  const entries = execFileSync("unzip", ["-Z1", zipPath], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
    .split(/\r?\n/).filter(Boolean);

  // Anchored to the zip root: BawrSpam/ and Sift/ must each be their own
  // top-level folder. An unanchored pattern would also match a BawrSpam
  // folder nested inside Sift/ (move-folders failing silently, packaging it
  // as Sift/BawrSpam/... instead of pulling it out beside Sift/), which is
  // exactly the layout mistake this check exists to catch.
  const companionTocs = entries.filter((e) => /^BawrSpam\/[^/]+\.toc$/i.test(e));
  const siftTocs = entries.filter((e) => /^Sift\/[^/]+\.toc$/i.test(e));
  const nestedCompanion = entries.filter((e) => /^Sift\/BawrSpam\//i.test(e));

  if (nestedCompanion.length) {
    fail(`${zipName}: BawrSpam/ shipped nested inside Sift/ instead of beside it (found ${nestedCompanion[0]}), move-folders did not pull it out to the zip root`);
  }

  if (!companionTocs.length) {
    fail(`${zipName}: no BawrSpam/*.toc found at the zip root, the companion folder did not ship`);
    continue;
  }

  const companionNames = companionTocs.map((e) => path.basename(e));
  for (const legacyName of LEGACY_TOC_NAMES) {
    if (!companionNames.includes(legacyName)) {
      fail(`${zipName}: companion TOC set [${companionNames.join(", ")}] does not cover legacy name '${legacyName}': a leftover file with that name on a player's disk would go uncovered`);
    }
  }

  const siftInterfaceBySuffix = {};
  for (const entry of siftTocs) {
    const text = readEntry(zipPath, entry);
    const declared = tocSavedVariables(text);
    if (declared.includes("BawrSpamDB")) {
      fail(`${zipName} :: ${entry} declares BawrSpamDB, the double declaration this companion exists to remove`);
    }
    const suffix = flavorSuffix(entry, "Sift");
    if (suffix !== null) siftInterfaceBySuffix[suffix] = { entry, interface: tocInterface(text) };
  }

  for (const entry of companionTocs) {
    const text = readEntry(zipPath, entry);
    const declared = tocSavedVariables(text);
    if (declared.length !== 1 || declared[0] !== "BawrSpamDB") {
      fail(`${zipName} :: ${entry} declares [${declared.join(", ")}], expected exactly BawrSpamDB`);
    }
    const fileLines = tocFileLines(text);
    if (fileLines.length) {
      fail(`${zipName} :: ${entry} has file lines (should be data-only): ${fileLines.join(", ")}`);
    }
    const suffix = flavorSuffix(entry, "BawrSpam");
    const match = suffix !== null ? siftInterfaceBySuffix[suffix] : null;
    if (!match) {
      fail(`${zipName} :: ${entry} has no matching Sift TOC to compare its Interface line against`);
    } else if (tocInterface(text) !== match.interface) {
      fail(`${zipName} :: ${entry} Interface (${tocInterface(text)}) differs from ${match.entry} (${match.interface})`);
    }
  }
}

if (failures.length) {
  console.error(`check-legacy-companion: FAILED (${failures.length}), see errors above.`);
  process.exit(1);
}
console.log(`check-legacy-companion: PASSED, ${zips.length} zip(s), companion present, data-only, matching Interface, legacy names covered.`);
