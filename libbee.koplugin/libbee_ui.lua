-- libbee_ui.lua — All UI for the Libbee plugin
-- Shelf browser, setup dialogs, download flow, about screen.
-- Uses ConfirmBox everywhere (not ButtonDialog) for Kindle PW1 compatibility.
-- All network calls run in Trapper:dismissableRunInSubprocess to keep UI live.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu        = require("ui/widget/menu")
-- Derive Lua module path prefix for sibling modules
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

local log = require(plugin_path .. "libbee_logger")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _close(w)
    if w then UIManager:close(w) end
end

-- Load config safely; returns empty table on failure.
local function _loadConfig(plugin_dir)
    local config_path = plugin_dir .. "/libbee_config.lua"
    local ok, cfg = pcall(dofile, config_path)
    if ok and type(cfg) == "table" then return cfg end
    log.warn("libbee ui: could not load config from " .. tostring(config_path))
    return {}
end

-- Run a function in a subprocess with a dismissable spinner.
-- on_done(result, err) is called with the returned values when the subprocess finishes.
-- Captures multiple returns and exceptions in a table to cross subprocess boundaries safely.
local function _runAsync(work_fn, spinner_text, on_done)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    local spinner = _toast(spinner_text, 120)

    if ok_tr and Trapper and Trapper.wrap then
        Trapper:wrap(function()
            local completed, ok, r1, r2 = Trapper:dismissableRunInSubprocess(
                function() return pcall(work_fn) end,
                spinner
            )
            _close(spinner)
            if not completed then
                on_done(nil, "Cancelled")
            elseif ok then
                on_done(r1, r2)
            else
                on_done(nil, tostring(r1 or "Unknown error"))
            end
        end)
    else
        UIManager:scheduleIn(0.1, function()
            local ok, r1, r2 = pcall(work_fn)
            _close(spinner)
            if ok then
                on_done(r1, r2)
            else
                on_done(nil, tostring(r1 or "Unknown error"))
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Setup Flow
-- ---------------------------------------------------------------------------

-- Silent version of _runAsync that does not display a spinner/toast.
local function _runAsyncSilent(work_fn, on_done)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    if ok_tr and Trapper and Trapper.wrap then
        Trapper:wrap(function()
            local completed, ok, r1, r2 = Trapper:dismissableRunInSubprocess(
                function() return pcall(work_fn) end,
                nil
            )
            if completed then
                if ok then
                    on_done(r1, r2)
                else
                    on_done(nil, tostring(r1 or "Unknown error"))
                end
            end
        end)
    else
        UIManager:scheduleIn(0.1, function()
            local ok, r1, r2 = pcall(work_fn)
            if ok then
                on_done(r1, r2)
            else
                on_done(nil, tostring(r1 or "Unknown error"))
            end
        end)
    end
end

-- Shows the setup dialog: generates a code and polls for clone completion.
function M.showSetupDialog(plugin_dir, on_done)
    local State = require(plugin_path .. "libbee_state")
    local API   = require(plugin_path .. "libbee_api")

    _runAsync(
        function()
            return API.requestSetupCode()
        end,
        "Connecting to Libby…",
        function(result, err)
            if not result or not result.code then
                local err_str = err or tostring(result or "Unknown error")
                log.warn("setup code request failed: " .. tostring(err_str))
                UIManager:show(ConfirmBox:new{
                    text = "Could not request setup code:\n" .. err_str ..
                           "\n\nMake sure your device is connected to the internet.",
                    ok_text = "OK",
                })
                if on_done then on_done(false) end
                return
            end

            local raw_code = result.code
            local display_code = raw_code:sub(1, 4) .. " " .. raw_code:sub(5, 8)

            local is_active = true
            local dlg

            local function cleanup()
                is_active = false
                _close(dlg)
            end

            local poll_count = 0
            local max_polls = 36 -- 3 minutes (5s interval)
            local function do_poll()
                if not is_active then return end
                poll_count = poll_count + 1
                if poll_count > max_polls then
                    cleanup()
                    UIManager:show(ConfirmBox:new{
                        text = "Setup timed out.\n\nPlease try again.",
                        ok_text = "OK",
                    })
                    if on_done then on_done(false) end
                    return
                end

                _runAsyncSilent(
                    function()
                        return API.pollForCloneResult(raw_code)
                    end,
                    function(poll_res, poll_err)
                        if not is_active then return end
                        if poll_res and poll_res.chip then
                            cleanup()
                            local lib_name = poll_res.library_name or "Libby"
                            UIManager:show(ConfirmBox:new{
                                text    = "✓ Libbee connected!\n\nLibrary: " .. tostring(lib_name) ..
                                          "\n\nYour device is now registered. You can browse your shelf.",
                                ok_text = "Open Shelf",
                                cancel_text = "OK",
                                ok_callback = function()
                                    M.showShelfBrowser(plugin_dir)
                                end,
                            })
                            if on_done then on_done(true) end
                        else
                            UIManager:scheduleIn(5, do_poll)
                        end
                    end
                )
            end

            local body = "Libby Setup\n\n" ..
                         "To link this device to your Libby account:\n\n" ..
                         "1. Open the Libby app on your phone or computer.\n" ..
                         "2. Tap Menu (☰) → Settings → Copy Library To Another Device.\n" ..
                         "3. Enter this setup code:\n\n" ..
                         "      [ " .. display_code .. " ]\n\n" ..
                         "Waiting for Libby app to authorize..."

            dlg = ConfirmBox:new{
                text = body,
                ok_text = "Cancel",
                ok_callback = function()
                    cleanup()
                    if on_done then on_done(false) end
                end,
            }
            local original_onClose = dlg.onClose
            dlg.onClose = function(self)
                is_active = false
                if original_onClose then original_onClose(self) end
            end

            UIManager:show(dlg)
            UIManager:scheduleIn(5, do_poll)
        end
    )
end

-- ---------------------------------------------------------------------------
-- Shelf Browser
-- ---------------------------------------------------------------------------

-- Formats days remaining as a short human string.
local function _fmtDays(days)
    if not days then return "" end
    if days == 0 then return " [expires today]" end
    if days == 1 then return " [1 day left]" end
    return string.format(" [%d days left]", days)
end

-- Formats a loan entry for a Menu row.
local function _loanToMenuEntry(loan, plugin_dir, refresh_fn)
    local days_str = _fmtDays(loan.days_remaining)
    return {
        text     = loan.title or "Unknown Title",
        mandatory = (loan.author or "") .. days_str,
        callback  = function()
            M.showDownloadConfirm(loan, plugin_dir, refresh_fn)
        end,
    }
end

-- Shows the shelf browser menu. Fetches shelf data in a subprocess.
function M.showShelfBrowser(plugin_dir)
    local cfg = _loadConfig(plugin_dir)
    local State = require(plugin_path .. "libbee_state")
    local API   = require(plugin_path .. "libbee_api")

    -- Check auth before fetching
    if not State.isAuthenticated() and (not cfg.bearer_token or cfg.bearer_token == "") then
        UIManager:show(ConfirmBox:new{
            text    = "Libbee is not set up yet.\n\nRun the setup to connect your library card.",
            ok_text = "Setup Now",
            cancel_text = "Cancel",
            ok_callback = function()
                M.showSetupDialog(plugin_dir, function(success)
                    if success then M.showShelfBrowser(plugin_dir) end
                end)
            end,
        })
        return
    end

    -- Try cache first for instant display
    local cached_shelf = State.getShelfCache()

    local function buildAndShowMenu(loans, from_cache)
        if not loans or #loans == 0 then
            _toast("No active loans found on your Libby shelf.", 5)
            return
        end

        -- Sort by days remaining (soonest expiry first)
        table.sort(loans, function(a, b)
            local da = a.days_remaining or 999
            local db = b.days_remaining or 999
            return da < db
        end)

        local refresh_fn  -- forward declaration
        local menu_items = {}

        for _, loan in ipairs(loans) do
            table.insert(menu_items, _loanToMenuEntry(loan, plugin_dir, function()
                refresh_fn()
            end))
        end

        -- Status footer
        local status_text = from_cache and "Shelf (cached)" or "Shelf"
        local lib_name = State.getLibraryName()
        if lib_name and lib_name ~= "" then
            status_text = lib_name .. " — " .. status_text
        end

        local shelf_menu
        shelf_menu = Menu:new{
            title             = status_text,
            item_table        = menu_items,
            width             = math.floor(require("ui/screen").width * 0.95),
            height            = math.floor(require("ui/screen").height * 0.90),
            show_caution      = false,
            onMenuSelect      = function(_, item)
                if item.callback then item.callback() end
            end,
            onMenuHold        = function(_, item) end, -- no hold action
            close_callback    = function() end,
        }

        -- Refresh action: re-fetch from network
        refresh_fn = function()
            _close(shelf_menu)
            State.clearShelfCache()
            M.showShelfBrowser(plugin_dir)
        end

        UIManager:show(shelf_menu)
    end

    if cached_shelf then
        -- Show cached data immediately, then silently refresh in background
        buildAndShowMenu(cached_shelf, true)
        -- Trigger a background refresh after 1s
        UIManager:scheduleIn(1, function()
            _runAsync(
                function() return API.fetchShelf(cfg) end,
                "Refreshing shelf…",
                function(result, err)
                    if type(result) == "table" then
                        State.saveShelfCache(result)
                    elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                        M._handleAuthExpired(plugin_dir)
                    end
                end
            )
        end)
    else
        -- No cache: fetch with spinner
        _runAsync(
            function() return API.fetchShelf(cfg) end,
            "Loading your Libby shelf…",
            function(result, err)
                if type(result) == "table" then
                    State.saveShelfCache(result)
                    buildAndShowMenu(result, false)
                elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                    M._handleAuthExpired(plugin_dir)
                else
                    local err_str = err or tostring(result or "Unknown error")
                    UIManager:show(ConfirmBox:new{
                        text    = "Could not load shelf:\n" .. err_str ..
                                  "\n\nCheck your network connection. If the problem persists, try re-authenticating.",
                        ok_text = "Retry",
                        cancel_text = "Cancel",
                        ok_callback = function() M.showShelfBrowser(plugin_dir) end,
                    })
                end
            end
        )
    end
end

-- ---------------------------------------------------------------------------
-- Auth Expired Handler
-- ---------------------------------------------------------------------------

function M._handleAuthExpired(plugin_dir)
    UIManager:show(ConfirmBox:new{
        text    = "Your Libby session has expired.\n\nPlease re-authenticate to continue.",
        ok_text = "Re-authenticate",
        cancel_text = "Cancel",
        ok_callback = function()
            local State = require(plugin_path .. "libbee_state")
            State.clearChipIdentity()
            State.clearShelfCache()
            M.showSetupDialog(plugin_dir, function(success)
                if success then M.showShelfBrowser(plugin_dir) end
            end)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Download Flow
-- ---------------------------------------------------------------------------

-- Shows a confirmation dialog before downloading an ACSM file.
function M.showDownloadConfirm(loan, plugin_dir, after_download_fn)
    local cfg = _loadConfig(plugin_dir)
    local API = require(plugin_path .. "libbee_api")

    -- Determine save path
    local base_dir = (cfg.download_dir and cfg.download_dir ~= "") and cfg.download_dir
                     or API.getDefaultDownloadDir()
    local dest_path = API.getAcsmPath(base_dir, loan)

    -- Check if file already exists
    local existing = io.open(dest_path, "r")
    if existing then
        existing:close()
        UIManager:show(ConfirmBox:new{
            text    = "\"" .. loan.title .. "\" was already downloaded.\n\n" .. dest_path ..
                      "\n\nOpen it now?",
            ok_text = "Open",
            cancel_text = "Cancel",
            ok_callback = function()
                M._openAcsm(dest_path)
            end,
        })
        return
    end

    local days_str = loan.days_remaining and
        ("\n\n⏳ " .. loan.days_remaining .. " days remaining on this loan.") or ""

    UIManager:show(ConfirmBox:new{
        text    = "Download \"" .. loan.title .. "\"?" .. days_str ..
                  "\n\nThe .acsm file will be saved to:\n" .. dest_path ..
                  "\n\nYou must have acsm.koplugin installed to open it.",
        ok_text = "Download",
        cancel_text = "Cancel",
        ok_callback = function()
            M._doDownload(loan, dest_path, base_dir, cfg, plugin_dir, after_download_fn)
        end,
    })
end

-- Performs the actual download in a subprocess.
function M._doDownload(loan, dest_path, base_dir, cfg, plugin_dir, after_download_fn)
    local API = require(plugin_path .. "libbee_api")

    -- Ensure download directory exists
    local dir_ok, dir_err = API.ensureDownloadDir(base_dir)
    if not dir_ok then
        _toast("Could not create download folder:\n" .. tostring(dir_err), 6)
        return
    end

    _runAsync(
        function()
            return API.downloadACSM(loan, dest_path, cfg)
        end,
        "Downloading \"" .. (loan.title or "ebook") .. "\"…",
        function(result, err)
            if result == true then
                -- Invalidate shelf cache (loan may now be tracked as downloaded)
                local State = require(plugin_path .. "libbee_state")
                State.clearShelfCache()

                if after_download_fn then after_download_fn() end

                UIManager:show(ConfirmBox:new{
                    text    = "✓ Downloaded!\n\n\"" .. loan.title .. "\"\n\n" ..
                              "Saved to:\n" .. dest_path ..
                              "\n\nOpen now with acsm.koplugin?",
                    ok_text = "Open",
                    cancel_text = "Later",
                    ok_callback = function()
                        M._openAcsm(dest_path)
                    end,
                })
            elseif (err and err:find("AUTH_EXPIRED")) or (type(result) == "string" and result:find("AUTH_EXPIRED")) then
                M._handleAuthExpired(plugin_dir)
            else
                local err_str = err or tostring(result or "Unknown error")
                UIManager:show(ConfirmBox:new{
                    text    = "Download failed:\n" .. err_str ..
                              "\n\nIf you see a 403 error, your session may have expired. Try re-authenticating.",
                    ok_text = "Retry",
                    cancel_text = "Cancel",
                    ok_callback = function()
                        M._doDownload(loan, dest_path, base_dir, cfg, plugin_dir, after_download_fn)
                    end,
                })
            end
        end
    )
end

-- Opens a downloaded .acsm file via KOReader's reader (hands off to acsm.koplugin).
function M._openAcsm(path)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI and ReaderUI.showReader then
        ReaderUI:showReader(path)
    else
        -- Try via UIManager event
        local ok2, Event = pcall(require, "ui/event")
        if ok2 then
            UIManager:broadcastEvent(Event:new("SetupShowReader", { file = path }))
        else
            _toast("Could not open file. Please navigate to it in the file browser:\n" .. path, 8)
        end
    end
end

-- ---------------------------------------------------------------------------
-- About Screen
-- ---------------------------------------------------------------------------

function M._showDebugLog()
    local path = log.path()
    local fh = io.open(path, "r")
    local content = nil
    if fh then
        fh:seek("end")
        local size = fh:seek()
        -- Show last 3 KB
        local offset = math.max(0, size - 3072)
        fh:seek("set", offset)
        local raw_content = fh:read("*a")
        fh:close()
        if raw_content and raw_content ~= "" then
            -- Prepend truncation message if we started reading after the beginning
            if offset > 0 then
                content = "... (truncated)\n" .. raw_content
            else
                content = raw_content
            end
        end
    end

    if not content then
        content = "No log file found yet at:\n" .. path .. "\n\nTry performing some actions first."
    end

    UIManager:show(ConfirmBox:new{
        text    = "Libbee Debug Log\n\n" .. content,
        ok_text = "Close",
    })
end

function M.showAbout(plugin_dir)
    local State   = require(plugin_path .. "libbee_state")
    local Updater = require(plugin_path .. "libbee_updater")

    -- Load current version
    local meta_path = plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    local version = (ok and meta and meta.version) or "unknown"

    -- Auth status
    local auth_status
    if State.isAuthenticated() then
        local lib_name = State.getLibraryName()
        auth_status = "✓ Connected" .. (lib_name and (" — " .. lib_name) or "")
    else
        local cfg = _loadConfig(plugin_dir)
        if cfg.bearer_token and cfg.bearer_token ~= "" then
            auth_status = "Manual Bearer token (config)"
        else
            auth_status = "✗ Not authenticated"
        end
    end

    local body = "Libbee v" .. version ..
        "\n\nBrowse your Libby shelf and download ebook loans directly to KOReader." ..
        "\n\nStatus: " .. auth_status ..
        "\n\nRequires acsm.koplugin to open downloaded .acsm files." ..
        "\n\nThis plugin uses Libby's unofficial API in the same way Kobo eReaders do natively." ..
        "\n\nDebug log path:\n" .. log.path()

    UIManager:show(ConfirmBox:new{
        text        = body,
        ok_text     = "Check for Updates",
        cancel_text = "Re-authenticate",
        other_buttons = {
            {{ text = "View Debug Log", callback = function() M._showDebugLog() end }},
            {{ text = "Close" }},
        },
        ok_callback = function()
            Updater.checkForUpdates(false)
        end,
        cancel_callback = function()
            State.clearChipIdentity()
            State.clearShelfCache()
            _toast("Session cleared. Use Setup to re-authenticate.", 4)
            UIManager:scheduleIn(1, function()
                M.showSetupDialog(plugin_dir, nil)
            end)
        end,
    })
end

return M
