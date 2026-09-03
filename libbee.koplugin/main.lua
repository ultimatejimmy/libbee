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

local ok_loc, Localization = pcall(require, plugin_path .. "libbee_localization")
if not ok_loc or not Localization then
    ok_loc, Localization = pcall(require, "libbee_localization")
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end

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
    -- Configure package.path for embedded DRM & XML dependencies
    if self.path then
        local p = self.path
        local extra = {
            p .. "/?.lua",
        }
        for _, ep in ipairs(extra) do
            if not package.path:find(ep, 1, true) then
                package.path = ep .. ";" .. package.path
            end
        end
    end

    -- Initialize our logger with the plugin directory
    local log = require(plugin_path .. "libbee_logger")
    log.init(self.path)

    -- Register Dispatcher actions (for gestures, keyboard shortcuts, quickmenu)
    self:onDispatcherRegisterActions()

    -- Register our menu items
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Register ACSM document provider so standalone .acsm files can be fulfilled directly
    self:registerDocumentRegistryAuxProvider()

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

    -- Silent startup cleanup for expired loans (15 seconds after reader ready)
    if not LibbeePlugin._startup_clean_done then
        LibbeePlugin._startup_clean_done = true
        if ok_ui then
            UIManager:scheduleIn(15, function()
                self:_startupExpiredCleanup()
            end)
        end
    end

    logger.info("libbee: initialized")
end

function LibbeePlugin:registerDocumentRegistryAuxProvider()
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_dr or not DocumentRegistry then return end

    local provider = {
        provider_name = "Libbee (ACSM)",
        provider = self.name,
        order = 30,
        disable_file = true,
        disable_type = false,
        enabled_func = function()
            return false
        end,
    }

    local acsm_registered = false
    for i = #DocumentRegistry.providers, 1, -1 do
        local entry = DocumentRegistry.providers[i]
        if entry.extension == "acsm" and entry.provider and entry.provider.provider == self.name then
            if acsm_registered then
                table.remove(DocumentRegistry.providers, i)
            else
                entry.mimetype = "application/vnd.adobe.adept+xml"
                entry.provider = provider
                entry.weight = 100
                acsm_registered = true
            end
        end
    end

    if not acsm_registered then
        DocumentRegistry:addProvider("acsm", "application/vnd.adobe.adept+xml", provider, 100)
    else
        DocumentRegistry.known_providers[self.name] = provider
    end
end

function LibbeePlugin:openFile(file)
    if not file or not file:find("%.[Aa][Cc][Ss][Mm]$") then return false end
    local LibbeeDRM = require(plugin_path .. "libbee_drm")
    local Trapper = require("ui/trapper")
    local ui = _ui()
    local info_toast = ui and ui.showToast and ui.showToast(_("Fulfilling ACSM loan with Libbee…"), 120)

    Trapper:wrap(function()
        local meta = LibbeeDRM.parseAcsmMetadata(file)
        local base_dir = file:match("^(.+)/[^/]+$") or "."
        local final_path = LibbeeDRM.deriveFinalBookPath(base_dir, nil, meta)

        local completed, ok, ful_ok, err = Trapper:dismissableRunInSubprocess(
            function()
                return pcall(LibbeeDRM.fulfillAcsm, file, final_path)
            end,
            info_toast
        )
        if info_toast then
            if info_toast.close then
                info_toast:close()
            else
                UIManager:close(info_toast, "ui")
            end
        end

        if completed and ok and ful_ok then
            pcall(os.remove, file)
            local ui = _ui()
            if ui then ui._openBook(final_path) end
        else
            local err_msg = tostring(err or ful_ok or _("ACSM fulfillment failed"))
            local ui = _ui()
            if ui then
                ui.showCardDialog{
                    title = _("ACSM Fulfillment Failed"),
                    body_text = _("Could not fulfill loan file:\n\n%s", err_msg),
                    buttons = { { text = _("OK"), is_primary = true } }
                }
            end
        end
    end)
    return true
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

function LibbeePlugin:_startupExpiredCleanup()
    local ok_state, State = pcall(require, plugin_path .. "libbee_state")
    if not ok_state or not State or not State.getAutoDeleteExpired or not State.getAutoDeleteExpired() then
        return
    end

    local ok_ac, AutoClean = pcall(require, plugin_path .. "libbee_autoclean")
    if not ok_ac or not AutoClean or not AutoClean.checkAndCleanup then
        return
    end

    local cached_shelf = State.getShelfCache and State.getShelfCache(true)
    AutoClean.checkAndCleanup(cached_shelf, { is_live_sync = false })
end

-- ---------------------------------------------------------------------------
-- Menu registration & ordering
-- ---------------------------------------------------------------------------

-- Helper to inject Libbee into Tools menu at top position if not already placed by another plugin / customizer
local function injectLibbeeIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
        "ui/elements/menu_order",
    }
    local function isItemInOrder(tbl, target_id)
        if type(tbl) ~= "table" then return false end
        for _, val in pairs(tbl) do
            if val == target_id then
                return true
            elseif type(val) == "table" then
                if isItemInOrder(val, target_id) then
                    return true
                end
            end
        end
        return false
    end

    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            if not isItemInOrder(order, "libbee") and not isItemInOrder(order, "Libbee") then
                table.insert(order.tools, 1, "libbee")
            end
        end
    end
end

-- addToMainMenu is called by KOReader's menu system when building the Tools menu.
-- It returns a table describing our top-level menu entry.
function LibbeePlugin:addToMainMenu(menu_items)
    injectLibbeeIntoToolsMenu()
    local path = self.path
    menu_items.libbee = {
        text         = _("Libbee"),
        sorting_hint = "tools",
        callback     = function()
            local ui = _ui()
            if ui then ui.showShelfBrowser(path) end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Dispatcher registration (gestures, keyboard shortcuts, quickmenu)
-- ---------------------------------------------------------------------------

function LibbeePlugin:onDispatcherRegisterActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or not Dispatcher then return end
    pcall(function()
        Dispatcher:registerAction("libbee_open", {
            category = "none",
            event    = "LibbeeOpen",
            title    = _("Libbee: Open"),
            general  = true,
        })
        Dispatcher:registerAction("libbee_browse_shelf", {
            category = "none",
            event    = "LibbeeBrowseShelf",
            title    = _("Libbee: Browse Shelf"),
            general  = true,
        })
    end)
end

function LibbeePlugin:onLibbeeOpen()
    local ui = _ui()
    if ui then ui.showShelfBrowser(self.path) end
    return true
end

function LibbeePlugin:onLibbeeBrowseShelf()
    return self:onLibbeeOpen()
end

function LibbeePlugin:onNetworkConnected()
    -- Nothing to do proactively; the shelf browser checks auth on open.
    logger.info("libbee: network connected")
end

return LibbeePlugin
