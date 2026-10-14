-- luacheck configuration for WorkshopBridge.
--
-- The mod's Lua runs inside Project Zomboid's Kahlua (Lua 5.1-ish), so the
-- default standard is lua51. The offline test rig (tests/lua/) runs under
-- plain Lua 5.4 instead; see the per-path override at the bottom.

std = "lua51"

-- Writable globals: the mod's own cross-file API surface. These are
-- assigned in one WB_*.lua file and read in others, so they must be
-- declared writable here.
globals = {
    -- Dialog classes (ISPanel:derive in their own files)
    "WB_AdoptDialog",
    "WB_DeleteDialog",
    "WB_DependenciesDialog",
    "WB_DownloadDialog",
    "WB_ImportCollectionDialog",
    "WB_ImportTextDialog",
    "WB_ServerModsDialog",
    "WB_ToolsDialog",

    -- Hook guard flags (deliberate reload guards, cf. WB_OptionsRegistered)
    "WB_ServerJoinHooked",

    -- ModSelector is monkey-patched on purpose (hook flags, wrapped
    -- methods), so it must stay writable here.
    "ModSelector",

    -- Cross-file state
    "WB_ApiKind",
    "WB_Config",
    "WB_JSON_NULL",
    "WB_OptionsRegistered",
    "WB_RegisterOptions",
    "WB_Text",
    "wbScreen",

    -- Cross-file functions
    "WB_CheckDependencies",
    "WB_ClearUpdateAvailable",
    "WB_ClearWorkshopIdCache",
    "WB_CollectEnabledWorkshopIds",
    "WB_CountUpdateAvailable",
    "WB_EnsurePolling",
    "WB_EnsureProgressPanel",
    "WB_FallbackPump",
    "WB_FlashMessage",
    "WB_GameWorkshopIdFor",
    "WB_GetCheckDependenciesAfterDownload",
    "WB_GetEnableCollectionImport",
    "WB_GetModListBoxClass",
    "WB_GetOfferServerModDownloads",
    "WB_GetRefreshListPerDownload",
    "WB_GetWriteSidecarStamp",
    "WB_HideProgress",
    "WB_HookInstance",
    "WB_HookModsMenu",
    "WB_HookServerJoin",
    "WB_InstallDebugStub",
    "WB_IsUpdateAvailable",
    "WB_JsonDecode",
    "WB_MarkUpdateAvailable",
    "WB_OnConnectFailed",
    "WB_OnDelete",
    "WB_ParseImportText",
    "WB_ParseWorkshopId",
    "WB_PollJobs",
    "WB_RefreshModList",
    "WB_RefreshUpdateAllButton",
    "WB_SetButtonTitle",
    "WB_SetLabel",
    "WB_ShortError",
    "WB_ShowAdoptDialog",
    "WB_ShowDeleteDialog",
    "WB_ShowDependenciesDialog",
    "WB_ShowDownloadDialog",
    "WB_ShowError",
    "WB_ShowImportCollectionDialog",
    "WB_ShowImportTextDialog",
    "WB_ShowProgress",
    "WB_ShowServerModsDialog",
    "WB_ShowToolsDialog",
    "WB_TickProgressPanel",
    "WB_TrackJob",
    "WB_UnmarkUpdateAvailable",
    "WB_WorkshopIdFor",
}

-- Read-only globals: the Java bridge (provided by ZombieBuddy's Exposer at
-- runtime, or faked by WB_DebugStub.lua in tests) and the Project Zomboid
-- API. Assigning to any of these from mod code would be a bug.
read_globals = {
    -- Java bridge
    "wbAdoptMod",
    "wbCheckDependencies",
    "wbCheckForUpdates",
    "wbDeleteMod",
    "wbExportModList",
    "wbGetJobStatus",
    "wbGetModIds",
    "wbGetServerMods",
    "wbGetWorkshopId",
    "wbImportCollection",
    "wbImportMods",
    "wbInvalidateModCaches",
    "wbIsAvailable",
    "wbOpenWorkshopPage",
    "wbUpdateAll",
    "wbUpdateMod",

    -- Project Zomboid API (verified in use by grep; extend as needed)
    "ConnectToServer",
    "Events",
    "getTextManager",
    "ISButton",
    "ISLabel",
    "ISPanel",
    "ISTextEntryBox",
    "ModInfoPanel",
    "ModListBox",
    "PZAPI",
    "UIFont",
}

-- WB_DebugStub.lua legitimately *defines* the Java bridge functions
-- (they are read-only everywhere else), so they are writable there.
files["**/WB_DebugStub.lua"] = {
    globals = {
        "wbAdoptMod",
        "wbCheckDependencies",
        "wbCheckForUpdates",
        "wbDeleteMod",
        "wbExportModList",
        "wbGetJobStatus",
        "wbGetModIds",
        "wbGetServerMods",
        "wbGetWorkshopId",
        "wbImportCollection",
        "wbImportMods",
        "wbInvalidateModCaches",
        "wbIsAvailable",
        "wbOpenWorkshopPage",
        "wbUpdateAll",
        "wbUpdateMod",
    },
}

-- The offline test rig runs under Lua 5.4 with its own stub scaffolding.
-- The stubs deliberately define PZ API globals, bridge functions, and
-- (in test_delete.lua) nil out `next` to mimic Kahlua, so all of those
-- are writable here.
files["tests/lua/**"] = {
    std = "lua54",
    globals = {
        "ConnectToServer",
        "Events",
        "ISButton",
        "ISLabel",
        "ISPanel",
        "ISTextEntryBox",
        "ModInfoPanel",
        "ModSelector",
        "next",
        "PZAPI",
        "UIFont",
        "UIElement",
        "wbAdoptMod",
        "wbCheckDependencies",
        "wbCheckForUpdates",
        "wbDeleteMod",
        "wbExportModList",
        "wbGetJobStatus",
        "wbGetModIds",
        "wbGetServerMods",
        "wbGetWorkshopId",
        "wbImportCollection",
        "wbImportMods",
        "wbInvalidateModCaches",
        "wbIsAvailable",
        "wbOpenWorkshopPage",
        "wbUpdateAll",
        "wbUpdateMod",
    },
}
