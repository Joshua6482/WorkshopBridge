-- UI integration test: loads the REAL WB_*.lua files with stubbed PZ globals
-- and exercises the full flow: boot -> hook -> check -> badge -> per-mod update.
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
function UIElement:update() end
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
function UIElement:drawText(...) end
function UIElement:drawTextRight(...) end

ISPanel = UIElement:derive("ISPanel")
ISLabel = UIElement:derive("ISLabel")
ISButton = UIElement:derive("ISButton")
function ISButton:new(x, y, w, h, title, clicktarget, onclick, ...)
    local o = UIElement.new(self, x, y, w, h)
    o.title, o.clicktarget, o.onclick = title, clicktarget, onclick
    return o
end

local badgesDrawn, rowsDrawn = {}, {}
-- fake ModListBox class: our row wrap is class-level, so the listbox
-- instance delegates to it via the metatable, like the game's class system
local fakeMLClass = {
    doDrawItem = function(lb, y, item, alt)
        table.insert(rowsDrawn, { item = item })
        return y + 40 -- vanilla returns y + height; prerender does math on it
    end,
}
local fakeList = setmetatable({
    width = 600,
    getWidth = function(self) return self.width end,
    drawTextRight = function(self, text, x, y, r, g, b, a, font)
        table.insert(badgesDrawn, { text = text, x = x, y = y })
    end,
}, { __index = fakeMLClass })
local fakeModListPanel = { modList = fakeList }
ModSelector = { instance = nil, ModListBox = fakeMLClass }
function ModSelector.create(self)
    self.backButton = ISButton:new(880, 710, 120, 30, "Back", self, function() end)
    self.mapOrderbtn = ISButton:new(700, 710, 100, 30, "MapsOrder", self, function() end)
    self.modListPanel = fakeModListPanel
end
function ModSelector:reloadMods() self.reloaded = (self.reloaded or 0) + 1 end

ModInfoPanel = UIElement:derive("ModInfoPanel")
function ModInfoPanel:createChildren() end
function ModInfoPanel:updateView(modInfo) self.lastModInfo = modInfo end

local function fakeModInfo(modId, workshopID)
    return {
        getId = function(self) return modId end,
        getWorkshopID = function(self) return workshopID or "" end,
        modId = modId, -- modData tables carry .modId (vanilla model sets data.modId)
    }
end

-- ---------- load the real mod files ----------
local tmp = os.getenv("TMPDIR") or "/tmp"
tmp = tmp .. "/wb-luatest"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_Config")
-- enable the canned debug stub explicitly: the shipped default is off
-- (WB_Main installs the stub only when this is true)
WB_Config.DEBUG_STUB = true
require("WorkshopBridge/WB_Main")
for _, h in ipairs(Events.OnGameBoot.handlers) do h() end

local function tick(n)
    for _ = 1, n do
        for _, h in ipairs(Events.OnTick.handlers) do h() end
    end
end

-- ---------- boot ----------
check(WB_ApiKind == "stub", "boot installs debug stub")
check(type(wbIsAvailable) == "function" and wbIsAvailable(), "stub api available")

-- wrap the cache-invalidation call so the flows below can assert the game
-- caches are invalidated before the list reloads
local invalidateCalls = 0
local realInvalidate = wbInvalidateModCaches
wbInvalidateModCaches = function(...)
    invalidateCalls = invalidateCalls + 1
    return realInvalidate(...)
end

-- ---------- menu hook ----------
local ms = setmetatable({ x = 0, y = 0, width = 1024, height = 768, children = {} },
    { __index = UIElement })
