-- WorkshopBridge workshop search by name.
--
-- Custom dialog (built from ISPanel primitives, deliberately NOT reusing
-- the game's ModListBox/ModInfoPanel: those assume local ModInfo objects
-- and are already class-level-patched for local mods). Layout mimics the
-- base game's mod menu: search top-left, results list left, details
-- panel right with an Install button.
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"

WB_SearchDialog = ISPanel:derive("WB_SearchDialog")

-- NOTE: deliberately no initialise()/createChildren() overrides, same as
-- the other WB dialogs: controls are built once, by an explicit call
-- after instantiate().

local function WB_Truncate(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    return s:sub(1, n - 3) .. "..."
end

local function WB_FormatCount(n)
    n = tonumber(n) or 0
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(n)
end

local function WB_FormatBytes(n)
    n = tonumber(n) or 0
    if n >= 1073741824 then
        return string.format("%.1f GB", n / 1073741824)
    elseif n >= 1048576 then
        return string.format("%.1f MB", n / 1048576)
    elseif n >= 1024 then
        return string.format("%.0f KB", n / 1024)
    end
    return tostring(n) .. " B"
end

local function WB_FormatStats(r)
    local parts = {}
    local rating = tonumber(r.rating)
    if rating and rating >= 0 then
        parts[#parts + 1] = string.format("%d%% positive",
            math.floor(rating * 100 + 0.5))
    end
    if (tonumber(r.subscribers) or 0) > 0 then
        parts[#parts + 1] = WB_FormatCount(r.subscribers) .. " subscribers"
    end
    if (tonumber(r.fileSize) or 0) > 0 then
        parts[#parts + 1] = WB_FormatBytes(r.fileSize)
    end
    if (tonumber(r.timeUpdated) or 0) > 0 then
        parts[#parts + 1] = "updated " .. os.date("%Y-%m-%d",
            tonumber(r.timeUpdated))
    end
    return table.concat(parts, "  |  ")
end

local function drawResultRow(lb, y, item)
    local r = item.item or {}
    local title = WB_Truncate(r.title ~= "" and r.title or r.id, 44)
    lb:drawText(title, 8, y + 4, 1, 1, 1, 1, UIFont.Small)
    local sub = WB_FormatStats(r)
    if r.installed then
        sub = WB_Text.InstalledBadge .. (sub ~= "" and "  |  " .. sub or "")
    end
    lb:drawText(WB_Truncate(sub, 64), 8, y + 24, 0.65, 0.65, 0.65, 1,
        UIFont.Small)
    return y + 46
end

-- result sort orders; relevance is Steam's textsearch order (arrival order)
local WB_SEARCH_SORTS = {
    { text = WB_Text.SortRelevance,
      fn = function(a, b) return (a._order or 0) < (b._order or 0) end },
    { text = WB_Text.SortSubscribers,
      fn = function(a, b) return (tonumber(a.subscribers) or 0) > (tonumber(b.subscribers) or 0) end },
    { text = WB_Text.SortUpdated,
      fn = function(a, b) return (tonumber(a.timeUpdated) or 0) > (tonumber(b.timeUpdated) or 0) end },
    { text = WB_Text.SortRating,
      fn = function(a, b)
          local ra, rb = tonumber(a.rating) or -1, tonumber(b.rating) or -1
          if ra ~= rb then return ra > rb end
          return (tonumber(a.subscribers) or 0) > (tonumber(b.subscribers) or 0)
      end },
}

local WB_SEARCH_MAX_PAGES = 10

function WB_SearchDialog:buildControls()
    local pad = 12
    local w, h = self:getWidth(), self:getHeight()

    -- results list (left); the search row above lives inside this column
    -- so it can never underlap the details title on the right
    local listY = pad + 56
    local listW = math.floor((w - pad * 3) * 0.52)
    local listH = h - listY - pad - 34 -- footer row holds the sort button
    local searchBtnW = 110
    local entryW = listW - searchBtnW - 8

    -- search row (top-left, inside the results column)
    self.searchEntry = ISTextEntryBox:new("", pad, pad, entryW, 26)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self.searchEntry:setText(WB_Text.SearchHint)
    self.searchEntry.onCommandEntered = function() self:onSearchClicked() end
    self:addChild(self.searchEntry)

    self.searchBtn = ISButton:new(pad + entryW + 8, pad, searchBtnW, 28,
        WB_Text.Search, self, function() self:onSearchClicked() end)
    self.searchBtn:initialise()
    self.searchBtn:instantiate()
    self.searchBtn:setFont(UIFont.Small)
    self:addChild(self.searchBtn)

    self.statusLabel = ISLabel:new(pad, pad + 32, 20, "",
        0.75, 0.75, 0.75, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self.statusLabel:instantiate()
    self:addChild(self.statusLabel)

    self.resultList = ISScrollingListBox:new(pad, listY, listW, listH)
    self.resultList:initialise()
    self.resultList:instantiate()
    self.resultList.itemheight = 46
    self.resultList.doDrawItem = function(lb, y, item)
        return drawResultRow(lb, y, item)
    end
    self.resultList.onMouseDoubleClick = function()
        self:onInstallClicked()
    end
    self:addChild(self.resultList)

    self.sortBtn = ISButton:new(pad, h - pad - 28, 180, 28,
        "Sort: " .. WB_SEARCH_SORTS[1].text, self,
        function() self:onSortClicked() end)
    self.sortBtn:initialise()
    self.sortBtn:instantiate()
    self.sortBtn:setFont(UIFont.Small)
    self:addChild(self.sortBtn)

    -- details panel (right)
    local dx = pad * 2 + listW
    local dw = w - dx - pad
    local y = pad
    self.detailTitle = ISLabel:new(dx, y, 20, "", 1, 1, 1, 1,
        UIFont.Medium, true)
    self.detailTitle:initialise()
    self.detailTitle:instantiate()
    self:addChild(self.detailTitle)
    y = y + 28
    self.detailStats = ISLabel:new(dx, y, 20, "", 0.7, 0.7, 0.7, 1,
        UIFont.Small, true)
    self.detailStats:initialise()
    self.detailStats:instantiate()
    self:addChild(self.detailStats)
    y = y + 22
    self.detailTags = ISLabel:new(dx, y, 20, "", 0.6, 0.75, 1, 1,
        UIFont.Small, true)
    self.detailTags:initialise()
    self.detailTags:instantiate()
    self:addChild(self.detailTags)
    y = y + 24
    local btnH = 28
    local descH = h - y - pad - btnH - 8
    self.descBox = ISTextEntryBox:new("", dx, y, dw, descH)
    self.descBox:initialise()
    self.descBox:instantiate()
    self.descBox:setMultipleLine(true)
    if self.descBox.setEditable then self.descBox:setEditable(false) end
    self:addChild(self.descBox)

    self.installBtn = ISButton:new(dx, h - pad - btnH, 140, btnH,
        WB_Text.Install, self, function() self:onInstallClicked() end)
    self.installBtn:initialise()
    self.installBtn:instantiate()
    self.installBtn:setFont(UIFont.Small)
    self:addChild(self.installBtn)

    self.closeBtn = ISButton:new(w - pad - 100, h - pad - btnH, 100, btnH,
        WB_Text.Close, self, function() self:close() end)
    self.closeBtn:initialise()
    self.closeBtn:instantiate()
    self.closeBtn:setFont(UIFont.Small)
    self:addChild(self.closeBtn)

    self.results = {}     -- all hits, arrival (relevance) order
    self.displayed = {}   -- sorted copy currently shown in the list
    self.seenIds = {}
    self.nextOrder = 1
    self.sortIdx = 1
    self.page = 0
    self.query = nil
    self.searchActive = false
    self.searchGen = 0
    self.selectedResult = nil
    self.lastSelected = nil
end

function WB_SearchDialog:setStatus(text)
    if self.statusLabel and self.statusLabel.setName then
        self.statusLabel:setName(tostring(text or ""))
    end
end

function WB_SearchDialog:onSearchClicked()
    local q = self.searchEntry:getText() or ""
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" or q == WB_Text.SearchHint then
        self:setStatus(WB_Text.SearchEnterQuery)
        return
    end
    if type(wbSearchWorkshop) ~= "function" then
        self:setStatus(WB_Text.SearchFailed)
        return
    end
    -- new search: bump the generation so a previous chain's late
    -- callbacks cannot merge into these results
    self.searchGen = self.searchGen + 1
    self.query = q
    self.page = 0
    self.results = {}
    self.displayed = {}
    self.seenIds = {}
    self.nextOrder = 1
    self.searchActive = true
    self.resultList:clear()
    self.selectedResult = nil
    self.lastSelected = nil
    self:showDetails(nil)
    self:setStatus(WB_Text.Searching)
    print("[WorkshopBridge] workshop search for \"" .. q .. "\"")
    self:fetchNextPage()
end

-- Starts the job for the next browse page. Pages stream into the list as
-- they arrive instead of waiting for all pages up front.
function WB_SearchDialog:fetchNextPage()
    if not self.searchActive then return end
    self.page = self.page + 1
    if self.page > WB_SEARCH_MAX_PAGES then
        self:finishSearch()
        return
    end
    local ok, jobId = pcall(wbSearchWorkshop, self.query, self.page)
    if not ok or not jobId then
        self:finishSearch(WB_Text.SearchFailed)
        return
    end
    local dlg = self
    local gen = self.searchGen
    local page = self.page
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            if dlg.searchActive and dlg.searchGen == gen then
                dlg:setStatus(st and st.message or WB_Text.Searching)
            end
        end,
        onDone = function(st)
            if not dlg.searchActive or dlg.searchGen ~= gen then return end
            if not st or st.state == "failed" then
                if page == 1 then
                    dlg:finishSearch(WB_Text.SearchFailed .. ": "
                        .. WB_ShortError(st and st.error, 80))
                else
                    -- keep the partial results, note the hiccup
                    dlg:finishSearch(WB_Text.SearchPartial .. ": "
                        .. WB_ShortError(st and st.error, 80))
                end
                return
            end
            local added = dlg:mergeResults(st.results or {})
            if added == 0 then
                dlg:finishSearch() -- no new ids: past the last page
            else
                dlg:fetchNextPage()
            end
        end,
    })
end

-- Merges one page's hits into the results (arrival order, duplicates
-- dropped). Returns the number of new hits; re-renders when > 0.
function WB_SearchDialog:mergeResults(incoming)
    local added = 0
    for _, r in ipairs(incoming or {}) do
        local id = tostring(r.id or "")
        if id ~= "" and not self.seenIds[id] then
            self.seenIds[id] = true
            r._order = self.nextOrder
            self.nextOrder = self.nextOrder + 1
            self.results[#self.results + 1] = r
            added = added + 1
        end
    end
    if added > 0 then
        self:renderResults()
    end
    return added
end

-- Rebuilds the list from self.results using the current sort order,
-- preserving the selection by workshop id.
function WB_SearchDialog:renderResults()
    local selId = self.selectedResult and tostring(self.selectedResult.id) or nil
    local hadSelection = self.selectedResult ~= nil
    local sorted = {}
    for _, r in ipairs(self.results) do sorted[#sorted + 1] = r end
    table.sort(sorted, WB_SEARCH_SORTS[self.sortIdx].fn)
    self.displayed = sorted
    self.resultList:clear()
    for _, r in ipairs(sorted) do
        self.resultList:addItem(r.title ~= "" and r.title or r.id, r)
    end
    self.lastSelected = nil
    self.selectedResult = nil
    if #sorted > 0 then
        local idx = nil
        if selId then
            for i, r in ipairs(sorted) do
                if tostring(r.id) == selId then idx = i; break end
            end
        elseif not hadSelection then
            idx = 1 -- auto-select the first hit of a fresh search
        end
        if idx then
            self.resultList.selected = idx
            self.lastSelected = idx
            self:showDetails(sorted[idx])
        end
    end
end

function WB_SearchDialog:finishSearch(statusText)
    self.searchActive = false
    if statusText then
        self:setStatus(statusText)
    elseif #self.results == 0 then
        self:setStatus(WB_Text.NoResults)
    else
        self:setStatus("")
    end
end

function WB_SearchDialog:onSortClicked()
    self.sortIdx = self.sortIdx % #WB_SEARCH_SORTS + 1
    if self.sortBtn.setTitle then
        self.sortBtn:setTitle("Sort: " .. WB_SEARCH_SORTS[self.sortIdx].text)
    end
    self:renderResults()
end

function WB_SearchDialog:showDetails(r)
    self.selectedResult = r
    local title = r and (r.title ~= "" and r.title or r.id) or ""
    if self.detailTitle.setName then
        self.detailTitle:setName(WB_Truncate(title, 48))
    end
    if self.detailStats.setName then
        self.detailStats:setName(r and WB_FormatStats(r) or "")
    end
    local tags = ""
    if r and type(r.tags) == "table" and #r.tags > 0 then
        tags = table.concat(r.tags, ", ")
    end
    if self.detailTags.setName then
        self.detailTags:setName(WB_Truncate(tags, 64))
    end
    if self.descBox.setText then
        self.descBox:setText(r and r.description or "")
    end
end

function WB_SearchDialog:onInstallClicked()
    local r = self.selectedResult
    if not r or not r.id then return end
    if type(wbImportMods) ~= "function" then return end
    local ok, jobId = pcall(wbImportMods, tostring(r.id))
    if not ok or not jobId then
        self:setStatus(WB_Text.ImportFailed)
        return
    end
    print("[WorkshopBridge] installing from search: " .. tostring(r.id)
        .. " (job " .. tostring(jobId) .. ")")
    local dlg = self
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            dlg:setStatus(st and st.message or WB_Text.Importing)
        end,
        onDone = function(st)
            if not st or st.state == "failed" then
                dlg:setStatus(WB_Text.ImportFailed .. ": "
                    .. WB_ShortError(st and st.error, 64))
                return
            end
            dlg:setStatus(WB_Text.Imported)
            r.installed = true
            WB_RefreshModList(dlg.ms)
        end,
    })
end

function WB_SearchDialog:update()
    ISPanel.update(self)
    -- selection can change via mouse or keyboard; poll cheaply. Index into
    -- displayed (the sorted view), not results (arrival order).
    local sel = self.resultList and self.resultList.selected or nil
    if sel and sel ~= self.lastSelected and self.displayed then
        self.lastSelected = sel
        local r = self.displayed[sel]
        if r then self:showDetails(r) end
    end
end

function WB_SearchDialog:close()
    self.searchActive = false -- stop any in-flight page chain
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbSearchDialog == self then ms.wbSearchDialog = nil end
    end
end

-- Opens the search dialog, sized as fractions of the ModSelector screen
-- (not fixed pixels: this dialog is large enough to matter on small
-- resolutions). Reuses the open one instead of stacking duplicates.
function WB_ShowSearchDialog(ms)
    if not ms then return end
    if ms.wbSearchDialog then
        ms.wbSearchDialog:setVisible(true)
        return
    end
    local mw, mh = ms:getWidth(), ms:getHeight()
    local w = math.floor(math.min(math.max(mw * 0.8, 640), 1100))
    local h = math.floor(math.min(math.max(mh * 0.8, 480), 750))
    w = math.max(400, math.min(w, mw - 40))
    h = math.max(300, math.min(h, mh - 40))
    local dlg = WB_SearchDialog:new(
        math.max(0, mw / 2 - w / 2),
        math.max(0, mh / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg:initialise()
    dlg:instantiate() -- once; createChildren is the empty base version
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbSearchDialog = dlg
end
