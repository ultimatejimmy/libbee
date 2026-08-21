-- libbee_state.lua — Persistent State Manager
-- Stores chip identity, pending setup tokens, shelf cache, and UI preferences in DataStorage.

local logger = require("logger")

local M = {}

local SECONDS_PER_DAY = 24 * 60 * 60

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function _stateDir()
    local ok, DS = pcall(require, "datastorage")
    local base = "/tmp"
    if ok and DS and DS.getSettingsDir then
        local s = DS:getSettingsDir()
        if s and s ~= "" then base = s end
    end
    local dir = base .. "/libbee"
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    if lfs_ok and lfs and lfs.mkdir then
        pcall(lfs.mkdir, base)
        pcall(lfs.mkdir, dir)
    end
    pcall(os.execute, "mkdir -p " .. dir .. " 2>/dev/null")
    return dir
end

local function _statePath()
    return _stateDir() .. "/state.json"
end

local function _shelfCachePath()
    return _stateDir() .. "/shelf_cache.json"
end

-- ---------------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------------

local function _readJson(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, data = pcall(rapidjson.decode, raw)
        if ok and type(data) == "table" then return data end
    end
    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then return data end
    end
    return nil
end

local function _writeJson(path, data)
    local encoded = nil
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, res = pcall(rapidjson.encode, data)
        if ok and type(res) == "string" then encoded = res end
    end
    if not encoded then
        local ok_j, json = pcall(require, "json")
        if ok_j and json then
            local ok, res = pcall(json.encode, data)
            if ok and type(res) == "string" then encoded = res end
        end
    end
    if not encoded then
        logger.warn("libbee state: json encoder unavailable, cannot save state")
        return false
    end
    local fh = io.open(path, "w")
    if not fh then
        logger.warn("libbee state: cannot write to " .. tostring(path))
        return false
    end
    fh:write(encoded)
    fh:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Chip Identity & Setup State
-- ---------------------------------------------------------------------------

function M.getChipIdentity()
    local data = _readJson(_statePath())
    if data and type(data.chip_identity) == "string" and data.chip_identity ~= "" then
        return data.chip_identity
    end
    return nil
end

function M.saveChipIdentity(chip_identity, library_name, cards)
    local data = _readJson(_statePath()) or {}
    data.chip_identity     = chip_identity
    data.library_name      = library_name or data.library_name or ""
    data.cards             = cards or data.cards
    data.registered_at     = os.time()
    data.pending_identity  = nil
    data.pending_code      = nil
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: chip identity saved")
    end
    return ok
end

function M.getPendingIdentity()
    local data = _readJson(_statePath())
    if data and type(data.pending_identity) == "string" and data.pending_identity ~= "" then
        return data.pending_identity
    end
    return nil
end

function M.savePendingIdentity(pending_identity, pending_code)
    local data = _readJson(_statePath()) or {}
    data.pending_identity = pending_identity
    data.pending_code     = pending_code
    return _writeJson(_statePath(), data)
end

function M.clearPendingIdentity()
    local data = _readJson(_statePath())
    if data and (data.pending_identity or data.pending_code) then
        data.pending_identity = nil
        data.pending_code     = nil
        _writeJson(_statePath(), data)
    end
end

function M.clearChipIdentity()
    local data = _readJson(_statePath()) or {}
    data.chip_identity     = nil
    data.library_name      = nil
    data.cards             = nil
    data.registered_at     = nil
    data.pending_identity  = nil
    data.pending_code      = nil
    _writeJson(_statePath(), data)
    logger.info("libbee state: chip identity cleared")
end

function M.getLibraryName()
    local data = _readJson(_statePath())
    return data and data.library_name or nil
end

function M.getCards()
    local data = _readJson(_statePath())
    return data and data.cards or nil
end

function M.isAuthenticated()
    return M.getChipIdentity() ~= nil
end

-- ---------------------------------------------------------------------------
-- DRM & ByteBooks Activation State
-- ---------------------------------------------------------------------------

function M.getDrmActivation()
    local data = _readJson(_statePath())
    return data and data.drm_activation or nil
end

function M.saveDrmActivation(activation_blob, mode, email)
    local data = _readJson(_statePath()) or {}
    data.drm_activation = activation_blob
    data.drm_mode       = mode or "anonymous"
    data.drm_email      = email or ""
    data.drm_updated_at = os.time()
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: DRM activation saved (mode=" .. tostring(data.drm_mode) .. ")")
    end
    return ok
end

function M.getDrmAccountInfo()
    local data = _readJson(_statePath())
    local activated = (data and data.drm_activation ~= nil)
    return {
        activated = activated,
        mode      = (data and data.drm_mode) or "anonymous",
        email     = (data and data.drm_email) or "",
        updated_at = data and data.drm_updated_at or nil,
    }
end

function M.clearDrmActivation()
    local data = _readJson(_statePath()) or {}
    data.drm_activation = nil
    data.drm_mode       = nil
    data.drm_email      = nil
    data.drm_updated_at = nil
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: DRM activation cleared")
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- UI Preferences
-- ---------------------------------------------------------------------------

function M.getViewMode()
    local data = _readJson(_statePath())
    if data and (data.view_mode == "cover" or data.view_mode == "list") then
        return data.view_mode
    end
    return "list"
end

function M.saveViewMode(view_mode)
    local data = _readJson(_statePath()) or {}
    data.view_mode = (view_mode == "cover") and "cover" or "list"
    return _writeJson(_statePath(), data)
end

-- ---------------------------------------------------------------------------
-- Download Directory Settings
-- ---------------------------------------------------------------------------

function M.getDefaultDownloadDir()
    local ok_api, API = pcall(require, "libbee_api")
    if ok_api and API and API.getDefaultDownloadDir then
        return API.getDefaultDownloadDir()
    end
    return "/tmp/Libby"
end

function M.getCustomDownloadDir(plugin_dir)
    local data = _readJson(_statePath())
    local custom = data and data.download_dir
    if not custom or custom == "" then
        if plugin_dir and plugin_dir ~= "" then
            local ok_cfg, cfg = pcall(dofile, plugin_dir .. "/libbee_config.lua")
            if ok_cfg and type(cfg) == "table" and cfg.download_dir and cfg.download_dir ~= "" then
                custom = cfg.download_dir
            end
        end
    end
    if custom and custom ~= "" then
        local clean = tostring(custom):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
        local def = M.getDefaultDownloadDir():gsub("[/\\]+$", "")
        if clean ~= "" and clean ~= def then
            return clean
        end
    end
    return nil
end

function M.isCustomDownloadDir(plugin_dir)
    return M.getCustomDownloadDir(plugin_dir) ~= nil
end

function M.getDownloadDir(plugin_dir)
    local custom = M.getCustomDownloadDir(plugin_dir)
    if custom and custom ~= "" then
        return custom
    end
    return M.getDefaultDownloadDir()
end

function M.setCustomDownloadDir(path)
    local data = _readJson(_statePath()) or {}
    if not path or path:match("^%s*$") then
        return M.resetCustomDownloadDir()
    end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    local def = M.getDefaultDownloadDir():gsub("[/\\]+$", "")
    if clean == "" or clean == def then
        return M.resetCustomDownloadDir()
    end

    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    if lfs_ok and lfs and lfs.attributes and not lfs.attributes(clean) then
        pcall(function() lfs.mkdir(clean) end)
    end

    data.download_dir = clean
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: custom download_dir set to " .. clean)
    end
    return ok
end

function M.resetCustomDownloadDir()
    local data = _readJson(_statePath()) or {}
    data.download_dir = nil
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: reset download_dir to default")
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Date / Loan helpers
-- ---------------------------------------------------------------------------

local function date_ordinal(year, month, day)
    if month <= 2 then
        year = year - 1
        month = month + 12
    end
    return 365 * year
        + math.floor(year / 4)
        - math.floor(year / 100)
        + math.floor(year / 400)
        + math.floor((153 * (month - 3) + 2) / 5)
        + day
end

function M.loanDaysRemaining(loan, now_timestamp)
    if type(loan) ~= "table" then return nil end
    local expire = loan.expireTimestamp or loan.expires or loan.expireDate
    if type(expire) == "number" then
        local seconds = expire - (now_timestamp or os.time())
        if seconds <= 0 then return 0 end
        return math.ceil(seconds / SECONDS_PER_DAY)
    end
    if type(expire) == "string" then
        local year, month, day = expire:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if year then
            year, month, day = tonumber(year), tonumber(month), tonumber(day)
            local now = os.date("!*t", now_timestamp or os.time())
            local remaining = date_ordinal(year, month, day) - date_ordinal(now.year, now.month, now.day)
            return remaining < 0 and 0 or remaining
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Shelf Cache
-- ---------------------------------------------------------------------------

local SHELF_CACHE_TTL = 7 * 24 * 60 * 60 -- 7 days

function M.getShelfCache(allow_stale)
    local data = _readJson(_shelfCachePath())
    if not data or type(data.shelf) ~= "table" then return nil end
    if not allow_stale and (os.time() - (data.timestamp or 0)) > SHELF_CACHE_TTL then
        logger.info("libbee state: shelf cache expired")
        return nil
    end
    return data.shelf
end

function M.saveShelfCache(shelf)
    _writeJson(_shelfCachePath(), {
        timestamp = os.time(),
        shelf     = shelf,
    })
end

function M.clearShelfCache()
    pcall(os.remove, _shelfCachePath())
end

return M
