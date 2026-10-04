-- WorkshopBridge Mods-menu UI.
--
-- B42 hook points (verified against PZ-Umbrella type stubs + Javadocs):
--   * Screen: ModSelector (ISPanelJoypad), singleton ModSelector.instance,
--     opened from the main menu via MainScreen:onClickModList().
--   * "Check for updates" + "Update all": wrapped ModSelector:create, buttons
--     anchored to self.backButton (provisional placement - verify in-game).
--   * Row status text: rows are drawn (not widget-composed) by
--     ModListBox:doDrawItem(y, item, alt); item.modId is the mod.info id=.
--     Wrapped per-instance inside create().
--   * Per-mod Update button / status label: ModInfoPanel (createChildren once,
--     updateView(modInfo) per selection). Provisional placement - verify in-game.
-- There is no dedicated event for the Mods screen; method-wrapping is the
-- standard approach. All hooks are idempotent (wb*Added flags).
require "WorkshopBridge/WB_Config"
require "WorkshopBridge/WB_Jobs"
require "WorkshopBridge/WB_Download"

-- ---------- helpers ----------

-- mod id from whatever the row / updateView hands us (Lua table or Java object)
local function WB_GetModId(info)
    if type(info) == "table" and info.modId and info.modId ~= "" then
        return info.modId
    end
    if info and type(info.getId) == "function" then
        local ok, id = pcall(function() return info:getId() end)
        if ok and id and id ~= "" then return id end
    end
    return nil
end

-- the game's own workshop id signal (non-empty only for Steam-managed mods)
local function WB_GameWorkshopId(modInfo)
    if modInfo and type(modInfo.getWorkshopID) == "function" then
        local ok, id = pcall(function() return modInfo:getWorkshopID() end)
        if ok and id and id ~= "" then return id end
    end
    return nil
end

-- (WB_WorkshopIdFor lives in WB_Jobs.lua now: the update-available state
-- there resolves mod ids through it too.)

-- ---------- per-mod panel state ----------
-- (declared up here: the button handlers below close over these)

local wbLastModPanel = nil -- { panel=..., modInfo=... } currently displayed
local wbScreen = nil -- the hooked ModSelector, for button-count refreshes
-- wsid -> { message=..., failed=bool }: per-mod update jobs in flight (or
-- failed and not yet retried). The ModInfoPanel is a single shared instance,
-- so without this a job's poll callbacks would scribble its status over
-- whichever mod is currently selected, and two queued jobs would fight over
-- the one label ("Downloading..." vs "Queued...").
local wbModJobs = {}

-- Button title reflects what we know: "Update" when a check found something
-- new, "Force update" otherwise (clicking always re-downloads regardless).
local function WB_RefreshModButtonTitle(panel, modId)
    if not panel.wbUpdateBtn then return end
    WB_SetButtonTitle(panel.wbUpdateBtn,
        WB_IsUpdateAvailable(modId) and WB_Text.Update or WB_Text.ForceUpdate)
end

local function WB_RefreshModPanel(panel, modInfo)
    local modId = WB_GetModId(modInfo)
    panel.wbModId = modId
    if not panel.wbUpdateBtn then return end
    local wsid = WB_WorkshopIdFor(modId)
    local gameWsid = WB_GameWorkshopId(modInfo)
    -- the workshop page button shows whenever an id is known: tracked by
    -- us or Steam-managed alike
    panel.wbWorkshopId = wsid or gameWsid
    if panel.wbWorkshopBtn then
        panel.wbWorkshopBtn:setVisible(panel.wbWorkshopId ~= nil)
    end
    if wsid then
        panel.wbUpdateBtn:setVisible(true)
        WB_SetLabel(panel.wbStatusLabel,
            WB_IsUpdateAvailable(modId) and WB_Text.UpdateAvailableBadge or "")
        WB_RefreshModButtonTitle(panel, modId)
    elseif gameWsid then
        panel.wbUpdateBtn:setVisible(false)
        WB_SetLabel(panel.wbStatusLabel, WB_Text.ManagedBySteam)
    else
        panel.wbUpdateBtn:setVisible(false)
        WB_SetLabel(panel.wbStatusLabel, WB_Text.UnknownWorkshopId)
    end
    -- an in-flight update (or an unretried failure) for this workshop item
    -- overrides the label, so selecting a mod mid-download shows its live
    -- status instead of a stale badge or a blank
    local mj = wsid and wbModJobs[wsid]
    if mj then
        WB_SetLabel(panel.wbStatusLabel, mj.message)
    end
