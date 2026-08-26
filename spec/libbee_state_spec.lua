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

    it("defaults group by card to true and can be toggled", function()
        State.setGroupByCard(true)
        assert.is_true(State.getGroupByCard() == true)
        State.setGroupByCard(false)
        assert.is_false(State.getGroupByCard() == true)
        State.setGroupByCard(true)
        assert.is_true(State.getGroupByCard() == true)
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

describe("libbee_state multi-account and card name support", function()
    before_each(function()
        State.clearChipIdentity()
    end)

    after_each(function()
        State.clearChipIdentity()
    end)

    it("supports adding, retrieving, updating and removing multiple accounts", function()
        assert.is_false(State.isAuthenticated())
        assert.are_equal(0, #State.getAccounts())

        -- Add Account 1
        local acc1 = {
            id = "chip_acc_1",
            chip_identity = "header.payload1.sig",
            library_name = "Seattle Public Library",
            cards = {
                { id = "card_spl_1", library = { name = "Seattle Public Library" } }
            }
        }
        assert.is_true(State.addOrUpdateAccount(acc1))
        assert.is_true(State.isAuthenticated())
        assert.are_equal(1, #State.getAccounts())
        assert.are_equal("header.payload1.sig", State.getChipIdentity("chip_acc_1"))
        assert.are_equal("Seattle Public Library", State.getLibraryName("chip_acc_1"))

        -- Add Account 2
        local acc2 = {
            id = "chip_acc_2",
            chip_identity = "header.payload2.sig",
            library_name = "Brooklyn Public Library",
            cards = {
                { id = "card_bpl_1", library = { name = "Brooklyn Public Library" } },
                { id = "card_nypl_1", libraryName = "New York Public Library" }
            }
        }
        assert.is_true(State.addOrUpdateAccount(acc2))
        assert.are_equal(2, #State.getAccounts())

        -- Retrieve all card names
        local card_names = State.getCardNames()
        assert.are_equal(3, #card_names)

        -- Remove Account 1
        assert.is_true(State.removeAccount("chip_acc_1"))
        assert.are_equal(1, #State.getAccounts())
        assert.are_equal("header.payload2.sig", State.getChipIdentity())
        assert.is_true(State.isAuthenticated())

        -- Clear all
        State.clearChipIdentity()
        assert.is_false(State.isAuthenticated())
        assert.are_equal(0, #State.getAccounts())
    end)

    it("resolves various card naming structures robustly", function()
        assert.are_equal("Seattle Public", State.cardName({ library = { name = "Seattle Public" } }))
        assert.are_equal("King County", State.cardName({ libraryName = "King County" }))
        assert.are_equal("Austin Public", State.cardName({ name = "Austin Public" }))
        assert.are_equal("lib_website_123", State.cardName({ library = { websiteId = "lib_website_123" } }))
        assert.are_equal("ADV_KEY_456", State.cardName({ advantageKey = "ADV_KEY_456" }))
        assert.are_equal("Library Card", State.cardName(nil))
        assert.are_equal("Library Card", State.cardName({}))
    end)

    it("formats card identifiers, display names and loan group labels", function()
        local card1 = {
            cardId = "83954655",
            username = "24273000280003",
            cardName = "24273000280003",
            library = { name = "Wisconsin Public Library Consortium" }
        }
        local card2 = {
            cardId = "33434074",
            emailAddress = "alyssa@jimmypautz.com",
            cardName = "24273000240544",
            library = { name = "Wisconsin Public Library Consortium" }
        }

        assert.are_equal("…0003", State.cardSuffix(card1))
        assert.are_equal("…0544", State.cardSuffix(card2))
        assert.are_equal("alyssa@jimmypautz.com", State.cardEmail(card2))

        local card3 = { username = "jpautz", library = { name = "Chicago Public Library" } }
        assert.are_equal("jpautz", State.cardUsername(card3))

        assert.are_equal("Wisconsin Public Library Consortium (…0003)", State.cardDisplayName(card1))
        assert.are_equal("Wisconsin Public Library Consortium (alyssa@jimmypautz.com)", State.cardDisplayName(card2))
        assert.are_equal("Chicago Public Library (jpautz)", State.cardDisplayName(card3))

        assert.are_equal("Card …0003", State.cardDetailString(card1))
        assert.are_equal("alyssa@jimmypautz.com · Card …0544", State.cardDetailString(card2))
        assert.are_equal("Card jpautz", State.cardDetailString(card3))

        local loan1 = { card_id = "83954655", library = "Wisconsin Public Library Consortium" }
        local label = State.loanGroupLabel(loan1, { card1, card2 })
        assert.are_equal("Wisconsin Public Library Consortium (…0003)", label)
    end)
end)

