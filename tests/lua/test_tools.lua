-- More-tools test: export/import/collection flows using the real WB_*.lua
-- files with stubbed PZ globals.
local LUA_DIR = os.getenv("WB_LUA_DIR")
local failures = 0
local function check(cond, name, extra)
    if cond then print("PASS " .. name)
    else print("FAIL " .. name .. (extra and (" -- " .. tostring(extra)) or "")); failures = failures + 1 end
end

-- ---------- stub PZ environment ----------
-- PZAPI.ModOptions stub mirroring the vanilla options system: create() +
-- addTickBox() register, getOptions()/getOption()/getValue() read back.
-- (The real one persists to ModOptions.ini; the stub just holds values.)
local registeredOptions = nil
PZAPI = { ModOptions = { Data = {}, Dict = {} } }
function PZAPI.ModOptions:create(modOptionsID, name)
    local opts = { modOptionsID = modOptionsID, name = name, data = {}, dict = {} }
    function opts:getOption(id) return self.dict[id] end
    function opts:addTickBox(id, label, value, tooltip)
        local opt = { type = "tickbox", id = id, name = label,
            value = value, tooltip = tooltip }
        function opt:getValue() return self.value end
        function opt:setValue(v) self.value = v end
        table.insert(self.data, opt)
        self.dict[id] = opt
        return opt
    end
    table.insert(PZAPI.ModOptions.Data, opts)
    PZAPI.ModOptions.Dict[modOptionsID] = opts
    registeredOptions = opts
    return opts
end
function PZAPI.ModOptions:getOptions(modOptionsID)
    return PZAPI.ModOptions.Dict[modOptionsID]
end
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
function UIElement:addChild(c)
    table.insert(self.children, c)
    -- mirrors the game: addChild is what creates the child's Java peer, so
    -- peer-touching calls (e.g. setMultipleLine) before this point throw
    c.addedToParent = true
end
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
ISButton = UIElement:derive("ISButton")
function ISButton:new(x, y, w, h, title, clicktarget, onclick, ...)
    local o = UIElement.new(self, x, y, w, h)
    o.title, o.clicktarget, o.onclick = title, clicktarget, onclick
    return o
end
function ISButton:setEnable(v) self.enable = v end
ISTextEntryBox = UIElement:derive("ISTextEntryBox")
function ISTextEntryBox:new(text, x, y, w, h)
    local o = UIElement.new(self, x, y, w, h)
    o.text = text or ""
    return o
end
function ISTextEntryBox:getText() return self.text end
function ISTextEntryBox:setText(t) self.text = t end
function ISTextEntryBox:setMultipleLine(m)
    if not self.addedToParent then
        error("setMultipleLine before addChild (no Java peer in-game)")
    end
    self.multiLine = m
end

local fakeList = {
    width = 600,
    doDrawItem = function(lb, y, item, alt) return y + 40 end,
    getWidth = function(self) return self.width end,
    drawTextRight = function(self, ...) end,
}
ModSelector = { instance = nil }
function ModSelector.create(self)
    self.backButton = ISButton:new(880, 710, 120, 30, "Back", self, function() end)
    self.mapOrderbtn = ISButton:new(700, 710, 100, 30, "MapsOrder", self, function() end)
    self.modListPanel = { modList = fakeList }
end

-- ---------- load the real mod files ----------
local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/wb-luatest-tools"
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

-- ---------- mod options (Options > Mods > WorkshopBridge) ----------
check(registeredOptions ~= nil, "mod options registered with PZAPI")
check(registeredOptions.modOptionsID == "WorkshopBridge"
        and registeredOptions.name == "WorkshopBridge",
    "options section id and title")
local refreshOpt = registeredOptions:getOption("RefreshListPerDownload")
check(refreshOpt ~= nil and refreshOpt:getValue() == true,
    "per-download refresh tickbox present, default on")
check(WB_GetRefreshListPerDownload() == true,
    "option reads true by default")
-- the three newer tickboxes follow the same pattern
local depsOpt = registeredOptions:getOption("CheckDependenciesAfterDownload")
check(depsOpt ~= nil and depsOpt:getValue() == true,
    "dependency-check tickbox present, default on")
check(WB_GetCheckDependenciesAfterDownload() == true,
    "dependency option reads true by default")
local serverOpt = registeredOptions:getOption("OfferServerModDownloads")
check(serverOpt ~= nil and serverOpt:getValue() == true,
    "server-download tickbox present, default on")
check(WB_GetOfferServerModDownloads() == true,
    "server-download option reads true by default")
local sidecarOpt = registeredOptions:getOption("WriteSidecarStamp")
check(sidecarOpt ~= nil and sidecarOpt:getValue() == true,
    "sidecar tickbox present, default on")
check(WB_GetWriteSidecarStamp() == true,
    "sidecar option reads true by default")
local collectionOpt = registeredOptions:getOption("EnableCollectionImport")
check(collectionOpt ~= nil and collectionOpt:getValue() == false,
    "collection import tickbox present, default off")
check(WB_GetEnableCollectionImport() == false,
    "collection import option reads false by default")
