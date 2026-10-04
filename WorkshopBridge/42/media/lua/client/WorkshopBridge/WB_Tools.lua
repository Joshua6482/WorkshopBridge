-- WorkshopBridge "more tools": export the enabled mod list, import mods
-- from pasted text, import a Workshop collection.
--
-- Export writes a timestamped .txt of Workshop URLs to a fixed location
-- (<Zomboid>/workshopbridge-exports/) - deliberately no file picker; the
-- user is told exactly where it landed. Import takes an ID/URL per line
-- (paste box) or a collection ID/URL, and downloads everything through one
-- serialized import job.
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"
require "WorkshopBridge/WB_Download"

-- Workshop ids of enabled mods, deduped. A mod counts when its workshop id
-- is known: tracked by us, or Steam-managed (the game knows those).
function WB_CollectEnabledWorkshopIds(ms)
    local ids, seen = {}, {}
    local model = ms and ms.model
    local mods = model and model.mods
    if type(mods) ~= "table" then return ids end
    for modId, modData in pairs(mods) do
        if type(modData) == "table" and modData.isActive then
            local wsid = WB_WorkshopIdFor(modId)
            if not wsid and modData.modInfo then
                wsid = WB_GameWorkshopIdFor(modData.modInfo)
            end
            if wsid and not seen[wsid] then
                seen[wsid] = true
                table.insert(ids, wsid)
            end
        end
    end
    return ids
end

-- Pull workshop ids out of pasted text: one ID or URL per line, order kept,
-- duplicates and junk lines dropped.
function WB_ParseImportText(text)
    local ids, seen = {}, {}
    if type(text) ~= "string" then return ids end
    for line in text:gmatch("[^\r\n]+") do
        local wsid = WB_ParseWorkshopId(line)
        if wsid and not seen[wsid] then
            seen[wsid] = true
            table.insert(ids, wsid)
        end
    end
    return ids
end

-- Shared completion handling for import jobs: progress while running, then
-- hide + flash the summary (or a stuck error) and rescan the mod list so
-- newly installed mods show up.
local function WB_TrackImportJob(ms, jobId, what)
    print("[WorkshopBridge] import started (" .. tostring(what)
        .. ", job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            WB_ShowProgress(ms, st.message or WB_Text.Importing)
        end,
        onDone = function(st)
            WB_HideProgress()
            if st and st.state == "failed" then
                print("[WorkshopBridge] import (" .. tostring(what) .. ") failed: "
                    .. tostring(st.error or "?"))
                WB_ShowError(ms,
                    WB_Text.ImportFailed .. ": " .. WB_ShortError(st.error, 64))
            else
                print("[WorkshopBridge] import (" .. tostring(what) .. ") complete")
                WB_FlashMessage(ms, (st and st.message) or WB_Text.Imported)
                WB_RefreshModList(ms)
            end
        end,
    })
end

