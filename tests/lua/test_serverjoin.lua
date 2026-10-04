-- Server-join prompt test: loads the REAL WB_ServerJoin.lua with stubbed
-- PZ globals and a stubbed Java API, and exercises:
-- message parse -> full mod list -> dialog -> Download all, plus the
-- silent no-op cases and the single-mod fallback.
local LUA_DIR = os.getenv("WB_LUA_DIR")
local failures = 0
local function check(cond, name, extra)
    if cond then print("PASS " .. name)
    else print("FAIL " .. name .. (extra and (" -- " .. tostring(extra)) or "")); failures = failures + 1 end
end

-- ---------- stub PZ environment ----------
Events = {}
Events.OnTick = { handlers = {} }
Events.OnConnectFailed = { handlers = {} }
function Events.OnTick.Add(fn) table.insert(Events.OnTick.handlers, fn) end
function Events.OnConnectFailed.Add(fn) table.insert(Events.OnConnectFailed.handlers, fn) end
UIFont = { Small = "UIFont.Small" }

local UIElement = {}
UIElement.__index = UIElement
function UIElement:derive(name)
    local cls = setmetatable({}, self); cls.__index = cls; cls.__name = name
    return cls
end
function UIElement:new(x, y, w, h, ...)
    local o = setmetatable({ x = x or 0, y = y or 0, width = w or 0, height = h or 0,
        visible = true, children = {}, enabled = true }, self)
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
function UIElement:getVisible() return self.visible end
function UIElement:getIsVisible() return self.visible end
function UIElement:getWidth() return self.width end
function UIElement:getHeight() return self.height end
function UIElement:setHeight(h) self.height = h end
function UIElement:setEnable(e) self.enabled = e end
function UIElement:isEnabled() return self.enabled end
function UIElement:setName(n) self.name = n end
function UIElement:setFont(f) self.font = f end

ISPanel = UIElement:derive("ISPanel")
ISLabel = UIElement:derive("ISLabel")
function ISLabel:new(x, y, h, text, ...)
    local o = UIElement.new(self, x, y, 100, h)
    o.name = text -- the real ISLabel stores text in .name
    return o
end
ISButton = UIElement:derive("ISButton")
function ISButton:new(x, y, w, h, title, clicktarget, onclick, ...)
    local o = UIElement.new(self, x, y, w, h)
    o.title, o.clicktarget, o.onclick = title, clicktarget, onclick
    return o
end

-- the ConnectToServer screen the dialog parents to
local screen = setmetatable({ x = 0, y = 0, width = 1024, height = 768,
    children = {}, visible = true }, { __index = UIElement })
ConnectToServer = { instance = screen }

-- ---------- load the real mod files ----------
local tmp = os.getenv("TMPDIR") or "/tmp"
tmp = tmp .. "/wb-luatest-serverjoin"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_ServerJoin")

local function tick(n)
    for _ = 1, n do
        for _, h in ipairs(Events.OnTick.handlers) do h() end
    end
end

local function fireConnectFailed(msg)
    for _, h in ipairs(Events.OnConnectFailed.handlers) do h(msg) end
end

-- ---------- stub Java API ----------
local statuses = {}
local importCsv = nil
local invalidateCalled = false
local serverModsJson = nil -- set per-case; nil = Java returns nil
local importStatusJson = nil -- override per-case; default = success
function wbGetServerMods() return serverModsJson end
function wbGetJobStatus(jobId) return statuses[jobId] end
function wbImportMods(csv)
    importCsv = csv
    statuses["importjob1"] = importStatusJson
        or '{"state":"done","done":2,"total":2,"message":"Imported 2 mods","updates":[]}'
    return "importjob1"
end
function wbInvalidateModCaches() invalidateCalled = true end

local function serverMods(modsJson, steamMode)
    return '{"steamMode":' .. (steamMode and "true" or "false")
        .. ',"mods":[' .. table.concat(modsJson, ",") .. "]}"
end
local function smod(id, wsid, name, installed)
    return '{"id":"' .. id .. '","workshopId":"' .. wsid .. '","name":"' .. name
        .. '","installed":' .. (installed and "true" or "false") .. "}"
end