end

-- ---------- button handlers ----------

-- Invalidate the game's cached mod folder scan and mod-info cache, then
-- rebuild the visible mod list. reloadMods() alone is not enough: the game
-- caches the mod directory scan after the first call and keeps parsed
-- mod.infos by mod id, so newly downloaded folders (and changed mod.infos)
-- would not show up. Must run on the game thread; job onDone handlers
-- qualify (they run from the tick pump).
function WB_RefreshModList(ms)
    if type(wbInvalidateModCaches) == "function" then
        pcall(wbInvalidateModCaches)
    end
    if ms and ms.reloadMods then pcall(function() ms:reloadMods() end) end
    -- re-hook the instance (menu buttons, update pump); the row wrap lives
    -- on the ModListBox class so it survives list reloads on its own
    WB_HookInstance(ms)
end

local function WB_OnCheckAll(ms)
    if type(wbCheckForUpdates) ~= "function" then return end
    local ok, jobId = pcall(wbCheckForUpdates)
    if not ok or not jobId then
        WB_FlashMessage(ms, WB_Text.CheckFailed)
        return
    end
    print("[WorkshopBridge] check for updates started (job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            WB_ShowProgress(ms, st.message or WB_Text.Checking)
        end,
        onDone = function(st)
            WB_HideProgress()
            WB_ClearUpdateAvailable()
            local n = 0
            if st and st.state ~= "failed" and st.updates then
                -- st.updates lists workshop ids (one entry per outdated
                -- item, however many mods the item holds)
                for _, wsid in ipairs(st.updates) do
                    WB_MarkUpdateAvailable(wsid)
                    n = n + 1
                end
            end
            WB_RefreshUpdateAllButton(ms, n)
            -- refresh the currently displayed mod panel so badges/titles
            -- update without reselecting
            if wbLastModPanel then
                WB_RefreshModPanel(wbLastModPanel.panel, wbLastModPanel.modInfo)
            end
            if st and st.state == "failed" then
                print("[WorkshopBridge] check for updates failed: "
                    .. tostring(st.error or "?"))
                WB_ShowError(ms, WB_Text.CheckFailed .. ": " .. WB_ShortError(st.error, 64))
            else
                print("[WorkshopBridge] check for updates complete: "
                    .. n .. " update(s) available")
                -- the job's final message is the summary ("Everything is up
                -- to date" / "N mod(s) have updates"); flash it briefly so
                -- a clean check isn't just silence
                WB_FlashMessage(ms, (st and st.message) or WB_Text.Checking)
            end
        end,
    })
end

local function WB_OnUpdateAll(ms)
    if type(wbUpdateAll) ~= "function" then return end
    local ok, jobId = pcall(wbUpdateAll)
    if not ok or not jobId then
        WB_FlashMessage(ms, WB_Text.UpdateFailed)
        return
    end
    print("[WorkshopBridge] update-all started (job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            WB_ShowProgress(ms, st.message or WB_Text.Updating)
        end,
        onDone = function(st)
            WB_HideProgress()
            WB_ClearUpdateAvailable()
            WB_RefreshUpdateAllButton(ms, 0)
            if st and st.state == "failed" then
                print("[WorkshopBridge] update-all failed: " .. tostring(st.error or "?"))
                WB_ShowError(ms, WB_Text.UpdateFailed .. ": " .. WB_ShortError(st.error, 64))
            else
                print("[WorkshopBridge] update-all complete")
                -- update-all handled everything: persisted per-mod failure
                -- notes are stale now (in-flight entries, if any, are left
                -- alone - their own onDone will settle them)
                for k, j in pairs(wbModJobs) do
                    if j.failed then wbModJobs[k] = nil end
                end
                WB_FlashMessage(ms, (st and st.message) or WB_Text.Updating)
                -- rescan so newly downloaded/changed mods appear in the list
                WB_RefreshModList(ms)
            end
        end,
    })
end

local function WB_OnOpenWorkshop(panel)
    local wsid = panel.wbWorkshopId
    if not wsid or type(wbOpenWorkshopPage) ~= "function" then return end
    local ok = wbOpenWorkshopPage(wsid)
    if not ok then
        print("[WorkshopBridge] couldn't open the workshop page for " .. tostring(wsid))
    end
end

