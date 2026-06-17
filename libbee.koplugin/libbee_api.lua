-- libbee_api.lua — Libby/OverDrive Network API
-- All HTTP calls live here. No UI code. Returns plain Lua tables or error strings.
--
-- Libby API notes (reverse-engineered from odmpy / libbydl / MobileRead community):
--   Base:     https://sentry-read.svc.overdrive.com
--   Thunder:  https://thunder.api.overdrive.com
--
-- Authentication uses a "chip identity" — a device UUID registered against a
-- library card. This is the same mechanism Kobo eReaders use natively.
-- It is obtained once via a one-time "clone" setup code from the Libby app.

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local log = require(plugin_path .. "libbee_logger")


local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SENTRY_BASE  = "https://sentry-read.svc.overdrive.com"
local THUNDER_BASE = "https://thunder.api.overdrive.com"
local USER_AGENT   = "KOReader-Libbee/1.0"

-- Fulfill format to request (epub-adobe = ACSM file).
-- Other options: "ebook-epub-open" (open epub, no DRM), "audiobook-mp3" etc.
local FULFILL_FORMAT = "ebook-epub-adobe"

-- ---------------------------------------------------------------------------
-- Internal: HTTP helpers
-- ---------------------------------------------------------------------------

-- Sets up socketutil timeouts and returns http, ltn12, socket modules.
local function _initHttp()
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")
    return {
        socketutil = ok_su and socketutil or nil,
        http       = http,
        ltn12      = ltn12,
        socket     = socket,
    }
end

