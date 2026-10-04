-- WorkshopBridge mod deletion.
--
-- Delete button (under Open in Workshop) on the per-mod info panel, for
-- WB-tracked mods and manually-installed ones alike - never Steam-managed,
-- Steam owns those files. A confirmation dialog names the mod and, when
-- the workshop item holds more than the selected one, lists the sub-mods
-- that go with it. The Java side (ModDeleter) deletes the folders under
-- strict guards - game-resolved path, inside the mods dir, matching
-- mod.info id, not claimed by another map entry - and drops the map entry
-- so a later "update all" cannot resurrect the mod.
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"
require "WorkshopBridge/WB_Json"

-- Entry point from the Delete button on the mod info panel.
function WB_OnDelete(panel)
    if not panel then return end
    local ms = wbScreen
    if not ms then return end
    local modId = panel.wbModId
    if not modId then return end
    -- tracked workshop id only; nil for manually-installed mods (those get
    -- a single-folder delete with no sub-mod list)
    local wsid = WB_WorkshopIdFor(modId)
    local others = {}
    if wsid and type(wbGetModIds) == "function" then
        local ok, raw = pcall(wbGetModIds, wsid)
        if ok and raw then
            local dok, dec = pcall(WB_JsonDecode, raw)
            if dok and type(dec) == "table" then
                for _, id in ipairs(dec) do
                    id = tostring(id)
                    if id ~= modId then others[#others + 1] = id end
                end
            end
        end
    end
    print("[WorkshopBridge] delete requested for " .. tostring(modId)
        .. (wsid and (" (workshop " .. tostring(wsid) .. ")") or " (manual)"))
    WB_ShowDeleteDialog(ms, modId, wsid, others)
end

WB_DeleteDialog = ISPanel:derive("WB_DeleteDialog")

-- NOTE: deliberately no initialise()/createChildren() overrides, same as
-- the other WB dialogs: controls are built once, by an explicit call after
-- instantiate().
function WB_DeleteDialog:buildControls()
    local pad = 12
    local w = self:getWidth()
    local y = pad
    self.titleLabel = ISLabel:new(pad, y, 20, WB_Text.DeleteModTitle,
        1, 1, 1, 1, UIFont.Small, true)
    y = y + 24
    self.confirmLabel = ISLabel:new(pad, y, 20, WB_Text.DeleteConfirm,
        0.9, 0.9, 0.9, 1, UIFont.Small, true)
    y = y + 22
    self.modLabel = ISLabel:new(pad + 8, y, 20, "- " .. tostring(self.modId),
        1, 1, 1, 1, UIFont.Small, true)
    y = y + 24
    self.subLabels = {}
    if #self.otherIds > 0 then
        local also = ISLabel:new(pad, y, 20, WB_Text.DeleteAlsoDeletes,
            0.7, 0.7, 0.7, 1, UIFont.Small, true)
        self.subLabels[#self.subLabels + 1] = also
        y = y + 20
        local shown = math.min(#self.otherIds, 8)
        for i = 1, shown do
            local lbl = ISLabel:new(pad + 8, y, 20,
                "- " .. tostring(self.otherIds[i]),
                1, 1, 1, 1, UIFont.Small, true)
            self.subLabels[#self.subLabels + 1] = lbl
            y = y + 20
        end
        if #self.otherIds > shown then
            local more = ISLabel:new(pad + 8, y, 20,
                string.format(WB_Text.DependenciesMore,
                    #self.otherIds - shown),
                0.7, 0.7, 0.7, 1, UIFont.Small, true)
            self.subLabels[#self.subLabels + 1] = more
            y = y + 20
        end
        y = y + 4
    end
    self.deleteBtn = ISButton:new(pad, y, 140, 28, WB_Text.Delete, self,
        function() self:onDeleteClicked() end)
    self.cancelBtn = ISButton:new(pad + 150, y, 140, 28, WB_Text.Cancel, self,
        function() self:close() end)
    local controls = { self.titleLabel, self.confirmLabel, self.modLabel,
        self.deleteBtn, self.cancelBtn }
    for _, l in ipairs(self.subLabels) do controls[#controls + 1] = l end
    for _, c in ipairs(controls) do
        c:initialise()
        self:addChild(c)
    end
    self.deleteBtn:setFont(UIFont.Small)
    self.cancelBtn:setFont(UIFont.Small)
end

function WB_DeleteDialog:onDeleteClicked()
    local ms, modId, wsid = self.ms, self.modId, self.wsid
    self:close()
    if type(wbDeleteMod) ~= "function" then
        WB_FlashMessage(ms, WB_Text.DeleteFailed)
        return
    end
    local ok, raw = pcall(wbDeleteMod, wsid, modId)
    if not ok or not raw then
        print("[WorkshopBridge] delete failed for " .. tostring(modId))
        WB_FlashMessage(ms, WB_Text.DeleteFailed)
        return
    end
    local dok, dec = pcall(WB_JsonDecode, raw)
    if not dok or type(dec) ~= "table" then
        WB_FlashMessage(ms, WB_Text.DeleteFailed)
        return
    end
    local failed = dec.failed or {}
    local skipped = dec.skipped or {}
    if #failed > 0 then
        print("[WorkshopBridge] delete failed for " .. tostring(modId)
            .. ": " .. table.concat(failed, ", "))
        WB_FlashMessage(ms, WB_Text.DeleteFailed)
        return
    end
    local deleted = dec.deleted or {}
    print("[WorkshopBridge] deleted " .. tostring(#deleted)
        .. " folder(s) for " .. tostring(modId))
    if next(skipped) ~= nil then
        local kept = {}
        for id, reason in pairs(skipped) do
            kept[#kept + 1] = tostring(id) .. " (" .. tostring(reason) .. ")"
            print("[WorkshopBridge] kept " .. tostring(id) .. ": "
                .. tostring(reason))
        end
        WB_FlashMessage(ms, WB_Text.DeletePartial .. ": "
            .. table.concat(kept, ", "))
    else
        WB_FlashMessage(ms, WB_Text.Deleted)
    end
    WB_RefreshModList(ms)
end

function WB_DeleteDialog:close()
    local ms = self.ms
    self:setVisible(false)
    if ms then
        pcall(function() ms:removeChild(self) end)
        if ms.wbDeleteDialog == self then ms.wbDeleteDialog = nil end
    end
end

-- Opens the dialog, centered on the ModSelector screen. Reuses the open
-- one instead of stacking duplicates.
function WB_ShowDeleteDialog(ms, modId, wsid, otherIds)
    if not ms or not modId then return end
    if ms.wbDeleteDialog then
        ms.wbDeleteDialog:setVisible(true)
        return
    end
    otherIds = otherIds or {}
    local shown = math.min(#otherIds, 8)
    local h = 12 + 24 + 22 + 24 + 4
    if #otherIds > 0 then
        h = h + 20 + shown * 20
        if #otherIds > shown then h = h + 20 end
        h = h + 4
    end
    h = h + 28 + 12
    local w = 420
    local dlg = WB_DeleteDialog:new(
        math.max(0, ms:getWidth() / 2 - w / 2),
        math.max(0, ms:getHeight() / 2 - h / 2), w, h)
    dlg.ms = ms
    dlg.modId = modId
    dlg.wsid = wsid
    dlg.otherIds = otherIds
    dlg:initialise()
    dlg:instantiate() -- once; createChildren is the empty base version
    dlg:buildControls()
    dlg.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.97 }
    dlg.borderColor = { r = 0.45, g = 0.45, b = 0.45, a = 1.0 }
    ms:addChild(dlg)
    ms.wbDeleteDialog = dlg
end
