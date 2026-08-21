-- libbee_updater.lua — Libbee OTA Updater
-- Checks GitHub Releases for a newer version and installs it.
-- Adapted directly from xray_updater.lua (proven pattern).
--
-- SETUP: Replace GITHUB_OWNER with your GitHub username once the repo is created.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local logger      = require("logger")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local ok_loc, Localization = pcall(require, plugin_path .. "localization_libbee")
if not ok_loc or not Localization then
    ok_loc, Localization = pcall(require, "localization_libbee")
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end

-- ---------------------------------------------------------------------------
-- Configuration — UPDATE THESE WHEN REPO IS CREATED
-- ---------------------------------------------------------------------------
local GITHUB_OWNER = "ultimatejimmy"
local GITHUB_REPO  = "libbee"
local ASSET_NAME   = "libbee.koplugin.zip"

-- Cache validity (seconds). Prevents hammering GitHub API on every open.
local CACHE_TTL    = 3600  -- 1 hour

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

local M = {}

local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/mnt/us/extensions/libbee.koplugin"

local function _apiUrl(use_beta)
    return string.format(
        "https://api.github.com/repos/%s/%s/releases",
        GITHUB_OWNER, GITHUB_REPO
    )
end

local function _cacheFile(use_beta)
    local suffix = use_beta and "_beta" or ""
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        return DS:getSettingsDir() .. "/libbee_update_cache" .. suffix .. ".json"
    end
    return "/tmp/libbee_update_cache" .. suffix .. ".json"
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function _loadCache(use_beta)
    if CACHE_TTL <= 0 then return nil end
    local path = _cacheFile(use_beta)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok_d, data = pcall(json.decode, raw)
    if not ok_d or type(data) ~= "table" then return nil end
    if (os.time() - (data.timestamp or 0)) > CACHE_TTL then return nil end
    return data.payload
end

local function _saveCache(payload, use_beta)
    if CACHE_TTL <= 0 then return end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return end
    local ok_e, encoded = pcall(json.encode, { timestamp = os.time(), payload = payload })
    if not ok_e then return end
    local fh = io.open(_cacheFile(use_beta), "w")
    if fh then fh:write(encoded); fh:close() end
end

local function _clearCache(use_beta)
    pcall(os.remove, _cacheFile(use_beta))
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _currentVersion()
    local meta_path = _plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "0.0.0"
end

local function _versionLessThan(a, b)
    local function parts(v)
        local t_parts = {}
        if not v then return t_parts end
        for n in v:gmatch("(%d+)") do t_parts[#t_parts + 1] = tonumber(n) end
        return t_parts
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local va = pa[i] or 0
        local vb = pb[i] or 0
        if va < vb then return true end
        if va > vb then return false end
    end
    return false
end

local function _toast(msg, timeout, opts)
    local ok_ui, UI = pcall(require, plugin_path .. "libbee_ui")
    if not ok_ui or not UI then
        ok_ui, UI = pcall(require, "libbee_ui")
    end
    if ok_ui and UI and (UI.showToast or UI._toast) then
        return (UI.showToast or UI._toast)(msg, timeout, opts)
    end
    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_im and InfoMessage then
        local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
        UIManager:show(w)
        return w
    end
end

local function _closeWidget(w)
    if w then
        if w.close then
            w:close()
        else
            UIManager:close(w, "ui")
        end
    end
end

-- ---------------------------------------------------------------------------
-- HTTP (Manual Redirect Following)
-- ---------------------------------------------------------------------------

local function _httpGet(url)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local https_ok, https = pcall(require, "ssl.https")
    local ltn12  = require("ltn12")

    local current_url = url
    local redirect_count = 0
    local max_redirects = 5

    while redirect_count < max_redirects do
        local chunks = {}
        local is_https = current_url:match("^https://") ~= nil
        local http_req = (is_https and https_ok) and https or http

        if ok_su then
            socketutil:set_timeout(
                socketutil.LARGE_BLOCK_TIMEOUT,
                socketutil.LARGE_TOTAL_TIMEOUT
            )
        end

        local params = {
            url      = current_url,
            method   = "GET",
            headers  = {
                ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader-Libbee-Updater/1.0)",
                ["Accept"]     = "application/vnd.github.v3+json",
            },
            sink     = ltn12.sink.table(chunks),
        }
        if not is_https then params.redirect = true end

        local ok_pcall, req_ok, code, headers = pcall(http_req.request, params)
        if ok_su then socketutil:reset_timeout() end

        local res_code = tonumber(code) or tonumber(req_ok) or 0
        if ok_pcall and (res_code == 301 or res_code == 302 or res_code == 303 or res_code == 307 or res_code == 308) then
            local location = (type(headers) == "table") and (headers.location or headers.Location)
            if location and location ~= "" then
                current_url = location
                redirect_count = redirect_count + 1
            else
                break
            end
        elseif ok_pcall and res_code == 200 then
            return table.concat(chunks)
        else
            if not ok_pcall then
                return nil, "network error (" .. tostring(req_ok) .. ")"
            end
            return nil, string.format("HTTP %s", tostring(res_code > 0 and res_code or code))
        end
    end

    return nil, "HTTP request failed (too many redirects or not found)"
