-- libbee_api.lua — Libby/OverDrive Network API
-- All HTTP calls live here. Returns plain Lua tables or error strings.
--
-- Uses Libby's active Sentry API (https://sentry.libbyapp.com) and the
-- standard device pairing flow (anonymous chip -> clone code -> blessing -> chip refresh -> sync).

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local log = require(plugin_path .. "libbee_logger")
local State = require(plugin_path .. "libbee_state")
local Transport = require(plugin_path .. "libbee_transport")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

M.SENTRY_BASE     = "https://sentry.libbyapp.com"
M.CLIENT_VERSION  = "d:22.0.3"
M.USER_AGENT      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

-- ---------------------------------------------------------------------------
-- Internal: Transport singleton
-- ---------------------------------------------------------------------------

local _transport_instance = nil
local function _getTransport()
    if not _transport_instance then
        _transport_instance = Transport.new()
    end
    return _transport_instance
end

-- ---------------------------------------------------------------------------
-- Accept-Language algorithm (required by Libby Sentry API)
-- ---------------------------------------------------------------------------

function M.chip_accept_language(identity_token, chip_id)
    local seed = identity_token
    if not seed or seed == "" then
        if chip_id and chip_id ~= "" then
            seed = "xxxxxx" .. chip_id
        else
            seed = "cudlkahllcnsjxhbmddl"
        end
    end

    local chars = {}
    for i = 1, #seed do
        local ch = seed:sub(i, i)
        if ch >= "a" and ch <= "z" then
            table.insert(chars, ch)
        end
    end

    local reversed = {}
    for i = #chars, 1, -1 do
        table.insert(reversed, chars[i])
    end
    local normalized = table.concat(reversed)
    return normalized:sub(5, 6)
end

-- ---------------------------------------------------------------------------
-- JWT & Chip ID Helpers
-- ---------------------------------------------------------------------------

function M.decodeJwtPayload(identity)
    if type(identity) ~= "string" then return nil, "Identity is missing" end
    local payload = identity:match("^[^.]+%.([^.]+)%.")
    if not payload then return nil, "Identity is not a JWT" end

    local transport = _getTransport()
    local decoded, decode_err = transport:base64url_decode(payload)
    if not decoded then return nil, decode_err or "Could not decode JWT payload" end

    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, res = pcall(rapidjson.decode, decoded)
        if ok and type(res) == "table" then return res end
    end

    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok, res = pcall(json.decode, decoded)
        if ok and type(res) == "table" then return res end
    end

    return nil, "Could not parse decoded JWT JSON"
end

function M.short_chip_id(identity)
    local payload, err = M.decodeJwtPayload(identity)
    if not payload then return nil, err end
    local chip = payload.chip
    if type(chip) ~= "table" or type(chip.id) ~= "string" then
        return nil, "Identity JWT is missing chip.id"
    end
    return chip.id:match("^([^-]+)")
end

-- ---------------------------------------------------------------------------
-- HTTP Request wrapper
-- ---------------------------------------------------------------------------

local function _defaultHeaders(user_agent)
    return {
        ["User-Agent"]      = user_agent or M.USER_AGENT,
        ["Accept"]          = "application/json",
        ["Accept-Encoding"] = "gzip",
        ["Referer"]         = "https://libbyapp.com/",
        ["Origin"]          = "https://libbyapp.com",
        ["Sec-Fetch-Dest"]  = "empty",
        ["Sec-Fetch-Mode"]  = "cors",
        ["Sec-Fetch-Site"]  = "same-site",
        ["Cache-Control"]   = "no-cache",
        ["Pragma"]          = "no-cache",
    }
end

local function _request(method, path, options)
    options = options or {}
    local transport = _getTransport()
    local headers = _defaultHeaders(options.user_agent)

    for k, v in pairs(options.headers or {}) do
        headers[k] = v
    end
    if options.identity and options.identity ~= "" then
        headers["Authorization"] = "Bearer " .. options.identity
        if not headers["Accept-Language"] then
            headers["Accept-Language"] = M.chip_accept_language(options.identity)
        end
    end

    local response, err = transport:request({
        method    = method,
        base_url  = options.base_url or M.SENTRY_BASE,
        path      = path,
        query     = options.query,
        headers   = headers,
        json      = options.json,
    })

    if not response then
        return nil, err or "Libby request failed"
    end
    return response
end

local function _responseResult(response)
    if response and type(response.body) == "table" then
        return response.body.result
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Chip Refresh & Management
-- ---------------------------------------------------------------------------

function M.getChip(identity, update_state)
    local query = {
        c = M.CLIENT_VERSION,
        s = "0",
    }
    if identity and identity ~= "" then
        local short_id, err = M.short_chip_id(identity)
        if not short_id then
            log.warn("libbee api: could not get short_chip_id: " .. tostring(err))
        else
            query.v = short_id
        end
    end

    local headers = {
        ["Accept-Language"] = M.chip_accept_language(identity),
    }

    local response, err = _request("POST", "/chip", {
        query    = query,
        headers  = headers,
        identity = identity,
    })

    if not response then return nil, err end
    if response.status ~= 200 then
        return nil, "Libby chip request failed with HTTP " .. tostring(response.status)
    end
    if type(response.body) ~= "table" or type(response.body.identity) ~= "string" then
        return nil, "Libby chip response did not contain an identity"
    end

    local new_identity = response.body.identity
    if update_state then
        local current_lib = State.getLibraryName()
        local current_cards = State.getCards()
        State.saveChipIdentity(new_identity, current_lib, current_cards)
    end

    return response.body