-- toggling one does not affect the others
depsOpt:setValue(false)
check(WB_GetCheckDependenciesAfterDownload() == false,
    "dependency option reads false when turned off")
check(WB_GetOfferServerModDownloads() == true
        and WB_GetWriteSidecarStamp() == true
        and WB_GetRefreshListPerDownload() == true,
    "other options unaffected by the toggle")
depsOpt:setValue(true)
serverOpt:setValue(false)
sidecarOpt:setValue(false)
check(WB_GetOfferServerModDownloads() == false
        and WB_GetWriteSidecarStamp() == false
        and WB_GetCheckDependenciesAfterDownload() == true,
    "each option toggles independently")
serverOpt:setValue(true)
sidecarOpt:setValue(true)
-- degrades to on when the options API is absent (e.g. game changes)
local savedPZAPI = PZAPI
PZAPI = nil
check(WB_GetRefreshListPerDownload() == true,
    "option defaults to on without the API")
check(WB_GetCheckDependenciesAfterDownload() == true,
    "dependency option defaults to on without the API")
check(WB_GetOfferServerModDownloads() == true,
    "server-download option defaults to on without the API")
check(WB_GetWriteSidecarStamp() == true,
    "sidecar option defaults to on without the API")
PZAPI = savedPZAPI
check(WB_GetRefreshListPerDownload() == true,
    "option still reads true after API restore")

-- ---------- WB_ParseImportText unit tests ----------
local ids = WB_ParseImportText("2685600088\nhttps://steamcommunity.com/sharedfiles/filedetails/?id=12345\n\njunk line\n2685600088\n")
check(#ids == 2 and ids[1] == "2685600088" and ids[2] == "12345",
    "import text: ids + URLs parsed, blanks/junk/dupes dropped",
    table.concat(ids, ","))