end

local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local https_ok, https = pcall(require, "ssl.https")
    local ltn12  = require("ltn12")

    local current_url = url
    local redirect_count = 0
    local max_redirects = 5

    while redirect_count < max_redirects do
        local response_body = {}
        local is_https = current_url:match("^https://") ~= nil
        local http_req = (is_https and https_ok) and https or http

        if ok_su then
            socketutil:set_timeout(
                socketutil.FILE_BLOCK_TIMEOUT,
                socketutil.FILE_TOTAL_TIMEOUT
            )
        end

        local params = {
            url      = current_url,
            method   = "GET",
            headers  = {
                ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader-Libbee-Updater/1.0)",
            },
            sink     = ltn12.sink.table(response_body),
        }
        if not is_https then params.redirect = true end

        local ok_pcall, req_ok, code, headers = pcall(http_req.request, params)
        if ok_su then socketutil:reset_timeout() end

        local res_code = tonumber(code) or tonumber(req_ok) or 0
        if ok_pcall and (res_code == 301 or res_code == 302 or res_code == 303 or res_code == 307 or res_code == 308) then
            local location = (type(headers) == "table") and (headers.location or headers.Location)
            if location and location ~= "" then
                current_url = location
                redirect_count = redirect_count + 1
            else
                break
            end
        elseif ok_pcall and res_code == 200 then
            local target = io.open(dest_path, "wb")
            if not target then
                return false, "Could not open target file for writing"
            end
            for _, chunk in ipairs(response_body) do
                target:write(chunk)
            end
            target:close()
            return true
        else
            if not ok_pcall then
                pcall(os.remove, dest_path)
                return false, "network error (" .. tostring(req_ok) .. ")"
            end
            pcall(os.remove, dest_path)
            return false, string.format("HTTP %s", tostring(res_code > 0 and res_code or code))
        end
    end

    pcall(os.remove, dest_path)
    return false, "HTTP request failed (too many redirects)"
end

-- ---------------------------------------------------------------------------
-- Release parsing
-- ---------------------------------------------------------------------------