local function WB_OnModUpdate(panel)
    local modId = panel.wbModId
    local wsid = WB_WorkshopIdFor(modId)
    if not wsid or type(wbUpdateMod) ~= "function" then return end
    -- coalesce: an update for this workshop item is already in flight, so
    -- just (re)show its status instead of queueing a duplicate download.
    -- A previous failure does not coalesce: the user is retrying.
    local inflight = wbModJobs[wsid]
    if inflight and not inflight.failed then
        WB_SetLabel(panel.wbStatusLabel, inflight.message)
        return
    end
    local ok, jobId = pcall(wbUpdateMod, wsid)
    if not ok or not jobId then
        WB_SetLabel(panel.wbStatusLabel, WB_Text.UpdateFailed)
        return
    end
    wbModJobs[wsid] = { message = WB_Text.Updating }
    WB_SetLabel(panel.wbStatusLabel, WB_Text.Updating)
    print("[WorkshopBridge] updating " .. tostring(modId)
        .. " (workshop " .. tostring(wsid) .. ", job " .. tostring(jobId) .. ")")
    WB_TrackJob(jobId, {
        onUpdate = function(st)
            local msg = (st and st.message) or WB_Text.Updating
            local j = wbModJobs[wsid]
            if j then j.message = msg end
            -- only paint while the panel is still showing this workshop
            -- item (a sibling mod counts: same download, same result).
            -- Otherwise this job would scribble over the selected mod's
            -- own status, or fight a queued job over the one label.
            if WB_WorkshopIdFor(panel.wbModId) == wsid then
                WB_SetLabel(panel.wbStatusLabel, msg)
            end
        end,
        onDone = function(st)
            local failed = st and st.state == "failed"
            if failed then
                print("[WorkshopBridge] update of " .. tostring(modId)
                    .. " failed: " .. tostring(st.error or "?"))
                -- persist the failure: reselecting the mod still shows it
                -- (until the next update attempt for this item)
                wbModJobs[wsid] = {
                    message = WB_Text.UpdateFailed .. ": " .. WB_ShortError(st.error, 48),
                    failed = true,
                }
            else
                print("[WorkshopBridge] update of " .. tostring(modId) .. " complete")
                wbModJobs[wsid] = nil
                -- clear by workshop id: the download updated the whole
                -- item, so sibling mods from the same item stop showing
                -- "update available" too
                WB_UnmarkUpdateAvailable(wsid)
                -- the Update-all count dropped by one as well
                WB_RefreshUpdateAllButton(wbScreen, WB_CountUpdateAvailable())
            end
            if WB_WorkshopIdFor(panel.wbModId) == wsid then
                WB_SetLabel(panel.wbStatusLabel,
                    failed and wbModJobs[wsid].message or WB_Text.UpToDate)
                WB_RefreshModButtonTitle(panel, panel.wbModId)
            end
            -- the files on disk changed: rescan so the list shows the new
            -- mod.info (name/version) instead of stale cached data. The
            -- info panel is not repainted by the reload (it only updates
            -- on selection), so the confirmation above stays visible.
            if not failed then
                WB_RefreshModList(wbScreen)
            end
        end,
    })
end

-- ---------- ModSelector (screen) hooks ----------

function WB_RefreshUpdateAllButton(ms, n)
    if not ms or not ms.wbUpdateAllBtn then return end
    WB_SetButtonTitle(ms.wbUpdateAllBtn,
        n > 0 and string.format(WB_Text.UpdateAllN, n) or WB_Text.UpdateAll)
end

local function WB_AddMenuButtons(ms)
    if ms.wbButtonsAdded then return end
    ms.wbButtonsAdded = true
    -- build the progress panel up-front, in normal UI-construction context
    -- (lazy tick-time construction hid failures and poisoned the panel)
    WB_EnsureProgressPanel(ms)
    -- vanilla's action cluster is bottom-right (MapsOrder, ModsOrder, Accept),
    -- anchored right+bottom; ours join it on the left using the same pattern
    local anchor = ms.mapOrderbtn or ms.modOrderbtn or ms.acceptButton
    if not anchor then return end
    local bw, bh, gap = 150, anchor:getHeight(), 10
    local y = anchor:getY()
    local xUpdate = anchor:getX() - gap - bw
    local xCheck = xUpdate - gap - bw
    local xDownload = xCheck - gap - bw
    ms.wbCheckBtn = ISButton:new(xCheck, y, bw, bh, WB_Text.CheckForUpdates, ms,
        function() WB_OnCheckAll(ms) end)
    ms.wbUpdateAllBtn = ISButton:new(xUpdate, y, bw, bh, WB_Text.UpdateAll, ms,
        function() WB_OnUpdateAll(ms) end)
    ms.wbDownloadBtn = ISButton:new(xDownload, y, bw, bh, WB_Text.Download, ms,
        function() WB_ShowDownloadDialog(ms) end)
    for _, b in ipairs({ ms.wbCheckBtn, ms.wbUpdateAllBtn, ms.wbDownloadBtn }) do
        b:initialise()
        b:instantiate()
        b:setAnchorLeft(false)
        b:setAnchorRight(true)
        b:setAnchorTop(false)
        b:setAnchorBottom(true)
        b:setFont(UIFont.Small)
        b:ignoreWidthChange()
        b:ignoreHeightChange()
        ms:addChild(b)
    end
