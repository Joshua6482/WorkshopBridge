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
    print("[WorkshopBridge] mod options registered")
end

-- The live value of the per-download refresh option. Defaults to true
-- (the behavior is on) when the options API is absent, which also keeps
-- the offline test suite on the default path.
function WB_GetRefreshListPerDownload()
    if type(PZAPI) == "table" and type(PZAPI.ModOptions) == "table"
            and type(PZAPI.ModOptions.getOptions) == "function" then
        local ok, opts = pcall(PZAPI.ModOptions.getOptions,
            PZAPI.ModOptions, MOD_OPTIONS_ID)
        if ok and type(opts) == "table" and type(opts.getOption) == "function" then
            local ok2, opt = pcall(opts.getOption, opts, OPT_REFRESH_PER_DOWNLOAD)
            if ok2 and type(opt) == "table" and type(opt.getValue) == "function" then
                local ok3, v = pcall(opt.getValue, opt)
                if ok3 and type(v) == "boolean" then return v end
            end
        end
    end
    return true
end

WB_RegisterOptions()
