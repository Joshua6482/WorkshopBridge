-- WorkshopBridge "adopt a manually installed mod" UI.
--
-- The Java side does the heavy lifting (wbAdoptMod): it force-downloads the
-- workshop item, verifies the download actually contains this mod BEFORE
-- overwriting anything, then installs and records it like a normal update.
-- This file is just the Lua half: an Adopt button on the mod panel (shown
-- only when the workshop id is unknown) and a small dialog taking a
-- workshop ID or URL, with the usual job tracking via WB_Jobs.
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"
require "WorkshopBridge/WB_Options"
require "WorkshopBridge/WB_Download" -- WB_ParseWorkshopId

WB_AdoptDialog = ISPanel:derive("WB_AdoptDialog")

-- NOTE: deliberately no initialise()/createChildren() overrides, same as
-- WB_DownloadDialog: controls are built once, by an explicit call after
-- instantiate().
function WB_AdoptDialog:buildControls()
    local pad = 12
    local w = self:getWidth()
    self.titleLabel = ISLabel:new(pad, pad, 20,
        WB_Text.AdoptModTitle .. " - " .. tostring(self.modId),
        1, 1, 1, 1, UIFont.Small, true)
    self.hintLabel = ISLabel:new(pad, 34, 20, WB_Text.AdoptHint,
        0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.entry = ISTextEntryBox:new("", pad, 56, w - pad * 2, 26)
    self.errorLabel = ISLabel:new(pad, 88, 20, "",
        1, 0.35, 0.35, 1, UIFont.Small, true)
    self.adoptBtn = ISButton:new(pad, 116, 140, 28, WB_Text.Adopt, self,
        function() self:onAdoptClicked() end)
    self.cancelBtn = ISButton:new(pad + 150, 116, 140, 28, WB_Text.Cancel, self,
        function() self:close() end)
    for _, c in ipairs({ self.titleLabel, self.hintLabel, self.entry,
                         self.errorLabel, self.adoptBtn, self.cancelBtn }) do
        c:initialise()
        self:addChild(c)
    end
    self.adoptBtn:setFont(UIFont.Small)
    self.cancelBtn:setFont(UIFont.Small)
end

function WB_AdoptDialog:onAdoptClicked()
    local ms = self.ms
    local modId = self.modId
    local wsid = WB_ParseWorkshopId(self.entry:getText())
    if not wsid then
        WB_SetLabel(self.errorLabel, WB_Text.InvalidWorkshopId)
        return
    end
    self:close()
    if type(wbAdoptMod) ~= "function" then
        WB_FlashMessage(ms, WB_Text.AdoptFailed)
        return
    end
    local ok, jobId = pcall(wbAdoptMod, wsid, modId)
    if not ok or not jobId then
        WB_FlashMessage(ms, WB_Text.AdoptFailed)
        return
    end
    print("[WorkshopBridge] adopting " .. tostring(modId)
        .. " as workshop item " .. tostring(wsid)
        .. " (job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            WB_ShowProgress(ms, st.message or WB_Text.Adopting)
        end,
        onDone = function(st)
            WB_HideProgress()
            if st and st.state == "failed" then
                print("[WorkshopBridge] adopt of " .. tostring(modId)
                    .. " failed: " .. tostring(st.error or "?"))
                WB_ShowError(ms,
                    WB_Text.AdoptFailed .. ": " .. WB_ShortError(st.error, 64))
            else
                print("[WorkshopBridge] adopt of " .. tostring(modId) .. " complete")
                WB_FlashMessage(ms, (st and st.message) or WB_Text.Adopted)
                -- rescan: the mod is now tracked, so badges/buttons update
                WB_RefreshModList(ms)
                -- then offer its Workshop dependencies, if any
                if WB_GetCheckDependenciesAfterDownload() then
                    WB_CheckDependencies(ms, wsid)
                end
            end
        end,
    })
end

function WB_AdoptDialog:close()
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbAdoptDialog == self then ms.wbAdoptDialog = nil end
    end
end

-- Opens the dialog, centered on the ModSelector screen. Reuses the open
-- one instead of stacking duplicates.
function WB_ShowAdoptDialog(ms, modId)
    if not ms or not modId then return end
    if ms.wbAdoptDialog then
        ms.wbAdoptDialog:setVisible(true)
        return
    end
    local w, h = 420, 170
    local dlg = WB_AdoptDialog:new(
        math.max(0, ms:getWidth() / 2 - w / 2),
        math.max(0, ms:getHeight() / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg.modId = modId
    dlg:initialise()
    dlg:instantiate() -- once; createChildren is the empty base version
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbAdoptDialog = dlg
end
