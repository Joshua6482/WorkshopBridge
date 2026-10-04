-- WorkshopBridge configuration + UI strings.
-- All Lua lives under media/lua/client/WorkshopBridge/ so requires stay simple.

WB_Config = {
    MOD_ID = "WorkshopBridge",
    STEAM_APP_ID = 108600, -- Project Zomboid

    -- When true and the ZombieBuddy Java API is NOT present, WB_Main installs
    -- WB_DebugStub, which fakes the Java API with canned responses. This lets
    -- you verify the whole UI in-game without building the Java side.
    -- Defaults to false: a shipped build must never report fake successes.
    -- The Lua UI tests enable it explicitly (see tests/lua/test_ui.lua).
    DEBUG_STUB = false,
}

-- Hardcoded English strings, kept in one table so localization can be
-- layered on later without touching UI code.
WB_Text = {
    CheckForUpdates  = "Check for updates",
    UpdateAll        = "Update all",
    UpdateAllN       = "Update all (%d)",
    Update           = "Update",
    ForceUpdate      = "Force update",
    OpenInWorkshop   = "Open in Workshop",
    Download         = "Download",
    Cancel           = "Cancel",
    Import           = "Import",
    MoreTools        = "More tools",
    ToolsTitle       = "More tools",
    ExportMods       = "Export enabled mods",
    ImportFromText   = "Import from text",
    ImportFromCollection = "Import from collection",
    DownloadModTitle = "Download mod from Workshop",
    DownloadHint     = "Workshop ID or URL, e.g. 2685600088",
    DownloadFailed   = "Download failed",
    Downloaded       = "Downloaded",
    Downloading      = "Downloading...",
    InvalidWorkshopId = "Enter a Workshop ID or URL",
    ExportFailed     = "Export failed",
    NothingToExport  = "No enabled mods with a known Workshop ID",
    ExportedN        = "Exported %d mod(s) to workshopbridge-exports/",
    ImportTextTitle  = "Import mods from text",
    ImportTextHint   = "One Workshop ID or URL per line",
    ImportCollectionTitle = "Import Workshop collection",
    ImportCollectionHint  = "Collection ID or URL, e.g. 1234567890",
    NothingToImport  = "No valid Workshop IDs found",
    Importing        = "Importing...",
    Imported         = "Imported",
    ImportFailed     = "Import failed",
    UnknownWorkshopId = "Unknown workshop ID",
    ManagedBySteam   = "Managed by Steam",
    UpdateAvailableBadge = "[Update available]",
    UpToDate         = "Up to date",
    Checking         = "Checking for updates...",
    Updating         = "Updating...",
    CheckFailed      = "Check failed",
    UpdateFailed     = "Update failed",
}
