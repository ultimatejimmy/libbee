-- libbee_transport.lua — HTTP/HTTPS transport & sequence execution
-- Handles standard requests and persistent TLS connection sequences for Libby Sentry.

local logger = require("logger")

local LibbeeTransport = {}
LibbeeTransport.__index = LibbeeTransport

local function url_encode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

local function query_string(query)
    if type(query) ~= "table" then return "" end
    local keys = {}
    for key, value in pairs(query) do
        if value ~= nil then table.insert(keys, key) end
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, url_encode(key) .. "=" .. url_encode(query[key]))
    end
    return table.concat(parts, "&")
end

function LibbeeTransport.new(options)
    options = options or {}
    return setmetatable({
        https        = options.https,
        http         = options.http,
        ltn12        = options.ltn12,
        socket       = options.socket,
        socketutil   = options.socketutil,
        mime         = options.mime,
        json_encode  = options.json_encode,
        json_decode  = options.json_decode,
        tls_options  = options.tls_options or {},
    }, LibbeeTransport)
end

function LibbeeTransport:_load()
    if not self.https then
        local ok, module = pcall(require, "ssl.https")
        if ok and module then
            self.https = module
        else
            logger.warn("libbee transport: ssl.https module could not be loaded: " .. tostring(module))
        end
    end
    if not self.http then
        local ok, module = pcall(require, "socket.http")
        if ok and module then
            self.http = module
        else
            logger.warn("libbee transport: socket.http module could not be loaded: " .. tostring(module))
        end
    end
    if not self.ltn12 then
        local ok, module = pcall(require, "ltn12")
        if ok and module then
            self.ltn12 = module
        else
            logger.warn("libbee transport: ltn12 module could not be loaded: " .. tostring(module))
        end
    end
    if not self.socket then
        local ok, module = pcall(require, "socket")
        if ok and module then
            self.socket = module
        else
            logger.warn("libbee transport: socket module could not be loaded: " .. tostring(module))
        end
    end
    if not self.socketutil then
        local ok, module = pcall(require, "socketutil")
        if ok and module then
            self.socketutil = module
        end
    end
    if not self.mime then
        local ok, module = pcall(require, "mime")
        if ok and module then
            self.mime = module
        else
            logger.warn("libbee transport: mime module could not be loaded: " .. tostring(module))
        end
    end
    if not self.json_encode or not self.json_decode then
        local ok_rj, rapidjson = pcall(require, "rapidjson")
        if ok_rj and rapidjson then
            self.json_encode = self.json_encode or rapidjson.encode
            self.json_decode = self.json_decode or rapidjson.decode
        else
            local ok_j, json = pcall(require, "json")
            if ok_j and json then
                self.json_encode = self.json_encode or json.encode
                self.json_decode = self.json_decode or json.decode
            end
        end
    end
    return true
end

function LibbeeTransport:base64url_decode(value)
    self:_load()
    if type(value) ~= "string" then return nil, "base64url input is missing" end
    if not self.mime or type(self.mime.unb64) ~= "function" then
        return nil, "MIME support is unavailable"
    end

    local normalized = value:gsub("-", "+"):gsub("_", "/")
    local remainder = #normalized % 4
    if remainder == 2 then
        normalized = normalized .. "=="
    elseif remainder == 3 then
        normalized = normalized .. "="
    elseif remainder == 1 then
        return nil, "invalid base64url input length"
    end

    local decoded = self.mime.unb64(normalized)
    if not decoded then return nil, "base64url decode failed" end
    return decoded
end

