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
        assert.is_true(type(UI.showToast) == "function")
    end)

    it("shows styled toast", function()
        _G.ui_tracker.shown = {}
        local toast = UI.showToast("Test Toast", 3)
        assert.is_table(toast)
        assert.is_true(#_G.ui_tracker.shown > 0)
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

    it("opens about settings dialog", function()
        _G.ui_tracker.shown = {}
        UI.showAbout("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)

    it("opens libby account submenu", function()
        _G.ui_tracker.shown = {}
        UI.showLibbyAccountSubmenu("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)

    it("opens bytebooks drm submenu", function()
        _G.ui_tracker.shown = {}
        UI.showByteBooksDRMSubmenu("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)

    it("opens maintenance submenu", function()
        _G.ui_tracker.shown = {}
        UI.showMaintenanceSubmenu("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)

    it("registers dispatcher actions for gestures and keyboard shortcuts", function()
        local LibbeePlugin = require("main")
        _G.dispatcher_tracker.actions = {}
        local plugin = LibbeePlugin:new{ path = "/tmp/test_plugin" }
        plugin:onDispatcherRegisterActions()
        
        local open_action = _G.dispatcher_tracker.actions["libbee_open"]
        assert.is_table(open_action)
        assert.are_equal("LibbeeOpen", open_action.event)
        assert.are_equal("none", open_action.category)
        assert.is_true(open_action.general)

        local browse_action = _G.dispatcher_tracker.actions["libbee_browse_shelf"]
        assert.is_table(browse_action)
        assert.are_equal("LibbeeBrowseShelf", browse_action.event)
    end)

    it("handles onLibbeeOpen and onLibbeeBrowseShelf events", function()
        local LibbeePlugin = require("main")
        _G.ui_tracker.shown = {}
        local plugin = LibbeePlugin:new{ path = "/tmp/test_plugin" }
        local res_open = plugin:onLibbeeOpen()
        assert.is_true(res_open)
        assert.is_true(#_G.ui_tracker.shown > 0)

        _G.ui_tracker.shown = {}
        local res_browse = plugin:onLibbeeBrowseShelf()
        assert.is_true(res_browse)
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)
end)