end

-- The ModListBox class our row wrapper chains. Global so tests can stub it.
function WB_GetModListBoxClass()
    if ModSelector and ModSelector.ModListBox then return ModSelector.ModListBox end
    return ModListBox
end

-- Wrap ModListBox:doDrawItem at CLASS level, not per listbox instance.
-- The ModSelector is created eagerly with the MainScreen at boot, but mods
-- like ModFolders patch ModListBox.doDrawItem at class level later, on
-- OnMainMenuEnter. A per-instance wrap would capture vanilla as its base
-- and then shadow their patch, so folder rows would render through vanilla
-- (big red X, no folder buttons). Wrapping the class instead is
-- order-proof: whoever wraps last chains the previous implementation.
local function WB_WrapRowDrawing()
    local MLB = WB_GetModListBoxClass()
    if not MLB or MLB.wbRowWrapped then return end
    local baseDraw = MLB.doDrawItem
    if type(baseDraw) ~= "function" then return end
    MLB.wbRowWrapped = true
    MLB.doDrawItem = function(lb, y, item, alt)
        -- vanilla prerender does arithmetic on the return value
        -- (v.height = y2 - y), so it MUST be propagated
        local y2 = baseDraw(lb, y, item, alt)
        -- doDrawItem receives the listbox row wrapper { text, item=modData };
        -- the mod id lives on the wrapped modData, not the wrapper itself.
        -- (Folder rows from ModFolders have no mod id: badge skipped, no error.)
        local data = item and item.item or nil
        local modId = data and WB_GetModId(data)
        if modId and WB_IsUpdateAvailable(modId) then
            -- ModFolders draws its +/- folder icons in the row's right-hand
            -- strip; shift our badge left of them when its panel controls are
            -- present (resolved per draw: they install after our wrap).
            local bx = lb:getWidth() - 10
            local panel = lb and lb.parent or nil
            if panel and panel.mfNewFolderButton ~= nil then
                local buttonH = getTextManager():getFontHeight(UIFont.Small) + 6
                bx = bx - 3 * buttonH - 16
            end
            -- drawTextRight: right-aligned at x, no manual width measuring needed
            lb:drawTextRight(WB_Text.UpdateAvailableBadge, bx, y,
                0.5, 1.0, 0.5, 1.0, UIFont.Small)
        end
        return y2
    end
end

-- Fallback job pump: the poll normally runs on Events.OnTick, but if the
-- tick doesn't fire while the Mods menu is open (main-menu context), the
-- screen's per-frame update() drives it instead via WB_FallbackPump (which
-- also advances the UI timers - WB_PollJobs itself must not, or the timers
-- would run double speed when both pumps run). WB_PollJobs is idempotent
-- (terminal jobs are removed on first sighting), so double-pumping the
-- poll is safe; only the timer advancement is single-sourced.
local function WB_WrapUpdatePump(ms)
    if ms.wbUpdatePumped then return end
    ms.wbUpdatePumped = true
    local _update = ms.update
    if type(_update) ~= "function" then return end
    local pollErrorLogged = false
    ms.update = function(self, ...)
        local ok, err = pcall(WB_FallbackPump)
        if not ok and not pollErrorLogged then
            pollErrorLogged = true
            print("[WorkshopBridge] poll error: " .. tostring(err))
        end
        return _update(self, ...)
    end
end

-- idempotent per-instance hook (safe to re-call, e.g. after reloadMods)
function WB_HookInstance(ms)
    if not ms then return end
    wbScreen = ms
    WB_AddMenuButtons(ms)
    WB_WrapUpdatePump(ms)
end

-- ---------- ModInfoPanel (per-mod) hooks ----------

local function WB_GetModInfoPanelClass()
    if ModInfoPanel then return ModInfoPanel end
    if ModSelector and ModSelector.ModInfoPanel then return ModSelector.ModInfoPanel end
    return nil
