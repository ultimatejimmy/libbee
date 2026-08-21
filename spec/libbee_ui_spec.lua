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

    describe("deleted / missing book checks", function()
        local tmp_dir = "/tmp/libbee_spec_test"

        before_each(function()
            pcall(os.execute, "mkdir -p " .. tmp_dir)
        end)

        after_each(function()
            pcall(os.remove, tmp_dir .. "/The Great Gatsby.epub")
            pcall(os.remove, tmp_dir .. "/The.epub")
            pcall(os.remove, tmp_dir .. "/Existing Book.epub")
            pcall(os.remove, tmp_dir .. "/Empty Book.epub")
            pcall(os.remove, tmp_dir .. "/non_existent_book.epub")
        end)

        it("findExistingBook returns nil when book does not exist or was deleted", function()
            local loan = { title = "Deleted Book Title" }
            local found = UI.findExistingBook(loan, tmp_dir)
            assert.is_nil(found)
        end)

        it("findExistingBook does not false-match unrelated books with substring names", function()
            -- Create an unrelated short-named book "The.epub"
            local f = io.open(tmp_dir .. "/The.epub", "wb")
            if f then f:write("sample content"); f:close() end

            local loan = { title = "The Great Gatsby" }
            local found = UI.findExistingBook(loan, tmp_dir)
            assert.is_nil(found)
        end)

        it("findExistingBook finds an existing non-empty book file", function()
            local f = io.open(tmp_dir .. "/Existing Book.epub", "wb")
            if f then f:write("valid book data"); f:close() end

            local loan = { title = "Existing Book" }
            local found = UI.findExistingBook(loan, tmp_dir)
            assert.is_not_nil(found)
            assert.is_truthy(found:find("Existing Book.epub"))
        end)

        it("_openBook returns false and does not crash on non-existent or empty files", function()
            local res_missing = UI._openBook(tmp_dir .. "/non_existent_book.epub")
            assert.is_false(res_missing)

            local f_empty = io.open(tmp_dir .. "/Empty Book.epub", "wb")
            if f_empty then f_empty:close() end

            local res_empty = UI._openBook(tmp_dir .. "/Empty Book.epub")
            assert.is_false(res_empty)
        end)

        it("showDownloadConfirm shows download dialog when book does not exist", function()
            _G.ui_tracker.shown = {}
            local State = require("libbee_state")
            State.setCustomDownloadDir(tmp_dir)

            local loan = {
                title = "Un-downloaded Book",
                author = "Author Name",
                format = "ebook-epub-adobe",
                days_remaining = 14,
            }

            UI.showDownloadConfirm(loan, "/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)
        end)
    end)
end)