local function _parseRelease(body, use_beta)
    local ok_j, json = pcall(require, "json")
    if not ok_j then
        -- Regex fallback
        local tag = body:match('"tag_name"%s*:%s*"([^"]*)"')
        if not tag then return { up_to_date = true } end
        local download_url = body:match(
            '"browser_download_url"%s*:%s*"([^"]*' .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
        )
        return { version = tag:match("v?(.*)"), download_url = download_url }
    end

    local ok_d, data = pcall(json.decode, body)
    if not ok_d or type(data) ~= "table" then
        return nil, "JSON parse error: " .. tostring(data)
    end

    if data.message and not data.tag_name and not data[1] then
        if data.message == "Not Found" then
            return { up_to_date = true }
        end
        return nil, "GitHub API error: " .. tostring(data.message)
    end

    local release_data = nil
    if type(data) == "table" and data[1] then
        if use_beta then
            release_data = data[1]
        else
            for _, r in ipairs(data) do
                if not r.prerelease and not r.draft then
                    release_data = r
                    break
                end
            end
            if not release_data then
                release_data = data[1]
            end
        end
    elseif data.tag_name then
        release_data = data
    else
        return { up_to_date = true }
    end

    if not release_data or not release_data.tag_name then
        return { up_to_date = true }
    end

    local tag = release_data.tag_name

    local download_url = nil
    for _, asset in ipairs(release_data.assets or {}) do
        if type(asset.name) == "string" and asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end

    local notes = release_data.body
    if notes and notes ~= "" then
        notes = notes:gsub("#+%s*", "")
        notes = notes:gsub("%*%*(.-)%*%*", "%1")
        notes = notes:gsub("`(.-)`", "%1")
        notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
        if #notes > 600 then notes = notes:sub(1, 597) .. "..." end
        notes = notes:match("^%s*(.-)%s*$")
    end

    return {
        version      = tag:match("v?(.*)"),
        download_url = download_url,
        notes        = (notes and notes ~= "") and notes or nil,
        html_url     = release_data.html_url,
    }
end

-- ---------------------------------------------------------------------------
-- Unzip
-- ---------------------------------------------------------------------------

local function _unzip(zip_path, dest_dir)
    local cmd = string.format("unzip -o -q %q -d %q", zip_path, dest_dir)
    local ret = os.execute(cmd)
    if ret ~= 0 and ret ~= true then
        return nil, "unzip failed (exit " .. tostring(ret) .. ")"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Download & Install
-- ---------------------------------------------------------------------------

local function _tmpZipPath()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then return DS:getSettingsDir() .. "/libbee_update.zip" end
    return "/tmp/libbee_update.zip"
end

