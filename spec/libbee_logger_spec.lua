-- libbee_logger_spec.lua
require("spec.spec_helper")

describe("libbee_logger", function()
    local logger

    setup(function()
        -- Clear mock to test the real implementation
        package.loaded["libbee_logger"] = nil
        logger = require("libbee_logger")
    end)

    teardown(function()
        -- Restore mock
        package.loaded["libbee_logger"] = {
            info  = function(m) end,
            warn  = function(m) end,
            err   = function(m) end,
            debug = function(m) end,
            path  = function()  return "/tmp/libbee_debug.log" end,
        }
    end)

    it("returns the correct log file path and initializes", function()
        logger.init("/tmp/test_dir")
        local path = logger.path()
        assert.is_string(path)
        assert.is_true(path:find("/tmp/test_dir/libbee_debug.log") ~= nil)
    end)

    it("writes info, warn, err, and debug logs without errors", function()
        logger.init("/tmp/test_dir")
        local path = logger.path()
        pcall(os.remove, path) -- Start fresh

        logger.info("Test Info message")
        logger.warn("Test Warn message")
        logger.err("Test Err message")
        logger.debug("Test Debug message")

        local fh = io.open(path, "r")
        assert.is_not_nil(fh)
        local content = fh:read("*a")
        fh:close()

        assert.is_true(content:find("%[INFO%] Test Info message") ~= nil)
        assert.is_true(content:find("%[WARN%] Test Warn message") ~= nil)
        assert.is_true(content:find("%[ERR%] Test Err message") ~= nil)
        assert.is_true(content:find("%[DEBUG%] Test Debug message") ~= nil)
    end)

    it("rolls the log file when it exceeds 64KB", function()
        local path = logger.path()
        pcall(os.remove, path)

        -- Write > 64KB of dummy data
        local fh = io.open(path, "w")
        assert.is_not_nil(fh)
        fh:write(string.rep("A", 65 * 1024))
        fh:close()

        -- Confirm size is > 64KB
        local fh_check = io.open(path, "r")
        local initial_size = fh_check:seek("end")
        fh_check:close()
        assert.is_true(initial_size > 64 * 1024)

        -- Write a new log entry - this should trigger roll
        logger.info("New entry after roll")

        -- Check file size and content
        local fh_after = io.open(path, "r")
        assert.is_not_nil(fh_after)
        local final_content = fh_after:read("*a")
        local final_size = fh_after:seek("end")
        fh_after:close()

        assert.is_true(final_size < 1024) -- Should be small now
        assert.is_true(final_content:find("New entry after roll") ~= nil)
        assert.is_nil(final_content:find("AAAAA"))
    end)
end)
