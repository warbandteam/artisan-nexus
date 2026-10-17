dofile(arg[1])
local cat_path=arg[2]
ns={} ; local f=assert(loadfile(cat_path)); f("x",ns)
local mid={}
for prof,t in pairs(ns.MidnightRecipeCatalog) do for sid,n in pairs(t.recipes or {}) do mid[sid]=prof end end
local rs=ArtisanNexusDB.global.recipeSchematics or {}
local out=io.open(arg[3],"w")
local function ser(v) local t=type(v)
 if t=="table" then local p={} local isarr=#v>0 for k,x in pairs(v) do if isarr and type(k)=="number" then p[#p+1]=ser(x) else p[#p+1]=string.format("%q:%s",tostring(k),ser(x)) end end
  if isarr then return "["..table.concat(p,",").."]" else return "{"..table.concat(p,",").."}" end
 elseif t=="string" then return string.format("%q",v) elseif t=="boolean" then return tostring(v) else return tostring(v) end end
out:write("{")
local first=true
for sid,v in pairs(rs) do if mid[sid] then if not first then out:write(",") end first=false out:write(string.format('"%d":',sid),ser(v)) end end
out:write("}")
out:close()
local m={} out=io.open(arg[4],"w") out:write("{") first=true
for sid,p in pairs(mid) do if not first then out:write(",") end first=false out:write(string.format('"%d":"%s"',sid,p)) end out:write("}") out:close()
