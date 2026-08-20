-- main.lua — Libbee KOReader Plugin
-- Browse your Libby shelf and download ebook loans directly to KOReader.
--
-- is_doc_only = false: plugin works from the file manager AND the reader.
-- Menu appears under Tools in both contexts.

local logger = require("logger")

-- CRITICAL: Derive the Lua module path prefix for loading sibling modules.
-- In KOReader, plugin sub-modules must be required with this prefix.
-- e.g., require(plugin_path .. "libbee_ui") not require("libbee_ui")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

local ok_wc, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
local ok_ui, UIManager       = pcall(require, "ui/uimanager")

if not ok_wc or not WidgetContainer then
    -- Bail out gracefully if core widgets aren't available
    logger.err("libbee: WidgetContainer unavailable, plugin disabled")
    return
end

-- ---------------------------------------------------------------------------
-- Plugin object
-- ---------------------------------------------------------------------------

local LibbeePlugin = WidgetContainer:extend{
    name        = "libbee",
    is_doc_only = false,   -- Available from file manager AND reader
}

-- Resolve plugin directory path is not needed at file scope anymore as we use self.path.

-- Lazy-load the UI module only when the user actually opens the menu.
local function _ui()
    local ok, LibbeeUI = pcall(require, plugin_path .. "libbee_ui")
    if not ok then
        logger.err("libbee: could not load libbee_ui: " .. tostring(LibbeeUI))
        return nil
    end
    return LibbeeUI
end

-- ---------------------------------------------------------------------------
-- Initialization
-- ---------------------------------------------------------------------------

function LibbeePlugin:init()
    -- Initialize our logger with the plugin directory
    local log = require(plugin_path .. "libbee_logger")
    log.init(self.path)

    -- Register our menu items
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Silent weekly update check (10 seconds after reader ready)
    -- Uses a flag to avoid multiple checks in the same session
    if not LibbeePlugin._weekly_check_done then
        LibbeePlugin._weekly_check_done = true
        if ok_ui then
            UIManager:scheduleIn(10, function()
                self:_weeklyUpdateCheck()
            end)
        end
    end

    logger.info("libbee: initialized")
end

function LibbeePlugin:_weeklyUpdateCheck()
    -- Only check once per week using a timestamp in state
    local ok_state, State = pcall(require, plugin_path .. "libbee_state")
    if not ok_state then return end

    -- We reuse the state infrastructure to track last-checked time
    local ok_ds, DS = pcall(require, "datastorage")
    if not ok_ds then return end

    local cache_file = DS:getSettingsDir() .. "/libbee_last_update_check.txt"
    local ONE_WEEK   = 7 * 24 * 3600

    local last_check = 0
    local fh = io.open(cache_file, "r")
    if fh then
        last_check = tonumber(fh:read("*a")) or 0
        fh:close()
    end

    if (os.time() - last_check) < ONE_WEEK then return end

    -- Save new timestamp
    local ofh = io.open(cache_file, "w")
    if ofh then ofh:write(tostring(os.time())); ofh:close() end

    -- Run check
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.isConnected and NetworkMgr:isConnected() then
        local ok_upd, Updater = pcall(require, plugin_path .. "libbee_updater")
        if ok_upd then
            Updater.checkSilentForUpdates(false)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Menu registration
-- ---------------------------------------------------------------------------

-- addToMainMenu is called by KOReader's menu system when building the Tools menu.
-- It must return a table describing our top-level menu entry.
function LibbeePlugin:addToMainMenu(menu_items)
    local path = self.path
    menu_items.libbee = {
        text         = "Libbee",
        sorting_hint = "tools",
        callback     = function()
            local ui = _ui()
            if ui then ui.showShelfBrowser(path) end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Dispatcher registration (optional keyboard shortcut)
-- ---------------------------------------------------------------------------

function LibbeePlugin:onDispatcherRegisterActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or not Dispatcher then return end
    pcall(function()
        Dispatcher:registerAction("libbee_browse_shelf", {
            category = "none",
            event    = "LibbeeBrowseShelf",
            title    = "Libbee: Browse Shelf",
            general  = true,
        })
    end)
end

function LibbeePlugin:onLibbeeBrowseShelf()
    local ui = _ui()
    if ui then ui.showShelfBrowser(self.path) end
    return true
end

function LibbeePlugin:onNetworkConnected()
    -- Nothing to do proactively; the shelf browser checks auth on open.
    logger.info("libbee: network connected")
end

return LibbeePlugin
