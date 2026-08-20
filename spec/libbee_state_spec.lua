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