local function _applyUpdate(download_url, new_version)
    local tmp_zip    = _tmpZipPath()
    local parent_dir = _plugin_dir:match("^(.+)/[^/]+$") or _plugin_dir

    local progress_msg = _toast(_("Downloading Libbee v%s…", new_version), 120)

    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function doDownloadAndInstall()
        -- 1. Download
        local dl_ok, dl_err = _httpGetToFile(download_url, tmp_zip)
        if not dl_ok then return { success = false, stage = "download", err = dl_err } end

        -- 2. Unzip
        local uz_ok, uz_err = _unzip(tmp_zip, parent_dir)
        pcall(os.remove, tmp_zip)
        if not uz_ok then return { success = false, stage = "unzip", err = uz_err } end

        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err   = result and result.err   or "unknown error"
            logger.err("libbee updater: failed at " .. stage .. ": " .. err)
            if stage == "download" then
                _toast(_("Download failed: %s", tostring(err)))
            else
                _toast(_("Install failed (unzip): %s", tostring(err)))
            end
            return
        end
        _clearCache(true)
        _clearCache(false)
        local ok_ui, UI = pcall(require, plugin_path .. "libbee_ui")
        if ok_ui and UI and UI.showCardDialog then
            UI.showCardDialog{
                title = _("Update Installed"),
                body_text = _("Libbee has been updated to v%s.\n\nRestart KOReader now to apply the changes?", new_version),
                buttons = {
                    {
                        text = _("Restart Now"),
                        is_primary = true,
                        callback = function() UIManager:restartKOReader() end,
                    },
                    {
                        text = _("Later"),
                    }
                }
            }
        else
            UIManager:show(ConfirmBox:new{
                text        = _("Libbee updated to v%s. Restart KOReader to apply?", new_version),
                ok_text     = _("Restart Now"),
                cancel_text = _("Later"),
                ok_callback = function() UIManager:restartKOReader() end,
            })
        end
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doDownloadAndInstall,
            progress_msg,
            function(res) handleInstallResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleInstallResult(result) end)
        elseif completed == false then
            _closeWidget(progress_msg)
            pcall(os.remove, tmp_zip)
            _toast(_("Update cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleInstallResult(doDownloadAndInstall())
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Version Check
-- ---------------------------------------------------------------------------

local function _showUpdateDialog(release, current)
    if release.up_to_date or not release.version or not _versionLessThan(current, release.version) then
        logger.info("libbee updater: up to date (" .. current .. ")")
        _toast(_("Libbee is up to date (v%s)", current))
        return
    end

    local latest       = release.version
    local download_url = release.download_url
    local notes        = release.notes

    logger.info("libbee updater: new version available: " .. latest)

    local header = _("Libbee v%s is available (current: v%s).", latest, current)
    local notes_block = notes and ("\n\n" .. _("What's new:") .. "\n" .. notes) or ""

    local ok_ui, UI = pcall(require, plugin_path .. "libbee_ui")

    if not download_url then
        if ok_ui and UI and UI.showCardDialog then
            UI.showCardDialog{
                title = _("Update Available"),
                body_text = header .. notes_block .. "\n\n" .. _("No automatic download asset found. Visit GitHub to update manually."),
                buttons = {
                    {
                        text = _("Open GitHub"),
                        is_primary = true,
                        callback = function()
                            local Device = require("device")
                            if Device:canOpenLink() then
                                Device:openLink(string.format(
                                    "https://github.com/%s/%s/releases/latest",
                                    GITHUB_OWNER, GITHUB_REPO
                                ))
                            end
                        end,
                    },
                    {
                        text = _("Cancel"),
                    }
                }
            }
        else
            UIManager:show(ConfirmBox:new{
                text        = header .. notes_block .. "\n\n" .. _("No automatic download asset found. Visit GitHub to update manually."),
                ok_text     = _("Open GitHub"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    local Device = require("device")
                    if Device:canOpenLink() then
                        Device:openLink(string.format(
                            "https://github.com/%s/%s/releases/latest",
                            GITHUB_OWNER, GITHUB_REPO
                        ))
                    end
                end,
            })
        end
        return
    end

    if ok_ui and UI and UI.showCardDialog then
        UI.showCardDialog{
            title = _("Update Available"),
            body_text = header .. notes_block .. "\n\n" .. _("Download and install now?"),
            buttons = {
                {
                    text = _("Update Now"),
                    is_primary = true,
                    callback = function() _applyUpdate(download_url, latest) end,
                },
                {
                    text = _("Cancel"),
                }
            }
        }
    else
        UIManager:show(ConfirmBox:new{
            text        = header .. notes_block .. "\n\n" .. _("Download and install now?"),
            ok_text     = _("Update"),
            cancel_text = _("Cancel"),
            ok_callback = function() _applyUpdate(download_url, latest) end,
        })
    end
end

local function _doFetch(use_beta)
    local cached = _loadCache(use_beta)
    if cached then
        logger.info("libbee updater: using cached release info")
        return cached
    end
    local body, err = _httpGet(_apiUrl(use_beta))
    if not body then
        if err and err:find("404") then
            return { up_to_date = true }
        end
        return { error = err }
    end
    local release, parse_err = _parseRelease(body, use_beta)
    if not release then return { error = "parse error: " .. tostring(parse_err) } end
    _saveCache(release, use_beta)
    return release
end

function M._doCheckForUpdates(current, use_beta)
    local checking_msg = _toast(_("Checking for Libbee updates…"), 15)
    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast(_("Update check failed."))
            return
        end
        if release.error then
            logger.err("libbee updater: check error: " .. release.error)
            _toast(_("Update check error: %s", tostring(release.error)))
            return
        end
        _showUpdateDialog(release, current)
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            function() return _doFetch(use_beta) end,
            checking_msg,
            function(res) handleCheckResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleCheckResult(result) end)
        elseif completed == false then
            _closeWidget(checking_msg)
            _toast(_("Update check cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleCheckResult(_doFetch(use_beta))
        end)
    end
end

-- Main entry point: check for updates (user-initiated).
function M.checkForUpdates(use_beta)
    local current = _currentVersion()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function()
            M._doCheckForUpdates(current, use_beta)
        end)
        return
    end
    M._doCheckForUpdates(current, use_beta)
end

-- Silent weekly check (called from init).
function M.checkSilentForUpdates(use_beta)
    local current = _currentVersion()
    local release = _doFetch(use_beta)
    if release and not release.error then
        if _versionLessThan(current, release.version) then
            _showUpdateDialog(release, current)
        end
    end
end

return M
