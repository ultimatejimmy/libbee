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

