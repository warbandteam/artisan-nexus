# Warband Nexus UI sync

Artisan Nexus does not have a UI framework of its own. The files in `files.txt` are Warband Nexus
files copied under the same relative paths. Keep them diffable with Warband Nexus: do not restyle,
reformat or "clean up" them, and leave WN functions that AN does not call in place.

- `wn_transform.py SRC DST` applies the mechanical renames (rules in its header): the addon object
  `ns.WarbandNexus` / `_G.WarbandNexus` / `rawget(_G, "WarbandNexus")` becomes `ns.ArtisanNexus`, and
  `WarbandNexus` inside string literals (frame names, `Interface\AddOns\WarbandNexus\` media paths)
  becomes `ArtisanNexus`. Comments and local variable names (`local WarbandNexus = ...`) are untouched.
- `verbatim` files are exactly the transform output.
- `adapted` files carry Artisan Nexus edits on top of the transform (tab list and dispatch, launchers in
  the rail footer, AN settings panels, AN refresh routing, rail badges). Keep those edits small and
  mark them with a comment.
- `WN_REV` is the Warband Nexus commit the copies were last synced from.

## Re-sync

From the Artisan Nexus repo root, with a warband-nexus checkout next to it:

    python3 tools/wnsync/wnsync.py --wn ../warband-nexus            # report: ok / differs / merged / CONFLICTS
    python3 tools/wnsync/wnsync.py --wn ../warband-nexus --apply    # write the files

`verbatim` files are replaced by the transform of the WN working-tree file. `adapted` files get a
three-way merge (`git merge-file`): the AN file, the transform of the file at `WN_REV`, and the
transform of the current WN file, so AN's edits survive and WN's changes come in. Resolve any
`<<<<<<<` blocks by hand: WN features Artisan Nexus does not ship (Characters, PvE, Gear ... settings
rows, tabs, data listeners) stay out. Then:

1. Copy new WN media the files reference (`Fonts/*.ttf`, `Media/Icon-*.tga`) and update
   `libs/LibSharedMedia-3.0` if WN updated it.
2. Add new WN locale keys the files read to all 11 `Locales/*.lua` (WN translations, product name
   changed to Artisan Nexus); `python3 .github/scripts/check_locale_parity.py` must pass.
3. If WN added a file to the framework, copy it with `wn_transform.py`, list it in `files.txt` and
   `ArtisanNexus.toc` at its WN load position.
4. Run the gates (README "Gates") and the E2E harness, then write the synced WN commit into `WN_REV`.

Requires `python3` and `git`.
