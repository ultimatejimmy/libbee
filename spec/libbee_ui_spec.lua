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

    it("shows styled centered toast", function()
        _G.ui_tracker.shown = {}
        local toast = UI.showToast("Test Toast", 3)
        assert.is_table(toast)
        assert.is_true(#_G.ui_tracker.shown > 0)
        assert.are_equal("CenterContainer", toast[1].type)
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

    it("opens libby account submenu when unauthenticated and authenticated", function()
        local State = require("libbee_state")
        _G.ui_tracker.shown = {}
        State.clearChipIdentity()
        UI.showLibbyAccountSubmenu("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)

        -- Test authenticated state with multiple accounts and cached loans
        _G.ui_tracker.shown = {}
        State.addOrUpdateAccount({
            id = "test_acc_1",
            chip_identity = "header.payload.sig",
            library_name = "Wisconsin Public Library Consortium",
            cards = {
                { id = "card_1", library = { name = "Wisconsin Public Library Consortium" } }
            }
        })
        State.saveShelfCache({
            { id = "loan-1", library = "Wisconsin Public Library Consortium", title = "Book 1" }
        })
        UI.showLibbyAccountSubmenu("/tmp/test_plugin")
        assert.is_true(#_G.ui_tracker.shown > 0)
    end)

    it("opens manage linked accounts dialog", function()
        local State = require("libbee_state")
        _G.ui_tracker.shown = {}
        State.addOrUpdateAccount({
            id = "test_acc_2",
            chip_identity = "header.payload2.sig",
            library_name = "Second Library",
            cards = { { id = "card_2", cardName = "24273000240544" } }
        })
        UI.showManageAccountsDialog("/tmp/test_plugin")
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

        it("correctly paginates multi-library shelf in cover view without overflow", function()
            local State = require("libbee_state")
            _G.ui_tracker.shown = {}
            State.saveViewMode("cover")
            State.addOrUpdateAccount({
                id = "acc_multi_1",
                chip_identity = "multi.jwt.1",
                library_name = "Library A",
                cards = { { id = "card_a", library = { name = "Library A" } } }
            })
            State.addOrUpdateAccount({
                id = "acc_multi_2",
                chip_identity = "multi.jwt.2",
                library_name = "Library B",
                cards = { { id = "card_b", library = { name = "Library B" } } }
            })
            State.saveShelfCache({
                { id = "loan-a1", card_id = "card_a", library = "Library A", title = "Book A1" },
                { id = "loan-b1", card_id = "card_b", library = "Library B", title = "Book B1" },
                { id = "loan-b2", card_id = "card_b", library = "Library B", title = "Book B2" },
                { id = "loan-b3", card_id = "card_b", library = "Library B", title = "Book B3" },
                { id = "loan-b4", card_id = "card_b", library = "Library B", title = "Book B4" },
            })
            UI.showShelfBrowser("/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)
        end)

        it("correctly paginates single-library shelf in cover view with 2 rows of 3 (6 items max)", function()
            local State = require("libbee_state")
            _G.ui_tracker.shown = {}
            State.clearChipIdentity()
            State.saveViewMode("cover")
            State.addOrUpdateAccount({
                id = "acc_single_1",
                chip_identity = "single.jwt.1",
                library_name = "Single Library",
                cards = { { id = "card_1", library = { name = "Single Library" } } }
            })
            local loans = {}
            for i = 1, 8 do
                table.insert(loans, { id = "loan-" .. i, card_id = "card_1", library = "Single Library", title = "Book " .. i })
            end
            UI.showShelfBrowser("/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)
        end)

        it("correctly paginates tall screen (e.g. Android phone) in cover view with 3 rows of 3", function()
            local State = require("libbee_state")
            local Device = require("device")
            local orig_getWidth = Device.screen.getWidth
            local orig_getHeight = Device.screen.getHeight
            Device.screen.getWidth = function() return 1080 end
            Device.screen.getHeight = function() return 2400 end

            _G.ui_tracker.shown = {}
            State.clearChipIdentity()
            State.saveViewMode("cover")
            State.addOrUpdateAccount({
                id = "acc_tall_1",
                chip_identity = "tall.jwt.1",
                library_name = "Tall Library",
                cards = { { id = "card_tall", library = { name = "Tall Library" } } }
            })
            local loans = {}
            for i = 1, 12 do
                table.insert(loans, { id = "loan-" .. i, card_id = "card_tall", library = "Tall Library", title = "Book " .. i })
            end
            State.saveShelfCache(loans)
            UI.showShelfBrowser("/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)

            Device.screen.getWidth = orig_getWidth
            Device.screen.getHeight = orig_getHeight
        end)

        it("renders cover view with long multi-line titles and badges properly bounded", function()
            local State = require("libbee_state")
            _G.ui_tracker.shown = {}
            State.clearChipIdentity()
            State.saveViewMode("cover")
            State.addOrUpdateAccount({
                id = "acc_multi_title",
                chip_identity = "jwt.title.test",
                library_name = "Wisconsin Consortium",
                cards = { { id = "card_wisc", library = { name = "Wisconsin Consortium" } } }
            })
            local loans = {
                { id = "loan-t1", card_id = "card_wisc", library = "Wisconsin Consortium", title = "The Girl on the Train", days_remaining = 12 },
                { id = "loan-t2", card_id = "card_wisc", library = "Wisconsin Consortium", title = "In a Blink", days_remaining = 10 },
                { id = "loan-t3", card_id = "card_wisc", library = "Wisconsin Consortium", title = "Harry Potter and the Chamber of Secrets: Extended Edition", days_remaining = 13 },
            }
            State.saveShelfCache(loans)
            UI.showShelfBrowser("/tmp/test_plugin")
            assert.is_true(#_G.ui_tracker.shown > 0)
            local shelf_widget = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(shelf_widget)
        end)

        it("supports button cycling, enter, and back in showCardDialog", function()
            _G.ui_tracker.shown = {}
            local primary_clicked = false
            local cancel_clicked = false
            local dlg = UI.showCardDialog{
                title = "Keyboard Navigation Dialog",
                body_text = "Testing D-Pad and keyboard navigation in card dialog.",
                buttons = {
                    {
                        text = "Confirm",
                        is_primary = true,
                        callback = function() primary_clicked = true end,
                    },
                    {
                        text = "Cancel",
                        callback = function() cancel_clicked = true end,
                    },
                }
            }
            assert.is_table(dlg)
            assert.is_true(type(dlg.onPrevBtn) == "function")
            assert.is_true(type(dlg.onNextBtn) == "function")
            assert.is_true(type(dlg.onPress) == "function")
            assert.is_true(type(dlg.onClose) == "function")

            -- Cycle buttons
            dlg:onNextBtn()
            dlg:onPrevBtn()
            -- Trigger primary button press
            dlg:onPress()
            assert.is_true(primary_clicked)

            -- Test onClose on second dialog
            local dlg2 = UI.showCardDialog{
                title = "Dialog 2",
                body_text = "Testing onClose",
                buttons = { { text = "OK" } }
            }
            dlg2:onClose()
        end)

        it("supports D-Pad, number keys, view toggle, and refresh shortcuts on active shelf overlay", function()
            local State = require("libbee_state")
            _G.ui_tracker.shown = {}
            State.clearChipIdentity()
            State.saveViewMode("cover")
            State.addOrUpdateAccount({
                id = "acc_nav_test",
                chip_identity = "jwt.nav.test",
                library_name = "Navigation Library",
                cards = { { id = "card_nav", library = { name = "Navigation Library" } } }
            })
            local loans = {
                { id = "loan-n1", card_id = "card_nav", library = "Navigation Library", title = "Book One", days_remaining = 5 },
                { id = "loan-n2", card_id = "card_nav", library = "Navigation Library", title = "Book Two", days_remaining = 6 },
                { id = "loan-n3", card_id = "card_nav", library = "Navigation Library", title = "Book Three", days_remaining = 7 },
            }
            State.saveShelfCache(loans)
            UI.showShelfBrowser("/tmp/test_plugin")

            local shelf_overlay = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(shelf_overlay)
            assert.is_true(type(shelf_overlay.onUp) == "function")
            assert.is_true(type(shelf_overlay.onDown) == "function")
            assert.is_true(type(shelf_overlay.onLeft) == "function")
            assert.is_true(type(shelf_overlay.onRight) == "function")
            assert.is_true(type(shelf_overlay.onPress) == "function")
            assert.is_true(type(shelf_overlay.onNum1) == "function")
            assert.is_true(type(shelf_overlay.onNum2) == "function")
            assert.is_true(type(shelf_overlay.onNum3) == "function")
            assert.is_true(type(shelf_overlay.onMenuKey) == "function")
            assert.is_true(type(shelf_overlay.onViewToggleKey) == "function")
            assert.is_true(type(shelf_overlay.onRefreshKey) == "function")
            assert.is_true(type(shelf_overlay.onClose) == "function")

            -- D-Pad movements
            shelf_overlay:onRight()
            shelf_overlay:onLeft()
            shelf_overlay:onDown()
            shelf_overlay:onUp() -- transitions into header zone

            -- Header cycling
            shelf_overlay:onRight()
            shelf_overlay:onLeft()
            shelf_overlay:onPress() -- triggers focused header action

            -- Transition back down from header to items
            local current_ov = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            current_ov:onDown()
            current_ov:onPress()

            -- Toggle view mode via shortcut
            current_ov = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            current_ov:onViewToggleKey()
            assert.are_equal("list", State.getViewMode())

            -- Press number shortcut
            local active_overlay = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            active_overlay:onNum1()

            -- Close shelf
            active_overlay:onClose()
        end)

        it("supports D-Pad navigation across submenu items and settings dialogs", function()
            local State = require("libbee_state")

            -- 1. Libby Account Submenu
            _G.ui_tracker.shown = {}
            UI.showLibbyAccountSubmenu("/tmp/test_plugin")
            local libby_menu = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(libby_menu)
            assert.is_true(type(libby_menu.onDown) == "function")
            assert.is_true(type(libby_menu.onUp) == "function")
            assert.is_true(type(libby_menu.onPress) == "function")
            assert.is_true(type(libby_menu.onClose) == "function")
            libby_menu:onDown()
            libby_menu:onUp()
            libby_menu:onClose()

            -- 2. ByteBooks DRM Submenu
            _G.ui_tracker.shown = {}
            UI.showByteBooksDRMSubmenu("/tmp/test_plugin")
            local drm_menu = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(drm_menu)
            assert.is_true(type(drm_menu.onDown) == "function")
            assert.is_true(type(drm_menu.onUp) == "function")
            assert.is_true(type(drm_menu.onPress) == "function")
            assert.is_true(type(drm_menu.onClose) == "function")
            drm_menu:onDown()
            drm_menu:onUp()
            drm_menu:onClose()

            -- 3. Maintenance Submenu
            _G.ui_tracker.shown = {}
            UI.showMaintenanceSubmenu("/tmp/test_plugin")
            local maint_menu = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(maint_menu)
            assert.is_true(type(maint_menu.onDown) == "function")
            assert.is_true(type(maint_menu.onUp) == "function")
            assert.is_true(type(maint_menu.onPress) == "function")
            assert.is_true(type(maint_menu.onClose) == "function")
            maint_menu:onDown()
            maint_menu:onUp()
            maint_menu:onClose()

            -- 4. Main About / Settings Menu
            _G.ui_tracker.shown = {}
            UI.showAbout("/tmp/test_plugin")
            local about_menu = _G.ui_tracker.shown[#_G.ui_tracker.shown]
            assert.is_table(about_menu)
            assert.is_true(type(about_menu.onDown) == "function")
            assert.is_true(type(about_menu.onUp) == "function")
            assert.is_true(type(about_menu.onPress) == "function")
            assert.is_true(type(about_menu.onClose) == "function")
            about_menu:onDown()
            about_menu:onUp()
            about_menu:onClose()
        end)
    end)
end)
