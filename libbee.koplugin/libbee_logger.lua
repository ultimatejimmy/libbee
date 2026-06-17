-- libbee_logger.lua — Persistent + console logger for Libbee
-- Writes to <plugin_dir>/libbee_debug.log AND KOReader's logger.
local klogger = require("logger")
local M = {}
local MAX_LOG_BYTES = 64 * 1024  -- 64 KB cap

local cached_path = "/tmp/libbee_debug.log"
local initialized = false

function M.init(plugin_dir)
    if initialized then return end
    if plugin_dir and plugin_dir ~= "" then
        cached_path = plugin_dir .. "/libbee_debug.log"
    end
    initialized = true
    -- Write a startup marker
    M.info("Logger initialized. Path: " .. cached_path)
end

local function _logPath()
    return cached_path
end

local function _write(level, msg)
    local path = _logPath()
    -- Roll log if too large
    local fh_check = io.open(path, "r")
    if fh_check then
        local size = fh_check:seek("end")
        fh_check:close()
        if size and size > MAX_LOG_BYTES then pcall(os.remove, path) end
    end
    local fh = io.open(path, "a")
    if fh then
        fh:write(os.date("%Y-%m-%d %H:%M:%S ") .. "[" .. level .. "] " .. tostring(msg) .. "\n")
        fh:close()
    end
end

function M.info(msg)  _write("INFO",  msg); klogger.info("libbee: "  .. tostring(msg)) end
function M.warn(msg)  _write("WARN",  msg); klogger.warn("libbee: "  .. tostring(msg)) end
function M.err(msg)   _write("ERR",   msg); klogger.err("libbee: "   .. tostring(msg)) end
function M.debug(msg) _write("DEBUG", msg); klogger.dbg("libbee: "   .. tostring(msg)) end
function M.path()     return _logPath() end

return M
