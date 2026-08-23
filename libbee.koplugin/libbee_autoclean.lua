-- libbee_autoclean.lua — Auto-Delete Expired & Returned Loans Manager
-- Automatically deletes downloaded book files when loan due date has passed
-- (with a 1-day grace period) or if the book was returned early via the Libby app.

local logger = require("logger")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local ok_state, State = pcall(require, plugin_path .. "libbee_state")
if not ok_state or not State then
    ok_state, State = pcall(require, "libbee_state")
end

local M = {}

local SECONDS_PER_DAY = 24 * 60 * 60

-- ---------------------------------------------------------------------------
-- Date calculation helpers
-- ---------------------------------------------------------------------------

function M.date_ordinal(year, month, day)
    if month <= 2 then
        year = year - 1
        month = month + 12
    end
    return 365 * year
        + math.floor(year / 4)
        - math.floor(year / 100)
        + math.floor(year / 400)
        + math.floor((153 * (month - 3) + 2) / 5)
        + day
end

--- Check if an expiration date has exceeded the grace period.
--- Default grace period is 1 day (grace_days = 1).
--- @param expire number|string Expiration timestamp or date string ("YYYY-MM-DD...")
--- @param now_timestamp number|nil Current unix timestamp (defaults to os.time())
--- @param grace_days number|nil Grace period in days (defaults to 1)
--- @return boolean True if expired past grace period
function M.isPastGracePeriod(expire, now_timestamp, grace_days)
    if not expire then return false end
    local grace = (type(grace_days) == "number" and grace_days >= 0) and grace_days or 1
    local now_ts = now_timestamp or os.time()

    if type(expire) == "number" then
        local grace_seconds = grace * SECONDS_PER_DAY
        return now_ts >= (expire + grace_seconds)
    end

    if type(expire) == "string" then
        local year, month, day = expire:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if year then
            year, month, day = tonumber(year), tonumber(month), tonumber(day)
            local now = os.date("!*t", now_ts)
            local diff_days = M.date_ordinal(year, month, day) - M.date_ordinal(now.year, now.month, now.day)
            -- If due date was yesterday (diff_days == -1) and grace is 1, diff_days <= -1 is true
            return diff_days <= -grace
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Shelf search & lookup
-- ---------------------------------------------------------------------------

--- Checks whether a tracked loan is present in an active shelf list.
--- @param tracked_id string
--- @param reserve_id string|nil
--- @param shelf table Array of active loan objects
--- @return boolean found, table|nil matching_loan
function M.isLoanInShelf(tracked_id, reserve_id, shelf)
    if type(shelf) ~= "table" then return false, nil end
    local tid_str = tracked_id and tostring(tracked_id) or ""
    local rid_str = reserve_id and tostring(reserve_id) or ""

    for _, item in ipairs(shelf) do
        if type(item) == "table" then
            local id1 = item.id and tostring(item.id)
            local id2 = item.loanId and tostring(item.loanId)
            local id3 = item.reserveId and tostring(item.reserveId)

            if (tid_str ~= "" and (tid_str == id1 or tid_str == id2 or tid_str == id3)) or
               (rid_str ~= "" and (rid_str == id1 or rid_str == id2 or rid_str == id3)) then
                return true, item
            end
        end
    end
    return false, nil
end

-- ---------------------------------------------------------------------------
-- File & Sidecar Cleanup
-- ---------------------------------------------------------------------------

--- Safely removes a book file while preserving KOReader's .sdr sidecar directory
--- (so reading progress, bookmarks, and highlights remain intact if loaned again).
--- @param file_path string
function M.removeFileAndSidecar(file_path)
    if not file_path or file_path == "" then return end

    -- 1. Close document if currently opened in ReaderUI to avoid engine lockup
    pcall(function()
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_rui and ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
            if ReaderUI.instance.document.file == file_path then
                ReaderUI.instance:onClose()
            end
        end
    end)

    -- 2. Remove book file only; preserve .sdr sidecar directory
    pcall(os.remove, file_path)

    -- 3. Invalidate KOReader caches and history safely
    pcall(function()
        local ok_ev, Event = pcall(require, "ui/event")
        local ok_uim, UIManager = pcall(require, "ui/uimanager")
        if ok_ev and Event and ok_uim and UIManager and UIManager.broadcastEvent then
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file_path))
        end
    end)
    pcall(function()
        local ok_rh, ReadHistory = pcall(require, "readhistory")
        if ok_rh and ReadHistory and type(ReadHistory.fileDeleted) == "function" then
            ReadHistory:fileDeleted(file_path)
        end
    end)
    pcall(function()
        local ok_rc, ReadCollection = pcall(require, "readcollection")
        if ok_rc and ReadCollection and type(ReadCollection.removeItem) == "function" then
            ReadCollection:removeItem(file_path)
        end
    end)
end

M.removeBookFile = M.removeFileAndSidecar

-- ---------------------------------------------------------------------------
-- Main Cleanup Orchestrator
-- ---------------------------------------------------------------------------

--- Scans registered downloads and removes files that are expired or returned.
--- @param shelf table|nil Array of active loans (from live API sync or cache)
--- @param options table|nil { is_live_sync = boolean, now_timestamp = number, grace_days = number }
--- @return table { deleted_count = number, deleted_titles = table, errors = table }
function M.checkAndCleanup(shelf, options)
    options = options or {}
    local is_live_sync = (options.is_live_sync == true)
    local now_ts = options.now_timestamp or os.time()
    local grace_days = options.grace_days or 1

    local registry = (State and State.getDownloadRegistry and State.getDownloadRegistry()) or {}
    local deleted_count = 0
    local deleted_titles = {}
    local errors = {}

    for loan_id, tracked in pairs(registry) do
        local should_delete = false
        local reason = nil

        if is_live_sync and type(shelf) == "table" then
            local in_shelf, shelf_item = M.isLoanInShelf(tracked.loan_id or loan_id, tracked.reserve_id, shelf)
            if not in_shelf then
                -- Loan is absent from verified live shelf -> returned early in Libby app (or expired & removed)
                should_delete = true
                reason = "returned_early"
            else
                -- Loan is still on shelf; check if past 1-day grace period
                local exp = (shelf_item and (shelf_item.expires or shelf_item.expireDate or shelf_item.expireTimestamp)) or tracked.expires
                if M.isPastGracePeriod(exp, now_ts, grace_days) then
                    should_delete = true
                    reason = "expired_grace_period"
                end
            end
        else
            -- Offline / startup check without verified live sync: only delete if expiry date + grace period elapsed
            if M.isPastGracePeriod(tracked.expires, now_ts, grace_days) then
                should_delete = true
                reason = "expired_grace_period"
            end
        end

        if should_delete then
            logger.info("libbee autoclean: auto-deleting tracked loan " .. tostring(loan_id) ..
                        " ('" .. tostring(tracked.title) .. "'), reason: " .. tostring(reason))

            if tracked.path and tracked.path ~= "" then
                M.removeFileAndSidecar(tracked.path)
            end

            if State and State.unregisterDownload then
                State.unregisterDownload(loan_id)
            end

            deleted_count = deleted_count + 1
            table.insert(deleted_titles, tracked.title or loan_id)
        end
    end

    if deleted_count > 0 then
        logger.info("libbee autoclean: completed auto-cleanup, removed " .. deleted_count .. " book(s)")
    end

    return {
        deleted_count  = deleted_count,
        deleted_titles = deleted_titles,
        errors         = errors,
    }
end

return M
