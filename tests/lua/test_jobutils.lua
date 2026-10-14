-- Unit tests for WB_Jobs.lua's pure helpers (WB_ShortError). No PZ globals
-- needed: WB_Jobs has no load-time side effects beyond its requires.
local LUA_DIR = os.getenv("WB_LUA_DIR")
local failures = 0
local function check(cond, name, extra)
    if cond then print("PASS " .. name)
    else print("FAIL " .. name .. (extra and (" -- " .. tostring(extra)) or "")); failures = failures + 1 end
end

local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/wb-luatest-jobutils"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_Jobs")

check(WB_ShortError("boom") == "boom", "plain message passes through")
check(WB_ShortError("com.foo.BarException: boom") == "boom",
    "strips dotted Exception prefix")
check(WB_ShortError("line1\nline2\nline3") == "line1", "first line only")
check(WB_ShortError(nil) == "?", "nil becomes ?")
check(WB_ShortError("  spaced out  ") == "spaced out", "trims whitespace")
local short = WB_ShortError(string.rep("x", 200), 20)
check(#short == 20 and short:sub(-3) == "...", "truncates with ellipsis", #short)
local exact = WB_ShortError(string.rep("y", 120))
check(#exact == 120, "default maxLen 120 not exceeded needlessly", #exact)
check(WB_ShortError("a: b") == "a: b", "non-Exception colon kept")

print(failures == 0 and "ALL JOBUTIL TESTS PASSED" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
