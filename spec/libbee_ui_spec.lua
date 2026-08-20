-- libbee_ui_spec.lua
require("spec.spec_helper")
local UI = require("libbee_ui")

describe("libbee_ui", function()
    it("is a table with UI functions", function()
        assert.is_table(UI)
        assert.is_true(type(UI.showCardDialog) == "function")
        assert.is_true(type(UI.showSetupDialog) == "function")
        assert.is_true(type(UI.showShelfBrowser) == "function")
        assert.is_true(type(UI.showDownloadConfirm) == "function")
        assert.is_true(type(UI.showAbout) == "function")
    end)

    it("shows styled card dialog", function()
        _G.ui_tracker.shown = {}
        local dlg = UI.showCardDialog{
            title = "Test Card",
            body_text = "This is a test card dialog.",
            buttons = {
                { text = "Confirm", is_primary = true },
                { text = "Cancel" }
            }
        }
        assert.is_table(dlg)
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)

    it("opens about dialog", function()
        _G.ui_tracker.shown = {}
        UI.showAbout("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)
end)
