-- WorkshopBridge server-join mod download prompt.
--
-- In non-Steam mode the game skips its workshop states entirely when
-- joining a server: a missing mod fails the join with OnConnectFailed
-- carrying "... [ModID: x, WorkshopID: y]" and then disconnects. There is
-- no prompt and no resume; the flow is download, then rejoin manually.
--
-- This hooks OnConnectFailed, reads the server's FULL mod list (id,
-- workshop id, name per mod) from the failed join's connection details
-- via wbGetServerMods (one packet parse, no Steam traffic), and offers to
-- download every missing mod in a single import job. Deliberately no
-- workshop "required items" lookup here: the server already enumerates
-- what it needs, and scraping a page per server mod would hammer Steam on
-- big mod lists.
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"
require "WorkshopBridge/WB_Options"

-- Parses the game's CheckMods failure message:
--   "<translated text> [ModID: abc, WorkshopID: 123]"
-- Returns modId, workshopId-or-nil. A null/empty workshop id means the
-- missing mod is not a workshop item the server listed (e.g. a transitive
-- mod.info require=), so it can only be installed by hand.
local function parseModRequired(message)
    if type(message) ~= "string" then return nil end
    local modId, wsId = message:match("%[ModID: ([^,%]]+), WorkshopID: ([^%]]+)%]")
    if not modId then return nil end
    modId = modId:match("^%s*(.-)%s*$")
    if modId == "" then return nil end
    wsId = wsId and wsId:match("^%s*(.-)%s*$") or ""
    if wsId == "" or wsId == "null" or wsId == "nil" then wsId = nil end
    return modId, wsId
end

local function entryName(e)
    if e.name and e.name ~= "" then return e.name end
    return e.id
end