end

-- ---------------------------------------------------------------------------
-- Loan & Card Parsing Helpers
-- ---------------------------------------------------------------------------

local function _firstNonempty(...)
    for i = 1, select("#", ...) do
        local val = select(i, ...)
        if type(val) == "string" and val ~= "" then return val end
    end
    return nil
end

local function _cardName(card)
    if type(card) ~= "table" then return "Library Card" end
    local lib = type(card.library) == "table" and card.library or nil
    return _firstNonempty(
        lib and lib.name,
        card.libraryName,
        card.name,
        lib and lib.websiteId,
        card.advantageKey
    ) or "Library Card"
end

local function _loanLibraryName(loan, cards)
    if type(loan) ~= "table" or type(cards) ~= "table" then return nil end
    local card_id = tostring(loan.cardId or loan.card_id or "")
    if card_id == "" then return nil end
    for _, card in ipairs(cards) do
        if type(card) == "table" then
            local cid = tostring(card.id or card.cardId or "")
            if cid == card_id then
                return _cardName(card)
            end
        end
    end
    return nil
end

local function _loanAuthor(loan)
    if type(loan) ~= "table" then return "Unknown Author" end
    if type(loan.creators) == "table" and loan.creators[1] then
        local c = loan.creators[1]
        if type(c) == "table" then
            return _firstNonempty(c.name, c.displayName, c.fullName) or "Unknown Author"
        elseif type(c) == "string" then
            return c
        end
    end
    return _firstNonempty(loan.firstCreatorName, loan.author) or "Unknown Author"
end

-- ---------------------------------------------------------------------------
-- Setup Flow (Pairing with Libby App)
-- ---------------------------------------------------------------------------

function M.requestSetupCode()
    log.info("libbee api: requesting setup code")

    -- Step 1: Obtain an initial unauthenticated chip identity
    local chip_body, chip_err = M.getChip(nil, false)
    if not chip_body or not chip_body.identity then
        local err_msg = "Could not initialize Libby chip: " .. tostring(chip_err)
        log.err("libbee api: " .. err_msg)
        return nil, err_msg
    end

    local pending_identity = chip_body.identity

    -- Step 2: Request setup code from Libby
    local response, err = _request("GET", "/chip/clone/code", {
        query    = { code = "", role = "pointer" },
        identity = pending_identity,
    })

    if not response then
        local err_msg = "Libby setup code request failed: " .. tostring(err)
        log.err("libbee api: " .. err_msg)
        return nil, err_msg
    end
    if response.status ~= 200 or type(response.body) ~= "table" then
        local err_msg = "Could not generate Libby setup code (HTTP " .. tostring(response.status) .. ")"
        log.err("libbee api: " .. err_msg)
        return nil, err_msg
    end

    local code = response.body.code
    if type(code) ~= "string" or code == "" then
        local err_msg = "Libby setup-code response did not contain a code"
        log.err("libbee api: " .. err_msg)
        return nil, err_msg
    end

    -- Save pending session in state
    State.savePendingIdentity(pending_identity, code)
    log.info("libbee api: successfully generated setup code " .. tostring(code))

    return { code = code }
end

