-- libbee_autoclean_spec.lua
require("spec.spec_helper")
local State = require("libbee_state")
local AutoClean = require("libbee_autoclean")

describe("libbee_autoclean isPastGracePeriod", function()
    it("handles numeric unix timestamps with 1-day grace period", function()
        local now = 1000000
        local one_day = 86400

        -- Expired 2 days ago (exceeds 1-day grace)
        assert.is_true(AutoClean.isPastGracePeriod(now - (2 * one_day), now, 1))

        -- Expired exactly 1 day ago (due date + 24h passed)
        assert.is_true(AutoClean.isPastGracePeriod(now - one_day, now, 1))

        -- Expired 12 hours ago (within 1-day grace period)
        assert.is_false(AutoClean.isPastGracePeriod(now - (one_day / 2), now, 1))

        -- Expires tomorrow (active)
        assert.is_false(AutoClean.isPastGracePeriod(now + one_day, now, 1))
    end)

    it("handles string date YYYY-MM-DD with 1-day grace period", function()
        -- Fixed reference time: 2026-08-21 12:00:00 UTC
        local now = os.time{ year = 2026, month = 8, day = 21, hour = 12 }

        -- Due on 2026-08-19 (2 days ago -> expired past 1-day grace)
        assert.is_true(AutoClean.isPastGracePeriod("2026-08-19", now, 1))

        -- Due on 2026-08-20 (yesterday / 1 day past due date -> expired past 1-day grace)
        assert.is_true(AutoClean.isPastGracePeriod("2026-08-20", now, 1))

        -- Due on 2026-08-21 (today -> within grace period)
        assert.is_false(AutoClean.isPastGracePeriod("2026-08-21", now, 1))

        -- Due on 2026-08-22 (tomorrow -> active)
        assert.is_false(AutoClean.isPastGracePeriod("2026-08-22", now, 1))
    end)
end)

describe("libbee_autoclean isLoanInShelf", function()
    local shelf = {
        { id = "loan-1", reserveId = "res-1", title = "Book 1" },
        { loanId = "loan-2", title = "Book 2" },
    }

    it("matches loan by id, loanId, or reserveId", function()
        local found1, item1 = AutoClean.isLoanInShelf("loan-1", nil, shelf)
        assert.is_true(found1)
        assert.are_equal("Book 1", item1.title)

        local found2, item2 = AutoClean.isLoanInShelf("non-existent", "res-1", shelf)
        assert.is_true(found2)
        assert.are_equal("Book 1", item2.title)

        local found3, item3 = AutoClean.isLoanInShelf("loan-2", nil, shelf)
        assert.is_true(found3)
        assert.are_equal("Book 2", item3.title)

        local found4, item4 = AutoClean.isLoanInShelf("loan-999", "res-999", shelf)
        assert.is_false(found4)
        assert.is_nil(item4)
    end)
end)

describe("libbee_autoclean checkAndCleanup", function()
    local temp_files = {}

    local function create_temp_file(name)
        local path = "/tmp/test_autoclean_" .. name .. "_" .. tostring(math.random(1000, 9999)) .. ".epub"
        local fh = io.open(path, "w")
        if fh then
            fh:write("dummy content")
            fh:close()
            table.insert(temp_files, path)
        end
        return path
    end

    before_each(function()
        -- Clean registry
        local reg = State.getDownloadRegistry()
        for k, _ in pairs(reg) do
            State.unregisterDownload(k)
        end
    end)

    after_each(function()
        for _, p in ipairs(temp_files) do
            pcall(os.remove, p)
        end
        temp_files = {}
    end)

    it("auto-deletes early-returned books during live sync", function()
        local path1 = create_temp_file("returned_early")
        local path2 = create_temp_file("still_active")

        State.registerDownload({
            id = "loan-early",
            title = "Early Returned Book",
            expires = "2026-08-30",
        }, path1)

        State.registerDownload({
            id = "loan-active",
            title = "Active Book",
            expires = "2026-08-30",
        }, path2)

        -- Live sync shelf: 'loan-early' was returned in Libby, only 'loan-active' remains on shelf
        local live_shelf = {
            { id = "loan-active", title = "Active Book", expires = "2026-08-30" }
        }

        local res = AutoClean.checkAndCleanup(live_shelf, { is_live_sync = true })
        assert.are_equal(1, res.deleted_count)
        assert.are_equal("Early Returned Book", res.deleted_titles[1])

        -- loan-early file removed and unregistered
        local f1 = io.open(path1, "r")
        assert.is_nil(f1)
        assert.is_nil(State.getTrackedDownload("loan-early"))

        -- loan-active file preserved and still registered
        local f2 = io.open(path2, "r")
        assert.is_not_nil(f2)
        if f2 then f2:close() end
        assert.is_not_nil(State.getTrackedDownload("loan-active"))
    end)

    it("auto-deletes loans expired past the 1-day grace period", function()
        local now = os.time{ year = 2026, month = 8, day = 21, hour = 12 }
        local path_expired = create_temp_file("expired")
        local path_today = create_temp_file("due_today")

        -- Expired yesterday (1 day past due date)
        State.registerDownload({
            id = "loan-exp",
            title = "Expired Yesterday",
            expires = "2026-08-20",
        }, path_expired)

        -- Due today (within grace period)
        State.registerDownload({
            id = "loan-today",
            title = "Due Today",
            expires = "2026-08-21",
        }, path_today)

        local live_shelf = {
            { id = "loan-exp", title = "Expired Yesterday", expires = "2026-08-20" },
            { id = "loan-today", title = "Due Today", expires = "2026-08-21" },
        }

        local res = AutoClean.checkAndCleanup(live_shelf, { is_live_sync = true, now_timestamp = now })
        assert.are_equal(1, res.deleted_count)
        assert.are_equal("Expired Yesterday", res.deleted_titles[1])

        assert.is_nil(io.open(path_expired, "r"))
        assert.is_nil(State.getTrackedDownload("loan-exp"))

        local f_today = io.open(path_today, "r")
        assert.is_not_nil(f_today)
        if f_today then f_today:close() end
        assert.is_not_nil(State.getTrackedDownload("loan-today"))
    end)

    it("does not delete unexpired books during offline/startup checks even if shelf is missing", function()
        local now = os.time{ year = 2026, month = 8, day = 21, hour = 12 }
        local path_active = create_temp_file("offline_active")

        State.registerDownload({
            id = "loan-offline",
            title = "Offline Active Book",
            expires = "2026-08-25",
        }, path_active)

        -- Offline / startup check with empty or nil shelf
        local res = AutoClean.checkAndCleanup(nil, { is_live_sync = false, now_timestamp = now })
        assert.are_equal(0, res.deleted_count)

        local f = io.open(path_active, "r")
        assert.is_not_nil(f)
        if f then f:close() end
        assert.is_not_nil(State.getTrackedDownload("loan-offline"))
    end)
end)
