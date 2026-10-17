# CurseForge & Wago — release metadata

Use this when creating or updating the project **before** publishing a build.  
In-game text lives in `ArtisanNexus.toc` (`## Notes`, `## Title`, `## Version`).

---

## Summary (short description)

**Copy/paste candidate** (≈1–2 sentences; CurseForge “Summary” / Wago short intro):

> Professions QoL for **WoW Midnight / Retail**: unified **Session loot** for fishing and gathering, optional **AH price sync**, **overload** hints and tracker, **craft queue** and recipe matcher, **bag pressure** warnings, and a **minimap** launcher — Ace3, LibDataBroker minimap icon.

**In-game line** should stay aligned with `## Notes` in `ArtisanNexus.toc` (same meaning, can shorten).

---

## Suggested tags

Typical CurseForge / Wago tag picks (pick what fits; duplicate across sites is fine):

| Tag / keyword        | Use |
|---------------------|-----|
| Professions         | Primary |
| Fishing             | Yes |
| Gathering / Farming | Yes |
| Economy / Gold      | Yes (AH sync) |
| Inventory / Bags      | Optional (bag guard) |
| Map & Minimap       | Optional (minimap button) |
| Quality of Life     | Yes |

**CurseForge** project category (primary): **Professions** (or closest “Professions & Skills” if offered).

**Wago**: categories often include **Retail**, **Professions**, **Economy** — match your Wago UI when uploading.

---

## Long description (optional)

Expand on bullets, then paste into CurseForge “Description” / Wago long text:

- Session loot window: per-tab catalog (fishing, herbs, ore, skinning, DE, others), session vs overall, efficiency line.
- Fishing: channel-aware loot tracking from chat (no input overrides).
- Gathering: loot from chat (catalog herbs, ore, leather, DE, motes), overload node feedback, optional world overlay.
- Recipes: open a profession once to harvest schematics; **Recipe Matcher** (`/an recipe`) and **Artisan Hub** (`/an hub`) show bag crafts, profit, shopping list, and craft queue.
- AH: optional catalog price scan (Auction House open).
- Settings: Ace3 options; minimap button (LibDBIcon).

---

## IDs (release upload)

| Field | Value |
|--------|--------|
| Wago project ID | `QKy9MvK7` → `## X-Wago-ID` in `ArtisanNexus.toc` |
| Wago addon URL | `https://addons.wago.io/addons/artisan-nexus` (confirm slug on dashboard) |
| CurseForge project ID | `1598347` → `## X-Curse-Project-ID` in `ArtisanNexus.toc` |
| CurseForge project URL | `https://www.curseforge.com/wow/addons/artisan-nexus` |

### GitHub Actions secrets (never commit)

Repository → **Settings → Secrets and variables → Actions**:

| Secret | Value source |
|--------|----------------|
| `CF_API_KEY` | CurseForge Author Dashboard → API Tokens |
| `WAGO_API_TOKEN` | Wago → Account → API keys (full key string from dashboard) |

`.github/workflows/release.yml` maps `CF_API_KEY`, `WAGO_API_TOKEN`, and `GITHUB_TOKEN` for BigWigs packager on tag `v*`.

Local upload (optional): copy `_ignored/secrets.env.example` → `_ignored/secrets.env`, fill values, then:

```powershell
Get-Content _ignored\secrets.env | ForEach-Object {
  if ($_ -match '^\s*([^#=]+)=(.*)$') { Set-Item -Path "env:$($matches[1].Trim())" -Value $matches[2].Trim() }
}
# then run packager CLI or rely on tag push + Actions
```

---

## Build & zip

- **CurseForge Git**: `.pkgmeta` + tag `v*` triggers `.github/workflows/release.yml` (BigWigs packager).
- **Local zip** (addon folders only): `powershell -ExecutionPolicy Bypass -File Pack-ArtisanNexus.ps1` → `build\ArtisanNexus-<version>.zip`
- **Pre-release gate**: `python .github/scripts/preflight_release.py`
- **License**: matches root `LICENSE` — list **All Rights Reserved** on CurseForge if prompted.

---

## Checklist

- [ ] `## Version` and `Modules/Constants.lua` `ADDON_VERSION` match the release tag.
- [ ] `CHANGELOG.md` updated; `L["CHANGELOG_VXYZ"]` in all `Locales/*.lua` for the version.
- [ ] `python .github/scripts/preflight_release.py` passes (locale parity + version + changelog keys).
- [ ] Summary + tags + category set on CurseForge / Wago.
- [x] GitHub secrets `CF_API_KEY` and `WAGO_API_TOKEN` set.
- [x] `## X-Wago-ID` and `## X-Curse-Project-ID: 1598347` in `.toc`.