function M.pollForCloneResult(setup_code)
    if not setup_code or setup_code == "" then
        return nil, "No setup code provided"
    end

    local pending_identity = State.getPendingIdentity()
    if not pending_identity then
        return nil, "No pending setup session found"
    end

    local code = setup_code:gsub("[%s%-]", "")
    local response, err = _request("GET", "/chip/clone/code", {
        query    = { code = code, role = "pointer" },
        identity = pending_identity,
    })

    if not response then
        return nil, "pending"
    end

    local poll_body = response.body
    if type(poll_body) ~= "table" or poll_body.result ~= "fulfilled" or type(poll_body.blessing) ~= "string" then
        return nil, "pending"
    end

    local blessing = poll_body.blessing
    log.info("libbee api: received clone blessing, completing pairing")

    local short_id = M.short_chip_id(pending_identity) or ("acc_" .. tostring(os.time()))
    local auth_identity = nil
    local state_data = nil

    -- Attempt complete clone sequence on persistent keep-alive connection
    local transport = _getTransport()
    if type(transport.request_sequence) == "function" then
        local function seq_headers(token, language)
            local result = _defaultHeaders()
            result["Authorization"] = "Bearer " .. token
            result["Connection"] = "keep-alive"
            result["Accept-Language"] = language or M.chip_accept_language(token)
            return result
        end

        local sequence, seq_err = transport:request_sequence({
            -- Step 1: POST /chip/clone
            {
                method   = "POST",
                base_url = M.SENTRY_BASE,
                path     = "/chip/clone",
                headers  = seq_headers(pending_identity),
                json     = { blessing = blessing },
            },
            -- Step 2: If missing_chip, refresh with short_id; if 200, refresh chip to get authenticated token
            function(responses)
                local clone_resp = responses[1]
                if clone_resp and clone_resp.status == 403 and _responseResult(clone_resp) == "missing_chip" then
                    log.info("libbee api: missing_chip on clone, refreshing chip on same connection")
                    return {
                        method   = "POST",
                        base_url = M.SENTRY_BASE,
                        path     = "/chip",
                        query    = { c = M.CLIENT_VERSION, s = "0", v = short_id },
                        headers  = seq_headers(pending_identity, M.chip_accept_language(pending_identity)),
                    }
                elseif clone_resp and clone_resp.status == 200 then
                    return {
                        method   = "POST",
                        base_url = M.SENTRY_BASE,
                        path     = "/chip",
                        query    = { c = M.CLIENT_VERSION, s = "0", v = short_id },
                        headers  = seq_headers(pending_identity, M.chip_accept_language(pending_identity)),
                    }
                end
                return nil
            end,
            -- Step 3: If step 1 was 403, retry clone with step 2's token; else step 2 was refresh, so fetch sync
            function(responses)
                local step1 = responses[1]
                local step2 = responses[2]
                local token2 = step2 and type(step2.body) == "table" and step2.body.identity
                if type(token2) ~= "string" then return nil end

                if step1 and step1.status == 403 then
                    return {
                        method   = "POST",
                        base_url = M.SENTRY_BASE,
                        path     = "/chip/clone",
                        headers  = seq_headers(token2),
                        json     = { blessing = blessing },
                    }
                else
                    return {
                        method   = "GET",
                        base_url = M.SENTRY_BASE,
                        path     = "/chip/sync",
                        headers  = seq_headers(token2),
                    }
                end
            end,
            -- Step 4: If step 3 was retried clone, refresh chip again; else sequence done
            function(responses)
                local step1 = responses[1]
                if not step1 or step1.status ~= 403 then return nil end
                local step3 = responses[3]
                local token2 = responses[2] and type(responses[2].body) == "table" and responses[2].body.identity
                if not step3 or step3.status ~= 200 or type(token2) ~= "string" then return nil end

                return {
                    method   = "POST",
                    base_url = M.SENTRY_BASE,
                    path     = "/chip",
                    query    = { c = M.CLIENT_VERSION, s = "0", v = short_id },
                    headers  = seq_headers(token2, M.chip_accept_language(token2)),
                }
            end,
            -- Step 5: If in retry path, final sync
            function(responses)
                if not responses[4] then return nil end
                local final_token = responses[4] and type(responses[4].body) == "table" and responses[4].body.identity
                if type(final_token) ~= "string" then return nil end
                return {
                    method   = "GET",
                    base_url = M.SENTRY_BASE,
                    path     = "/chip/sync",
                    headers  = seq_headers(final_token),
                }
            end,
        })

        if sequence then
            if sequence[5] and sequence[5].status == 200 and type(sequence[5].body) == "table" then
                auth_identity = sequence[4] and sequence[4].body and sequence[4].body.identity
                state_data = sequence[5].body
            elseif sequence[3] and sequence[3].status == 200 and sequence[1] and sequence[1].status == 200 and type(sequence[3].body) == "table" then
                auth_identity = sequence[2] and sequence[2].body and sequence[2].body.identity
                state_data = sequence[3].body
            end
        else
            log.warn("libbee api: persistent clone sequence returned error: " .. tostring(seq_err))
        end
    end

    -- Fallback to standalone requests if sequence didn't complete
    if not auth_identity or not state_data then
        log.info("libbee api: running standalone clone request with blessing length " .. tostring(#blessing))
        local clone_resp, clone_err = _request("POST", "/chip/clone", {
            identity = pending_identity,
            json     = { blessing = blessing },
        })
        log.info("libbee api: clone_resp status=" .. tostring(clone_resp and clone_resp.status) .. " body=" .. tostring(clone_resp and clone_resp.raw_body))

        if clone_resp and clone_resp.status == 403 and _responseResult(clone_resp) == "missing_chip" then
            log.info("libbee api: missing_chip on clone fallback, refreshing chip")
            local refreshed, refresh_err = M.getChip(pending_identity, false)
            if refreshed and type(refreshed.identity) == "string" then
                pending_identity = refreshed.identity
                State.savePendingIdentity(pending_identity, code)
                clone_resp, clone_err = _request("POST", "/chip/clone", {
                    identity = pending_identity,
                    json     = { blessing = blessing },
                })
                log.info("libbee api: second clone_resp status=" .. tostring(clone_resp and clone_resp.status) .. " body=" .. tostring(clone_resp and clone_resp.raw_body))
            else
                log.err("libbee api: refresh chip failed: " .. tostring(refresh_err))
            end
        end

        if not clone_resp or clone_resp.status ~= 200 then
            local err_msg = "Libby clone blessing claim failed: " .. tostring(clone_err or (clone_resp and clone_resp.status))
            log.err("libbee api: " .. err_msg)
            return nil, err_msg
        end

        local refreshed, refresh_err = M.getChip(pending_identity, false)
        log.info("libbee api: post-clone getChip status=" .. tostring(refreshed and "ok" or refresh_err))
        if not refreshed or type(refreshed.identity) ~= "string" then
            local err_msg = "Libby chip refresh after clone failed: " .. tostring(refresh_err)
            log.err("libbee api: " .. err_msg)
            return nil, err_msg
        end
        auth_identity = refreshed.identity

        local sync_resp, sync_err = _request("GET", "/chip/sync", { identity = auth_identity })
        log.info("libbee api: sync_resp status=" .. tostring(sync_resp and sync_resp.status))
        if sync_resp and sync_resp.status == 403 and _responseResult(sync_resp) == "missing_chip" then
            local sync_refreshed, sync_ref_err = M.getChip(auth_identity, false)
            if sync_refreshed and type(sync_refreshed.identity) == "string" then
                auth_identity = sync_refreshed.identity
                sync_resp, sync_err = _request("GET", "/chip/sync", { identity = auth_identity })
            end
        end

        if not sync_resp or sync_resp.status ~= 200 or type(sync_resp.body) ~= "table" then
            local err_msg = "Libby sync failed: " .. tostring(sync_err or (sync_resp and sync_resp.status))
            log.err("libbee api: " .. err_msg)
            return nil, err_msg
        end

        state_data = sync_resp.body
    end

    local cards = (state_data and state_data.cards) or {}
    local lib_names = {}
    for _, c in ipairs(cards) do
        local n = _cardName(c)
        if n and n ~= "" and not lib_names[n] then
            table.insert(lib_names, n)
            lib_names[n] = true
        end
    end
    local library_name = #lib_names > 0 and table.concat(lib_names, ", ") or "Libby"
    local account_id = M.short_chip_id(auth_identity) or short_id

    -- Save/add authenticated account to state
    State.addOrUpdateAccount({
        id            = account_id,
        chip_identity = auth_identity,
        library_name  = library_name,
        cards         = cards,
    })
    State.clearPendingIdentity()
    log.info("libbee api: pairing complete, saved account " .. tostring(account_id) .. " with " .. #cards .. " cards")

    return { chip = auth_identity, library_name = library_name, cards = cards, id = account_id }
end

function M.analyzeLoanFormats(loan)
    if type(loan) ~= "table" then
        return {
            is_downloadable   = true,
            format            = "ebook-epub-adobe",
            is_ebook          = true,
            restriction_type  = nil,
            available_formats = {},
        }
    end

    local raw = loan.raw or loan
    local media_type = raw.type and (type(raw.type) == "table" and raw.type.id or tostring(raw.type)) or ""
    local is_audio = media_type:find("audio", 1, true) ~= nil
    local is_magazine = media_type:find("magazine", 1, true) ~= nil
    local is_ebook = not (is_audio or is_magazine)

    local format_list = {}
    local format_ids = {}
    if type(raw.formats) == "table" then
        for _, fmt in ipairs(raw.formats) do
            if type(fmt) == "table" and type(fmt.id) == "string" then
                table.insert(format_list, fmt)
                format_ids[fmt.id] = true
            elseif type(fmt) == "string" then
                table.insert(format_list, { id = fmt })
                format_ids[fmt] = true
            end
        end
    end

    -- If format specified directly on loan (e.g. from existing cache or mock)
    if #format_list == 0 and type(loan.format) == "string" and loan.format ~= "" then
        table.insert(format_list, { id = loan.format })
        format_ids[loan.format] = true
    end

    -- If no formats array is present, fallback gracefully based on media type
    if #format_list == 0 then
        if is_audio then
            return {
                is_downloadable   = false,
                format            = "audiobook-overdrive",
                is_ebook          = false,
                restriction_type  = "audiobook",
                available_formats = {},
            }
        elseif is_magazine then
            return {
                is_downloadable   = false,
                format            = "magazine-overdrive",
                is_ebook          = false,
                restriction_type  = "magazine",
                available_formats = {},
            }
        else
            return {
                is_downloadable   = true,
                format            = "ebook-epub-adobe",
                is_ebook          = true,
                restriction_type  = nil,
                available_formats = {},
            }
        end
    end

    -- Check for downloadable formats in priority order
    local downloadable_priority = {
        "ebook-epub-adobe",
        "ebook-pdf-adobe",
        "ebook-epub-open",
        "ebook-pdf-open",
    }
    for _, fid in ipairs(downloadable_priority) do
        if format_ids[fid] then
            return {
                is_downloadable   = true,
                format            = fid,
                is_ebook          = is_ebook,
                restriction_type  = nil,
                available_formats = format_list,
            }
        end
    end

    -- Non-downloadable formats
    if is_audio or format_ids["audiobook-overdrive"] or format_ids["audiobook-mp3"] then
        return {
            is_downloadable   = false,
            format            = format_ids["audiobook-overdrive"] and "audiobook-overdrive" or (format_list[1] and format_list[1].id or "audiobook-overdrive"),
            is_ebook          = false,
            restriction_type  = "audiobook",
            available_formats = format_list,
        }
    end

    if is_magazine or format_ids["magazine-overdrive"] then
        return {
            is_downloadable   = false,
            format            = "magazine-overdrive",
            is_ebook          = false,
            restriction_type  = "magazine",
            available_formats = format_list,
        }
    end

    local has_kindle = format_ids["ebook-kindle"] ~= nil
    local has_overdrive = format_ids["ebook-overdrive"] ~= nil

    if has_kindle and has_overdrive then
        return {
            is_downloadable   = false,
            format            = "ebook-overdrive",
            is_ebook          = true,
            restriction_type  = "kindle_or_libby",
            available_formats = format_list,
        }
    elseif has_kindle then
        return {
            is_downloadable   = false,
            format            = "ebook-kindle",
            is_ebook          = true,
            restriction_type  = "kindle_only",
            available_formats = format_list,
        }
    elseif has_overdrive then
        return {
            is_downloadable   = false,
            format            = "ebook-overdrive",
            is_ebook          = true,
            restriction_type  = "libby_only",
            available_formats = format_list,
        }
    end

    return {
        is_downloadable   = false,
        format            = format_list[1] and format_list[1].id or "unsupported",
        is_ebook          = is_ebook,
        restriction_type  = "unsupported",
        available_formats = format_list,
    }
end

local function _preferredAdobeFormat(loan)
    local analysis = M.analyzeLoanFormats(loan)
    return analysis.format or "ebook-epub-adobe"
end

local function _loanCoverUrl(loan)
    if type(loan) ~= "table" then return nil end
    local covers = type(loan.covers) == "table" and loan.covers or nil
    if covers then
        for _, k in ipairs({ "cover510Wide", "cover300Wide", "cover150Wide", "large", "medium", "small" }) do
            local val = covers[k]
            if type(val) == "string" and val ~= "" then return val end
            if type(val) == "table" and type(val.href) == "string" then return val.href end
        end
    end
    return _firstNonempty(
        type(loan.cover) == "string" and loan.cover or nil,
        type(loan.coverUrl) == "string" and loan.coverUrl or nil,
        type(loan.coverURL) == "string" and loan.coverURL or nil
    )
end

-- ---------------------------------------------------------------------------
-- Shelf Sync / Fetch Loans
-- ---------------------------------------------------------------------------

local function _syncShelfOnSameConnection(identity)
    local transport = _getTransport()
    if type(transport.request_sequence) ~= "function" then
        return nil, "Persistent connection transport unavailable"
    end

    local short_id, short_err = M.short_chip_id(identity)
    if not short_id then return nil, short_err end

    local function headers(token, language)
        local result = _defaultHeaders()
        result["Authorization"] = "Bearer " .. token
        result["Connection"] = "keep-alive"
        result["Accept-Language"] = language or M.chip_accept_language(token)
        return result
    end

    local sequence, err = transport:request_sequence({
        {
            method   = "GET",
            base_url = M.SENTRY_BASE,
            path     = "/chip/sync",
            headers  = headers(identity),
        },
        function(responses)
            if _responseResult(responses[1]) ~= "missing_chip" then return nil end
            return {
                method   = "POST",
                base_url = M.SENTRY_BASE,
                path     = "/chip",
                query    = { c = M.CLIENT_VERSION, s = "0", v = short_id },
                headers  = headers(identity, M.chip_accept_language(identity)),
            }
        end,
        function(responses)
            local chip = responses[2]
            local new_id = chip and type(chip.body) == "table" and chip.body.identity
            if type(new_id) ~= "string" then return nil end
            return {
                method   = "GET",
                base_url = M.SENTRY_BASE,
                path     = "/chip/sync",
                headers  = headers(new_id),
            }
        end,
    })

    if not sequence then return nil, err end

    local chip_step = sequence[2]
    local retry_step = sequence[3]
    local new_identity = chip_step and type(chip_step.body) == "table" and chip_step.body.identity
    if not chip_step or chip_step.status ~= 200 or type(new_identity) ~= "string" then
        return nil, "Libby chip recovery failed"
    end
    if not retry_step or retry_step.status ~= 200 then
        return nil, "Libby sync retry failed with HTTP " .. tostring(retry_step and retry_step.status or "unknown")
    end

    State.saveChipIdentity(new_identity, State.getLibraryName(), State.getCards())
    return retry_step
end

function M.fetchShelf()
    local accounts = State.getAccounts()
    if #accounts == 0 then
        local single_id = State.getChipIdentity()
        if not single_id or single_id == "" then
            return nil, "Not authenticated — please run setup first"
        end
        accounts = { { id = M.short_chip_id(single_id) or "acc_1", chip_identity = single_id } }
    end

    log.info("libbee api: syncing shelf from Libby across " .. #accounts .. " account(s)")

    local all_loans = {}
    local auth_expired_count = 0

    for _, account in ipairs(accounts) do
        local identity = account.chip_identity
        local acc_id = account.id or M.short_chip_id(identity) or "acc"

        if identity and identity ~= "" then
            local response, err = _request("GET", "/chip/sync", { identity = identity })

            -- Handle missing_chip / token expiration using sticky session sequence
            if response and response.status == 403 and _responseResult(response) == "missing_chip" then
                log.info("libbee api: missing_chip received for account " .. tostring(acc_id) .. ", running sticky recovery")
                local recovered_resp, rec_err = _syncShelfOnSameConnection(identity)
                if recovered_resp then
                    response = recovered_resp
                    identity = State.getChipIdentity(acc_id) or identity
                else
                    log.info("libbee api: sticky recovery failed, attempting standalone getChip")
                    local refreshed, refresh_err = M.getChip(identity, false)
                    if refreshed and type(refreshed.identity) == "string" then
                        identity = refreshed.identity
                        response, err = _request("GET", "/chip/sync", { identity = identity })
                    end
                end
            end

            if response and (response.status == 401 or response.status == 403) then
                auth_expired_count = auth_expired_count + 1
                log.warn("libbee api: auth expired for account " .. tostring(acc_id))
            elseif response and response.status == 200 and type(response.body) == "table" then
                local data = response.body
                local cards = data.cards or {}
                local raw_loans = data.loans or {}

                local lib_names = {}
                for _, c in ipairs(cards) do
                    local n = _cardName(c)
                    if n and n ~= "" and not lib_names[n] then
                        table.insert(lib_names, n)
                        lib_names[n] = true
                    end
                end
                local acc_lib_name = #lib_names > 0 and table.concat(lib_names, ", ") or account.library_name or "Libby"

                -- Update stored account data in state
                State.addOrUpdateAccount({
                    id            = acc_id,
                    chip_identity = identity,
                    library_name  = acc_lib_name,
                    cards         = cards,
                    registered_at = account.registered_at,
                })

                for _, raw in ipairs(raw_loans) do
                    local format_info = M.analyzeLoanFormats(raw)
                    local format_id = format_info.format
                    local is_ebook = format_info.is_ebook
                    local is_downloadable = format_info.is_downloadable
                    local restriction_type = format_info.restriction_type

                    local days_remaining = State.loanDaysRemaining(raw)
                    local raw_title = _firstNonempty(raw.title, raw.parentTitle, raw.sortTitle) or "Unknown Title"
                    local title = tostring(raw_title):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
                    if not title or title == "" then title = "Unknown Title" end

                    local raw_author = _loanAuthor(raw)
                    local author = tostring(raw_author):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
                    if not author or author == "" then author = "Unknown Author" end

                    local library = _loanLibraryName(raw, cards) or acc_lib_name or ""

                    table.insert(all_loans, {
                        id                = raw.id or raw.loanId or tostring(raw.reserveId or ""),
                        card_id           = raw.cardId or raw.card_id or (cards[1] and cards[1].id),
                        account_id        = acc_id,
                        chip_identity     = identity,
                        reserveId         = raw.reserveId or raw.id,
                        title             = title,
                        author            = author,
                        library           = library,
                        format            = format_id,
                        is_ebook          = is_ebook,
                        is_downloadable   = is_downloadable,
                        restriction_type  = restriction_type,
                        formats           = format_info.available_formats,
                        days_remaining    = days_remaining,
                        expires           = raw.expires or raw.expireDate or raw.expireTimestamp,
                        cover_url         = _loanCoverUrl(raw),
                        raw               = raw,
                    })
                end
            else
                log.warn("libbee api: shelf sync for account " .. tostring(acc_id) .. " failed: " .. tostring(err or (response and response.status)))
            end
        end
    end

    if #all_loans == 0 and auth_expired_count > 0 and auth_expired_count == #accounts then
        return nil, "AUTH_EXPIRED"
    end

    log.info("libbee api: successfully fetched " .. #all_loans .. " loans across all accounts")
    return all_loans
end

-- ---------------------------------------------------------------------------
-- Fulfillment & ACSM Download
-- ---------------------------------------------------------------------------

local function _recoverFulfillmentOnSameConnection(path, identity)
    local transport = _getTransport()
    if type(transport.request_sequence) ~= "function" then
        return nil, "Persistent connection transport unavailable"
    end

    local short_id, short_err = M.short_chip_id(identity)
    if not short_id then return nil, short_err end

    local function headers(token, language)
        local result = _defaultHeaders()
        result["Authorization"] = "Bearer " .. token
        result["Connection"] = "keep-alive"
        result["Accept-Language"] = language or M.chip_accept_language(token)
        return result
    end

    local sequence, err = transport:request_sequence({
        {
            method   = "GET",
            base_url = M.SENTRY_BASE,
            path     = path,
            headers  = headers(identity),
        },
        function(responses)
            if _responseResult(responses[1]) ~= "missing_chip" then return nil end
            return {
                method   = "POST",
                base_url = M.SENTRY_BASE,
                path     = "/chip",
                query    = { c = M.CLIENT_VERSION, s = "0", v = short_id },
                headers  = headers(identity, M.chip_accept_language(identity)),
            }
        end,
        function(responses)
            local chip = responses[2]
            local new_id = chip and type(chip.body) == "table" and chip.body.identity
            if type(new_id) ~= "string" then return nil end
            return {
                method   = "GET",
                base_url = M.SENTRY_BASE,
                path     = path,
                headers  = headers(new_id),
            }
        end,
    })

    if not sequence then return nil, err end

    local chip_step = sequence[2]
    local retry_step = sequence[3]
    local new_identity = chip_step and type(chip_step.body) == "table" and chip_step.body.identity
    if not chip_step or chip_step.status ~= 200 or type(new_identity) ~= "string" then
        return nil, "Libby chip recovery failed"
    end
    if not retry_step or retry_step.status ~= 200 then
        return nil, "Libby fulfillment retry failed with HTTP " .. tostring(retry_step and retry_step.status or "unknown")
    end

    State.saveChipIdentity(new_identity, State.getLibraryName(), State.getCards())

    local href = type(retry_step.body) == "table" and retry_step.body.fulfill and retry_step.body.fulfill.href
    if type(href) ~= "string" or href == "" then
        return nil, "Libby fulfillment response did not contain fulfill.href"
    end

    return href
end

function M.downloadACSM(loan, dest_path)
    local identity = loan.chip_identity or State.getChipIdentity(loan.account_id) or State.getChipIdentity()
    if not identity or identity == "" then
        return nil, "Not authenticated — please run setup first"
    end

    if loan.is_downloadable == false then
        if loan.restriction_type == "kindle_or_libby" or loan.restriction_type == "kindle_only" or loan.restriction_type == "libby_only" then
            return nil, "This book is only available in Libby or on Kindle and cannot be downloaded as EPUB/PDF."
        elseif loan.restriction_type == "audiobook" then
            return nil, "This loan is an audiobook and cannot be downloaded as EPUB/PDF."
        elseif loan.restriction_type == "magazine" then
            return nil, "This loan is a magazine and cannot be downloaded as EPUB/PDF."
        else
            return nil, "This loan format is not supported for download."
        end
    end

    if not loan.is_ebook then
        return nil, "This loan is not a downloadable ebook"
    end

    local card_id = loan.card_id or loan.cardId
    if not card_id then
        local cards = State.getCards(loan.account_id) or State.getCards()
        card_id = cards and cards[1] and (cards[1].id or cards[1].cardId)
    end
    local loan_id = loan.id or loan.reserveId
    local format_id = loan.format or "ebook-epub-adobe"

    if not card_id or not loan_id then
        return nil, "Loan identifiers (card_id / loan_id) are missing"
    end

    local path = "/card/" .. tostring(card_id) .. "/loan/" .. tostring(loan_id) .. "/fulfill/" .. tostring(format_id)
    log.info("libbee api: requesting fulfillment: " .. path)

    local response, err = _request("GET", path, { identity = identity })
    if not response then return nil, err end

    local fulfill_url = nil
    if response.status == 403 and _responseResult(response) == "missing_chip" then
        log.info("libbee api: 403 missing_chip during fulfillment, running sticky recovery sequence")
        fulfill_url, err = _recoverFulfillmentOnSameConnection(path, identity)
        if not fulfill_url then
            log.info("libbee api: sticky recovery failed (" .. tostring(err) .. "), attempting standalone getChip refresh")
            local refreshed, ref_err = M.getChip(identity, false)
            if refreshed and type(refreshed.identity) == "string" then
                local new_id = refreshed.identity
                if loan.account_id then
                    local acc = State.getAccount(loan.account_id)
                    if acc then
                        acc.chip_identity = new_id
                        State.addOrUpdateAccount(acc)
                    else
                        State.saveChipIdentity(new_id, State.getLibraryName(), State.getCards())
                    end
                else
                    State.saveChipIdentity(new_id, State.getLibraryName(), State.getCards())
                end
                local retry_resp, retry_err = _request("GET", path, { identity = new_id })
                if retry_resp and retry_resp.status == 200 and type(retry_resp.body) == "table" and retry_resp.body.fulfill and type(retry_resp.body.fulfill.href) == "string" then
                    fulfill_url = retry_resp.body.fulfill.href
                else
                    return nil, retry_err or (retry_resp and ("Libby fulfillment failed with HTTP " .. tostring(retry_resp.status))) or "Libby fulfillment failed"
                end
            else
                return nil, err or "Libby fulfillment failed: missing_chip"
            end
        end
    elseif response.status == 400 then
        return nil, "Libby rejected fulfillment (HTTP 400): Format not available for this loan (title may be restricted to Libby or Kindle)."
    elseif response.status ~= 200 then
        return nil, "Libby fulfillment request failed with HTTP " .. tostring(response.status)
    else
        local href = type(response.body) == "table" and response.body.fulfill and response.body.fulfill.href
        if type(href) ~= "string" or href == "" then
            return nil, "Libby fulfillment response did not contain fulfill.href"
        end
        fulfill_url = href
    end

    log.info("libbee api: downloading ACSM payload from " .. tostring(fulfill_url):sub(1, 80))

    local transport = _getTransport()
    local dl_resp, dl_err = transport:request({
        method      = "GET",
        base_url    = fulfill_url,
        path        = "",
        is_download = true,
        headers     = {
            ["User-Agent"] = M.USER_AGENT,
            ["Accept"]     = "*/*",
        },
    })

    if not dl_resp then return nil, "Download failed: " .. tostring(dl_err) end
    if dl_resp.status ~= 200 then
        return nil, "ACSM download failed with HTTP " .. tostring(dl_resp.status)
    end
    if type(dl_resp.raw_body) ~= "string" or dl_resp.raw_body == "" then
        return nil, "ACSM download returned empty body"
    end

    -- Write to destination file
    local fh, open_err = io.open(dest_path, "wb")
    if not fh then return nil, "Cannot create file: " .. tostring(open_err) end
    fh:write(dl_resp.raw_body)
    fh:close()

    log.info("libbee api: successfully downloaded ACSM to " .. dest_path .. " (" .. tostring(#dl_resp.raw_body) .. " bytes)")
    return true
end

-- ---------------------------------------------------------------------------
-- File Path Helpers
-- ---------------------------------------------------------------------------

function M.getAcsmPath(base_dir, loan)
    local title = (loan and loan.title or "download"):gsub('[/\\:*?"<>|]', "_"):gsub("%s+", "_")
    if #title > 60 then title = title:sub(1, 60) end
    local ext = ".acsm"
    if loan and loan.format == "ebook-epub-open" then ext = ".epub" end
    return base_dir .. "/" .. title .. ext
end

function M.getDefaultDownloadDir()
    -- 1. Check KOReader user-configured Library / Home folder
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local home_dir = G_reader_settings:readSetting("home_dir")
        if home_dir and home_dir ~= "" then
            local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
            if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
            if lfs_ok and lfs and lfs.attributes(home_dir, "mode") == "directory" then
                return home_dir .. "/ Libby"
            end
        end
    end

    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        local candidates = {
            DS.getDataDir and DS:getDataDir() or nil,
            DS.getSettingsDir and (DS:getSettingsDir() .. "/..") or nil,
        }
        for _, path in ipairs(candidates) do
            if path then
                local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
                if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
                if lfs_ok and lfs and lfs.attributes(path, "mode") == "directory" then
                    return path .. "/ Libby"
                end
            end
        end
    end

    local candidates = {
        "/mnt/us/documents",
        "/mnt/onboard",
        "/sdcard/Books",
        "/storage/emulated/0/Books",
        "/tmp",
    }
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    for _, path in ipairs(candidates) do
        if lfs_ok and lfs and lfs.attributes(path, "mode") == "directory" then
            return path .. "/ Libby"
        end
    end

    return "/tmp/ Libby"
end

function M.ensureDownloadDir(dir)
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    if not lfs_ok then return false, "lfs module unavailable" end

    if lfs.attributes(dir, "mode") == "directory" then return true end

    local ok = lfs.mkdir(dir)
    if not ok then return nil, "Could not create directory: " .. tostring(dir) end
    return true
end

function M.returnLoan(loan)
    if type(loan) ~= "table" then
        return nil, "Loan is missing"
    end

    local identity = loan.chip_identity or State.getChipIdentity(loan.account_id) or State.getChipIdentity()
    if not identity or identity == "" then
        return nil, "Not authenticated — please run setup first"
    end

    local card_id = loan.card_id or (loan.raw and (loan.raw.cardId or loan.raw.card_id))
    local loan_id = loan.id or loan.loanId or loan.reserveId or (loan.raw and (loan.raw.id or loan.raw.loanId or loan.raw.reserveId))

    if not card_id or tostring(card_id) == "" then
        return nil, "Loan card id is missing"
    end
    if not loan_id or tostring(loan_id) == "" then
        return nil, "Loan id is missing"
    end

    local path = "/card/" .. tostring(card_id) .. "/loan/" .. tostring(loan_id)
    log.info("libbee api: returning loan early via " .. path .. " (account=" .. tostring(loan.account_id or "default") .. ")")

    local response, err = _request("DELETE", path, { identity = identity })
    if not response then return nil, err end

    -- Handle missing_chip 403 with auto-refresh and retry
    if response.status == 403 and _responseResult(response) == "missing_chip" then
        log.info("libbee api: missing_chip received during return, refreshing chip")
        local refreshed, refresh_err = M.getChip(identity, false)
        if not refreshed or type(refreshed.identity) ~= "string" then
            return nil, "AUTH_EXPIRED"
        end
        identity = refreshed.identity
        if loan.account_id then
            local acc = State.getAccount(loan.account_id)
            if acc then
                acc.chip_identity = identity
                State.addOrUpdateAccount(acc)
            end
        else
            State.saveChipIdentity(identity)
        end
        response, err = _request("DELETE", path, { identity = identity })
        if not response then return nil, err end
    end

    if response.status == 401 or response.status == 403 then
        return nil, "AUTH_EXPIRED"
    end

    if response.status < 200 or response.status >= 300 then
        return nil, "Libby return failed with HTTP " .. tostring(response.status)
    end

    log.info("libbee api: successfully returned loan " .. tostring(loan_id))
    return true
end

return M
