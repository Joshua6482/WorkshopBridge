-- WorkshopBridge mod options (Options > Mods > WorkshopBridge).
--
-- Uses the vanilla PZAPI.ModOptions system, so the section appears where
-- every other mod's options live and values persist to ModOptions.ini
-- with no work from us: the game calls load() when the options screen
-- opens (after mod files load, so file-scope registration is correct)
-- and save() on apply. Every read goes through
-- WB_GetRefreshListPerDownload(), which degrades to the default (on)
-- when the API or the option is unavailable.
require "WorkshopBridge/WB_Config"

local MOD_OPTIONS_ID = "WorkshopBridge"
local OPT_REFRESH_PER_DOWNLOAD = "RefreshListPerDownload"
local OPT_CHECK_DEPENDENCIES = "CheckDependenciesAfterDownload"
local OPT_SERVER_DOWNLOAD_OFFER = "OfferServerModDownloads"
local OPT_SIDECAR_STAMP = "WriteSidecarStamp"

local function WB_RegisterOptions()
    if type(PZAPI) ~= "table" or type(PZAPI.ModOptions) ~= "table" then return end
    if type(PZAPI.ModOptions.create) ~= "function" then return end
    -- create() appends to the registry every call; register once even if
    -- this file is (re)loaded more than once
    if WB_OptionsRegistered then return end
    WB_OptionsRegistered = true
    local opts = PZAPI.ModOptions:create(MOD_OPTIONS_ID, "WorkshopBridge")
    if type(opts) ~= "table" or type(opts.addTickBox) ~= "function" then return end
    opts:addTickBox(OPT_REFRESH_PER_DOWNLOAD,
        "Refresh mod list after each download",
        true,
        "When importing mods, rebuild the mod list after every downloaded mod so newly arrived mods show up immediately. Turn off if the rebuilding bothers you.")
    opts:addTickBox(OPT_CHECK_DEPENDENCIES,
        "Check for required workshop items after download",
        true,
        "After downloading or adopting a mod, look up its Workshop required items and offer to install any that are missing.")
    opts:addTickBox(OPT_SERVER_DOWNLOAD_OFFER,
        "Offer downloads when joining a modded server",
        true,
        "When joining a server fails because mods are missing, offer to download them from the Steam Workshop.")
    opts:addTickBox(OPT_SIDECAR_STAMP,
        "Tag mod folders with Workshop info",
        true,
        "Write a small workshopbridge.json file into each installed mod folder recording its Workshop ID. Mods you archive and move back re-link automatically instead of showing as unknown. Turn off if you don't want extra files in your mod folders.")
    print("[WorkshopBridge] mod options registered")
end

-- Reads a tickbox, defaulting when the options API (or the option) is
-- unavailable. Keeps the offline test suite on the default path too.
local function wbGetTickBox(id, default)
    if type(PZAPI) == "table" and type(PZAPI.ModOptions) == "table"
            and type(PZAPI.ModOptions.getOptions) == "function" then
        local ok, opts = pcall(PZAPI.ModOptions.getOptions,
            PZAPI.ModOptions, MOD_OPTIONS_ID)
        if ok and type(opts) == "table" and type(opts.getOption) == "function" then
            local ok2, opt = pcall(opts.getOption, opts, id)
            if ok2 and type(opt) == "table" and type(opt.getValue) == "function" then
                local ok3, v = pcall(opt.getValue, opt)
                if ok3 and type(v) == "boolean" then return v end
            end
        end
    end
    return default
end

-- The live value of the per-download refresh option. Defaults to true
-- (the behavior is on) when the API or the option is unavailable.
function WB_GetRefreshListPerDownload()
    return wbGetTickBox(OPT_REFRESH_PER_DOWNLOAD, true)
end

function WB_GetCheckDependenciesAfterDownload()
    return wbGetTickBox(OPT_CHECK_DEPENDENCIES, true)
end

function WB_GetOfferServerModDownloads()
    return wbGetTickBox(OPT_SERVER_DOWNLOAD_OFFER, true)
end

-- NB: the Java side reads this same option straight from the game's
-- ModOptions.ini (see ModOptionsIni.java); the option id string must
-- match OPT_SIDECAR_STAMP.
function WB_GetWriteSidecarStamp()
    return wbGetTickBox(OPT_SIDECAR_STAMP, true)
end

WB_RegisterOptions()
