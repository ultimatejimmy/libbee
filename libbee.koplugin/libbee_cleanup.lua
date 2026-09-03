-- libbee_cleanup.lua — Auto-Delete Deprecated Folders & Duplicate Files
-- Cleans up obsolete folders and duplicate Lua files remaining after updates
-- (e.g. following the flattening of adobe/ and dependencies/ into root).
--
-- IMPORTANT: This script operates STRICTLY within the plugin directory and
-- NEVER touches user logins, tokens, or configuration (stored in state.json).

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger or not logger.info then
    logger = {
        info = function(...) end,
        warn = function(...) end,
        err  = function(...) end,
    }
end

local M = {}

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    return ok_lfs and lfs or nil
end

local function getAttributeMode(path)
    local lfs = getLfs()
    if lfs and lfs.attributes then
        local ok, attr = pcall(lfs.attributes, path, "mode")
        if ok and type(attr) == "string" then
            return attr
        end
        local ok2, tbl = pcall(lfs.attributes, path)
        if ok2 and type(tbl) == "table" and tbl.mode then
            return tbl.mode
        end
    end
    return nil
end

local function fileExists(path)
    if not path or path == "" then return false end
    local mode = getAttributeMode(path)
    if mode then return mode == "file" end
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

local function dirExists(path)
    if not path or path == "" then return false end
    local mode = getAttributeMode(path)
    if mode then return mode == "directory" end
    return false
end

--- Recursively remove a directory and all its contents
local function removeDirectoryRecursive(dir_path)
    if not dir_path or dir_path == "" then return false end
    local lfs = getLfs()

    if lfs and lfs.dir then
        local ok, iter, dir_obj = pcall(lfs.dir, dir_path)
        if ok and iter then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    local sub_path = dir_path .. "/" .. entry
                    local mode = getAttributeMode(sub_path)
                    if mode == "directory" then
                        removeDirectoryRecursive(sub_path)
                    else
                        pcall(os.remove, sub_path)
                    end
                end
            end
        end
    end

    -- Remove the now empty directory
    local removed = pcall(os.remove, dir_path)
    if not removed and lfs and lfs.rmdir then
        removed = pcall(lfs.rmdir, dir_path)
    end

    -- Fallback for Linux/POSIX systems if standard removal failed
    if dirExists(dir_path) then
        pcall(os.execute, string.format('rm -rf "%s" 2>/dev/null', dir_path))
    end

    return not dirExists(dir_path)
end

M._removeDirectoryRecursive = removeDirectoryRecursive

--- Clean deprecated folders and duplicate Lua files in the plugin directory.
--- @param plugin_dir string|nil Path to libbee.koplugin directory
--- @return table { deleted_folders = table, deleted_files = table }
function M.cleanDeprecated(plugin_dir)
    local target_dir = plugin_dir
    if not target_dir or target_dir == "" then
        target_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    end
    if not target_dir or target_dir == "" then
        target_dir = "."
    end

    -- Normalize slashes and strip trailing slash
    target_dir = target_dir:gsub("\\", "/"):gsub("/+$", "")

    local results = {
        deleted_folders = {},
        deleted_files   = {},
    }

    -- Definition of deprecated folders to remove.
    -- Each entry requires a modern replacement file to exist before deletion is allowed.
    local deprecated_dirs = {
        {
            name             = "adobe",
            rel_path         = "adobe",
            replacement_file = "libbee_adobe_core.lua",
        },
        {
            name             = "dependencies",
            rel_path         = "dependencies",
            replacement_file = "libbee_xml2lua.lua",
        },
        {
            name             = "xml2lua",
            rel_path         = "xml2lua",
            replacement_file = "libbee_xml2lua.lua",
        },
        {
            name             = "xmlhandler",
            rel_path         = "xmlhandler",
            replacement_file = "libbee_xmlhandler_dom.lua",
        },
    }

    -- Definition of deprecated / duplicate standalone Lua files to remove.
    local deprecated_files = {
        {
            name             = "localization_libbee.lua",
            rel_path         = "localization_libbee.lua",
            replacement_file = "libbee_localization.lua",
        },
        {
            name             = "libbee_config.lua",
            rel_path         = "libbee_config.lua",
            replacement_file = "libbee_state.lua",
        },
    }

    -- 1. Remove deprecated directories
    for _, item in ipairs(deprecated_dirs) do
        local dir_path = target_dir .. "/" .. item.rel_path
        local replacement_path = target_dir .. "/" .. item.replacement_file

        if dirExists(dir_path) then
            -- Safety check: ensure replacement exists before purging old directory
            if fileExists(replacement_path) then
                logger.info("libbee cleanup: removing deprecated directory " .. dir_path)
                removeDirectoryRecursive(dir_path)
                if not dirExists(dir_path) then
                    table.insert(results.deleted_folders, item.name)
                else
                    logger.warn("libbee cleanup: failed to completely remove " .. dir_path)
                end
            else
                logger.warn("libbee cleanup: skipped removing " .. dir_path ..
                            " because replacement " .. item.replacement_file .. " is missing")
            end
        end
    end

    -- 2. Remove deprecated duplicate files
    for _, item in ipairs(deprecated_files) do
        local file_path = target_dir .. "/" .. item.rel_path
        local replacement_path = target_dir .. "/" .. item.replacement_file

        if fileExists(file_path) then
            -- Safety check: ensure replacement exists before purging old file
            if fileExists(replacement_path) then
                logger.info("libbee cleanup: removing deprecated file " .. file_path)
                pcall(os.remove, file_path)
                if not fileExists(file_path) then
                    table.insert(results.deleted_files, item.name)
                else
                    logger.warn("libbee cleanup: failed to remove " .. file_path)
                end
            else
                logger.warn("libbee cleanup: skipped removing " .. file_path ..
                            " because replacement " .. item.replacement_file .. " is missing")
            end
        end
    end

    -- 3. Clean stale temporary files and partial downloads
    local temp_results = M.cleanTempFiles()
    for _, f in ipairs(temp_results.deleted_files or {}) do
        table.insert(results.deleted_files, f)
    end
    for _, d in ipairs(temp_results.deleted_folders or {}) do
        table.insert(results.deleted_folders, d)
    end

    return results
