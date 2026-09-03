-- libbee_drm.lua — Embedded ACSM Fulfillment & DRM Manager for Libbee
-- Handles Adobe & ByteBooks ADEPT activation (Anonymous default & ByteBooks account)
-- and direct ACSM -> EPUB/PDF fulfillment. Passwords are NEVER stored.

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local log = require(plugin_path .. "libbee_logger")
local State = require(plugin_path .. "libbee_state")

-- Resolve base directory of the plugin to configure package.path for submodules
local info = debug.getinfo(1, "S")
local plugin_root = (info and info.source and info.source:match("^@(.*[/\\])")) or "./"
plugin_root = plugin_root:gsub("[/\\]+$", "")

-- Ensure plugin root is in package.path
local extra_paths = {
    plugin_root .. "/?.lua",
}
for _, p in ipairs(extra_paths) do
    if not package.path:find(p, 1, true) then
        package.path = p .. ";" .. package.path
    end
end

local adobe = require("libbee_adobe_core")
local fulfillment = require("libbee_adobe_fulfillment")
local naming = require("libbee_adobe_naming")
local xml = require("libbee_adobe_xml")

local M = {}

local function _isActivationError(err)
    if type(err) ~= "string" then return false end
    return err:find("E_ADEPT_USER_AUTH", 1, true) ~= nil
        or err:find("E_ADEPT_DISTRIBUTOR_AUTH", 1, true) ~= nil
        or err:find("E_ADEPT_REQUEST_EXPIRED", 1, true) ~= nil
        or err:find("E_ADEPT", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- Activation Lifecycle
-- ---------------------------------------------------------------------------

--- Restores activation from State, or nil if none saved
function M.restoreActivation()
    local saved = State.getDrmActivation()
    if not saved then return nil end
    local restored, err = adobe.restoreActivation(saved)
    if not restored then
        log.warn("libbee_drm: could not restore saved activation: " .. tostring(err))
        State.clearDrmActivation()
        return nil
    end
    return restored
end

--- Performs anonymous device activation (default, single device)
function M.createAnonymousActivation()
    log.info("libbee_drm: starting anonymous device activation...")
    local auth_info, authErr = adobe.getAuthenticationServiceInfo()
    if not auth_info then
        return nil, "Could not fetch authentication service info: " .. tostring(authErr)
    end

    local creds, signInErr = adobe.signIn("anonymous", "", "", auth_info.certificate)
    if not creds then
        return nil, "Anonymous sign-in failed: " .. tostring(signInErr)
    end

    local serial = State.getOrCreateDeviceSerial and State.getOrCreateDeviceSerial()
    local device_uuid, fingerprintOrErr = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12, serial)
    if not device_uuid then
        return nil, "Device registration failed: " .. tostring(fingerprintOrErr)
    end

    local fingerprint = fingerprintOrErr
    local serialized, serializeErr = adobe.serializeActivation(creds, device_uuid, fingerprint, auth_info.certificate, creds.activationURL)
    if not serialized then
        return nil, "Serialization failed: " .. tostring(serializeErr)
    end

    State.saveDrmActivation(serialized, "anonymous", nil)
    log.info("libbee_drm: anonymous activation successful (uuid=" .. tostring(device_uuid) .. ")")

    return {
        creds = creds,
        deviceUUID = device_uuid,
        fingerprint = fingerprint,
        authCert = auth_info.certificate,
    }
end

