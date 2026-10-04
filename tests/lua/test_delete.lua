-- Delete-dialog test: loads the REAL WB_Delete.lua with stubbed PZ globals
-- and a stubbed Java API, and exercises the confirm -> delete flow:
-- sub-mod listing, delete/cancel, partial skips, failure, missing API.
local LUA_DIR = os.getenv("WB_LUA_DIR")
local failures = 0
local function check(cond, name, extra)
    if cond then print("PASS " .. name)
    else print("FAIL " .. name .. (extra and (" -- " .. tostring(extra)) or "")); failures = failures + 1 end
end

-- ---------- stub PZ environment ----------
-- NOTE: the game's Kahlua Lua has no next(); setting it nil here keeps the
-- test honest about which stdlib functions the mod may use.
next = nil
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
tmp = tmp .. "/wb-luatest-delete"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_Delete")

local ms = setmetatable({ x = 0, y = 0, width = 1024, height = 768, children = {} },
    { __index = UIElement })
wbScreen = ms

-- ---------- stub Java API + helpers ----------
local lastGetModIds = nil
local lastDeleteWsid, lastDeleteMod = nil, nil
local deleteResult = nil
function wbGetModIds(wsid)
    lastGetModIds = wsid
    return '["ModA","ModB"]'
end
function wbDeleteMod(wsid, modId)
    lastDeleteWsid, lastDeleteMod = wsid, modId
    return deleteResult
end
function wbGetWorkshopId(modId)
    if modId == "ModB" then return "555" end
    return nil
end
local flashed = nil
function WB_FlashMessage(m, msg) flashed = msg end
local refreshed = false
function WB_RefreshModList(m) refreshed = m == ms end

local function labelText(lbl)
    -- stub quirk: ISLabel:new(x, y, height, text, ...) lands text in .height
    return lbl.height
end
local function reset()
    lastGetModIds, lastDeleteWsid, lastDeleteMod = nil, nil, nil
    deleteResult, flashed, refreshed = nil, nil, false
end
local panel = { wbModId = "ModB" }

-- ---------- 1. tracked mod: sub-mods listed, delete works ----------
reset()
deleteResult = '{"deleted":["ModA","ModB"],"skipped":{},"failed":[]}'
WB_OnDelete(panel)
local dlg = ms.wbDeleteDialog
check(dlg ~= nil, "delete dialog shown for tracked mod")
check(lastGetModIds == "555", "sub-mod list fetched for the workshop item", lastGetModIds)
check(labelText(dlg.modLabel):find("ModB"), "dialog names the selected mod", labelText(dlg.modLabel))
local subTexts = {}
for _, l in ipairs(dlg.subLabels) do subTexts[#subTexts + 1] = labelText(l) end
check(#subTexts == 2, "also-deletes section + one sub-mod",
    table.concat(subTexts, " | "))
check(subTexts[1] == WB_Text.DeleteAlsoDeletes, "also-deletes header")
check(subTexts[2]:find("ModA") and not subTexts[2]:find("ModB"),
    "lists the OTHER sub-mod, not the selected one", subTexts[2])
check(dlg.deleteBtn.title == WB_Text.Delete, "delete button")
check(dlg.cancelBtn.title == WB_Text.Cancel, "cancel button")
dlg.deleteBtn.onclick()
check(lastDeleteWsid == "555" and lastDeleteMod == "ModB",
    "delete called with workshop id + mod id",
    tostring(lastDeleteWsid) .. "/" .. tostring(lastDeleteMod))
check(flashed == WB_Text.Deleted, "deleted flash", flashed)
check(refreshed, "mod list refreshed after delete")
check(ms.wbDeleteDialog == nil, "dialog closed after delete")

-- ---------- 2. manual mod: no sub-mod section ----------
reset()
panel = { wbModId = "ManualMod" }
deleteResult = '{"deleted":["ManualMod"],"skipped":{},"failed":[]}'
WB_OnDelete(panel)
dlg = ms.wbDeleteDialog
check(dlg ~= nil, "delete dialog shown for manual mod")
check(#dlg.subLabels == 0, "no also-deletes section for manual mod")
dlg.deleteBtn.onclick()
check(lastDeleteWsid == nil and lastDeleteMod == "ManualMod",
    "manual delete passes no workshop id",
    tostring(lastDeleteWsid) .. "/" .. tostring(lastDeleteMod))
check(flashed == WB_Text.Deleted, "deleted flash for manual mod")
check(refreshed, "mod list refreshed after manual delete")

-- ---------- 3. cancel does nothing ----------
reset()
panel = { wbModId = "ModB" }
WB_OnDelete(panel)
dlg = ms.wbDeleteDialog
dlg.cancelBtn.onclick()
check(lastDeleteMod == nil, "cancel never calls the Java side")
check(ms.wbDeleteDialog == nil, "dialog closed on cancel")

-- ---------- 4. partial: some folders kept ----------
reset()
deleteResult = '{"deleted":["ModB"],"skipped":{"ModA":"still tracked by workshop item 556"},"failed":[]}'
WB_OnDelete(panel)
dlg = ms.wbDeleteDialog
dlg.deleteBtn.onclick()
check(flashed and flashed:find(WB_Text.DeletePartial, 1, true)
        and flashed:find("ModA") and flashed:find("556"),
    "partial delete reports the kept folder and reason", flashed)
check(refreshed, "mod list refreshed after partial delete")

-- ---------- 5. failed delete ----------
reset()
deleteResult = '{"deleted":[],"skipped":{},"failed":["ModB"]}'
WB_OnDelete(panel)
dlg = ms.wbDeleteDialog
dlg.deleteBtn.onclick()
check(flashed == WB_Text.DeleteFailed, "failed flash", flashed)
check(not refreshed, "no refresh when nothing was deleted")

-- ---------- 6. no Java API: no error, no dialog content breakage ----------
reset()
wbGetModIds = nil
wbDeleteMod = nil
WB_OnDelete(panel) -- must not error
dlg = ms.wbDeleteDialog
check(dlg ~= nil, "dialog still opens without the Java API")
dlg.deleteBtn.onclick() -- must not error
check(flashed == WB_Text.DeleteFailed, "failed flash without the API", flashed)

-- ---------- 7. duplicate dialog reused ----------
reset()
wbGetModIds = function(wsid) return '["ModA","ModB"]' end
wbDeleteMod = function(wsid, modId) return deleteResult end
deleteResult = '{"deleted":["ModA","ModB"],"skipped":{},"failed":[]}'
WB_OnDelete(panel)
local first = ms.wbDeleteDialog
WB_OnDelete(panel)
check(ms.wbDeleteDialog == first, "open dialog reused, not stacked")

print("delete-dialog failures: " .. failures)
os.exit(failures == 0 and 0 or 1)
