-- libbee_state_spec.lua
require("spec.spec_helper")
local State = require("libbee_state")

describe("libbee_state view preferences", function()
    it("defaults view mode to list", function()
        local mode = State.getViewMode()
        assert.is_true(mode == "list" or mode == "cover")
    end)

    it("saves and retrieves view mode", function()
        State.saveViewMode("cover")
        assert.is_true(State.getViewMode() == "cover")
        State.saveViewMode("list")
        assert.is_true(State.getViewMode() == "list")
    end)

    it("normalizes unknown view mode to list", function()
        State.saveViewMode("invalid_mode")
        assert.is_true(State.getViewMode() == "list")
    end)
end)

describe("libbee_state DRM activation state", function()
    it("handles anonymous activation save, retrieval, and clear", function()
        State.clearDrmActivation()
        assert.is_nil(State.getDrmActivation())

        local test_blob = {
            deviceUUID = "urn:uuid:test-12345",
            fingerprint = "test-fp",
            user = "urn:uuid:test-user",
        }

        State.saveDrmActivation(test_blob, "anonymous", nil)
        local restored = State.getDrmActivation()
        assert.is_true(restored ~= nil)
        assert.is_true(restored.deviceUUID == "urn:uuid:test-12345")

        local info = State.getDrmAccountInfo()
        assert.is_true(info.activated)
        assert.is_true(info.mode == "anonymous")
        assert.is_true(info.email == "")

        State.clearDrmActivation()
        assert.is_nil(State.getDrmActivation())
        local cleared_info = State.getDrmAccountInfo()
        assert.is_false(cleared_info.activated)
    end)

    it("handles ByteBooks activation with email while ensuring zero passwords", function()
        State.clearDrmActivation()

        local test_blob = {
            deviceUUID = "urn:uuid:test-bytebooks",
            fingerprint = "test-fp-bb",
            user = "urn:uuid:test-bb-user",
        }

        State.saveDrmActivation(test_blob, "bytebooks", "reader@example.com")
        local info = State.getDrmAccountInfo()
        assert.is_true(info.activated)
        assert.is_true(info.mode == "bytebooks")
        assert.is_true(info.email == "reader@example.com")
        assert.is_nil(info.password)

        -- Verify no password field in activation blob or state
        local blob = State.getDrmActivation()
        assert.is_nil(blob.password)

        State.clearDrmActivation()
    end)
end)

describe("libbee_state download directory settings", function()
    it("handles default and custom download dir lifecycle", function()
        State.resetCustomDownloadDir()
        assert.is_false(State.isCustomDownloadDir())
        assert.is_nil(State.getCustomDownloadDir())

        local default_dir = State.getDefaultDownloadDir()
        assert.is_string(default_dir)
        assert.are_equal(default_dir, State.getDownloadDir())

        -- Set custom directory
        State.setCustomDownloadDir("/mnt/onboard/MyCustomLibby")
        assert.is_true(State.isCustomDownloadDir())
        assert.are_equal("/mnt/onboard/MyCustomLibby", State.getCustomDownloadDir())
        assert.are_equal("/mnt/onboard/MyCustomLibby", State.getDownloadDir())

        -- Reset to default
        State.resetCustomDownloadDir()
        assert.is_false(State.isCustomDownloadDir())
        assert.is_nil(State.getCustomDownloadDir())
        assert.are_equal(default_dir, State.getDownloadDir())
    end)
end)

describe("libbee_state shelf cache and 7-day TTL", function()
    local sample_shelf = {
        { id = "loan-1", title = "The Great Gatsby", days_remaining = 14 },
        { id = "loan-2", title = "1984", days_remaining = 7 }
    }

    before_each(function()
        State.clearShelfCache()
    end)

    after_each(function()
        State.clearShelfCache()
    end)

    it("saves and retrieves shelf cache within 7-day TTL", function()
        assert.is_nil(State.getShelfCache())
        State.saveShelfCache(sample_shelf)

        local cached = State.getShelfCache()
        assert.is_table(cached)
        assert.are_equal(2, #cached)
        assert.are_equal("The Great Gatsby", cached[1].title)
    end)

    it("expires cache after 7 days (7 * 24 * 60 * 60 seconds) when allow_stale is nil or false", function()
        State.saveShelfCache(sample_shelf)

        local orig_time = os.time
        -- Advance time by 8 days
        os.time = function() return orig_time() + (8 * 24 * 60 * 60) end

        local expired = State.getShelfCache()
        assert.is_nil(expired)

        local expired_explicit = State.getShelfCache(false)
        assert.is_nil(expired_explicit)

        -- If allow_stale is true, it should return the cached data
        local stale = State.getShelfCache(true)
        assert.is_table(stale)
        assert.are_equal(2, #stale)

        os.time = orig_time
    end)

    it("clears shelf cache correctly", function()
        State.saveShelfCache(sample_shelf)
        assert.is_not_nil(State.getShelfCache())

        State.clearShelfCache()
        assert.is_nil(State.getShelfCache())
    end)
end)

describe("libbee_state auto-delete and download registry", function()
    it("defaults auto-delete to enabled", function()
        -- Reset setting
        State.setAutoDeleteExpired(true)
        assert.is_true(State.getAutoDeleteExpired())
    end)

    it("toggles auto-delete setting", function()
        State.setAutoDeleteExpired(false)
        assert.is_false(State.getAutoDeleteExpired())
        State.setAutoDeleteExpired(true)
        assert.is_true(State.getAutoDeleteExpired())
    end)

    it("registers, retrieves, and unregisters downloaded books", function()
        local loan = {
            id = "loan-101",
            reserveId = "reserve-abc",
            title = "Pride and Prejudice",
            author = "Jane Austen",
            expires = "2026-09-01",
        }
        local file_path = "/tmp/Libby/Pride and Prejudice.epub"

        assert.is_true(State.registerDownload(loan, file_path))

        local reg = State.getDownloadRegistry()
        assert.is_table(reg)
        assert.is_not_nil(reg["loan-101"])
        assert.are_equal("Pride and Prejudice", reg["loan-101"].title)
        assert.are_equal(file_path, reg["loan-101"].path)
        assert.are_equal("2026-09-01", reg["loan-101"].expires)

        local tracked = State.getTrackedDownload("loan-101")
        assert.is_not_nil(tracked)
        assert.are_equal(file_path, tracked.path)

        assert.is_true(State.unregisterDownload("loan-101"))
        assert.is_nil(State.getTrackedDownload("loan-101"))
    end)
end)

