-- WorkshopBridge dependency ("required items") check.
--
-- After a fresh install (download dialog, adopt), Java resolves the
-- workshop item's required items by scraping the public workshop page
-- (Steam's Web API has no dependency field). When any are not already
-- installed via WorkshopBridge, this shows a dialog offering to install
-- them all through the normal import job path.
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"

-- Starts a dependency check for a freshly installed workshop item.
-- Shows the install dialog only when uninstalled dependencies are found;
-- silent otherwise (a failed check degrades to "no prompt", never an error).
function WB_CheckDependencies(ms, workshopId)
    if not ms or not workshopId then return end
    if type(wbCheckDependencies) ~= "function" then return end
    local ok, jobId = pcall(wbCheckDependencies, workshopId)
    if not ok or not jobId then return end
    print("[WorkshopBridge] checking dependencies for " .. tostring(workshopId)
        .. " (job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            WB_ShowProgress(ms, WB_Text.CheckingDependencies)
        end,
        onDone = function(st)
            WB_HideProgress()
            if not st or st.state == "failed" then return end
            local missing = {}
            for _, d in ipairs(st.deps or {}) do
                if type(d) == "table" and d.id and not d.installed then
                    missing[#missing + 1] = d
                end
            end
            if #missing == 0 then return end
            print("[WorkshopBridge] " .. tostring(workshopId) .. " requires "
                .. tostring(#missing) .. " uninstalled item(s)")
            WB_ShowDependenciesDialog(ms, missing)
        end,
    })
end

WB_DependenciesDialog = ISPanel:derive("WB_DependenciesDialog")

-- NOTE: deliberately no initialise()/createChildren() overrides, same as
-- WB_DownloadDialog: controls are built once, by an explicit call after
-- instantiate().
function WB_DependenciesDialog:buildControls()
    local pad = 12
    local w = self:getWidth()
    local y = pad
    self.titleLabel = ISLabel:new(pad, y, 20, WB_Text.DependenciesTitle,
        1, 1, 1, 1, UIFont.Small, true)
    y = y + 24
    self.hintLabel = ISLabel:new(pad, y, 20, WB_Text.DependenciesHint,
        0.7, 0.7, 0.7, 1, UIFont.Small, true)
    y = y + 26
    local shown = math.min(#self.deps, 8)
    self.depLabels = {}
    for i = 1, shown do
        local d = self.deps[i]
        local text = "- " .. tostring((d.title ~= nil and d.title ~= "")
            and d.title or d.id)
        if d.title ~= nil and d.title ~= "" then
            text = text .. " (" .. tostring(d.id) .. ")"
        end
        local lbl = ISLabel:new(pad + 8, y, 20, text,
            1, 1, 1, 1, UIFont.Small, true)
        self.depLabels[#self.depLabels + 1] = lbl
        y = y + 20
    end
    if #self.deps > shown then
        local more = ISLabel:new(pad + 8, y, 20,
            string.format(WB_Text.DependenciesMore, #self.deps - shown),
            0.7, 0.7, 0.7, 1, UIFont.Small, true)
        self.depLabels[#self.depLabels + 1] = more
        y = y + 20
    end
    y = y + 10
    self.installBtn = ISButton:new(pad, y, 140, 28, WB_Text.InstallAll, self,
        function() self:onInstallClicked() end)
    self.skipBtn = ISButton:new(pad + 150, y, 140, 28, WB_Text.Skip, self,
        function() self:close() end)
    local controls = { self.titleLabel, self.hintLabel, self.installBtn,
        self.skipBtn }
    for _, l in ipairs(self.depLabels) do controls[#controls + 1] = l end
    for _, c in ipairs(controls) do
        c:initialise()
        self:addChild(c)
    end
    self.installBtn:setFont(UIFont.Small)
    self.skipBtn:setFont(UIFont.Small)
end

function WB_DependenciesDialog:onInstallClicked()
    local ms = self.ms
    local ids = {}
    for _, d in ipairs(self.deps) do ids[#ids + 1] = tostring(d.id) end
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
    print("[WorkshopBridge] installing " .. tostring(#ids)
        .. " dependencies (job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            WB_ShowProgress(ms, st.message or WB_Text.Importing)
        end,
        onDone = function(st)
            WB_HideProgress()
            if st and st.state == "failed" then
                print("[WorkshopBridge] dependency install failed: "
                    .. tostring(st.error or "?"))
                WB_ShowError(ms,
                    WB_Text.ImportFailed .. ": " .. WB_ShortError(st.error, 64))
            else
                print("[WorkshopBridge] dependency install complete")
                WB_FlashMessage(ms, (st and st.message) or WB_Text.Imported)
                WB_RefreshModList(ms)
            end
        end,
    })
end

function WB_DependenciesDialog:close()
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbDependenciesDialog == self then ms.wbDependenciesDialog = nil end
    end
end

-- Opens the dialog, centered on the ModSelector screen. Reuses the open
-- one instead of stacking duplicates.
function WB_ShowDependenciesDialog(ms, deps)
    if not ms or not deps or #deps == 0 then return end
    if ms.wbDependenciesDialog then
        ms.wbDependenciesDialog:setVisible(true)
        return
    end
    local shown = math.min(#deps, 8)
    local h = 12 + 24 + 26 + shown * 20
    if #deps > shown then h = h + 20 end
    h = h + 10 + 28 + 12
    local w = 420
    local dlg = WB_DependenciesDialog:new(
        math.max(0, ms:getWidth() / 2 - w / 2),
        math.max(0, ms:getHeight() / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg.deps = deps
    dlg:initialise()
    dlg:instantiate() -- once; createChildren is the empty base version
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbDependenciesDialog = dlg
end