local function labelTexts(dlg)
    local t = {}
    for _, l in ipairs(dlg.modLabels or {}) do t[#t + 1] = l.name end
    return t
end

local FAIL_MSG = "Mod required: Super Mod [ModID: supermod, WorkshopID: 111]"

WB_HookServerJoin()
check(#Events.OnConnectFailed.handlers == 1, "handler registered on hook")

-- ---------- 1. missing mods -> dialog -> Download all ----------
serverModsJson = serverMods({
    smod("supermod", "111", "Super Mod", false),
    smod("libmod", "222", "Lib Mod", false),
    smod("havemod", "333", "Have Mod", true),
    smod("manualmod", "", "Manual Mod", false),
})
fireConnectFailed(FAIL_MSG)
local dlg = screen.wbServerModsDialog
check(dlg ~= nil, "dialog shown for missing server mods")
local texts = labelTexts(dlg)
check(#texts == 4, "two downloadable + manual title + entry", #texts)
check(texts[1]:find("Super Mod") and texts[1]:find("111"), "lists mod with workshop id", texts[1])
check(texts[2]:find("Lib Mod") and texts[2]:find("222"), "lists second missing mod", texts[2])
check(texts[3]:find("Not on the Workshop"), "manual section titled", texts[3])
check(texts[4]:find("Manual Mod") and texts[4]:find("manualmod"), "manual entry listed", texts[4])
check(dlg.downloadBtn and dlg.downloadBtn.title == WB_Text.ServerModsDownloadAll,
    "download-all button present")
dlg.downloadBtn.onclick()
check(importCsv == "111,222", "download-all imports only downloadable ids", importCsv)
tick(2)
check(invalidateCalled, "mod caches invalidated after download")
check(dlg.statusLabel.name == WB_Text.ServerModsDownloaded, "done status shown",
    dlg.statusLabel.name)
dlg.closeBtn.onclick()
check(screen.wbServerModsDialog == nil, "dialog closed via Close")

-- ---------- 2. non-matching message -> silent ----------
serverModsJson = serverMods({ smod("x", "1", "X", false) })
fireConnectFailed("Connection refused: wrong password")
check(screen.wbServerModsDialog == nil, "no dialog for unrelated failure")

-- ---------- 3. steam mode -> silent (vanilla owns it) ----------
serverModsJson = serverMods({ smod("supermod", "111", "Super Mod", false) }, true)
fireConnectFailed(FAIL_MSG)
check(screen.wbServerModsDialog == nil, "no dialog in steam mode")

-- ---------- 4. all installed -> silent ----------
serverModsJson = serverMods({ smod("supermod", "111", "Super Mod", true) })
fireConnectFailed(FAIL_MSG)
check(screen.wbServerModsDialog == nil, "no dialog when nothing is missing")

-- ---------- 5. Java returns nil -> single-mod fallback ----------
serverModsJson = nil
fireConnectFailed(FAIL_MSG)
dlg = screen.wbServerModsDialog
check(dlg ~= nil, "fallback dialog shown when packet parse failed")
texts = labelTexts(dlg)
check(#texts == 1 and texts[1]:find("111"), "fallback lists the message mod", texts[1])
dlg.closeBtn.onclick()

-- ---------- 6. transitive require= dep (no workshop id anywhere) ----------
serverModsJson = serverMods({ smod("supermod", "111", "Super Mod", true) })
fireConnectFailed("Mod required: Sub Dep [ModID: subdep, WorkshopID: null]")
dlg = screen.wbServerModsDialog
check(dlg ~= nil, "manual dialog for transitive dep")
texts = labelTexts(dlg)
check(#texts == 2 and texts[2]:find("subdep"), "transitive dep shown as manual", texts[2])
check(dlg.downloadBtn == nil, "no download button when nothing downloadable")
dlg.closeBtn.onclick()

-- ---------- 7. failed download -> error status, retryable ----------
serverModsJson = serverMods({ smod("supermod", "111", "Super Mod", false) })
importCsv = nil
importStatusJson =
    '{"state":"failed","done":0,"total":1,"message":"","error":"boom","updates":[]}'
fireConnectFailed(FAIL_MSG)
dlg = screen.wbServerModsDialog
dlg.downloadBtn.onclick()
tick(2)
check(dlg.statusLabel.name:find("Download failed"), "failure status shown",
    dlg.statusLabel.name)
check(dlg.downloadBtn:isEnabled(), "download button re-enabled after failure")
dlg.closeBtn.onclick()
importStatusJson = nil

-- ---------- 8. no Java API -> silent ----------
wbGetServerMods = nil
fireConnectFailed(FAIL_MSG) -- must not error
check(screen.wbServerModsDialog == nil, "no dialog without the Java API")

-- ---------- 9. invisible screen -> silent ----------
wbGetServerMods = function() return serverModsJson end
serverModsJson = serverMods({ smod("supermod", "111", "Super Mod", false) })
screen.visible = false
fireConnectFailed(FAIL_MSG)
check(screen.wbServerModsDialog == nil, "no dialog when screen not visible")
screen.visible = true

-- ---------- 10. duplicate dialog not stacked ----------
fireConnectFailed(FAIL_MSG)
local dlg2 = screen.wbServerModsDialog
fireConnectFailed(FAIL_MSG)
check(screen.wbServerModsDialog == dlg2, "second failure reuses the dialog")

if failures > 0 then print(failures .. " FAILURES") os.exit(1) end
print("ALL SERVERJOIN TESTS PASSED")