--- Authorizes device with a ByteBooks / Adobe ID account (multi-device sync)
-- Password is used ONLY in-memory for this request and NEVER persisted.
function M.authorizeByteBooks(username, password)
    if not username or username == "" then
        return nil, "Email / Username is required"
    end
    if not password or password == "" then
        return nil, "Password is required"
    end

    log.info("libbee_drm: authorizing ByteBooks account for " .. tostring(username))
    local auth_info, authErr = adobe.getAuthenticationServiceInfo()
    if not auth_info then
        return nil, "Could not reach ByteBooks authentication service: " .. tostring(authErr)
    end

    -- Determine sign-in method from server info (default to AdobeID for ByteBooks / Adobe accounts)
    local method = "AdobeID"
    if auth_info.methods and #auth_info.methods > 0 then
        for _, m in ipairs(auth_info.methods) do
            if m.method and (m.method == "AdobeID" or m.method:lower():find("adobe", 1, true) or m.method:lower():find("bytebooks", 1, true)) then
                method = m.method
                break
            end
        end
    end

    local creds, signInErr = adobe.signIn(method, username, password, auth_info.certificate)
    if not creds then
        return nil, "ByteBooks authorization failed: " .. tostring(signInErr)
    end

    local serial = State.getOrCreateDeviceSerial and State.getOrCreateDeviceSerial()
    local device_uuid, fingerprintOrErr = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12, serial)
    if not device_uuid then
        return nil, "Device registration failed: " .. tostring(fingerprintOrErr)
    end

    local fingerprint = fingerprintOrErr
    local serialized, serializeErr = adobe.serializeActivation(creds, device_uuid, fingerprint, auth_info.certificate, creds.activationURL)
    if not serialized then
        return nil, "Serialization failed: " .. tostring(serializeErr)
    end

    -- Save activation without password!
    State.saveDrmActivation(serialized, "bytebooks", username)
    log.info("libbee_drm: ByteBooks authorization successful for " .. tostring(username))

    return true
end

--- Deauthorizes and resets DRM activation
function M.deauthorize()
    State.clearDrmActivation()
    log.info("libbee_drm: DRM activation cleared")
    return true
end

--- Returns account information table
function M.getAccountInfo()
    return State.getDrmAccountInfo()
end

--- Ensures an active device activation exists (creates anonymous if none)
function M.ensureActivated(force_new)
    if not force_new then
        local existing = M.restoreActivation()
        if existing then
            return existing, true
        end
    end
    local created, err = M.createAnonymousActivation()
    return created, false, err
end

-- ---------------------------------------------------------------------------
-- ACSM Metadata & Output Path Helpers
-- ---------------------------------------------------------------------------

local function _firstMetadataValue(meta, key)
    if type(meta) ~= "table" then return nil end
    local raw = meta[key] or meta[key:gsub("^.-:", "")] or meta["adept:" .. key]
    if raw == nil then
        for k, v in pairs(meta) do
            if type(k) == "string" and (k == key or k:match(":" .. key:gsub("^.-:", "") .. "$")) then
                raw = v
                break
            end
        end
    end
    if type(raw) == "table" then return raw[1] end
    if type(raw) == "string" then return raw end
    return nil
end

function M.parseAcsmMetadata(acsm_path_or_content)
    local raw_data = acsm_path_or_content
    local f = io.open(acsm_path_or_content, "rb")
    if f then
        raw_data = f:read("*a")
        f:close()
    end

    if type(raw_data) ~= "string" or raw_data == "" then return nil end

    local ok, parsed = pcall(xml.deserialize, raw_data)
    if not ok or type(parsed) ~= "table" then return nil end

    local token = parsed.fulfillmentToken or parsed["adept:fulfillmentToken"]
    if not token then
        for k, v in pairs(parsed) do
            if type(k) == "string" and (k:match("fulfillmentToken$") or k:match("licenseToken$")) then
                token = v
                break
            end
        end
    end
    if not token or type(token) ~= "table" then return nil end

    local function getField(t, name)
        if type(t) ~= "table" then return nil end
        local d = t[name] or t["adept:" .. name]
        if d ~= nil then return d end
        for k, v in pairs(t) do
            if type(k) == "string" and (k == name or k:match(":" .. name .. "$")) then
                return v
            end
        end
        return nil
    end

    local rii = getField(token, "resourceItemInfo")
    if not rii then return nil end

    local resource = getField(rii, "resource")
    local meta = getField(rii, "metadata")
    local resource_item = getField(rii, "resourceItem")
    local asset = resource_item and getField(resource_item, "asset")

    return {
        title = _firstMetadataValue(meta, "dc:title"),
        creator = _firstMetadataValue(meta, "dc:creator"),
        identifier = _firstMetadataValue(meta, "dc:identifier"),
        publisher = _firstMetadataValue(meta, "dc:publisher"),
        language = _firstMetadataValue(meta, "dc:language"),
        subject = _firstMetadataValue(meta, "dc:subject"),
        description = _firstMetadataValue(meta, "dc:description"),
        resourceId = type(resource) == "table" and resource[1] or resource,
        format = _firstMetadataValue(meta, "dc:format") or (asset and (asset.assetType or getField(asset, "assetType"))),
    }