function ms:reloadMods() self.reloaded = (self.reloaded or 0) + 1 end
ModSelector.create(ms)
check(ms.wbButtonsAdded, "menu buttons added on create")
check(ms.wbCheckBtn and ms.wbUpdateAllBtn, "check + update-all buttons exist")
check(#ms.children >= 2, "buttons added as children", #ms.children)
check(ms.wbUpdateAllBtn.title == "Update all", "update-all initial title")
-- progress panel is built eagerly at menu open, hidden until a job runs
check(ms.wbProgressPanel ~= nil and ms.wbProgressPanel.wbLabel ~= nil,
    "progress panel created eagerly with label")
check(not ms.wbProgressPanel:isVisible(), "progress panel hidden initially")

-- idempotent re-hook
local kids = #ms.children
WB_HookInstance(ms)
check(#ms.children == kids, "re-hook adds nothing")

-- ---------- per-mod panel: three states ----------
local panel = ModInfoPanel:new(0, 0, 400, 600)
panel:createChildren()
check(panel.wbControlsAdded, "mod panel controls added")
check(panel.wbUpdateBtn and panel.wbStatusLabel, "update button + status label exist")

panel:updateView(fakeModInfo("SomeMod", ""))
check(panel.wbModId == "SomeMod", "panel tracks mod id")
check(panel.wbUpdateBtn.visible, "update button visible for WB-known mod")
check(panel.wbStatusLabel.name == "", "no badge before check")

-- stub wbGetWorkshopId returns nil for our own MOD_ID -> falls to game signal
panel:updateView(fakeModInfo("WorkshopBridge", "999"))
check(not panel.wbUpdateBtn.visible, "button hidden for Steam-managed mod")
check(panel.wbStatusLabel.name == WB_Text.ManagedBySteam, "Managed by Steam label")

panel:updateView(fakeModInfo("NoMapMod", ""))
-- stub knows every mod except our own, so force unknown by removing it:
-- (uses a modId the stub hasn't "seen"; wbGetWorkshopId still returns the id...
-- so instead verify the unknown branch via a temporary override)
local realWsid = wbGetWorkshopId
wbGetWorkshopId = function() return nil end
panel:updateView(fakeModInfo("NoMapMod", ""))
check(panel.wbStatusLabel.name == WB_Text.UnknownWorkshopId, "Unknown workshop ID label")
wbGetWorkshopId = realWsid

-- ---------- open-in-workshop button ----------
panel:updateView(fakeModInfo("SomeMod", ""))
check(panel.wbWorkshopBtn ~= nil, "workshop button exists")
check(panel.wbWorkshopBtn.visible, "workshop button visible for WB-tracked mod")
check(panel.wbWorkshopId == "1111111111", "workshop id stored for tracked mod",
    panel.wbWorkshopId)

panel:updateView(fakeModInfo("WorkshopBridge", "999"))
check(panel.wbWorkshopBtn.visible, "workshop button visible for Steam-managed mod")
check(panel.wbWorkshopId == "999", "game workshop id used when not tracked",
    panel.wbWorkshopId)

wbGetWorkshopId = function() return nil end
panel:updateView(fakeModInfo("NoMapMod", ""))
check(not panel.wbWorkshopBtn.visible, "workshop button hidden when id unknown")
wbGetWorkshopId = realWsid

-- clicking opens the stored workshop id in the browser
local openedId = nil
local realOpen = wbOpenWorkshopPage
wbOpenWorkshopPage = function(wsid) openedId = wsid return true end
panel:updateView(fakeModInfo("SomeMod", ""))
panel.wbWorkshopBtn.onclick()
check(openedId == "1111111111", "click opens the mod's workshop page", openedId)
wbOpenWorkshopPage = realOpen

-- ---------- check-for-updates flow ----------
panel:updateView(fakeModInfo("SomeMod", "")) -- re-select; marks seenModIds
ms.wbCheckBtn.onclick() -- click "Check for updates"
tick(30)
-- progress panel: the screen's own panel, visible, with a label
local prog = ms.wbProgressPanel
check(prog ~= nil and prog.wbLabel ~= nil, "progress panel present with label")
check(prog:isVisible(), "progress panel visible during job")
check(prog.wbLabel.name:find("Checking") ~= nil, "progress shows check message",
    prog.wbLabel.name)
tick(200) -- stub check job: 12 ticks/step x 6 steps
check(WB_IsUpdateAvailable("SomeMod"), "update marked available after check")
-- one workshop item, two mods: the count is items, not mods
check(ms.wbUpdateAllBtn.title == "Update all (1)", "update-all button shows item count",
    ms.wbUpdateAllBtn.title)

-- row badge: doDrawItem receives the listbox row wrapper { text, item=modData }
rowsDrawn, badgesDrawn = {}, {}
local retY = fakeList:doDrawItem(100, { item = fakeModInfo("SomeMod", "") }, false)
check(retY == 140, "wrapper propagates doDrawItem return value", retY)
check(#rowsDrawn == 1 and #badgesDrawn == 1, "badge drawn for update-available mod")
check(badgesDrawn[1] and badgesDrawn[1].text == WB_Text.UpdateAvailableBadge, "badge text")
rowsDrawn, badgesDrawn = {}, {}
fakeList:doDrawItem(120, { item = fakeModInfo("OtherMod", "") }, false)
check(#rowsDrawn == 1 and #badgesDrawn == 0, "no badge for up-to-date mod")

-- ---------- ModFolders coexistence ----------
-- folder rows carry no mod id: badge skipped, no error
rowsDrawn, badgesDrawn = {}, {}
local okFolder, errFolder = pcall(function()
    return fakeList:doDrawItem(100, { item = { mfFolderRow = true, name = "My Folder" } }, false)
end)
check(okFolder, "folder row draws without error", errFolder)
check(#rowsDrawn == 1 and #badgesDrawn == 0, "no badge on folder row")

-- helper: a fresh listbox class + instance delegating to it
local function makeListBoxPair(vanillaRet, parent)
    local cls = {
        doDrawItem = function(lb, y, item, alt)
            table.insert(rowsDrawn, { item = item })
            return y + vanillaRet
        end,
    }
    local list = setmetatable({
        width = 600,
        parent = parent,
        getWidth = function(self) return self.width end,
        drawTextRight = function(self, text, x, y, ...)
            table.insert(badgesDrawn, { text = text, x = x, y = y })
        end,
    }, { __index = cls })
    return cls, list
end
-- ModFolders-style class patch: folder rows drawn by it, rest chained
local function installFakeModFolders(cls, folderRows)
    local prev = cls.doDrawItem
    cls.doDrawItem = function(lb, y, item, alt)
        if item and item.item and item.item.mfFolderRow then
            table.insert(folderRows, item)
            return y + 99
        end
        return prev(lb, y, item, alt)
    end
end

-- install order 1: WB wraps first (boot), ModFolders patches the class later
-- (OnMainMenuEnter) - the real game's order; must not shadow the patch
rowsDrawn, badgesDrawn = {}, {}
local classB, listB = makeListBoxPair(40)
ModSelector.ModListBox = classB
WB_HookModsMenu() -- wraps classB while it is still vanilla
local mfFolderRowsB = {}
installFakeModFolders(classB, mfFolderRowsB)
local retB = listB:doDrawItem(100, { item = { mfFolderRow = true, name = "F" } }, false)
check(retB == 199, "WB-first: late ModFolders patch draws folder rows", retB)
check(#mfFolderRowsB == 1 and #badgesDrawn == 0, "WB-first: folder row handled, no badge")
rowsDrawn, badgesDrawn = {}, {}
listB:doDrawItem(100, { item = fakeModInfo("SomeMod", "") }, false)
check(#rowsDrawn == 1 and #badgesDrawn == 1, "WB-first: normal rows chain through both")

-- install order 2: ModFolders first, WB wraps second
rowsDrawn, badgesDrawn = {}, {}
local classC, listC = makeListBoxPair(40)
local mfFolderRowsC = {}
installFakeModFolders(classC, mfFolderRowsC)
ModSelector.ModListBox = classC
WB_HookModsMenu() -- wraps classC around the ModFolders patch
local retC = listC:doDrawItem(100, { item = { mfFolderRow = true, name = "F" } }, false)
check(retC == 199, "MF-first: folder row handled by ModFolders", retC)
check(#mfFolderRowsC == 1 and #badgesDrawn == 0, "MF-first: no badge on folder row")
rowsDrawn, badgesDrawn = {}, {}
listC:doDrawItem(100, { item = fakeModInfo("SomeMod", "") }, false)
check(#rowsDrawn == 1 and #badgesDrawn == 1, "MF-first: vanilla draw + badge both run")

-- with ModFolders panel controls present, the badge shifts left of its icons
-- (detected per draw via listbox.parent: the controls install after our wrap)
getTextManager = function()
    return { getFontHeight = function(self, font) return 14 end }
end
ModSelector.ModListBox = fakeMLClass
rowsDrawn, badgesDrawn = {}, {}
local _, listMF = makeListBoxPair(40, { mfNewFolderButton = {} })
-- listMF delegates to its own fresh class; point it at the wrapped fixture
-- class instead so the real wrapper under test runs
setmetatable(listMF, { __index = fakeMLClass })
listMF:doDrawItem(100, { item = fakeModInfo("SomeMod", "") }, false)
check(#badgesDrawn == 1, "badge drawn with ModFolders present")
local expectedX = 600 - 10 - 3 * (14 + 6) - 16
check(badgesDrawn[1] and badgesDrawn[1].x == expectedX,
    "badge shifted left of ModFolders icons", badgesDrawn[1] and badgesDrawn[1].x)

-- ---------- per-mod update flow ----------
panel:updateView(fakeModInfo("SomeMod", ""))
check(panel.wbStatusLabel.name == WB_Text.UpdateAvailableBadge, "panel shows badge pre-update")
check(panel.wbUpdateBtn.title == WB_Text.Update, "button says Update when update available",
    panel.wbUpdateBtn.title)
panel.wbUpdateBtn.onclick() -- click per-mod Update
tick(30)
tick(200) -- stub update job: 12 ticks/step x 8 steps
check(panel.wbStatusLabel.name == WB_Text.UpToDate, "panel shows Up to date after update",
    panel.wbStatusLabel.name)
check(not WB_IsUpdateAvailable("SomeMod"), "update-available cleared after update")
check(not WB_IsUpdateAvailable("NoMapMod"),
    "sibling mod from the same workshop item cleared too")
check(panel.wbUpdateBtn.title == WB_Text.ForceUpdate, "button says Force update when up to date",
    panel.wbUpdateBtn.title)
check(ms.wbUpdateAllBtn.title == "Update all", "update-all count reset after per-mod update",
    ms.wbUpdateAllBtn.title)
check(invalidateCalls >= 1, "mod caches invalidated after per-mod update", invalidateCalls)
check((ms.reloaded or 0) >= 1, "list reloaded after per-mod update", ms.reloaded)

-- ---------- per-mod job status follows the selected mod ----------
-- start a fresh update, then select other mods mid-download
panel:updateView(fakeModInfo("SomeMod", ""))
panel.wbUpdateBtn.onclick()
tick(20) -- stub job needs 96 ticks to finish; still running
check(panel.wbStatusLabel.name:find("Working") ~= nil, "in-flight job paints panel",
    panel.wbStatusLabel.name)
-- sibling mod (same workshop item) shows the same live status
panel:updateView(fakeModInfo("NoMapMod", ""))
check(panel.wbStatusLabel.name:find("Working") ~= nil, "sibling shows in-flight status",
    panel.wbStatusLabel.name)
-- unrelated mod: the other item's job must not scribble over it
panel:updateView(fakeModInfo("OtherMod", ""))
tick(10)
check(panel.wbStatusLabel.name == "", "no cross-talk onto unrelated mod",
    panel.wbStatusLabel.name)
-- reselect the updating mod: live status, not a stale badge
panel:updateView(fakeModInfo("SomeMod", ""))
check(panel.wbStatusLabel.name:find("Working") ~= nil, "reselect shows live status",
    panel.wbStatusLabel.name)
tick(200) -- let it finish
check(panel.wbStatusLabel.name == WB_Text.UpToDate, "in-flight update completes cleanly",
    panel.wbStatusLabel.name)

-- ---------- duplicate per-mod clicks coalesce ----------
local updateCalls = 0
local realUpdateMod = wbUpdateMod
wbUpdateMod = function(...)
    updateCalls = updateCalls + 1
    return realUpdateMod(...)
end
panel:updateView(fakeModInfo("SomeMod", ""))
panel.wbUpdateBtn.onclick()
tick(5)
panel.wbUpdateBtn.onclick() -- while in flight: coalesced, no second job
tick(5)
check(updateCalls == 1, "duplicate click while in flight submits once", updateCalls)
wbUpdateMod = realUpdateMod
tick(200)
check(panel.wbStatusLabel.name == WB_Text.UpToDate, "coalesced update completes",
    panel.wbStatusLabel.name)

-- ---------- update-all flow ----------
ms.wbCheckBtn.onclick()
tick(250)
check(WB_CountUpdateAvailable() >= 1, "check re-marks updates")
ms.wbUpdateAllBtn.onclick()
tick(250)
check(WB_CountUpdateAvailable() == 0, "update-all clears marks")
check(ms.wbUpdateAllBtn.title == "Update all", "update-all title reset")
check((ms.reloaded or 0) >= 1, "reloadMods called after update-all")
check(invalidateCalls >= 2, "mod caches invalidated after update-all", invalidateCalls)

-- ---------- check flashes its result summary ----------
panel:updateView(fakeModInfo("SomeMod", "")) -- select; no updates marked now
check(panel.wbUpdateBtn.title == WB_Text.ForceUpdate, "button neutral before check")
ms.wbCheckBtn.onclick()
tick(80) -- stub check job completes (~72 ticks)
local sumPanel = ms.wbProgressPanel
check(sumPanel:isVisible(), "check result flashed")
check(sumPanel.wbLabel.name == "Check complete", "flash shows check summary",
    sumPanel.wbLabel.name)
-- visible panel refreshed without reselecting: badge + Update title
check(panel.wbStatusLabel.name == WB_Text.UpdateAvailableBadge,
    "panel badge refreshed by check")
check(panel.wbUpdateBtn.title == WB_Text.Update,
    "button title refreshed by check", panel.wbUpdateBtn.title)
for _ = 1, 200 do ms:update() end -- fallback pump advances the flash timer
check(not sumPanel:isVisible(), "result flash auto-hides")

-- ---------- unknown job is dropped gracefully ----------
local doneState = nil
WB_TrackJob("no-such-job", { onDone = function(st) doneState = st end })
tick(2)
check(doneState and doneState.state == "failed", "unknown job -> failed onDone")

-- ---------- flash message auto-hides, error panel sticks ----------
WB_FlashMessage(ms, "boom")
local flashPanel = ms.wbProgressPanel
check(flashPanel:isVisible(), "flash panel visible")
check(flashPanel.wbLabel.name == "boom", "flash shows message", flashPanel.wbLabel.name)
for _ = 1, 200 do ms:update() end -- fallback pump advances the flash timer
-- progress panel should have been hidden by the flash timeout
check(not flashPanel:isVisible(), "flash auto-hides after timeout")

WB_ShowError(ms, "kaput")
local errPanel = ms.wbProgressPanel
check(errPanel:isVisible(), "error panel visible")
check(errPanel.wbLabel.name:find("kaput") ~= nil
    and errPanel.wbLabel.name:find("click to dismiss") ~= nil,
    "error shows message + dismiss hint", errPanel.wbLabel.name)
tick(300)
check(errPanel:isVisible(), "error panel sticks (no auto-hide)")
errPanel:onMouseUp(errPanel, 10, 10) -- click dismisses
check(not errPanel:isVisible(), "click dismisses error panel")

-- ---------- UI timers advance only via the fallback pump ----------
WB_FlashMessage(ms, "timer check")
tick(300) -- OnTick alone must not expire the flash
check(ms.wbProgressPanel:isVisible(), "OnTick pump does not advance flash timer")
for _ = 1, 200 do ms:update() end -- fallback pump advances timers
check(not ms.wbProgressPanel:isVisible(), "fallback pump expires the flash")

-- ---------- concurrent jobs: panel ownership ----------
-- two jobs share the one panel: the first painter owns it (no flicker),
-- and a completing job must not hide the still-running job's status.
local realStatusOw = wbGetJobStatus
wbGetJobStatus = function(jobId)
    if jobId == "owner-a" then
        return '{"state":"running","done":0,"total":1,"message":"A working"}'
    end
    return '{"state":"running","done":0,"total":1,"message":"B working"}'
end
WB_TrackJob("owner-a", {
    onUpdate = function(st) WB_ShowProgress(ms, st.message) end,
    onDone = function(st) WB_HideProgress() end, -- must not hide B
})
WB_TrackJob("owner-b", {
    onUpdate = function(st) WB_ShowProgress(ms, st.message) end,
})
tick(3)
local firstLabel = ms.wbProgressPanel.wbLabel.name
check(firstLabel:find("A working") ~= nil or firstLabel:find("B working") ~= nil,
    "panel shows one concurrent job's status", firstLabel)
tick(3)
check(ms.wbProgressPanel.wbLabel.name == firstLabel,
    "no flicker between concurrent jobs", ms.wbProgressPanel.wbLabel.name)
wbGetJobStatus = function(jobId)
    if jobId == "owner-a" then
        return '{"state":"done","done":1,"total":1,"message":"A done"}'
    end
    return '{"state":"running","done":0,"total":1,"message":"B working"}'
end
tick(3)
check(ms.wbProgressPanel:isVisible(),
    "completing job does not hide the running job's panel")
check(ms.wbProgressPanel.wbLabel.name:find("B working") ~= nil,
    "ownership passes to the remaining job", ms.wbProgressPanel.wbLabel.name)
wbGetJobStatus = function(jobId)
    return '{"state":"done","done":1,"total":1,"message":"done"}'
end
tick(2) -- drain both jobs so later tests start clean
wbGetJobStatus = realStatusOw

-- ---------- sticky error vs. concurrent job ----------
-- a failing job's error must show even with another job running, and
-- neither the running job's paints nor the other job's completion may
-- clear it before the user dismisses it.
local realStatusErr = wbGetJobStatus
wbGetJobStatus = function(jobId)
    if jobId == "err-a" then
        return '{"state":"failed","done":0,"total":1,"error":"boom"}'
    end
    return '{"state":"running","done":0,"total":1,"message":"B working"}'
end
WB_TrackJob("err-a", {
    onUpdate = function(st) WB_ShowProgress(ms, st.message) end,
    onDone = function(st)
        WB_HideProgress()
        WB_ShowError(ms, "kaput: " .. WB_ShortError(st.error, 32))
    end,
})
WB_TrackJob("err-b", {
    onUpdate = function(st) WB_ShowProgress(ms, st.message) end,
    onDone = function(st) WB_HideProgress() end, -- must not clear the error
})
tick(3)
check(ms.wbProgressPanel:isVisible(),
    "failed job's error shows despite a concurrent job")
check(ms.wbProgressPanel.wbLabel.name:find("kaput") ~= nil,
    "running job does not erase the stuck error", ms.wbProgressPanel.wbLabel.name)
wbGetJobStatus = function(jobId)
    return '{"state":"done","done":1,"total":1,"message":"done"}'
end
tick(2) -- err-b completes
check(ms.wbProgressPanel:isVisible(),
    "completing job does not hide a stuck error")
ms.wbProgressPanel:onMouseUp(ms.wbProgressPanel, 10, 10)
check(not ms.wbProgressPanel:isVisible(), "click dismisses the stuck error")
wbGetJobStatus = realStatusErr

-- ---------- no-backend guidance label ----------
-- as WB_Main does when the Java API is absent: the menu still hooks,
-- showing guidance instead of a silent empty menu
ModSelector.wbHooked = nil
local msNoApi = setmetatable({ x = 0, y = 0, width = 1024, height = 768, children = {} },
    { __index = UIElement })
msNoApi.mapOrderbtn = ISButton:new(700, 710, 100, 30, "MapsOrder", msNoApi, function() end)
local prevInstance = ModSelector.instance
ModSelector.instance = msNoApi
WB_HookModsMenuNoApi()
ModSelector.instance = prevInstance
check(msNoApi.wbGuidanceAdded, "guidance label added when backend absent")
local guidanceText = nil
for _, c in ipairs(msNoApi.children) do
    if c.name == WB_Text.NeedsZombieBuddy then guidanceText = c.name end
end
check(guidanceText ~= nil, "guidance label shows the ZombieBuddy message")
check(msNoApi.wbCheckBtn == nil, "no update buttons without backend")

-- ---------- update() fallback pump ----------
check(ms.wbUpdatePumped, "update() pump installed on menu instance")
-- simulate a dead tick (no OnTick firing): drive jobs via ms:update() only
local fbDone, fbUpdates = nil, 0
local realStatus = wbGetJobStatus
local fbTicks = 0
wbGetJobStatus = function(jobId)
    fbTicks = fbTicks + 1
    if fbTicks < 3 then
        return '{"state":"running","done":0,"total":1,"message":"Working"}'
    end
    return '{"state":"done","done":1,"total":1,"message":"Done"}'
end
WB_TrackJob("fallback-job", {
    onUpdate = function(st) fbUpdates = fbUpdates + 1 end,
    onDone = function(st) fbDone = st end,
})
for _ = 1, 5 do ms:update() end -- no tick() calls: OnTick stays silent
check(fbUpdates >= 1, "fallback pump delivers onUpdate", fbUpdates)
check(fbDone and fbDone.state == "done", "fallback pump delivers onDone")
wbGetJobStatus = realStatus

print(failures == 0 and "ALL UI TESTS PASSED" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
