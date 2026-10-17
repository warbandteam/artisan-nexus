-- Dump {spellID: profession} from Modules/Data/MidnightRecipeCatalog.lua as JSON (generator input).
-- Usage: luajit dump_mid.lua <repo>/Modules/Data/MidnightRecipeCatalog.lua <out.json>
local ns = {}
assert(loadfile(arg[1]))("ArtisanNexus", ns)
local parts = {}
for prof, data in pairs(ns.MidnightRecipeCatalog) do
    for spellID in pairs(data.recipes or {}) do
        parts[#parts + 1] = string.format('"%d":"%s"', spellID, prof)
    end
end
local out = assert(io.open(arg[2], "w"))
out:write("{", table.concat(parts, ","), "}")
out:close()