end

local function WB_AddModPanelControls(panel)
    if panel.wbControlsAdded then return end
    panel.wbControlsAdded = true
    -- provisional placement: bottom-left of the panel (verify in-game)
    local w, h = 130, 25
    local x = 10
    local y = math.max(40, panel:getHeight() - h - 10)
    panel.wbUpdateBtn = ISButton:new(x, y, w, h, WB_Text.ForceUpdate, panel,
        function() WB_OnModUpdate(panel) end)
    panel.wbUpdateBtn:initialise()
    panel.wbUpdateBtn:instantiate()
    panel:addChild(panel.wbUpdateBtn)
    panel.wbWorkshopBtn = ISButton:new(x + w + 8, y, w, h, WB_Text.OpenInWorkshop, panel,
        function() WB_OnOpenWorkshop(panel) end)
    panel.wbWorkshopBtn:initialise()
    panel.wbWorkshopBtn:instantiate()
    panel:addChild(panel.wbWorkshopBtn)
    panel.wbStatusLabel = ISLabel:new(x, y - 22, 20, "", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.wbStatusLabel:initialise()
    panel.wbStatusLabel:instantiate()
    panel:addChild(panel.wbStatusLabel)
end

-- (WB_RefreshModPanel lives in the helpers section above: the check/update
-- button handlers close over it, so it must be declared before them.)

local function WB_HookModInfoPanel()
    local MIP = WB_GetModInfoPanelClass()
    if not MIP or MIP.wbHooked then return end
    MIP.wbHooked = true
    local _createChildren = MIP.createChildren
    MIP.createChildren = function(self)
        _createChildren(self)
        WB_AddModPanelControls(self)
    end
    local _updateView = MIP.updateView
    MIP.updateView = function(self, modInfo)
        _updateView(self, modInfo)
        wbLastModPanel = { panel = self, modInfo = modInfo }
        WB_RefreshModPanel(self, modInfo)
    end
end

-- ---------- install ----------

-- Guidance label shown in place of the buttons when the Java backend is
-- absent: same bottom-right cluster, so users see WHY nothing else is there.
local function WB_AddGuidanceLabel(ms)
    if not ms or ms.wbGuidanceAdded then return end
    ms.wbGuidanceAdded = true
    local anchor = ms.mapOrderbtn or ms.modOrderbtn or ms.acceptButton
    if not anchor then return end
    local w = 470
    local x = anchor:getX() - 10 - w
    local y = anchor:getY() + 2
    local label = ISLabel:new(x, y, 20, WB_Text.NeedsZombieBuddy,
        1, 0.55, 0.25, 1, UIFont.Small, true)
    label:initialise()
    label:instantiate()
    WB_SetLabel(label, WB_Text.NeedsZombieBuddy)
    label:setAnchorLeft(false)
    label:setAnchorRight(true)
    label:setAnchorTop(false)
    label:setAnchorBottom(true)
    ms:addChild(label)
end

-- Called from WB_Main when the Java API is absent: hook the menu just
-- enough to explain why WorkshopBridge is inactive, instead of leaving
-- the user with a silent empty menu.
function WB_HookModsMenuNoApi()
    if type(ModSelector) ~= "table" then
        print("[WorkshopBridge] WARN: ModSelector not found, menu hooks skipped")
        return
    end
    if not ModSelector.wbHooked then
        ModSelector.wbHooked = true
        local _create = ModSelector.create
        ModSelector.create = function(self)
            _create(self)
            WB_AddGuidanceLabel(self)
        end
    end
    if ModSelector.instance then
        pcall(function() WB_AddGuidanceLabel(ModSelector.instance) end)
    end
end

-- Called from WB_Main once the Java API (or debug stub) is confirmed present.
function WB_HookModsMenu()
    if type(ModSelector) ~= "table" then
        print("[WorkshopBridge] WARN: ModSelector not found, menu hooks skipped")
        return
    end
    if not ModSelector.wbHooked then
        ModSelector.wbHooked = true
        local _create = ModSelector.create
        ModSelector.create = function(self)
            _create(self)
            WB_HookInstance(self)
        end
    end
    WB_HookModInfoPanel()
    -- class-level row wrap, outside the wbHooked guard so a re-call retries
    -- if the ModListBox class wasn't available the first time
    WB_WrapRowDrawing()
    -- if the screen already exists (re-entry), hook the live instance too
    if ModSelector.instance then
        pcall(function() WB_HookInstance(ModSelector.instance) end)
    end
end
