-- Workshop search UI test: loads the REAL WB_Search.lua with stubbed PZ
-- globals and a stubbed Java API, and exercises: build, empty query,
-- search -> results -> select -> install, failed search, no Java API.
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
UIFont = { Small = "UIFont.Small", Medium = "UIFont.Medium" }

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
function UIElement:drawText(...) end

ISPanel = UIElement:derive("ISPanel")
ISLabel = UIElement:derive("ISLabel")
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
function ISTextEntryBox:setMultipleLine(m) self.multiLine = m end
function ISTextEntryBox:setEditable(e) self.editable = e end
ISScrollingListBox = UIElement:derive("ISScrollingListBox")
function ISScrollingListBox:new(x, y, w, h)
    local o = UIElement.new(self, x, y, w, h)
    o.items = {}
    o.selected = nil
    return o
end
function ISScrollingListBox:addItem(text, item)
    table.insert(self.items, { text = text, item = item })
end
function ISScrollingListBox:clear()
    self.items = {}
    self.selected = nil
end

-- ---------- load the real mod files ----------
local tmp = os.getenv("TMPDIR") or "/tmp"
tmp = tmp .. "/wb-luatest-search"
os.execute("mkdir -p " .. tmp)
os.execute("ln -sfn " .. LUA_DIR .. " " .. tmp .. "/WorkshopBridge")
package.path = tmp .. "/?.lua;" .. package.path
require("WorkshopBridge/WB_Search")

local function tick(n)
    for _ = 1, n do
        for _, h in ipairs(Events.OnTick.handlers) do h() end
    end
end

local ms = setmetatable({ x = 0, y = 0, width = 1280, height = 720, children = {} },
    { __index = UIElement })

-- ---------- stub Java API ----------
local statuses = {}
local searchJobSeq = 0
local lastSearchQuery = nil
local importCsv = nil
function wbSearchWorkshop(q)
    searchJobSeq = searchJobSeq + 1
    lastSearchQuery = q
    return "searchjob" .. searchJobSeq
end
function wbGetJobStatus(jobId) return statuses[jobId] end
function wbImportMods(csv)
    importCsv = csv
    statuses["importjob1"] =
        '{"state":"done","done":1,"total":1,"message":"Imported","updates":[],"deps":[],"results":[]}'
    return "importjob1"
end
function WB_RefreshModList(m) end

local function searchStatus(resultsJson)
    return '{"state":"done","done":1,"total":1,"message":"2 mod(s) found",'
        .. '"updates":[],"deps":[],"results":[' .. table.concat(resultsJson, ",") .. "]}"
end
local function hit(id, title, installed)
    return '{"id":"' .. id .. '","title":"' .. title .. '",'
        .. '"description":"A test mod.","tags":["Mod"],"subscribers":1234,'
        .. '"rating":0.95,"fileSize":1048576,"timeUpdated":1780000000,'
        .. '"previewUrl":"","installed":' .. (installed and "true" or "false") .. "}"
end

-- ---------- 1. dialog opens and builds ----------
WB_ShowSearchDialog(ms)
local dlg = ms.wbSearchDialog
check(dlg ~= nil, "search dialog opens")
check(dlg.searchEntry ~= nil and dlg.searchBtn ~= nil, "search row built")
check(dlg.resultList ~= nil, "results list built")
check(dlg.installBtn ~= nil and dlg.closeBtn ~= nil, "install/close buttons built")
check(dlg.searchBtn.title == WB_Text.Search, "search button title")
check(dlg.installBtn.title == WB_Text.Install, "install button title")

-- ---------- 2. empty query does not call the bridge ----------
dlg.searchEntry:setText("   ")
dlg:onSearchClicked()
check(lastSearchQuery == nil, "empty query never reaches the bridge")
check(dlg.statusLabel.name == WB_Text.SearchEnterQuery, "empty query shows hint")

-- ---------- 3. search -> results -> details ----------
statuses["searchjob1"] = searchStatus({
    hit("111", "Alpha Mod", true),
    hit("222", "Beta Mod", false),
})
dlg.searchEntry:setText("test")
dlg:onSearchClicked()
tick(2)
check(lastSearchQuery == "test", "query passed to the bridge", lastSearchQuery)
check(#dlg.resultList.items == 2, "two results listed", #dlg.resultList.items)
check(dlg.resultList.items[1].item.id == "111", "first result id")
check(dlg.detailTitle.name == "Alpha Mod", "first result auto-selected in details",
    dlg.detailTitle.name)
-- select the second row via the update() poll (as a real click would)
dlg.resultList.selected = 2
dlg:update()
check(dlg.detailTitle.name == "Beta Mod", "selection updates details",
    dlg.detailTitle.name)
check(dlg.detailStats.name:find("95%% positive") ~= nil, "stats line shows rating",
    dlg.detailStats.name)
check(dlg.detailStats.name:find("1.2k subscribers") ~= nil, "stats line shows subscribers",
    dlg.detailStats.name)
check(dlg.detailTags.name == "Mod", "tags shown", dlg.detailTags.name)
check(dlg.descBox:getText() == "A test mod.", "description shown")

-- ---------- 4. install the selected result ----------
dlg.installBtn.onclick()
check(importCsv == "222", "install imports the selected workshop id", importCsv)
tick(2)
check(dlg.statusLabel.name == WB_Text.Imported, "import success shown")
check(dlg.results[2].installed == true, "installed flag refreshed on the hit")

-- ---------- 5. failed search shows the error ----------
dlg.searchEntry:setText("boom")
statuses["searchjob2"] =
    '{"state":"failed","done":0,"total":1,"message":"","error":"Steam is rate-limiting",'
    .. '"updates":[],"deps":[],"results":[]}'
dlg:onSearchClicked()
tick(2)
check(dlg.statusLabel.name:find(WB_Text.SearchFailed) ~= nil, "failed search shows error",
    dlg.statusLabel.name)

-- ---------- 6. no results ----------
dlg.searchEntry:setText("nada")
statuses["searchjob3"] =
    '{"state":"done","done":1,"total":1,"message":"No mods found","updates":[],"deps":[],"results":[]}'
dlg:onSearchClicked()
tick(2)
check(dlg.statusLabel.name == WB_Text.NoResults, "empty results message")

-- ---------- 7. no Java API -> no crash ----------
wbSearchWorkshop = nil
dlg.searchEntry:setText("test")
dlg:onSearchClicked() -- must not error
tick(2)
check(true, "no bridge function does not crash")

-- ---------- 8. close ----------
dlg.closeBtn.onclick()
check(ms.wbSearchDialog == nil, "dialog closed and dereferenced")

if failures == 0 then print("ALL SEARCH TESTS PASSED") end
os.exit(failures == 0 and 0 or 1)
