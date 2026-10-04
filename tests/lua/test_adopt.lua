-- Adopt-dialog test: the per-mod Adopt button visibility plus the full
-- dialog flow (open -> validate -> adopt job -> reloadMods), using the
-- real WB_*.lua files with stubbed PZ globals.
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
Events.OnGameBoot = { handlers = {} }
function Events.OnGameBoot.Add(fn) table.insert(Events.OnGameBoot.handlers, fn) end
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
function UIElement:setVisible(v) self.visible = v end
function UIElement:isVisible() return self.visible end
function UIElement:getWidth() return self.width end
function UIElement:getHeight() return self.height end
function UIElement:getX() return self.x end
function UIElement:getY() return self.y end
function UIElement:setName(n) self.name = n end
function UIElement:setTitle(t) self.title = t end
function UIElement:setFont(f) self.font = f end
function UIElement:setAnchorLeft(v) end
function UIElement:setAnchorRight(v) end
function UIElement:setAnchorTop(v) end
function UIElement:setAnchorBottom(v) end
function UIElement:ignoreWidthChange() end
function UIElement:ignoreHeightChange() end

ISPanel = UIElement:derive("ISPanel")
ISLabel = UIElement:derive("ISLabel")
function ISLabel:new(x, y, w, text, ...)
    local o = UIElement.new(self, x, y, w, 20)
    o.labelText = text
    return o
end
ISButton = UIElement:derive("ISButton")
function ISButton:new(x, y, w, h, title, clicktarget, onclick, ...)
    local o = UIElement.new(self, x, y, w, h)
    o.title, o.clicktarget, o.onclick = title, clicktarget, onclick
    return o
end
ISTextEntryBox = UIElement:derive("ISTextEntryBox")
function ISTextEntryBox:new(text, x, y, w, h)
    local o = UIElement.new(self, x, y, w, h)
    o.text = text or ""
    return o
end
function ISTextEntryBox:getText() return self.text end
function ISTextEntryBox:setText(t) self.text = t end

ModSelector = { instance = nil }
ModInfoPanel = UIElement:derive("ModInfoPanel")
function ModInfoPanel:createChildren() end
function ModInfoPanel:updateView(modInfo) self.lastModInfo = modInfo end

local function fakeModInfo(modId, workshopID)
    return {
        getId = function(self) return modId end,
        getWorkshopID = function(self) return workshopID or "" end,
        modId = modId,
    }
end

-- ---------- load the real mod files ----------
local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/wb-luatest-adopt"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_Config")
WB_Config.DEBUG_STUB = true
require("WorkshopBridge/WB_Main")
for _, h in ipairs(Events.OnGameBoot.handlers) do h() end

local function tick(n)
    for _ = 1, n do
        for _, h in ipairs(Events.OnTick.handlers) do h() end
    end
end

check(WB_ApiKind == "stub", "boot installs debug stub")

-- MysteryMod is unknown to everyone (our map and the game)
local realWsid = wbGetWorkshopId
wbGetWorkshopId = function(modId)
    if modId == "MysteryMod" then return nil end
    return realWsid(modId)
end

-- ---------- adopt button visibility (real panel via the class hook) ----------
local panel = ModInfoPanel:new(0, 0, 400, 600)
panel:createChildren()
check(panel.wbAdoptBtn ~= nil, "adopt button added to mod panel")

panel:updateView(fakeModInfo("MysteryMod", ""))
check(panel.wbAdoptBtn.visible, "adopt button visible for unknown mod")
check(not panel.wbUpdateBtn.visible, "update button hidden for unknown mod")
check(panel.wbStatusLabel.name == WB_Text.UnknownWorkshopId,
    "unknown mod still shows unknown status")

panel:updateView(fakeModInfo("SomeMod", "")) -- stub maps it to 1111111111
check(not panel.wbAdoptBtn.visible, "adopt button hidden for tracked mod")
check(panel.wbUpdateBtn.visible, "update button visible for tracked mod")

panel:updateView(fakeModInfo("WorkshopBridge", "999")) -- Steam-managed
check(not panel.wbAdoptBtn.visible, "adopt button hidden for Steam-managed mod")

-- the button wires to the adopt dialog; no screen is hooked in this test,
-- so the click must fail safe rather than crash
panel:updateView(fakeModInfo("MysteryMod", ""))
local okClick = pcall(function() panel.wbAdoptBtn.onclick() end)
check(okClick, "adopt button click without a hooked screen is safe")

-- ---------- adopt dialog flow ----------
local ms = setmetatable({ x = 0, y = 0, width = 1024, height = 768, children = {} },
    { __index = UIElement })
function ms:reloadMods() self.reloaded = (self.reloaded or 0) + 1 end

WB_ShowAdoptDialog(ms, "MysteryMod")
local dlg = ms.wbAdoptDialog
check(dlg ~= nil and dlg:isVisible(), "adopt dialog opens")
check(dlg.titleLabel.labelText:find("MysteryMod") ~= nil, "dialog names the mod",
    dlg.titleLabel.labelText)

local kidsBefore = #ms.children
WB_ShowAdoptDialog(ms, "MysteryMod") -- again: must not stack duplicates
check(#ms.children == kidsBefore, "no duplicate adopt dialogs", #ms.children)

-- invalid input: error shown, dialog stays open, no job started
dlg.entry:setText("not a workshop id")
dlg.adoptBtn.onclick()
check(dlg.errorLabel.name == WB_Text.InvalidWorkshopId, "invalid input shows error",
    dlg.errorLabel.name)
check(ms.wbAdoptDialog == dlg, "dialog stays open on invalid input")

-- valid id: dialog closes, adopt job runs with (workshopId, modId)
local adoptArgs = nil
local realAdopt = wbAdoptMod
wbAdoptMod = function(wsid, modId) adoptArgs = { wsid, modId }; return realAdopt(wsid, modId) end
dlg.entry:setText("https://steamcommunity.com/sharedfiles/filedetails/?id=444555666")
dlg.adoptBtn.onclick()
check(ms.wbAdoptDialog == nil, "dialog closes on valid input")
check(adoptArgs and adoptArgs[1] == "444555666" and adoptArgs[2] == "MysteryMod",
    "wbAdoptMod called with (workshopId, modId)",
    adoptArgs and table.concat(adoptArgs, ","))
tick(200) -- stub adopt job: 12 ticks/step x 8 steps
check((ms.reloaded or 0) >= 1, "reloadMods called after adopt")

-- cancel closes without starting anything
adoptArgs = nil
WB_ShowAdoptDialog(ms, "MysteryMod")
local dlg2 = ms.wbAdoptDialog
dlg2.cancelBtn.onclick()
check(ms.wbAdoptDialog == nil, "cancel closes dialog")
check(adoptArgs == nil, "cancel adopts nothing")

print(failures == 0 and "ALL ADOPT TESTS PASSED" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