function WB_OnConnectFailed(message)
    -- checked at event time (not at hook registration): the option value
    -- is only meaningful once the options screen has loaded it
    if not WB_GetOfferServerModDownloads() then return end
    local modId, wsId = parseModRequired(message)
    if not modId then return end
    if type(wbGetServerMods) ~= "function" then return end
    local ok, json = pcall(wbGetServerMods)
    local data = (ok and json) and WB_JsonDecode(json) or nil
    if data and data.steamMode then return end -- vanilla workshop flow owns it
    local entries = (data and type(data.mods) == "table") and data.mods or {}
    if #entries == 0 and wsId then
        -- packet parse failed: fall back to the one mod in the message
        entries = { { id = modId, workshopId = wsId,
            name = modId, installed = false } }
    end
    local downloadable, manual, seen = {}, {}, {}
    for _, e in ipairs(entries) do
        if type(e) == "table" and e.id and not seen[e.id] then
            seen[e.id] = true
            if not e.installed then
                if e.workshopId and e.workshopId ~= "" then
                    downloadable[#downloadable + 1] = e
                else
                    manual[#manual + 1] = e
                end
            end
        end
    end
    -- the failure may name a transitive require= dep that is not in the
    -- server list at all; surface it as a manual install instead of going
    -- silent
    if #downloadable == 0 and #manual == 0 and not seen[modId] then
        manual[#manual + 1] = { id = modId, workshopId = nil,
            name = modId, installed = false }
    end
    if #downloadable == 0 and #manual == 0 then return end
    local screen = ConnectToServer and ConnectToServer.instance
    if not screen or not screen:getIsVisible() then return end
    print("[WorkshopBridge] server needs " .. tostring(#downloadable)
        .. " downloadable + " .. tostring(#manual) .. " manual mod(s)")
    WB_ShowServerModsDialog(screen, downloadable, manual)
end

function WB_HookServerJoin()
    if Events.OnConnectFailed then
        Events.OnConnectFailed.Add(WB_OnConnectFailed)
    end
end

WB_ServerModsDialog = ISPanel:derive("WB_ServerModsDialog")

-- NOTE: deliberately no initialise()/createChildren() overrides, same as
-- WB_DependenciesDialog: controls are built once, by an explicit call after
-- instantiate().
function WB_ServerModsDialog:buildControls()
    local pad = 12
    local y = pad
    self.titleLabel = ISLabel:new(pad, y, 20, WB_Text.ServerModsTitle,
        1, 1, 1, 1, UIFont.Small, true)
    y = y + 24
    self.hintLabel = ISLabel:new(pad, y, 20, WB_Text.ServerModsHint,
        0.7, 0.7, 0.7, 1, UIFont.Small, true)
    y = y + 26
    self.modLabels = {}
    local shown = math.min(#self.downloadable, 8)
    for i = 1, shown do
        local e = self.downloadable[i]
        local lbl = ISLabel:new(pad + 8, y, 20,
            "- " .. entryName(e) .. " (" .. tostring(e.workshopId) .. ")",
            1, 1, 1, 1, UIFont.Small, true)
        self.modLabels[#self.modLabels + 1] = lbl
        y = y + 20
    end
    if #self.downloadable > shown then
        local more = ISLabel:new(pad + 8, y, 20,
            string.format(WB_Text.ServerModsMore, #self.downloadable - shown),
            0.7, 0.7, 0.7, 1, UIFont.Small, true)
        self.modLabels[#self.modLabels + 1] = more
        y = y + 20
    end
    local mshown = math.min(#self.manual, 4)
    if mshown > 0 then
        local mtitle = ISLabel:new(pad, y + 6, 20, WB_Text.ServerModsManual,
            0.7, 0.7, 0.7, 1, UIFont.Small, true)
        self.modLabels[#self.modLabels + 1] = mtitle
        y = y + 28
        for i = 1, mshown do
            local e = self.manual[i]
            local lbl = ISLabel:new(pad + 8, y, 20,
                "- " .. entryName(e) .. " [" .. tostring(e.id) .. "]",
                0.7, 0.7, 0.7, 1, UIFont.Small, true)
            self.modLabels[#self.modLabels + 1] = lbl
            y = y + 20
        end
        if #self.manual > mshown then
            local more = ISLabel:new(pad + 8, y, 20,
                string.format(WB_Text.ServerModsMore, #self.manual - mshown),
                0.7, 0.7, 0.7, 1, UIFont.Small, true)
            self.modLabels[#self.modLabels + 1] = more
            y = y + 20
        end
    end
    y = y + 10
    self.statusLabel = ISLabel:new(pad, y, 20, "",
        0.7, 0.7, 0.7, 1, UIFont.Small, true)
    y = y + 26
    local bx = pad
    if #self.downloadable > 0 then
        self.downloadBtn = ISButton:new(bx, y, 140, 28,
            WB_Text.ServerModsDownloadAll, self,
            function() self:onDownloadClicked() end)
        self.downloadBtn:setFont(UIFont.Small)
        bx = bx + 150
    end
    self.closeBtn = ISButton:new(bx, y, 140, 28, WB_Text.Close, self,
        function() self:close() end)
    self.closeBtn:setFont(UIFont.Small)
    local controls = { self.titleLabel, self.hintLabel, self.statusLabel,
        self.closeBtn }
    if self.downloadBtn then controls[#controls + 1] = self.downloadBtn end
    for _, l in ipairs(self.modLabels) do controls[#controls + 1] = l end
    for _, c in ipairs(controls) do
        c:initialise()
        self:addChild(c)
    end
end

function WB_ServerModsDialog:onDownloadClicked()
    local ids = {}
    for _, e in ipairs(self.downloadable) do
        ids[#ids + 1] = tostring(e.workshopId)
    end
    if type(wbImportMods) ~= "function" then
        self.statusLabel.name = WB_Text.ImportFailed
        return
    end
    local ok, jobId = pcall(wbImportMods, table.concat(ids, ","))
    if not ok or not jobId then
        self.statusLabel.name = WB_Text.ImportFailed
        return
    end
    if self.downloadBtn then self.downloadBtn:setEnable(false) end
    print("[WorkshopBridge] downloading " .. tostring(#ids)
        .. " server mod(s) (job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            self.statusLabel.name = (st and st.message)
                or WB_Text.ServerModsDownloading
        end,
        onDone = function(st)
            if st and st.state == "failed" then
                print("[WorkshopBridge] server mod download failed: "
                    .. tostring(st.error or "?"))
                self.statusLabel.name = WB_Text.ServerModsDownloadFailed
                    .. ": " .. WB_ShortError(st.error, 64)
                if self.downloadBtn then self.downloadBtn:setEnable(true) end
            else
                -- the game's mod lookup cached at boot; without this the
                -- rejoin fails on the same missing mods
                pcall(wbInvalidateModCaches)
                print("[WorkshopBridge] server mods downloaded")
                self.statusLabel.name = WB_Text.ServerModsDownloaded
            end
        end,
    })
end

function WB_ServerModsDialog:close()
    local screen = self.screen
    self:setVisible(false)
    if screen then
        pcall(function() screen:removeChild(self) end)
        if screen.wbServerModsDialog == self then
            screen.wbServerModsDialog = nil
        end
    end
end

-- Opens the dialog centered on the ConnectToServer screen. Reuses the open
-- one instead of stacking duplicates.
function WB_ShowServerModsDialog(screen, downloadable, manual)
    if not screen then return end
    if screen.wbServerModsDialog then
        screen.wbServerModsDialog:setVisible(true)
        return
    end
    downloadable = downloadable or {}
    manual = manual or {}
    local shown = math.min(#downloadable, 8)
    local h = 12 + 24 + 26 + shown * 20
    if #downloadable > shown then h = h + 20 end
    local mshown = math.min(#manual, 4)
    if mshown > 0 then
        h = h + 28 + mshown * 20
        if #manual > mshown then h = h + 20 end
    end
    h = h + 10 + 26 + 28 + 12
    local w = 460
    local dlg = WB_ServerModsDialog:new(
        math.max(0, screen:getWidth() / 2 - w / 2),
        math.max(0, screen:getHeight() / 2 - h / 2), w, h)
    dlg.screen = screen
    dlg.downloadable = downloadable
    dlg.manual = manual
    dlg:initialise()
    dlg:instantiate() -- once; createChildren is the empty base version
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    screen:addChild(dlg)
    screen.wbServerModsDialog = dlg
end
