-- libbee_updater.lua — Libbee OTA Updater
-- Checks GitHub Releases for a newer version and installs it.
-- Adapted directly from xray_updater.lua (proven pattern).
--
-- SETUP: Replace GITHUB_OWNER with your GitHub username once the repo is created.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local logger      = require("logger")

-- ---------------------------------------------------------------------------
-- Configuration — UPDATE THESE WHEN REPO IS CREATED
-- ---------------------------------------------------------------------------
local GITHUB_OWNER = "PLACEHOLDER_OWNER"    -- ← Replace with your GitHub username
local GITHUB_REPO  = "libbee"               -- ← Replace if you name the repo differently
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
    if use_beta then
        return string.format(
            "https://api.github.com/repos/%s/%s/releases",
            GITHUB_OWNER, GITHUB_REPO
        )
    end
    return string.format(
        "https://api.github.com/repos/%s/%s/releases/latest",
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

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

local function _httpGet(url)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local https_ok, https = pcall(require, "ssl.https")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    -- Use https for github.com
    local impl = (https_ok and url:sub(1,8) == "https://") and https or http

    if ok_su then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local chunks = {}
    local code, headers, status = socket.skip(1, impl.request({
        url      = url,
        method   = "GET",
        headers  = {
            ["User-Agent"] = "KOReader-Libbee-Updater/1.0",
            ["Accept"]     = "application/vnd.github.v3+json",
        },
        sink     = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return table.concat(chunks) end
    return nil, string.format("HTTP %s", tostring(code))
end

local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local https_ok, https = pcall(require, "ssl.https")
    local ltn12  = require("ltn12")
    local socket = require("socket")
    local impl = (https_ok and url:sub(1,8) == "https://") and https or http

    local fh, err_open = io.open(dest_path, "wb")
    if not fh then return nil, "Could not create file: " .. tostring(err_open) end

    if ok_su then
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT
        )
    end

    local code, headers, status = socket.skip(1, impl.request({
        url      = url,
        method   = "GET",
        headers  = { ["User-Agent"] = "KOReader-Libbee-Updater/1.0" },
        sink     = ltn12.sink.file(fh),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        pcall(os.remove, dest_path)
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return true end
    pcall(os.remove, dest_path)
    return nil, string.format("HTTP %s", tostring(code))
end

-- ---------------------------------------------------------------------------
-- Release parsing
-- ---------------------------------------------------------------------------

local function _parseRelease(body, use_beta)
    local ok_j, json = pcall(require, "json")
    if not ok_j then
        -- Regex fallback
        local tag = body:match('"tag_name"%s*:%s*"([^"]*)"')
        if not tag then return nil, "could not parse tag_name" end
        local download_url = body:match(
            '"browser_download_url"%s*:%s*"([^"]*' .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
        )
        return { version = tag:match("v?(.*)"), download_url = download_url }
    end

    local ok_d, data = pcall(json.decode, body)
    if not ok_d or type(data) ~= "table" then
        return nil, "JSON parse error: " .. tostring(data)
    end

    if data.message and not data.tag_name and not (use_beta and data[1]) then
        return nil, "GitHub API error: " .. tostring(data.message)
    end

    local release_data = data
    if use_beta then
        if type(data) == "table" and data[1] then
            release_data = data[1]
        else
            return nil, "No releases found"
        end
    end

    local tag = release_data.tag_name
    if not tag then return nil, "tag_name missing from API response" end

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

    local progress_msg = _toast("Downloading Libbee v" .. new_version .. "…", 120)

    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function doDownloadAndInstall()
        -- 1. Save user config values before overwrite
        local config_path  = _plugin_dir .. "/libbee_config.lua"
        local saved = {}
        local ok_cfg, cfg = pcall(dofile, config_path)
        if ok_cfg and type(cfg) == "table" then
            saved.library_id   = cfg.library_id
            saved.card_number  = cfg.card_number
            saved.bearer_token = cfg.bearer_token
            saved.download_dir = cfg.download_dir
            -- Note: setup_code is intentionally NOT saved — it's single-use
        end

        -- 2. Download
        local dl_ok, dl_err = _httpGetToFile(download_url, tmp_zip)
        if not dl_ok then return { success = false, stage = "download", err = dl_err } end

        -- 3. Unzip
        local uz_ok, uz_err = _unzip(tmp_zip, parent_dir)
        os.remove(tmp_zip)
        if not uz_ok then return { success = false, stage = "unzip", err = uz_err } end

        -- 4. Smart merge: restore user config into new file
        if saved.library_id or saved.card_number or saved.bearer_token or saved.download_dir then
            local nfh = io.open(config_path, "r")
            if nfh then
                local content = nfh:read("*a")
                nfh:close()
                local function restore(content, key, val)
                    if val and val ~= "" then
                        content = content:gsub(
                            key .. '%s*=%s*""',
                            key .. ' = "' .. val:gsub('["\\]', '\\%0') .. '"'
                        )
                    end
                    return content
                end
                content = restore(content, "library_id",   saved.library_id)
                content = restore(content, "card_number",  saved.card_number)
                content = restore(content, "bearer_token", saved.bearer_token)
                content = restore(content, "download_dir", saved.download_dir)
                local outh = io.open(config_path, "w")
                if outh then outh:write(content); outh:close() end
            end
        end

        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err   = result and result.err   or "unknown error"
            logger.err("libbee updater: failed at " .. stage .. ": " .. err)
            if stage == "download" then
                _toast("Download failed: " .. tostring(err))
            else
                _toast("Install failed (unzip): " .. tostring(err))
            end
            return
        end
        _clearCache(true)
        _clearCache(false)
        UIManager:show(ConfirmBox:new{
            text        = "Libbee updated to v" .. new_version .. ". Restart KOReader to apply?",
            ok_text     = "Restart Now",
            cancel_text = "Later",
            ok_callback = function() UIManager:restartKOReader() end,
        })
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
            _toast("Update cancelled.")
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
    local latest       = release.version
    local download_url = release.download_url
    local notes        = release.notes

    if not _versionLessThan(current, latest) then
        logger.info("libbee updater: up to date (" .. current .. ")")
        _toast("Libbee is up to date (v" .. current .. ")")
        return
    end

    logger.info("libbee updater: new version available: " .. latest)

    local header = "Libbee v" .. latest .. " is available (current: v" .. current .. ")."
    local notes_block = notes and ("\n\nWhat's new:\n" .. notes) or ""

    if not download_url then
        UIManager:show(ConfirmBox:new{
            text        = header .. notes_block .. "\n\nNo download asset found. Visit GitHub to update manually.",
            ok_text     = "Open GitHub",
            cancel_text = "Cancel",
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
        return
    end

    UIManager:show(ConfirmBox:new{
        text        = header .. notes_block .. "\n\nDownload and install now?",
        ok_text     = "Update",
        cancel_text = "Cancel",
        ok_callback = function() _applyUpdate(download_url, latest) end,
    })
end

local function _doFetch(use_beta)
    local cached = _loadCache(use_beta)
    if cached then
        logger.info("libbee updater: using cached release info")
        return cached
    end
    local body, err = _httpGet(_apiUrl(use_beta))
    if not body then return { error = err } end
    local release, parse_err = _parseRelease(body, use_beta)
    if not release then return { error = "parse error: " .. tostring(parse_err) } end
    _saveCache(release, use_beta)
    return release
end

function M._doCheckForUpdates(current, use_beta)
    local checking_msg = _toast("Checking for Libbee updates…", 15)
    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast("Update check failed.")
            return
        end
        if release.error then
            logger.err("libbee updater: check error: " .. release.error)
            _toast("Update check error: " .. tostring(release.error))
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
            _toast("Update check cancelled.")
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
