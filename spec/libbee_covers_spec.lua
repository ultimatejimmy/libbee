-- libbee_covers_spec.lua
require("spec.spec_helper")
local Covers = require("libbee_covers")

describe("libbee_covers", function()
    it("is a table with cover functions", function()
        assert.is_table(Covers)
        assert.is_true(type(Covers.getCacheDir) == "function")
        assert.is_true(type(Covers.getCoverFilePath) == "function")
        assert.is_true(type(Covers.getCachedCoverPath) == "function")
        assert.is_true(type(Covers.fetchCover) == "function")
        assert.is_true(type(Covers.createPlaceholderWidget) == "function")
    end)

    it("returns cache dir", function()
        local dir = Covers.getCacheDir()
        assert.is_not_nil(dir)
        assert.is_true(dir:find("cache") ~= nil)
    end)

    it("generates clean cover file path from loan", function()
        local loan = {
            id = "loan-12345",
            title = "Test Book",
            cover_url = "https://img.libbyapp.com/cover.jpg"
        }
        local path = Covers.getCoverFilePath(loan)
        assert.is_not_nil(path)
        assert.is_true(path:find("loan%-12345%.jpg") ~= nil)
    end)

    it("handles loans with png cover urls", function()
        local loan = {
            id = "loan-png-1",
            cover_url = "https://img.libbyapp.com/cover.png"
        }
        local path = Covers.getCoverFilePath(loan)
        assert.is_not_nil(path)
        assert.is_true(path:find(".png") ~= nil)
    end)

    it("creates placeholder widget with zero border inflation", function()
        local widget = Covers.createPlaceholderWidget(100, 140, "Sample Title")
        assert.is_table(widget)
        assert.are_equal(0, widget.bordersize)
        assert.are_equal(100, widget.width)
        assert.are_equal(140, widget.height)
    end)

    it("cleans up expired covers safely", function()
        assert.is_true(type(Covers.cleanupExpiredCovers) == "function")
        local active_loans = {
            { id = "loan-1", title = "Active Book", days_remaining = 14 },
            { id = "loan-2", title = "Expired Book", days_remaining = 0 },
        }
        local deleted = Covers.cleanupExpiredCovers(active_loans)
        assert.is_true(type(deleted) == "number")
    end)
end)
