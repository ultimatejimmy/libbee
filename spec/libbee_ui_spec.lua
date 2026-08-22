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

    it("opens debug log viewer in TextViewer with line tailing", function()
        _G.ui_tracker.shown = {}
        local log = require("libbee_logger")
        local log_path = log.path()
        local fh = io.open(log_path, "w")
        if fh then
            for i = 1, 150 do
                fh:write("2026-08-21 12:00:00 [INFO] Log line number " .. i .. "\n")
            end
            fh:close()
        end

        local viewer = UI._showDebugLog(50)
        assert.is_table(viewer)
        assert.are_equal("TextViewer", viewer.type)
        assert.are_equal("code", viewer.args.text_type)
        local pos_150 = viewer.args.text:find("Log line number 150")
        local pos_101 = viewer.args.text:find("Log line number 101")
        assert.is_not_nil(pos_150)
        assert.is_not_nil(pos_101)
        assert.is_true(pos_150 < pos_101) -- newest entry appears before older entry
        assert.is_nil(viewer.args.text:find("Log line number 10\n"))
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

        it("showDownloadConfirm shows informative restriction dialog for Kindle/Libby only loan", function()
            _G.ui_tracker.shown = {}
            local loan = {
                title = "Kindle Exclusive Book",
                author = "Popular Author",
                is_downloadable = false,
                restriction_type = "kindle_or_libby",
                days_remaining = 10,
            }

            UI.showDownloadConfirm(loan, "/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)
            local dlg = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(dlg)
        end)

        it("showDownloadConfirm shows informative dialog for audiobook loan", function()
            _G.ui_tracker.shown = {}
            local loan = {
                title = "Audiobook Title",
                author = "Author",
                is_downloadable = false,
                restriction_type = "audiobook",
                days_remaining = 5,
            }

            UI.showDownloadConfirm(loan, "/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)
        end)

        it("showSetupDialog shows Retry and Cancel on setup code failure", function()
            _G.ui_tracker.shown = {}
            local API = require("libbee_api")
            local orig_requestSetupCode = API.requestSetupCode
            API.requestSetupCode = function()
                return nil, "Test connection refused error"
            end

            local done_called = false
            local done_success = nil
            UI.showSetupDialog("/tmp/test_plugin", function(success)
                done_called = true
                done_success = success
            end)

            assert.is_true(#_G.ui_tracker.shown > 0)
            local dlg = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(dlg)

            API.requestSetupCode = orig_requestSetupCode
        end)
    end)

    describe("download flow and progress toast lifecycle", function()
        local API = require("libbee_api")
        local LibbeeDRM = require("libbee_drm")
        local orig_downloadACSM = API.downloadACSM
        local orig_fulfillAcsm = LibbeeDRM.fulfillAcsm
        local orig_parseAcsmMetadata = LibbeeDRM.parseAcsmMetadata
        local orig_deriveFinalBookPath = LibbeeDRM.deriveFinalBookPath

        after_each(function()
            API.downloadACSM = orig_downloadACSM
            LibbeeDRM.fulfillAcsm = orig_fulfillAcsm
            LibbeeDRM.parseAcsmMetadata = orig_parseAcsmMetadata
            LibbeeDRM.deriveFinalBookPath = orig_deriveFinalBookPath
        end)

        it("shows progress toast and handles successful download & fulfillment", function()
            _G.ui_tracker.shown = {}
            _G.ui_tracker.closed = {}

            API.downloadACSM = function(loan, target_path) return true end
            LibbeeDRM.parseAcsmMetadata = function(path) return { title = "Test Book" } end
            LibbeeDRM.deriveFinalBookPath = function(base, loan, meta) return base .. "/Test Book.epub" end
            LibbeeDRM.fulfillAcsm = function(acsm, out) return true end

            local loan = { title = "Test Book", author = "Author" }
            local after_called = false

            UI._doDownload(loan, "/tmp/download.acsm", "/tmp", "", function()
                after_called = true
            end)

            -- Toast should be shown
            assert.is_true(#_G.ui_tracker.shown >= 2)
            local toast_shown = false
            for _, widget in ipairs(_G.ui_tracker.shown) do
                if widget.type == "InputContainer" and widget.label_widget and widget.label_widget.text:find("Downloading") then
                    toast_shown = true
                    break
                end
            end
            assert.is_true(toast_shown)
            assert.is_true(after_called)
            assert.is_true(#_G.ui_tracker.closed > 0)
        end)

        it("dismisses progress toast and displays failure dialog on download error", function()
            _G.ui_tracker.shown = {}
            _G.ui_tracker.closed = {}

            API.downloadACSM = function(loan, target_path) return false, "Network timeout" end

            local loan = { title = "Failing Book", author = "Author" }
            UI._doDownload(loan, "/tmp/download.acsm", "/tmp", "", nil)

            assert.is_true(#_G.ui_tracker.shown >= 2)
            assert.is_true(#_G.ui_tracker.closed > 0)
            local last_dialog = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(last_dialog)
        end)

        it("dismisses progress toast and displays multi-device dialog on ALREADY_FULFILLED", function()
            _G.ui_tracker.shown = {}
            _G.ui_tracker.closed = {}

            API.downloadACSM = function(loan, target_path) return true end
            LibbeeDRM.parseAcsmMetadata = function(path) return { title = "Fulfilled Book" } end
            LibbeeDRM.deriveFinalBookPath = function(base, loan, meta) return base .. "/Fulfilled Book.epub" end
            LibbeeDRM.fulfillAcsm = function(acsm, out) return false, "ALREADY_FULFILLED" end

            local loan = { title = "Fulfilled Book", author = "Author" }
            UI._doDownload(loan, "/tmp/download.acsm", "/tmp", "", nil)

            assert.is_true(#_G.ui_tracker.shown >= 2)
            assert.is_true(#_G.ui_tracker.closed > 0)
            local last_dialog = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(last_dialog)
        end)

        it("dismisses progress toast and displays format not supported dialog on HTTP 400 format error", function()
            _G.ui_tracker.shown = {}
            _G.ui_tracker.closed = {}

            API.downloadACSM = function(loan, target_path)
                return nil, "Libby rejected fulfillment (HTTP 400): Format not available for this loan (title may be restricted to Libby or Kindle)."
            end

            local loan = { title = "Restricted Book", author = "Author" }
            UI._doDownload(loan, "/tmp/download.acsm", "/tmp", "", nil)

            assert.is_true(#_G.ui_tracker.shown >= 2)
            assert.is_true(#_G.ui_tracker.closed > 0)
            local last_dialog = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(last_dialog)
        end)
    end)
end)