function LibbeeTransport:request(request)
    self:_load()
    if type(request) ~= "table" then return nil, "request is required" end

    local url = tostring(request.base_url or "") .. tostring(request.path or "")
    local query = query_string(request.query)
    if query ~= "" then url = url .. "?" .. query end

    local headers = {}
    for key, value in pairs(request.headers or {}) do headers[key] = value end
    headers["Accept-Encoding"] = "identity"

    local body
    if request.json ~= nil then
        local ok, encoded = pcall(self.json_encode, request.json)
        if not ok or type(encoded) ~= "string" then return nil, "Could not encode JSON request" end
        body = encoded
        headers["Content-Type"] = "application/json; charset=UTF-8"
        headers["Content-Length"] = tostring(#body)
    end

    if not headers["Content-Length"] and (request.method == "POST" or request.method == "PUT") then
        headers["Content-Length"] = "0"
    end

    local chunks = {}
    local sink = self.ltn12 and self.ltn12.sink and self.ltn12.sink.table and self.ltn12.sink.table(chunks) or nil
    if self.socketutil and type(self.socketutil.table_sink) == "function" then
        sink = self.socketutil.table_sink(chunks)
    end

    local spec = {
        url      = url,
        method   = request.method or "GET",
        headers  = headers,
        source   = body and self.ltn12 and self.ltn12.source and self.ltn12.source.string and self.ltn12.source.string(body) or nil,
        sink     = sink,
        redirect = false,
    }
    for key, value in pairs(self.tls_options) do spec[key] = value end

    if self.socketutil and type(self.socketutil.set_timeout) == "function" then
        if request.is_download or request.large_timeout then
            self.socketutil:set_timeout(self.socketutil.LARGE_BLOCK_TIMEOUT or 30, self.socketutil.LARGE_TOTAL_TIMEOUT or 120)
        else
            self.socketutil:set_timeout(self.socketutil.BLOCK_TIMEOUT or 5, self.socketutil.TOTAL_TIMEOUT or 15)
        end
    end

    local is_https = url:match("^https://") ~= nil
    local impl = (is_https and self.https) or self.http
    if not impl or not impl.request then
        if self.socketutil and type(self.socketutil.reset_timeout) == "function" then
            self.socketutil:reset_timeout()
        end
        if is_https and not self.https then
            return nil, "HTTPS unavailable (ssl.https could not be loaded)"
        elseif not self.http then
            return nil, "HTTP unavailable (socket.http could not be loaded)"
        else
            return nil, "HTTP client request function unavailable"
        end
    end

    local ok, code_or_err, response_headers, status_line = pcall(function()
        if self.socket and type(self.socket.skip) == "function" then
            return self.socket.skip(1, impl.request(spec))
        else
            local _, c, h, sl = impl.request(spec)
            return c, h, sl
        end
    end)

    if self.socketutil and type(self.socketutil.reset_timeout) == "function" then
        self.socketutil:reset_timeout()
    end

    if not ok then return nil, tostring(code_or_err or "HTTP request failed") end
    local status = tonumber(code_or_err)
    if not status then return nil, tostring(code_or_err or response_headers or "No status code returned") end

    local raw_body = table.concat(chunks)
    local parsed = raw_body
    if raw_body ~= "" and self.json_decode then
        local decode_ok, decoded = pcall(self.json_decode, raw_body)
        if decode_ok then parsed = decoded end
    end

    return {
        status      = status,
        headers     = response_headers or {},
        status_line = status_line,
        body        = parsed,
        raw_body    = raw_body,
    }
end

function LibbeeTransport:request_sequence(requests)
    self:_load()
    if type(requests) ~= "table" or #requests == 0 then return nil, "requests are required" end

    if not self.socket or not self.http or not self.https or
       type(self.https.tcp) ~= "function" or type(self.http.open) ~= "function" then
        -- Fallback to non-persistent if persistent connection primitives are missing
        local responses = {}
        for index, request_spec in ipairs(requests) do
            local req = request_spec
            if type(request_spec) == "function" then
                req = request_spec(responses)
            end
            if not req then break end
            local resp, err = self:request(req)
            if not resp then return nil, err end
            responses[index] = resp
        end
        return responses
    end

    local first = requests[1]
    local base = tostring(first.base_url or "")
    local host = base:match("^https://([^/:]+)")
    local port = tonumber(base:match("^https://[^/:]+:(%d+)")) or 443
    if not host then return nil, "Persistent HTTPS sequence requires an HTTPS base URL" end

    local params = { protocol = "tlsv1_2", verify = "none", options = "all" }
    for key, value in pairs(self.tls_options) do params[key] = value end
    local connection
    local opened, open_err = pcall(function()
        connection = self.http.open(host, port, self.https.tcp(params))
    end)
    if not opened or not connection then return nil, tostring(open_err or "Could not open persistent HTTPS connection") end

    local responses = {}

    for index, request_spec in ipairs(requests) do
        local request = request_spec
        if type(request_spec) == "function" then
            request = request_spec(responses)
        end
        if type(request) ~= "table" then break end
        if tostring(request.base_url or "") ~= base then connection:close(); return nil, "Persistent HTTPS sequence cannot change origin" end

        local query = query_string(request.query)
        local headers = {}
        for key, value in pairs(request.headers or {}) do headers[key] = value end
        headers["Accept-Encoding"] = "identity"
        headers["Connection"] = index == #requests and "close" or "keep-alive"
        local body
        if request.json ~= nil then
            local ok, encoded = pcall(self.json_encode, request.json)
            if not ok or type(encoded) ~= "string" then connection:close(); return nil, "Could not encode JSON request" end
            body = encoded
            headers["Content-Type"] = "application/json; charset=UTF-8"
            headers["Content-Length"] = tostring(#body)
        end
        headers["Host"] = host
        if not headers["Content-Length"] and (request.method == "POST" or request.method == "PUT") then
            headers["Content-Length"] = "0"
        end
        local uri = tostring(request.path or "")
        if uri == "" then uri = "/" end
        if query ~= "" then uri = uri .. "?" .. query end
        local chunks = {}
        local ok, status, response_headers, status_line = pcall(function()
            connection:sendrequestline(request.method or "GET", uri)
            connection:sendheaders(headers)
            if body then connection:sendbody(headers, self.ltn12.source.string(body)) end
            local code, line = connection:receivestatusline()
            local received_headers = connection:receiveheaders()
            connection:receivebody(received_headers, (self.ltn12.sink.table(chunks)))
            return code, received_headers, line
        end)
        if not ok then connection:close(); return nil, tostring(status or "HTTPS request failed") end
        status = tonumber(status)
        if not status then connection:close(); return nil, "HTTPS response did not include a numeric status" end
        local raw_body = table.concat(chunks)
        local parsed = raw_body
        if raw_body ~= "" and self.json_decode then
            local decode_ok, decoded = pcall(self.json_decode, raw_body)
            if decode_ok then parsed = decoded end
        end
        responses[index] = { status = status, headers = response_headers or {}, status_line = status_line, body = parsed, raw_body = raw_body }
    end
    pcall(function() connection:close() end)
    return responses
end

return LibbeeTransport
