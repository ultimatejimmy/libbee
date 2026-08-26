-- libbee_state.lua — Persistent State Manager
-- Stores chip identity, pending setup tokens, shelf cache, and UI preferences in DataStorage.

local logger = require("logger")

local M = {}

local SECONDS_PER_DAY = 24 * 60 * 60

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function _stateDir()
    local ok, DS = pcall(require, "datastorage")
    local base = "/tmp"
    if ok and DS and DS.getSettingsDir then
        local s = DS:getSettingsDir()
        if s and s ~= "" then base = s end
    end
    local dir = base .. "/libbee"
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    if lfs_ok and lfs and lfs.mkdir then
        pcall(lfs.mkdir, base)
        pcall(lfs.mkdir, dir)
    end
    pcall(os.execute, "mkdir -p " .. dir .. " 2>/dev/null")
    return dir
end

local function _statePath()
    return _stateDir() .. "/state.json"
end

local function _shelfCachePath()
    return _stateDir() .. "/shelf_cache.json"
end

-- ---------------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------------

local function _readJson(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, data = pcall(rapidjson.decode, raw)
        if ok and type(data) == "table" then return data end
    end
    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then return data end
    end
    return nil
end

local function _writeJson(path, data)
    local encoded = nil
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, res = pcall(rapidjson.encode, data)
        if ok and type(res) == "string" then encoded = res end
    end
    if not encoded then
        local ok_j, json = pcall(require, "json")
        if ok_j and json then
            local ok, res = pcall(json.encode, data)
            if ok and type(res) == "string" then encoded = res end
        end
    end
    if not encoded then
        logger.warn("libbee state: json encoder unavailable, cannot save state")
        return false
    end
    local fh = io.open(path, "w")
    if not fh then
        logger.warn("libbee state: cannot write to " .. tostring(path))
        return false
    end
    fh:write(encoded)
    fh:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Chip Identity & Setup State (Multi-Account Supported)
-- ---------------------------------------------------------------------------

local function _extractShortChipId(identity)
    if type(identity) ~= "string" then return nil end
    local payload = identity:match("^[^.]+%.([^.]+)%.")
    if not payload then return nil end
    local ok_tr, Transport = pcall(require, "libbee_transport")
    local transport = ok_tr and Transport and Transport.new and Transport.new()
    local decoded = nil
    if transport and transport.base64url_decode then
        decoded = transport:base64url_decode(payload)
    end
    if not decoded then
        -- fallback rudimentary base64 url decode
        local b64 = payload:gsub("-", "+"):gsub("_", "/")
        local pad = #b64 % 4
        if pad == 2 then b64 = b64 .. "==" elseif pad == 3 then b64 = b64 .. "=" end
        local b64_ok, mime = pcall(require, "mime")
        if b64_ok and mime and mime.unb64 then
            decoded = mime.unb64(b64)
        end
    end
    if decoded then
        local ok_rj, rapidjson = pcall(require, "rapidjson")
        local data = (ok_rj and rapidjson and pcall(rapidjson.decode, decoded)) and select(2, pcall(rapidjson.decode, decoded))
        if not data then
            local ok_j, json = pcall(require, "json")
            data = (ok_j and json and pcall(json.decode, decoded)) and select(2, pcall(json.decode, decoded))
        end
        if type(data) == "table" and type(data.chip) == "table" and type(data.chip.id) == "string" then
            return data.chip.id:match("^([^-]+)") or data.chip.id
        end
    end
    return nil
end

local function _resolveCardName(card)
    if type(card) ~= "table" then return "Library Card" end
    local lib = type(card.library) == "table" and card.library or nil
    local val = (lib and lib.name) or card.libraryName or card.name or (lib and lib.websiteId) or card.advantageKey
    if type(val) == "string" and val ~= "" then
        return val
    end
    return "Library Card"
end

function M.cardEmail(card)
    if type(card) ~= "table" then return nil end
    if type(card.emailAddress) == "string" and card.emailAddress ~= "" then
        return card.emailAddress
    end
    return nil
end

function M.cardSuffix(card)
    if type(card) ~= "table" then return nil end
    local custom_name = card.cardName
    if type(custom_name) == "string" and custom_name ~= "" and custom_name ~= "Library Card" and not custom_name:match("^card_") and not custom_name:match("^%d+$") then
        return custom_name
    end
    local num = tostring(card.cardName or card.username or card.cardId or card.id or "")
    if num:match("^%d+$") and #num >= 4 then
        return "…" .. num:sub(-4)
    elseif num ~= "" and num ~= "Library Card" and not num:match("^card_") then
        return num
    end
    return nil
end

function M.cardUsername(card)
    if type(card) ~= "table" then return nil end
    local u = card.username or card.cardName
    if type(u) == "string" and u ~= "" and u ~= "Library Card" and not u:match("^card_") then
        return u
    end
    return nil
end

function M.cardTag(card)
    if type(card) ~= "table" then return nil end
    -- 1. Username / Custom Nickname (if non-numeric and not "Library Card")
    local custom_name = card.cardName
    if type(custom_name) == "string" and custom_name ~= "" and custom_name ~= "Library Card" and not custom_name:match("^card_") and not custom_name:match("^%d+$") then
        return custom_name
    end
    local username = card.username
    if type(username) == "string" and username ~= "" and not username:match("^%d+$") then
        return username
    end

    -- 2. Email
    local email = M.cardEmail(card)
    if email then
        return email
    end

    -- 3. Card Number Suffix (last 4 digits)
    local suffix = M.cardSuffix(card)
    if suffix then
        return suffix
    end
    return nil
end

function M.cardIdentifier(card)
    return M.cardTag(card)
end

function M.cardDisplayName(card)
    if type(card) ~= "table" then return "Library Card" end
    local lib_name = _resolveCardName(card)
    local tag = M.cardTag(card)

    if tag then
        return lib_name .. " (" .. tag .. ")"
    end
    return lib_name
end

function M.cardDetailString(card)
    if type(card) ~= "table" then return "" end
    local parts = {}
    local email = M.cardEmail(card)
    local suffix = M.cardSuffix(card)
    if email then table.insert(parts, email) end
    if suffix then
        table.insert(parts, "Card " .. suffix)
    else
        local u = M.cardUsername(card)
        if u then table.insert(parts, "Card " .. u) end
    end
    return table.concat(parts, " · ")
end

function M.accountDisplayName(account)
    if type(account) ~= "table" then return "Libby Account" end
    local cards = account.cards or {}
    if #cards > 0 then
        local names = {}
        for _, c in ipairs(cards) do
            table.insert(names, M.cardDisplayName(c))
        end
        return table.concat(names, ", ")
    end
    if account.library_name and account.library_name ~= "" then
        return account.library_name
    end
    return "Libby Account"
end

function M.getAllCards()
    local accounts = M.getAccounts()
    local all_cards = {}
    for _, acc in ipairs(accounts) do
        for _, card in ipairs(acc.cards or {}) do
            table.insert(all_cards, card)
        end
    end
    return all_cards
end

function M.loanGroupLabel(loan, all_cards)
    if type(loan) ~= "table" then return "Libby" end
    all_cards = all_cards or M.getAllCards()
    local cid = tostring(loan.card_id or (loan.raw and (loan.raw.cardId or loan.raw.card_id)) or "")
    if cid ~= "" then
        for _, c in ipairs(all_cards) do
            if tostring(c.cardId or c.id or "") == cid then
                return M.cardDisplayName(c)
            end
        end
    end
    return loan.library or M.getLibraryName() or "Libby"
end

function M.getAccounts()
    local data = _readJson(_statePath())
    if not data then return {} end
    local accounts = data.accounts
    if type(accounts) == "table" and #accounts > 0 then
        return accounts
    end
    -- Backward compatibility migration for legacy single chip_identity
    if type(data.chip_identity) == "string" and data.chip_identity ~= "" then
        local legacy_account = {
            id            = _extractShortChipId(data.chip_identity) or "account_1",
            chip_identity = data.chip_identity,
            library_name  = data.library_name or "",
            cards         = data.cards or {},
            registered_at = data.registered_at or os.time(),
        }
        return { legacy_account }
    end
    return {}
end

function M.getAccount(account_id)
    local accounts = M.getAccounts()
    if not account_id then return accounts[1] end
    for _, acc in ipairs(accounts) do
        if tostring(acc.id) == tostring(account_id) then
            return acc
        end
    end
    return nil
end

function M.addOrUpdateAccount(account)
    if type(account) ~= "table" or type(account.chip_identity) ~= "string" or account.chip_identity == "" then
        return false
    end
    local data = _readJson(_statePath()) or {}
    local accounts = M.getAccounts()
    local acc_id = account.id or _extractShortChipId(account.chip_identity) or ("acc_" .. tostring(os.time()))
    
    local found = false
    for idx, acc in ipairs(accounts) do
        local is_match = (acc.id and acc.id == acc_id) or (acc.chip_identity == account.chip_identity)
        if not is_match and acc.chip_identity and account.chip_identity then
            local id1 = _extractShortChipId(acc.chip_identity)
            local id2 = _extractShortChipId(account.chip_identity)
            if id1 and id2 and id1 == id2 then
                is_match = true
            end
        end
        if is_match then
            accounts[idx] = {
                id            = acc_id,
                chip_identity = account.chip_identity,
                library_name  = account.library_name or acc.library_name or "",
                cards         = account.cards or acc.cards or {},
                registered_at = acc.registered_at or os.time(),
                updated_at    = os.time(),
            }
            found = true
            break
        end
    end

    if not found then
        table.insert(accounts, {
            id            = acc_id,
            chip_identity = account.chip_identity,
            library_name  = account.library_name or "",
            cards         = account.cards or {},
            registered_at = account.registered_at or os.time(),
        })
    end

    data.accounts = accounts
    -- Keep legacy top-level keys in sync with primary account
    if accounts[1] then
        data.chip_identity = accounts[1].chip_identity
        data.library_name  = accounts[1].library_name
        data.cards         = accounts[1].cards
        data.registered_at = accounts[1].registered_at
    end
    data.pending_identity = nil
    data.pending_code     = nil

    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: saved account " .. tostring(acc_id) .. " (total accounts: " .. #accounts .. ")")
    end
    return ok
end

function M.removeAccount(account_id)
    local data = _readJson(_statePath()) or {}
    local accounts = M.getAccounts()
    local new_accounts = {}
    local removed = false

    for _, acc in ipairs(accounts) do
        if tostring(acc.id) == tostring(account_id) or (account_id == nil and #new_accounts == 0) then
            removed = true
        else
            table.insert(new_accounts, acc)
        end
    end

    if removed then
        data.accounts = new_accounts
        if new_accounts[1] then
            data.chip_identity = new_accounts[1].chip_identity
            data.library_name  = new_accounts[1].library_name
            data.cards         = new_accounts[1].cards
            data.registered_at = new_accounts[1].registered_at
        else
            data.chip_identity = nil
            data.library_name  = nil
            data.cards         = nil
            data.registered_at = nil
        end
        _writeJson(_statePath(), data)
        logger.info("libbee state: removed account " .. tostring(account_id))
    end
    return removed
end

function M.getChipIdentity(account_id)
    local accounts = M.getAccounts()
    if account_id then
        for _, acc in ipairs(accounts) do
            if tostring(acc.id) == tostring(account_id) then
                return acc.chip_identity
            end
        end
    end
    if accounts[1] and type(accounts[1].chip_identity) == "string" and accounts[1].chip_identity ~= "" then
        return accounts[1].chip_identity
    end
    local data = _readJson(_statePath())
    if data and type(data.chip_identity) == "string" and data.chip_identity ~= "" then
        return data.chip_identity
    end
    return nil
end

function M.saveChipIdentity(chip_identity, library_name, cards)
    return M.addOrUpdateAccount({
        chip_identity = chip_identity,
        library_name  = library_name,
        cards         = cards,
    })
end

function M.getPendingIdentity()
    local data = _readJson(_statePath())
    if data and type(data.pending_identity) == "string" and data.pending_identity ~= "" then
        return data.pending_identity
    end
    return nil
end

function M.savePendingIdentity(pending_identity, pending_code)
    local data = _readJson(_statePath()) or {}
    data.pending_identity = pending_identity
    data.pending_code     = pending_code
    return _writeJson(_statePath(), data)
end

function M.clearPendingIdentity()
    local data = _readJson(_statePath())
    if data and (data.pending_identity or data.pending_code) then
        data.pending_identity = nil
        data.pending_code     = nil
        _writeJson(_statePath(), data)
    end
end

function M.clearChipIdentity()
    local data = _readJson(_statePath()) or {}
    data.accounts          = nil
    data.chip_identity     = nil
    data.library_name      = nil
    data.cards             = nil
    data.registered_at     = nil
    data.pending_identity  = nil
    data.pending_code      = nil
    _writeJson(_statePath(), data)
    logger.info("libbee state: all chip identities cleared")
end

function M.getLibraryName(account_id)
    local acc = M.getAccount(account_id)
    if acc and acc.library_name and acc.library_name ~= "" then
        return acc.library_name
    end
    local data = _readJson(_statePath())
    return data and data.library_name or nil
end

function M.getCards(account_id)
    if account_id then
        local acc = M.getAccount(account_id)
        return acc and acc.cards or nil
    end
    local all_cards = {}
    local accounts = M.getAccounts()
    for _, acc in ipairs(accounts) do
        if type(acc.cards) == "table" then
            for _, card in ipairs(acc.cards) do
                table.insert(all_cards, card)
            end
        end
    end
    if #all_cards > 0 then return all_cards end
    local data = _readJson(_statePath())
    return data and data.cards or nil
end

function M.getCardNames()
    local cards = M.getCards() or {}
    local names = {}
    local seen = {}
    for _, card in ipairs(cards) do
        local name = _resolveCardName(card)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    return names
end

function M.cardName(card)
    return _resolveCardName(card)
end

function M.isAuthenticated()
    local accounts = M.getAccounts()
    return #accounts > 0 or M.getChipIdentity() ~= nil
end

-- ---------------------------------------------------------------------------
-- DRM & ByteBooks Activation State
-- ---------------------------------------------------------------------------

function M.getDrmActivation()
    local data = _readJson(_statePath())
    return data and data.drm_activation or nil
end

function M.saveDrmActivation(activation_blob, mode, email)
    local data = _readJson(_statePath()) or {}
    data.drm_activation = activation_blob
    data.drm_mode       = mode or "anonymous"
    data.drm_email      = email or ""
    data.drm_updated_at = os.time()
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: DRM activation saved (mode=" .. tostring(data.drm_mode) .. ")")
    end
    return ok
end

function M.getDrmAccountInfo()
    local data = _readJson(_statePath())
    local activated = (data and data.drm_activation ~= nil)
    return {
        activated = activated,
        mode      = (data and data.drm_mode) or "anonymous",
        email     = (data and data.drm_email) or "",
        updated_at = data and data.drm_updated_at or nil,
    }
end

function M.clearDrmActivation()
    local data = _readJson(_statePath()) or {}
    data.drm_activation = nil
    data.drm_mode       = nil
    data.drm_email      = nil
    data.drm_updated_at = nil
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: DRM activation cleared")
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- UI Preferences
-- ---------------------------------------------------------------------------

function M.getViewMode()
    local data = _readJson(_statePath())
    if data and (data.view_mode == "cover" or data.view_mode == "list") then
        return data.view_mode
    end
    return "list"
end

function M.saveViewMode(view_mode)
    local data = _readJson(_statePath()) or {}
    data.view_mode = (view_mode == "cover") and "cover" or "list"
    return _writeJson(_statePath(), data)
end

function M.getGroupByCard()
    local data = _readJson(_statePath())
    if data and data.group_by_card ~= nil then
        return data.group_by_card == true
    end
    return true -- default: grouping enabled
end

function M.setGroupByCard(enabled)
    local data = _readJson(_statePath()) or {}
    data.group_by_card = (enabled == true)
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: group_by_card set to " .. tostring(data.group_by_card))
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Auto-Delete Expired Loans Settings & Download Tracking Registry
-- ---------------------------------------------------------------------------

function M.getAutoDeleteExpired()
    local data = _readJson(_statePath())
    if data and data.auto_delete_expired ~= nil then
        return data.auto_delete_expired == true
    end
    return true -- default enabled
end

function M.setAutoDeleteExpired(enabled)
    local data = _readJson(_statePath()) or {}
    data.auto_delete_expired = (enabled == true)
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: auto_delete_expired set to " .. tostring(data.auto_delete_expired))
    end
    return ok
end

function M.getDownloadRegistry()
    local data = _readJson(_statePath())
    if data and type(data.downloaded_books) == "table" then
        return data.downloaded_books
    end
    return {}
end

function M.getTrackedDownload(loan_id)
    if not loan_id then return nil end
    local registry = M.getDownloadRegistry()
    return registry[tostring(loan_id)]
end

function M.registerDownload(loan, file_path)
    if type(loan) ~= "table" or not file_path or file_path == "" then
        return false
    end
    local loan_id = tostring(loan.id or loan.loanId or loan.reserveId or "")
    if loan_id == "" then
        return false
    end
    local data = _readJson(_statePath()) or {}
    data.downloaded_books = data.downloaded_books or {}
    data.downloaded_books[loan_id] = {
        loan_id       = loan_id,
        reserve_id    = loan.reserveId and tostring(loan.reserveId) or nil,
        title         = loan.title or "",
        author        = loan.author or "",
        path          = file_path,
        expires       = loan.expires or loan.expireDate or loan.expireTimestamp,
        downloaded_at = os.time(),
    }
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: registered download tracking for loan " .. loan_id .. " (" .. tostring(loan.title) .. ")")
    end
    return ok
end

function M.unregisterDownload(loan_id)
    if not loan_id then return false end
    local id_str = tostring(loan_id)
    local data = _readJson(_statePath()) or {}
    if data.downloaded_books and data.downloaded_books[id_str] then
        data.downloaded_books[id_str] = nil
        local ok = _writeJson(_statePath(), data)
        if ok then
            logger.info("libbee state: unregistered download tracking for loan " .. id_str)
        end
        return ok
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Download Directory Settings
-- ---------------------------------------------------------------------------

function M.getDefaultDownloadDir()
    local ok_api, API = pcall(require, "libbee_api")
    if ok_api and API and API.getDefaultDownloadDir then
        return API.getDefaultDownloadDir()
    end
    return "/tmp/Libby"
end

function M.getCustomDownloadDir(plugin_dir)
    local data = _readJson(_statePath())
    local custom = data and data.download_dir
    if not custom or custom == "" then
        if plugin_dir and plugin_dir ~= "" then
            local ok_cfg, cfg = pcall(dofile, plugin_dir .. "/libbee_config.lua")
            if ok_cfg and type(cfg) == "table" and cfg.download_dir and cfg.download_dir ~= "" then
                custom = cfg.download_dir
            end
        end
    end
    if custom and custom ~= "" then
        local clean = tostring(custom):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
        local def = M.getDefaultDownloadDir():gsub("[/\\]+$", "")
        if clean ~= "" and clean ~= def then
            return clean
        end
    end
    return nil
end

function M.isCustomDownloadDir(plugin_dir)
    return M.getCustomDownloadDir(plugin_dir) ~= nil
end

function M.getDownloadDir(plugin_dir)
    local custom = M.getCustomDownloadDir(plugin_dir)
    if custom and custom ~= "" then
        return custom
    end
    return M.getDefaultDownloadDir()
end

function M.setCustomDownloadDir(path)
    local data = _readJson(_statePath()) or {}
    if not path or path:match("^%s*$") then
        return M.resetCustomDownloadDir()
    end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    local def = M.getDefaultDownloadDir():gsub("[/\\]+$", "")
    if clean == "" or clean == def then
        return M.resetCustomDownloadDir()
    end

    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then lfs_ok, lfs = pcall(require, "lfs") end
    if lfs_ok and lfs and lfs.attributes and not lfs.attributes(clean) then
        pcall(function() lfs.mkdir(clean) end)
    end

    data.download_dir = clean
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: custom download_dir set to " .. clean)
    end
    return ok
end

function M.resetCustomDownloadDir()
    local data = _readJson(_statePath()) or {}
    data.download_dir = nil
    local ok = _writeJson(_statePath(), data)
    if ok then
        logger.info("libbee state: reset download_dir to default")
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Date / Loan helpers
-- ---------------------------------------------------------------------------

local function date_ordinal(year, month, day)
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

function M.loanDaysRemaining(loan, now_timestamp)
    if type(loan) ~= "table" then return nil end
    local expire = loan.expireTimestamp or loan.expires or loan.expireDate
    if type(expire) == "number" then
        local seconds = expire - (now_timestamp or os.time())
        if seconds <= 0 then return 0 end
        return math.ceil(seconds / SECONDS_PER_DAY)
    end
    if type(expire) == "string" then
        local year, month, day = expire:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if year then
            year, month, day = tonumber(year), tonumber(month), tonumber(day)
            local now = os.date("!*t", now_timestamp or os.time())
            local remaining = date_ordinal(year, month, day) - date_ordinal(now.year, now.month, now.day)
            return remaining < 0 and 0 or remaining
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Shelf Cache
-- ---------------------------------------------------------------------------

local SHELF_CACHE_TTL = 7 * 24 * 60 * 60 -- 7 days

function M.getShelfCache(allow_stale)
    local data = _readJson(_shelfCachePath())
    if not data or type(data.shelf) ~= "table" then return nil end
    if not allow_stale and (os.time() - (data.timestamp or 0)) > SHELF_CACHE_TTL then
        logger.info("libbee state: shelf cache expired")
        return nil
    end
    return data.shelf
end

function M.saveShelfCache(shelf)
    _writeJson(_shelfCachePath(), {
        timestamp = os.time(),
        shelf     = shelf,
    })
end

function M.clearShelfCache()
    pcall(os.remove, _shelfCachePath())
end

return M