local function WB_OnExport(ms)
    if type(wbExportModList) ~= "function" then
        WB_FlashMessage(ms, WB_Text.ExportFailed)
        return
    end
    local ids = WB_CollectEnabledWorkshopIds(ms)
    if #ids == 0 then
        WB_FlashMessage(ms, WB_Text.NothingToExport)
        return
    end
    local ok, path = pcall(wbExportModList, table.concat(ids, ","))
    if not ok or not path or path == "" then
        print("[WorkshopBridge] export failed")
        WB_FlashMessage(ms, WB_Text.ExportFailed)
        return
    end
    print("[WorkshopBridge] exported " .. #ids .. " mod(s) to " .. tostring(path))
    WB_FlashMessage(ms, string.format(WB_Text.ExportedN, #ids))
end

-- ---------- import-from-text dialog ----------

WB_ImportTextDialog = ISPanel:derive("WB_ImportTextDialog")

-- Same one-explicit-build pattern as WB_DownloadDialog: no
-- initialise()/createChildren() overrides, controls built once after
-- instantiate().
function WB_ImportTextDialog:buildControls()
    local pad = 12
    local w = self:getWidth()
    self.titleLabel = ISLabel:new(pad, pad, 20, WB_Text.ImportTextTitle,
        1, 1, 1, 1, UIFont.Small, true)
    self.hintLabel = ISLabel:new(pad, 34, 20, WB_Text.ImportTextHint,
        0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.entry = ISTextEntryBox:new("", pad, 56, w - pad * 2, 150)
    self.errorLabel = ISLabel:new(pad, 212, 20, "",
        1, 0.35, 0.35, 1, UIFont.Small, true)
    self.importBtn = ISButton:new(pad, 238, 140, 28, WB_Text.Import, self,
        function() self:onImportClicked() end)
    self.cancelBtn = ISButton:new(pad + 150, 238, 140, 28, WB_Text.Cancel, self,
        function() self:close() end)
    for _, c in ipairs({ self.titleLabel, self.hintLabel, self.entry,
                         self.errorLabel, self.importBtn, self.cancelBtn }) do
        c:initialise()
        self:addChild(c)
    end
    -- after addChild: that is what creates the entry's Java peer, and
    -- setMultipleLine indexes into it (calling it on the fresh object
    -- throws "attempted index: setMultipleLine of non-table: null")
    if self.entry.setMultipleLine then self.entry:setMultipleLine(true) end
    self.importBtn:setFont(UIFont.Small)
    self.cancelBtn:setFont(UIFont.Small)
end

function WB_ImportTextDialog:onImportClicked()
    local ms = self.ms
    local ids = WB_ParseImportText(self.entry:getText())
    if #ids == 0 then
        WB_SetLabel(self.errorLabel, WB_Text.NothingToImport)
        return
    end
    self:close()
    if type(wbImportMods) ~= "function" then
        WB_FlashMessage(ms, WB_Text.ImportFailed)
        return
    end
    local ok, jobId = pcall(wbImportMods, table.concat(ids, ","))
    if not ok or not jobId then
        WB_FlashMessage(ms, WB_Text.ImportFailed)
        return
    end
    WB_TrackImportJob(ms, jobId, #ids .. " id(s) from text")
end

function WB_ImportTextDialog:close()
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbImportTextDialog == self then ms.wbImportTextDialog = nil end
    end
end

function WB_ShowImportTextDialog(ms)
    if not ms then return end
    if ms.wbImportTextDialog then
        ms.wbImportTextDialog:setVisible(true)
        return
    end
    local w, h = 420, 290
    local dlg = WB_ImportTextDialog:new(
        math.max(0, ms:getWidth() / 2 - w / 2),
        math.max(0, ms:getHeight() / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg:initialise()
    dlg:instantiate()
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbImportTextDialog = dlg
end

-- ---------- import-from-collection dialog ----------

WB_ImportCollectionDialog = ISPanel:derive("WB_ImportCollectionDialog")

function WB_ImportCollectionDialog:buildControls()
    local pad = 12
    local w = self:getWidth()
    self.titleLabel = ISLabel:new(pad, pad, 20, WB_Text.ImportCollectionTitle,
        1, 1, 1, 1, UIFont.Small, true)
    self.hintLabel = ISLabel:new(pad, 34, 20, WB_Text.ImportCollectionHint,
        0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.entry = ISTextEntryBox:new("", pad, 56, w - pad * 2, 26)
    self.errorLabel = ISLabel:new(pad, 88, 20, "",
        1, 0.35, 0.35, 1, UIFont.Small, true)
    self.importBtn = ISButton:new(pad, 116, 140, 28, WB_Text.Import, self,
        function() self:onImportClicked() end)
    self.cancelBtn = ISButton:new(pad + 150, 116, 140, 28, WB_Text.Cancel, self,
        function() self:close() end)
    for _, c in ipairs({ self.titleLabel, self.hintLabel, self.entry,
                         self.errorLabel, self.importBtn, self.cancelBtn }) do
        c:initialise()
        self:addChild(c)
    end
    self.importBtn:setFont(UIFont.Small)
    self.cancelBtn:setFont(UIFont.Small)
end

function WB_ImportCollectionDialog:onImportClicked()
    local ms = self.ms
    local wsid = WB_ParseWorkshopId(self.entry:getText())
    if not wsid then
        WB_SetLabel(self.errorLabel, WB_Text.InvalidWorkshopId)
        return
    end
    self:close()
    if type(wbImportCollection) ~= "function" then
        WB_FlashMessage(ms, WB_Text.ImportFailed)
        return
    end
    local ok, jobId = pcall(wbImportCollection, wsid)
    if not ok or not jobId then
        WB_FlashMessage(ms, WB_Text.ImportFailed)
        return
    end
    WB_TrackImportJob(ms, jobId, "collection " .. wsid)
end

function WB_ImportCollectionDialog:close()
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbImportCollectionDialog == self then ms.wbImportCollectionDialog = nil end
    end
end

function WB_ShowImportCollectionDialog(ms)
    if not ms then return end
    if ms.wbImportCollectionDialog then
        ms.wbImportCollectionDialog:setVisible(true)
        return
    end
    local w, h = 420, 170
    local dlg = WB_ImportCollectionDialog:new(
        math.max(0, ms:getWidth() / 2 - w / 2),
        math.max(0, ms:getHeight() / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg:initialise()
    dlg:instantiate()
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbImportCollectionDialog = dlg
end

-- ---------- tools menu dialog ----------

WB_ToolsDialog = ISPanel:derive("WB_ToolsDialog")

function WB_ToolsDialog:buildControls()
    local pad = 12
    local w = self:getWidth()
    local bw, bh = w - pad * 2, 30
    local y = 40
    self.titleLabel = ISLabel:new(pad, pad, 20, WB_Text.ToolsTitle,
        1, 1, 1, 1, UIFont.Small, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    self.exportBtn = ISButton:new(pad, y, bw, bh, WB_Text.ExportMods, self,
        function() local ms = self.ms; self:close(); WB_OnExport(ms) end)
    y = y + bh + 8
    self.importTextBtn = ISButton:new(pad, y, bw, bh, WB_Text.ImportFromText, self,
        function() self:close(); WB_ShowImportTextDialog(self.ms) end)
    y = y + bh + 8
    self.importCollectionBtn = ISButton:new(pad, y, bw, bh, WB_Text.ImportFromCollection, self,
        function() self:close(); WB_ShowImportCollectionDialog(self.ms) end)
    y = y + bh + 8
    self.cancelBtn = ISButton:new(pad, y, 140, 28, WB_Text.Cancel, self,
        function() self:close() end)
    for _, c in ipairs({ self.exportBtn, self.importTextBtn,
                         self.importCollectionBtn, self.cancelBtn }) do
        c:initialise()
        c:setFont(UIFont.Small)
        self:addChild(c)
    end
    -- collection import is untested in-game (no small test collection found
    -- yet); disabled until it can be exercised for real. Re-enable by
    -- deleting this block.
    if self.importCollectionBtn.setEnable then
        self.importCollectionBtn:setEnable(false)
    end
end

function WB_ToolsDialog:close()
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbToolsDialog == self then ms.wbToolsDialog = nil end
    end
end

function WB_ShowToolsDialog(ms)
    if not ms then return end
    if ms.wbToolsDialog then
        ms.wbToolsDialog:setVisible(true)
        return
    end
    local w, h = 360, 250
    local dlg = WB_ToolsDialog:new(
        math.max(0, ms:getWidth() / 2 - w / 2),
        math.max(0, ms:getHeight() / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg:initialise()
    dlg:instantiate()
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbToolsDialog = dlg
end