-- Performs an HTTP(S) GET. Returns body string or nil, errmsg.
local function _httpGet(url, headers)
    local libs = _initHttp()
    local impl = libs.http

    if libs.socketutil then
        libs.socketutil:set_timeout(
            libs.socketutil.LARGE_BLOCK_TIMEOUT,
            libs.socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local chunks = {}
    local req_headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"]     = "application/json",
    }
    if headers then
        for k, v in pairs(headers) do req_headers[k] = v end
    end

    local code, resp_headers, status = libs.socket.skip(1, impl.request({
        url      = url,
        method   = "GET",
        headers  = req_headers,
        sink     = libs.ltn12.sink.table(chunks),
    }))

    if libs.socketutil then libs.socketutil:reset_timeout() end

    if libs.socketutil and (
        code == libs.socketutil.TIMEOUT_CODE or
        code == libs.socketutil.SSL_HANDSHAKE_CODE or
        code == libs.socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if resp_headers == nil then
        local err_detail = "network error (" .. tostring(code or status) .. ")"
        log.warn("_httpGet failed: " .. err_detail .. " url=" .. url)
        return nil, err_detail
    end

    local body = table.concat(chunks)
    if code == 200 then
        return body, nil, resp_headers
    end
    if code == 526 then
        log.err("HTTP 526 — Cloudflare TLS validation failed. Device clock or CA bundle may be outdated. url=" .. url)
        return nil, "HTTP 526 SSL error", resp_headers
    end
    log.warn("_httpGet HTTP " .. tostring(code) .. " url=" .. url)
    return nil, ("HTTP " .. tostring(code)), resp_headers
end

-- Performs an HTTP(S) POST with a JSON body. Returns body string or nil, errmsg.
local function _httpPost(url, payload_table, headers)
    local libs = _initHttp()
    local impl = libs.http

    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil, "json module unavailable" end

    local ok_e, payload_str = pcall(json.encode, payload_table or {})
    if not ok_e then return nil, "json encode error: " .. tostring(payload_str) end

    if libs.socketutil then
        libs.socketutil:set_timeout(
            libs.socketutil.LARGE_BLOCK_TIMEOUT,
            libs.socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local chunks = {}
    local req_headers = {
        ["User-Agent"]   = USER_AGENT,
        ["Accept"]       = "application/json",
        ["Content-Type"] = "application/json",
    }
    if headers then
        for k, v in pairs(headers) do req_headers[k] = v end
    end

    local code, resp_headers, status = libs.socket.skip(1, impl.request({
        url     = url,
        method  = "POST",
        headers = req_headers,
        source  = libs.ltn12.source.string(payload_str),
        sink    = libs.ltn12.sink.table(chunks),
    }))

    if libs.socketutil then libs.socketutil:reset_timeout() end

    if libs.socketutil and (
        code == libs.socketutil.TIMEOUT_CODE or
        code == libs.socketutil.SSL_HANDSHAKE_CODE or
        code == libs.socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if resp_headers == nil then
        local err_detail = "network error (" .. tostring(code or status) .. ")"
        log.warn("_httpPost failed: " .. err_detail .. " url=" .. url)
        return nil, err_detail
    end

    local body = table.concat(chunks)
    if code == 200 or code == 201 then
        return body, nil, resp_headers
    end
    if code == 526 then
        log.err("HTTP 526 — Cloudflare TLS validation failed. Device clock or CA bundle may be outdated. url=" .. url)
        return nil, "HTTP 526 SSL error", resp_headers
    end
    log.warn("_httpPost HTTP " .. tostring(code) .. " url=" .. url)
    return nil, ("HTTP " .. tostring(code)), resp_headers
end

-- Downloads a URL to a file on disk. Returns true or nil, errmsg.
local function _httpGetToFile(url, dest_path, headers)
    local libs = _initHttp()
    local impl = libs.http

    local fh, open_err = io.open(dest_path, "wb")
    if not fh then return nil, "cannot create file: " .. tostring(open_err) end

    if libs.socketutil then
        libs.socketutil:set_timeout(
            libs.socketutil.FILE_BLOCK_TIMEOUT,
            libs.socketutil.FILE_TOTAL_TIMEOUT
        )
    end

    local req_headers = { ["User-Agent"] = USER_AGENT }
    if headers then
        for k, v in pairs(headers) do req_headers[k] = v end
    end

    local code, resp_headers, status = libs.socket.skip(1, impl.request({
        url      = url,
        method   = "GET",
        headers  = req_headers,
        sink     = libs.ltn12.sink.file(fh),
    }))

    if libs.socketutil then libs.socketutil:reset_timeout() end

    if libs.socketutil and (
        code == libs.socketutil.TIMEOUT_CODE or
        code == libs.socketutil.SSL_HANDSHAKE_CODE or
        code == libs.socketutil.SINK_TIMEOUT_CODE
    ) then
        pcall(os.remove, dest_path)
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if resp_headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return true end
    pcall(os.remove, dest_path)
    if code == 526 then
        log.err("HTTP 526 — Cloudflare TLS validation failed. Device clock or CA bundle may be outdated. url=" .. url)
        return nil, "HTTP 526 SSL error"
    end
    return nil, ("HTTP " .. tostring(code))
end

-- ---------------------------------------------------------------------------
-- Internal: JSON decode helper
-- ---------------------------------------------------------------------------

local function _decodeJson(body, context)
    local ok, json = pcall(require, "json")
    if not ok then return nil, "json module unavailable" end
    local ok2, data = pcall(json.decode, body)
    if not ok2 or type(data) ~= "table" then
        return nil, "JSON parse error in " .. (context or "response") .. ": " .. tostring(data)
    end
    return data
end

-- ---------------------------------------------------------------------------
-- Internal: Build Authorization header from state or config
-- ---------------------------------------------------------------------------

-- Returns "Bearer <token>" or nil if no auth available.
-- Checks state (chip identity) first, then config fallback.
local function _getBearerHeader(config)
    local State = require(plugin_path .. "libbee_state")
    local chip = State.getChipIdentity()
    if chip and chip ~= "" then
        return { ["Authorization"] = "Bearer " .. chip }
    end
    -- Manual fallback from config
    if config and config.bearer_token and config.bearer_token ~= "" then
        return { ["Authorization"] = "Bearer " .. config.bearer_token }
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public: Authentication
-- ---------------------------------------------------------------------------

-- Attempts to register a new chip identity using a one-time Libby setup code.
-- setup_code: the 8-digit code from Libby app → Settings → Copy To Another Device
-- Returns: { chip = "...", library_name = "..." } or nil, errmsg
function M.setupWithCode(setup_code)
    local State = require(plugin_path .. "libbee_state")
    if not setup_code or setup_code == "" then
        return nil, "No setup code provided"
    end

    -- Strip whitespace and dashes from the code
    local code = setup_code:gsub("[%s%-]", "")
    if #code < 6 then
        return nil, "Setup code is too short (expected 8 digits)"
    end

    log.info("libbee api: attempting chip clone with code")
    log.debug("Attempting setup with code: " .. tostring(code))

    local url = SENTRY_BASE .. "/chip/clone/code/" .. code
    log.debug("POST URL: " .. url)
    local body, err = _httpPost(url, nil, nil)
    if not body then
        local err_str = "Setup request failed: " .. tostring(err)
        log.debug(err_str)
        return nil, err_str
    end

    log.debug("POST Success. Response body: " .. tostring(body))

    local data, parse_err = _decodeJson(body, "clone response")
    if not data then
        log.debug("JSON parse error: " .. tostring(parse_err))
        return nil, parse_err
    end

    -- Safe retrieval of chip token to avoid string indexing crash
    local chip = nil
    if type(data) == "table" then
        chip = data.chip or data.identity
        if not chip and type(data.result) == "table" then
            chip = data.result.chip
        end
    end

    if not chip or chip == "" then
        local err_detail = ""
        if type(data) == "table" then
            if type(data.result) == "string" then
                err_detail = " (result: " .. data.result .. ")"
            elseif type(data.message) == "string" then
                err_detail = " (" .. data.message .. ")"
            end
        end
        local err_msg = "Unexpected response from Libby — no chip identity received" .. err_detail
        log.debug(err_msg)
        log.warn("libbee api: clone response had no chip field: " .. tostring(body):sub(1, 500))
        return nil, err_msg
    end

    -- Extract a friendly library name if available
    local library_name = ""
    if type(data) == "table" and data.cards and type(data.cards) == "table" and data.cards[1] then
        local card = data.cards[1]
        if type(card) == "table" then
            library_name = (card.library and type(card.library) == "table" and card.library.name) or
                           (card.advantageKey) or ""
        end
    end

    log.debug("Chip successfully cloned. Library: " .. tostring(library_name))

    -- Persist to state
    State.saveChipIdentity(chip, library_name)

    return { chip = chip, library_name = library_name }
end

-- Requests a new 8-digit setup code from Libby to display on this device.
-- Returns: { code = "..." } or nil, errmsg
function M.requestSetupCode()
    local State = require(plugin_path .. "libbee_state")
    log.info("libbee api: requesting setup code")
    log.debug("Requesting setup code...")

    local url = SENTRY_BASE .. "/chip/clone/code"
    log.debug("POST URL: " .. url)
    local body, err = _httpPost(url, nil, nil)
    if not body then
        local err_str = "Request setup code failed: " .. tostring(err)
        log.debug(err_str)
        return nil, err_str
    end

    log.debug("Request setup code success. Response: " .. tostring(body))

    local data, parse_err = _decodeJson(body, "setup code response")
    if not data then
        log.debug("JSON parse error: " .. tostring(parse_err))
        return nil, parse_err
    end

    local code = data.code
    if not code and type(data.result) == "table" then
        code = data.result.code
    end

    if not code or code == "" then
        local err_msg = "Unexpected response from Libby — no setup code received"
        log.debug(err_msg)
        return nil, err_msg
    end

    return { code = code }
end

-- Polls Libby to see if the user entered the displayed code in their app.
-- Returns: { chip = "...", library_name = "..." } or nil, "pending" or nil, errmsg
function M.pollForCloneResult(setup_code)
    local State = require(plugin_path .. "libbee_state")
    if not setup_code or setup_code == "" then
        return nil, "No setup code provided"
    end

    local code = setup_code:gsub("[%s%-]", "")
    local url = SENTRY_BASE .. "/chip/clone/code/" .. code
    log.debug("Polling URL: " .. url)

    local body, err, resp_headers = _httpGet(url, nil)
    if not body then
        log.debug("Poll request pending or failed: " .. tostring(err))
        return nil, "pending"
    end

    log.debug("Poll success. Response: " .. tostring(body))

    local data, parse_err = _decodeJson(body, "poll response")
    if not data then
        log.debug("Poll JSON parse error: " .. tostring(parse_err))
        return nil, "pending"
    end

    local chip = nil
    if type(data) == "table" then
        chip = data.chip or data.identity
        if not chip and type(data.result) == "table" then
            chip = data.result.chip
        end
    end

    if not chip or chip == "" then
        log.debug("Poll response had no chip identity yet")
        return nil, "pending"
    end

    local library_name = ""
    if type(data) == "table" and data.cards and type(data.cards) == "table" and data.cards[1] then
        local card = data.cards[1]
        if type(card) == "table" then
            library_name = (card.library and type(card.library) == "table" and card.library.name) or
                           (card.advantageKey) or ""
        end
    end

    log.debug("Chip successfully cloned via polling. Library: " .. tostring(library_name))

    -- Persist to state
    State.saveChipIdentity(chip, library_name)

    return { chip = chip, library_name = library_name }
end

-- ---------------------------------------------------------------------------
-- Public: Shelf / Loans
-- ---------------------------------------------------------------------------

-- Fetches the current loans from the Libby shelf.
-- config: the loaded libbee_config table (for bearer_token fallback)
-- Returns: array of loan tables, or nil, errmsg
-- Each loan table contains at minimum:
--   { id, title, author, format, days_remaining, is_ebook, ... }
function M.fetchShelf(config)
    local auth_headers = _getBearerHeader(config)
    if not auth_headers then
        return nil, "Not authenticated — please run setup first"
    end

    log.info("libbee api: fetching shelf")

    -- The sync endpoint returns loans, holds, and identity info
    local url = SENTRY_BASE .. "/chip/sync"
    local body, err = _httpGet(url, auth_headers)
    if not body then
        return nil, "Shelf fetch failed: " .. tostring(err)
    end

    local data, parse_err = _decodeJson(body, "shelf sync")
    if not data then return nil, parse_err end

    -- Check for auth errors
    if data.result == "unauthorized" or data.code == 401 or data.errorCode == "Unauthorized" then
        return nil, "AUTH_EXPIRED"
    end

    -- Parse loans from the response
    local loans = {}
    local raw_loans = data.loans or data.items or {}

    for _, loan in ipairs(raw_loans) do
        -- Determine the format
        local format = loan.type and loan.type.id or loan.formatId or ""

        -- Skip non-ebook loans entirely (audiobooks, magazines, etc.)
        local is_ebook = (
            format == "ebook-epub-adobe" or
            format == "ebook-pdf-adobe"  or
            format == "ebook-epub-open"  or
            format:find("^ebook") ~= nil
        )
        if not is_ebook then
            log.info("libbee api: skipping non-ebook loan: " .. tostring(loan.title) .. " (" .. format .. ")")
        end
        if not is_ebook then goto continue end

        -- Calculate days remaining from ISO 8601 expiry string or Unix timestamp
        local days_remaining = nil
        if loan.expires then
            local exp_time = loan.expires
            if type(exp_time) == "string" then
                local y, mo, d = exp_time:match("(%d%d%d%d)-(%d%d)-(%d%d)")
                if y then
                    local now_date = os.date("*t")
                    local exp_days  = tonumber(y) * 365 + tonumber(mo) * 30 + tonumber(d)
                    local now_days  = now_date.year  * 365 + now_date.month  * 30 + now_date.day
                    days_remaining  = exp_days - now_days
                end
            elseif type(exp_time) == "number" then
                days_remaining = math.floor((exp_time - os.time()) / 86400)
            end
        end
        if days_remaining and days_remaining < 0 then days_remaining = 0 end

        table.insert(loans, {
            id             = loan.id or loan.loanId or tostring(loan.reserveId or ""),
            reserveId      = loan.reserveId or loan.id,
            title          = loan.title or loan.sortTitle or "Unknown Title",
            author         = loan.firstCreatorName or loan.author or "Unknown Author",
            format         = format,
            is_ebook       = true,
            days_remaining = days_remaining,
            expires        = loan.expires,
            raw            = loan,
        })

        ::continue::
    end

    log.info("libbee api: fetched " .. #loans .. " loans")
    return loans
end

-- ---------------------------------------------------------------------------
-- Public: Download ACSM
-- ---------------------------------------------------------------------------

-- Gets the fulfillment URL for a loan, then downloads the .acsm file to dest_path.
-- loan:      a loan table from fetchShelf()
-- dest_path: full path where the .acsm file should be written
-- config:    the loaded libbee_config table
-- Returns: true or nil, errmsg
function M.downloadACSM(loan, dest_path, config)
    local auth_headers = _getBearerHeader(config)
    if not auth_headers then
        return nil, "Not authenticated"
    end

    if not loan.is_ebook then
        return nil, "This loan is not a downloadable ebook"
    end

    local reserve_id = loan.reserveId or loan.id
    if not reserve_id or reserve_id == "" then
        return nil, "Loan has no valid ID"
    end

    -- Step 1: Request the fulfill URL from Thunder API
    -- Try the standard ebook-epub-adobe format first, fall back to loan's format
    local formats_to_try = { FULFILL_FORMAT }
    if loan.format and loan.format ~= FULFILL_FORMAT then
        table.insert(formats_to_try, loan.format)
    end
    -- Also try open epub (no DRM) as a last resort
    if loan.format ~= "ebook-epub-open" then
        table.insert(formats_to_try, "ebook-epub-open")
    end

    local fulfill_url = nil
    local fulfill_err = nil

    for _, fmt in ipairs(formats_to_try) do
        local url = THUNDER_BASE .. "/v2/loans/" .. tostring(reserve_id) .. "/fulfill/" .. fmt
        log.info("libbee api: requesting fulfill URL: " .. url)

        local body, err, resp_headers = _httpGet(url, auth_headers)
        if body then
            -- If Content-Type is application/json, it's a redirect URL in JSON
            local ct = resp_headers and (resp_headers["content-type"] or resp_headers["Content-Type"]) or ""
            if ct:find("application/json") then
                local fdata, _ = _decodeJson(body, "fulfill")
                if fdata and fdata.href then
                    fulfill_url = fdata.href
                    break
                elseif fdata and fdata.links then
                    -- Some responses nest the URL in links
                    for _, link in ipairs(fdata.links) do
                        if link.href and (link.type == "application/vnd.adobe.adept+xml" or
                                          link.rel == "license") then
                            fulfill_url = link.href
                            break
                        end
                    end
                    if fulfill_url then break end
                end
            else
                -- The response body itself IS the .acsm content
                -- Write it directly
                local fh = io.open(dest_path, "wb")
                if fh then
                    fh:write(body)
                    fh:close()
                    log.info("libbee api: ACSM written directly (inline response)")
                    return true
                end
            end
        else
            fulfill_err = err
            log.warn("libbee api: fulfill attempt failed for format " .. fmt .. ": " .. tostring(err))
        end
    end

    if not fulfill_url then
        return nil, "Could not get download link" .. (fulfill_err and (": " .. fulfill_err) or "")
    end

    -- Step 2: Download the actual ACSM file
    log.info("libbee api: downloading ACSM from: " .. tostring(fulfill_url):sub(1, 80))
    local ok, dl_err = _httpGetToFile(fulfill_url, dest_path, auth_headers)
    if not ok then
        return nil, "Download failed: " .. tostring(dl_err)
    end

    log.info("libbee api: ACSM downloaded to " .. tostring(dest_path))
    return true
end

-- ---------------------------------------------------------------------------
-- Public: Derive download path for a loan
-- ---------------------------------------------------------------------------

-- Returns a safe file path for saving a loan's ACSM file.
-- base_dir: directory to save in (from config or default storage)
-- loan:     a loan table from fetchShelf()
function M.getAcsmPath(base_dir, loan)
    -- Sanitize title for use as filename
    local title = (loan.title or "download"):gsub('[/\\:*?"<>|]', "_"):gsub("%s+", "_")
    if #title > 60 then title = title:sub(1, 60) end
    local ext = ".acsm"
    -- Open epub doesn't need ACSM, use .epub
    if loan.format == "ebook-epub-open" then ext = ".epub" end
    return base_dir .. "/" .. title .. ext
end

-- ---------------------------------------------------------------------------
-- Public: Determine default download directory
-- ---------------------------------------------------------------------------

-- Returns the best available download directory on this device.
function M.getDefaultDownloadDir()
    -- Try DataStorage first (configured KOReader storage root)
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        -- Try various paths used on different devices
        local candidates = {
            DS.getDataDir and DS:getDataDir() or nil,
            DS.getSettingsDir and (DS:getSettingsDir() .. "/..") or nil,
        }
        for _, path in ipairs(candidates) do
            if path then
                local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
                if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
                if lfs_ok and lfs and lfs.attributes(path, "mode") == "directory" then
                    return path .. "/Libby"
                end
            end
        end
    end

    -- Platform-specific fallbacks
    local candidates = {
        "/mnt/us/documents",        -- Kindle
        "/mnt/onboard",             -- Kobo
        "/sdcard/Books",            -- Android
        "/storage/emulated/0/Books", -- Android alternative
        "/tmp",                     -- Last resort
    }
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    for _, path in ipairs(candidates) do
        if lfs_ok and lfs and lfs.attributes(path, "mode") == "directory" then
            return path .. "/Libby"
        end
    end

    return "/tmp/Libby"
end

-- Ensures the download directory exists, creating it if necessary.
function M.ensureDownloadDir(dir)
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    if not lfs_ok then return false, "lfs module unavailable" end

    if lfs.attributes(dir, "mode") == "directory" then return true end

    -- Create it (may need to create parent too)
    local parent = dir:match("^(.+)/[^/]+$")
    if parent and lfs.attributes(parent, "mode") ~= "directory" then
        pcall(lfs.mkdir, parent)
    end
    local ok = lfs.mkdir(dir)
    if not ok then return nil, "Could not create directory: " .. tostring(dir) end
    return true
end

return M