end

function M.deriveFinalBookPath(base_dir, loan, acsm_meta)
    local ext = ".epub"
    if acsm_meta and acsm_meta.format then
        local fmt = acsm_meta.format
        if type(fmt) == "table" then fmt = fmt[1] end
        if fmt == "application/pdf" then ext = ".pdf" end
    elseif loan and loan.format and loan.format:find("pdf", 1, true) then
        ext = ".pdf"
    end

    local title = (acsm_meta and acsm_meta.title) or (loan and loan.title) or "book"
    local safe_title = naming.sanitizeTitle(title) or title:gsub('[/\\:*?"<>|]', "_"):gsub("%s+", "_")
    if #safe_title > 60 then safe_title = safe_title:sub(1, 60) end

    local path = base_dir .. "/" .. safe_title .. ext
    local f = io.open(path, "r")
    if not f then return path end
    f:close()

    for i = 1, 999 do
        local candidate = base_dir .. "/" .. safe_title .. " (" .. i .. ")" .. ext
        local cf = io.open(candidate, "r")
        if not cf then return candidate end
        cf:close()
    end

    return path
end

-- ---------------------------------------------------------------------------
-- Fulfillment Engine
-- ---------------------------------------------------------------------------

--- Fulfills an ACSM file into a decrypted, ready-to-read EPUB or PDF
function M.fulfillAcsm(acsm_path, output_path, progress_fn)
    log.info("libbee_drm: fulfilling ACSM at " .. tostring(acsm_path) .. " -> " .. tostring(output_path))
    local activation, reused, act_err = M.ensureActivated(false)
    if not activation then
        return nil, act_err or "Could not initialize DRM activation"
    end

    local result, err = fulfillment.process(
        acsm_path,
        output_path,
        activation.creds,
        activation.deviceUUID,
        activation.fingerprint,
        activation.authCert,
        progress_fn
    )

    -- If fulfillment failed due to expired activation and we had reused one, retry once with fresh activation
    if not result and reused and _isActivationError(err) then
        log.warn("libbee_drm: saved activation failed with " .. tostring(err) .. ", retrying with fresh activation...")
        local acct = State.getDrmAccountInfo()
        if acct.mode == "anonymous" then
            M.deauthorize()
            local fresh_act, reused_fresh, fresh_err = M.ensureActivated(true)
            if fresh_act then
                result, err = fulfillment.process(
                    acsm_path,
                    output_path,
                    fresh_act.creds,
                    fresh_act.deviceUUID,
                    fresh_act.fingerprint,
                    fresh_act.authCert,
                    progress_fn
                )
            else
                return nil, fresh_err or "Activation renewal failed"
            end
        end
    end

    if not result then
        if err and err:find("E_LIC_ALREADY_FULFILLED_BY_ANOTHER_USER") then
            return nil, "ALREADY_FULFILLED"
        end
        log.err("libbee_drm: fulfillment failed: " .. tostring(err))
        return nil, err or "Fulfillment failed"
    end

    log.info("libbee_drm: successfully fulfilled book to " .. tostring(output_path))
    return true, output_path
end

return M
