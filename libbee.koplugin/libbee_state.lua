-- libbee_state.lua — Persistent State Manager
-- Stores chip identity and optional shelf cache in DataStorage (survives updates).
-- The chip identity lives OUTSIDE the plugin zip so OTA updates never wipe auth.

local logger = require("logger")

local M = {}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function _stateDir()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        local dir = DS:getSettingsDir() .. "/libbee"
        -- Ensure the directory exists
        local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
        if lfs_ok and lfs and lfs.attributes(dir) == nil then
            pcall(lfs.mkdir, dir)
        end
        return dir
    end
    return "/tmp/libbee"
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
    local ok, json = pcall(require, "json")
    if not ok then return nil end
    local ok2, data = pcall(json.decode, raw)
    if not ok2 or type(data) ~= "table" then return nil end
    return data
end

local function _writeJson(path, data)
    local ok, json = pcall(require, "json")
    if not ok then
        logger.warn("libbee state: json module unavailable, cannot save state")
        return false
    end
    local ok2, encoded = pcall(json.encode, data)
    if not ok2 then
        logger.warn("libbee state: json encode failed: " .. tostring(encoded))
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
-- Chip Identity (long-term auth token)
-- ---------------------------------------------------------------------------

-- Returns the stored chip identity string, or nil if not set.
function M.getChipIdentity()
    local data = _readJson(_statePath())
    if data and type(data.chip_identity) == "string" and data.chip_identity ~= "" then
        return data.chip_identity
    end
    return nil
end

-- Saves the chip identity returned by the clone/setup endpoint.
-- chip_identity: the raw chip token string from the API response
-- library_name:  human-readable library name (optional, for display)
function M.saveChipIdentity(chip_identity, library_name)
    local data = _readJson(_statePath()) or {}
    data.chip_identity = chip_identity
    data.library_name  = library_name or data.library_name or ""
    data.registered_at = os.time()
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: chip identity saved")
    end
    return ok
end

-- Clears the chip identity (forces re-authentication).
function M.clearChipIdentity()
    local data = _readJson(_statePath()) or {}
    data.chip_identity = nil
    data.registered_at = nil
    _writeJson(_statePath(), data)
    logger.info("libbee state: chip identity cleared")
end

-- Returns a human-readable library name if stored.
function M.getLibraryName()
    local data = _readJson(_statePath())
    return data and data.library_name or nil
end

-- Returns true if the chip identity is set.
function M.isAuthenticated()
    return M.getChipIdentity() ~= nil
end

-- ---------------------------------------------------------------------------
-- Shelf Cache (short-lived, speeds up re-opens)
-- ---------------------------------------------------------------------------

local SHELF_CACHE_TTL = 15 * 60 -- 15 minutes

-- Returns cached shelf data if fresh, else nil.
function M.getShelfCache()
    local data = _readJson(_shelfCachePath())
    if not data then return nil end
    if (os.time() - (data.timestamp or 0)) > SHELF_CACHE_TTL then
        logger.info("libbee state: shelf cache expired")
        return nil
    end
    return data.shelf
end

-- Saves the fetched shelf (array of loan tables) to the cache.
function M.saveShelfCache(shelf)
    _writeJson(_shelfCachePath(), {
        timestamp = os.time(),
        shelf     = shelf,
    })
end

-- Invalidates the shelf cache (call after a download or on user request).
function M.clearShelfCache()
    pcall(os.remove, _shelfCachePath())
end

return M
