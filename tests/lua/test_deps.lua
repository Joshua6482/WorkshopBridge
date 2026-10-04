-- Dependency-check UI test: loads the REAL WB_Dependencies.lua with stubbed
-- PZ globals and a stubbed Java API, and exercises the full flow:
-- check -> dialog -> Install all / Skip, plus the silent no-op cases.
local LUA_DIR = os.getenv("WB_LUA_DIR")
local failures = 0
local function check(cond, name, extra)
    if cond then print("PASS " .. name)
    else print("FAIL " .. name .. (extra and (" -- " .. tostring(extra)) or "")); failures = failures + 1 end
end

-- ---------- stub PZ environment ----------
Events = {}
Events.OnTick = { handlers = {} }
function Events.OnTick.Add(fn) table.insert(Events.OnTick.handlers, fn) end
UIFont = { Small = "UIFont.Small" }

local UIElement = {}
UIElement.__index = UIElement
function UIElement:derive(name)
    local cls = setmetatable({}, self); cls.__index = cls; cls.__name = name
    return cls
end
function UIElement:new(x, y, w, h, ...)
    local o = setmetatable({ x = x or 0, y = y or 0, width = w or 0, height = h or 0,
        visible = true, children = {} }, self)
    o.initArgs = { ... }
    return o
end
function UIElement:initialise() end
function UIElement:instantiate() end
function UIElement:addChild(c) table.insert(self.children, c) end
function UIElement:removeChild(c)
    for i, k in ipairs(self.children) do if k == c then table.remove(self.children, i) break end end
end
function UIElement:setVisible(v) self.visible = v end
function UIElement:isVisible() return self.visible end
function UIElement:getWidth() return self.width end
function UIElement:getHeight() return self.height end
function UIElement:setName(n) self.name = n end
function UIElement:setTitle(t) self.title = t end
function UIElement:setFont(f) self.font = f end

ISPanel = UIElement:derive("ISPanel")
ISLabel = UIElement:derive("ISLabel")
ISButton = UIElement:derive("ISButton")
function ISButton:new(x, y, w, h, title, clicktarget, onclick, ...)
    local o = UIElement.new(self, x, y, w, h)
    o.title, o.clicktarget, o.onclick = title, clicktarget, onclick
    return o
end

-- ---------- load the real mod files ----------
local tmp = os.getenv("TMPDIR") or "/tmp"
tmp = tmp .. "/wb-luatest-deps"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_Dependencies")

local function tick(n)
    for _ = 1, n do
        for _, h in ipairs(Events.OnTick.handlers) do h() end
    end
end

local ms = setmetatable({ x = 0, y = 0, width = 1024, height = 768, children = {} },
    { __index = UIElement })

-- ---------- stub Java API ----------
local statuses = {}      -- jobId -> status JSON
local depJobSeq = 0
local lastDepCheckWsid = nil
local importCsv = nil
function wbCheckDependencies(wsid)
    depJobSeq = depJobSeq + 1
    lastDepCheckWsid = wsid
    return "depjob" .. depJobSeq
end
function wbGetJobStatus(jobId) return statuses[jobId] end
function wbImportMods(csv)
    importCsv = csv
    statuses["importjob1"] =
        '{"state":"done","done":1,"total":1,"message":"Imported","updates":[],"deps":[]}'
    return "importjob1"
end
function WB_RefreshModList(m) end

local function depsStatus(depsJson)
    return '{"state":"done","done":1,"total":1,'
        .. '"message":"required items found","updates":[],"deps":['
        .. table.concat(depsJson, ",") .. "]}"
end
local function dep(id, title, installed)
    return '{"id":"' .. id .. '","title":"' .. title .. '","installed":'
        .. (installed and "true" or "false") .. "}"
end

local function labelTexts(dlg)
    -- stub quirk: ISLabel:new(x, y, height, text, ...) lands the text in
    -- the 4th positional, which the stub maps to .height
    local t = {}
    for _, l in ipairs(dlg.depLabels or {}) do t[#t + 1] = l.height end
    return t
end

-- ---------- 1. missing dep -> dialog -> Install all ----------
statuses["depjob1"] = depsStatus({
    dep("3171167894", "that DAMN Library", false),
    dep("999", "Already There", true),
})
WB_CheckDependencies(ms, "3799732653")
tick(2)
check(lastDepCheckWsid == "3799732653", "dep check started for the installed item")
local dlg = ms.wbDependenciesDialog
check(dlg ~= nil, "dialog shown when a dep is missing")
local texts = labelTexts(dlg)
check(#texts == 1 and texts[1]:find("that DAMN Library") and texts[1]:find("3171167894"),
    "dialog lists the missing dep with title and id", texts[1])
check(dlg.installBtn.title == WB_Text.InstallAll, "install-all button")
check(dlg.skipBtn.title == WB_Text.Skip, "skip button")
dlg.installBtn.onclick()
check(importCsv == "3171167894", "install-all imports only the missing dep", importCsv)
check(ms.wbDependenciesDialog == nil, "dialog closed after install-all")

-- ---------- 2. all deps installed -> silent ----------
statuses["depjob2"] = depsStatus({ dep("999", "Already There", true) })
WB_CheckDependencies(ms, "3799732653")
tick(2)
check(ms.wbDependenciesDialog == nil, "no dialog when everything is installed")

-- ---------- 3. failed check -> silent ----------
statuses["depjob3"] = '{"state":"failed","done":0,"total":1,"message":"","error":"boom","updates":[],"deps":[]}'
WB_CheckDependencies(ms, "3799732653")
tick(2)
check(ms.wbDependenciesDialog == nil, "no dialog when the check fails")

-- ---------- 4. no Java API -> silent ----------
wbCheckDependencies = nil
WB_CheckDependencies(ms, "3799732653") -- must not error
tick(2)
check(ms.wbDependenciesDialog == nil, "no dialog without the Java API")

-- ---------- 5. many deps -> capped list ----------
local many = {}
for i = 1, 9 do many[#many + 1] = dep("100" .. i, "Dep " .. i, false) end
local jobSeqBefore = depJobSeq
wbCheckDependencies = function(wsid)
    depJobSeq = depJobSeq + 1
    return "depjob" .. depJobSeq
end
statuses["depjob" .. (jobSeqBefore + 1)] = depsStatus(many)
WB_CheckDependencies(ms, "3799732653")
tick(2)
dlg = ms.wbDependenciesDialog
check(dlg ~= nil, "dialog shown for many deps")
texts = labelTexts(dlg)
check(#texts == 9, "8 deps shown plus overflow line", #texts)
check(texts[9]:find("1 more"), "overflow line counts the rest", texts[9])
-- skip closes without importing
importCsv = nil
dlg.skipBtn.onclick()
check(importCsv == nil, "skip does not start an import")
check(ms.wbDependenciesDialog == nil, "dialog closed after skip")

if failures > 0 then
    print(failures .. " FAILURES")
    os.exit(1)
end
print("deps UI: all passed")