check(#WB_ParseImportText("") == 0, "import text: empty -> none")
check(#WB_ParseImportText("hello\r\nworld\r\n") == 0, "import text: CRLF junk -> none")
check(#WB_ParseImportText(nil) == 0, "import text: nil -> none")
local crlf = WB_ParseImportText("111\r\n222\r\n")
check(#crlf == 2 and crlf[1] == "111" and crlf[2] == "222", "import text: CRLF split")

-- ---------- menu button + tools dialog ----------
local ms = setmetatable({ x = 0, y = 0, width = 1024, height = 768, children = {} },
    { __index = UIElement })
function ms:reloadMods() self.reloaded = (self.reloaded or 0) + 1 end
ModSelector.create(ms)
check(ms.wbToolsBtn and ms.wbToolsBtn.title == WB_Text.MoreTools,
    "more-tools button added to menu")

ms.wbToolsBtn.onclick()
local tools = ms.wbToolsDialog
check(tools ~= nil and tools:isVisible(), "tools dialog opens")
check(tools.exportBtn and tools.importTextBtn and tools.importCollectionBtn,
    "tools dialog has all three tool buttons")
check(tools.importCollectionBtn.enable == false,
    "collection import disabled by default (option off)")
-- enabling the experimental option enables the button (no restart: the
-- dialog reads the option when it opens)
collectionOpt:setValue(true)
ms.wbToolsDialog:close()
ms.wbToolsBtn.onclick()
check(ms.wbToolsDialog.importCollectionBtn.enable ~= false,
    "collection import enabled when the option is on")
collectionOpt:setValue(false)
ms.wbToolsDialog:close()

-- ---------- export ----------
local function modInfo(wsid)
    return {
        getId = function() return "x" end,
        getWorkshopID = function() return wsid or "" end,
    }
end
-- SteamMod is invisible to our map (Steam-managed); UnknownMod to everyone
local realWsid = wbGetWorkshopId
wbGetWorkshopId = function(modId)
    if modId == "SteamMod" or modId == "UnknownMod" then return nil end
    return realWsid(modId)
end
ms.model = { mods = {
    TrackedMod  = { isActive = true,  modInfo = modInfo("") },
    SteamMod    = { isActive = true,  modInfo = modInfo("7777777") },
    InactiveMod = { isActive = false, modInfo = modInfo("") },
    UnknownMod  = { isActive = true,  modInfo = modInfo("") },
} }
local got = WB_CollectEnabledWorkshopIds(ms)
local set = {}
for _, id in ipairs(got) do set[id] = true end
check(set["3333333333"] and set["7777777"] and #got == 2,
    "export collects tracked + Steam-managed enabled mods only",
    table.concat(got, ","))

local exportedCsv = nil
local realExport = wbExportModList
wbExportModList = function(csv) exportedCsv = csv; return realExport(csv) end
tools.exportBtn.onclick()
check(ms.wbToolsDialog == nil, "tools dialog closes on export")
check(exportedCsv ~= nil, "wbExportModList called")
local eset = {}
for id in (exportedCsv or ""):gmatch("%d+") do eset[id] = true end
check(eset["3333333333"] and eset["7777777"], "export passes enabled ids",
    tostring(exportedCsv))
local flash = ms.wbProgressPanel and ms.wbProgressPanel.wbLabel
check(flash and flash.name:find("Exported 2") ~= nil, "export flashes count",
    flash and flash.name)

-- export with nothing enabled-known: message, no backend call
ms.model = { mods = { UnknownMod = { isActive = true, modInfo = modInfo("") } } }
exportedCsv = nil
ms.wbToolsBtn.onclick()
ms.wbToolsDialog.exportBtn.onclick()
check(exportedCsv == nil, "no export call when nothing exportable")
flash = ms.wbProgressPanel and ms.wbProgressPanel.wbLabel
check(flash and flash.name == WB_Text.NothingToExport, "empty export explains",
    flash and flash.name)

-- ---------- import from text ----------
ms.wbToolsBtn.onclick()
ms.wbToolsDialog.importTextBtn.onclick()
local tdlg = ms.wbImportTextDialog
check(tdlg ~= nil and tdlg:isVisible(), "import-text dialog opens")
check(tdlg.entry.multiLine == true, "import-text entry is multi-line")

tdlg.entry:setText("not an id")
tdlg.importBtn.onclick()
check(tdlg.errorLabel.name == WB_Text.NothingToImport, "junk shows error")
check(ms.wbImportTextDialog == tdlg, "dialog stays open on junk")

local importedCsv = nil
local realImport = wbImportMods
wbImportMods = function(csv) importedCsv = csv; return realImport(csv) end
local invalidateCount = 0
local realInvalidate = wbInvalidateModCaches
wbInvalidateModCaches = function()
    invalidateCount = invalidateCount + 1
    return realInvalidate()
end
tdlg.entry:setText("111\nhttps://steamcommunity.com/sharedfiles/filedetails/?id=222\n111\njunk\n")
local reloadedBefore = ms.reloaded or 0
tdlg.importBtn.onclick()
check(ms.wbImportTextDialog == nil, "import-text dialog closes on valid input")
check(importedCsv == "111,222", "import passes deduped ids", tostring(importedCsv))
tick(200)
check((ms.reloaded or 0) - reloadedBefore >= 2,
    "mod list rebuilt per download, not just at the end",
    tostring((ms.reloaded or 0) - reloadedBefore))
check(invalidateCount >= 2,
    "mod caches invalidated per download, not just at the end", invalidateCount)
wbInvalidateModCaches = realInvalidate

-- ---------- per-download refresh disabled via mod option ----------
refreshOpt:setValue(false)
check(WB_GetRefreshListPerDownload() == false,
    "option reads false when turned off")
local invalidateOff = 0
wbInvalidateModCaches = function() invalidateOff = invalidateOff + 1 end
local reloadedOffBefore = ms.reloaded or 0
ms.wbToolsBtn.onclick()
ms.wbToolsDialog.importTextBtn.onclick()
local tdlg2 = ms.wbImportTextDialog
tdlg2.entry:setText("333\n444\n")
tdlg2.importBtn.onclick()
check(ms.wbImportTextDialog == nil, "second import starts with option off")
tick(200)
local reloadedOffDelta = (ms.reloaded or 0) - reloadedOffBefore
check(reloadedOffDelta == 1,
    "no per-download rebuilds when option off (end refresh only)",
    tostring(reloadedOffDelta))
check(invalidateOff >= 2,
    "caches still invalidated per download when option off", invalidateOff)
wbInvalidateModCaches = realInvalidate
refreshOpt:setValue(true)
check(WB_GetRefreshListPerDownload() == true,
    "option reads true when turned back on")

-- cancel closes without importing
importedCsv = nil
ms.wbToolsBtn.onclick()
ms.wbToolsDialog.importTextBtn.onclick()
local tdlg2 = ms.wbImportTextDialog
tdlg2.cancelBtn.onclick()
check(ms.wbImportTextDialog == nil, "import-text cancel closes")
check(importedCsv == nil, "cancel imports nothing")

-- ---------- import from collection ----------
ms.wbToolsBtn.onclick()
ms.wbToolsDialog.importCollectionBtn.onclick()
local cdlg = ms.wbImportCollectionDialog
check(cdlg ~= nil and cdlg:isVisible(), "collection dialog opens")

cdlg.entry:setText("abc")
cdlg.importBtn.onclick()
check(cdlg.errorLabel.name == WB_Text.InvalidWorkshopId, "bad id shows error")
check(ms.wbImportCollectionDialog == cdlg, "dialog stays open on bad id")

local collectionId = nil
local realCollection = wbImportCollection
wbImportCollection = function(id) collectionId = id; return realCollection(id) end
cdlg.entry:setText("https://steamcommunity.com/sharedfiles/filedetails/?id=999000111")
cdlg.importBtn.onclick()
check(ms.wbImportCollectionDialog == nil, "collection dialog closes on valid id")
check(collectionId == "999000111", "collection id parsed from URL",
    tostring(collectionId))
tick(200)
check((ms.reloaded or 0) >= 2, "reloadMods called after collection import")

print(failures == 0 and "ALL TOOLS TESTS PASSED" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