end

--- Cleans temporary fulfillment files, partial downloads, and stale progress files.
-- Safe to call at startup or immediately after a cancelled/failed download.
--- @param base_dir string|nil Optional user download directory
--- @return table { deleted_files = table, deleted_folders = table }
function M.cleanTempFiles(base_dir)
    local results = {
        deleted_files = {},
        deleted_folders = {},
    }

    local lfs = getLfs()
    if not lfs or not lfs.dir then return results end

    local function scanAndPurge(dir_path, file_pred, dir_pred)
        if not dirExists(dir_path) then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir_path)
        if not ok or not iter then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local full_path = dir_path .. "/" .. entry
                local mode = getAttributeMode(full_path)
                if mode == "directory" and dir_pred and dir_pred(entry) then
                    logger.info("libbee cleanup: removing temp directory " .. full_path)
                    if removeDirectoryRecursive(full_path) then
                        table.insert(results.deleted_folders, entry)
                    end
                elseif (mode == "file" or not mode) and file_pred and file_pred(entry) then
                    logger.info("libbee cleanup: removing temp file " .. full_path)
                    local rm_ok = pcall(os.remove, full_path)
                    if rm_ok and not fileExists(full_path) then
                        table.insert(results.deleted_files, entry)
                    end
                end
            end
        end
    end

    -- 1. Clean KOReader acsm cache: cache/acsm.koplugin (fulfillment-*.bin, epub-work-*, epub_work)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or nil
    if data_dir then
        local acsm_cache = data_dir .. "/cache/acsm.koplugin"
        scanAndPurge(
            acsm_cache,
            function(name)
                return (name:match("^fulfillment%-") and name:match("%.bin$"))
                    or name == "fulfillment-temp.bin"
                    or name:match("^%.fulfillment")
            end,
            function(name)
                return name:match("^epub%-work%-") or name == "epub_work"
            end
        )

        -- 2. Clean progress files in cache/
        local koreader_cache = data_dir .. "/cache"
        scanAndPurge(
            koreader_cache,
            function(name)
                return name:match("^%.libbee_prog_") or name:match("^%.temp_dl_prog_")
            end,
            nil
        )

        -- 3. Clean temporary cover downloads
        local covers_cache = data_dir .. "/cache/libbee_covers"
        scanAndPurge(
            covers_cache,
            function(name)
                return name:match("%.tmp$")
            end,
            nil
        )
    end

    -- 4. Clean /tmp if it exists
    if dirExists("/tmp") then
        scanAndPurge(
            "/tmp",
            function(name)
                return name:match("^%.libbee_prog_")
                    or name:match("^%.temp_dl_prog_")
                    or (name:match("^%.temp_") and name:match("%.acsm"))
                    or (name:match("^fulfillment%-") and name:match("%.bin$"))
                    or name == "fulfillment-temp.bin"
            end,
            nil
        )
    end

    -- 5. Clean base_dir (download folder) for leftover .temp_*.acsm or .temp_dl_prog_*
    local target_base = base_dir
    if not target_base or target_base == "" then
        pcall(function()
            local ok_st, State = pcall(require, "libbee_state")
            if not ok_st or not State then
                ok_st, State = pcall(require, plugin_path .. "libbee_state")
            end
            if ok_st and State and State.getDownloadDir then
                target_base = State.getDownloadDir()
            end
        end)
    end

    if target_base and dirExists(target_base) then
        scanAndPurge(
            target_base,
            function(name)
                return name:match("^%.temp_.*%.acsm")
                    or name:match("^%.temp_dl_prog_")
                    or name:match("^%.libbee_prog_")
            end,
            nil
        )
    end

    return results
end

-- Allow running directly from command line: lua libbee_cleanup.lua [plugin_path]
if arg and arg[0] and arg[0]:find("libbee_cleanup%.lua") then
    local path = arg[1] or "."
    local res = M.cleanDeprecated(path)
    print("Libbee cleanup completed for: " .. tostring(path))
    print("  Deleted folders: " .. table.concat(res.deleted_folders, ", "))
    print("  Deleted files:   " .. table.concat(res.deleted_files, ", "))
end

return M
