-- spec_helper.lua
package.path = package.path .. ";libbee.koplugin/?.lua"
package.path = package.path .. ";/home/jpautz/.luarocks/share/lua/5.1/?.lua"
package.path = package.path .. ";/home/jpautz/.luarocks/share/lua/5.1/?/init.lua"

-- Mocking KOReader environment
package.loaded["device"] = {
    getModel = function() return "K5" end,
    isKindle = function() return true end,
    isPocketBook = function() return false end,
    isKobo = function() return false end,
    isKoboV2 = function() return false end,
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(a, b) return b or a end,
    }
}

package.loaded["docsettings"] = {
    getSidecarDir = function(_, book_path) return book_path .. ".sdr" end
}

package.loaded["lfs"] = {
    attributes = function(path) 
        if path == "/tmp" or path:match("^/tmp") or path:match("%.sdr$") or path:match("%.sdr/$") then
            return { mode = "directory" }
        end
        -- If we can open it, it's a file
        local f = io.open(path, "r")
        if f then
            f:close()
            return { mode = "file" }
        end
        return nil
    end,
    mkdir = function(p)
        if p and os.execute then
            pcall(os.execute, "mkdir -p " .. tostring(p) .. " 2>/dev/null")
        end
        return true
    end,
    dir = function(path)
        return function() return nil end
    end,
}
package.loaded["libs/libkoreader-lfs"] = package.loaded["lfs"]
package.loaded["libs/libkoreader-lfs"] = package.loaded["lfs"]

package.loaded["logger"] = {
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
    debug = function(...) end
}

package.loaded["util"] = {
    fixUtf8 = function(s) return s end,
    tableShallowCopy = function(t) local c = {} for k,v in pairs(t) do c[k]=v end return c end,
}

local mock_crypto = {
    isAvailable = function() return true end,
    sha1 = function(s) return s end,
    sha256 = function(s) return s end,
    md5 = function(s) return s end,
    hmacSha256 = function(k, d) return d end,
    aesCbcDecrypt = function(k, iv, d) return d end,
    aesCbcEncrypt = function(k, iv, d) return d end,
    randomBytes = function(n) return string.rep("x", n) end,
}
package.loaded["libbee_adobe_nativecrypto"] = mock_crypto
package.loaded["libbee_adobe_nativecrypto"] = mock_crypto
package.preload["libbee_adobe_nativecrypto"] = function() return mock_crypto end
package.preload["libbee_adobe_nativecrypto"] = function() return mock_crypto end
package.loaded["adobe/util/nativecrypto"] = mock_crypto
package.loaded["adobe.util.nativecrypto"] = mock_crypto
package.preload["adobe/util/nativecrypto"] = function() return mock_crypto end
package.preload["adobe.util.nativecrypto"] = function() return mock_crypto end

package.loaded["ffi/archiver"] = {
    extract = function() return true end,
    compress = function() return true end,
}
package.loaded["ffi.archiver"] = package.loaded["ffi/archiver"]
package.loaded["ffi/posix_h"] = {}
package.loaded["ffi.posix_h"] = {}

local mock_sha2 = {
    hex2bin = function(hex)
        return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16) or 0) end))
    end,
    bin2hex = function(bin)
        return (bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
    end,
    md5 = function(s) return string.rep("a", 32) end,
    sha256 = function(s) return string.rep("b", 64) end,
    base642bin = function(s) return s end,
    bin2base64 = function(s) return s end,
}
package.loaded["ffi/sha2"] = mock_sha2
package.loaded["ffi.sha2"] = mock_sha2

local mock_ffi_util = {
    orderedPairs = function(t) return pairs(t) end,
}
package.loaded["ffi/util"] = mock_ffi_util
package.loaded["ffi.util"] = mock_ffi_util

package.loaded["ffi"] = _G.ffi or {
    cdef = function() end,
    load = function() return {} end,
    new = function() return {} end,
    string = function(s) return s end,
}

package.loaded["bit"] = _G.bit or {
    band = function(a, b) return 0 end,
    bor = function(a, b) return 0 end,
    bxor = function(a, b) return 0 end,
    rshift = function(a, b) return 0 end,
    lshift = function(a, b) return 0 end,
}

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp" end,
    getDataDir = function() return "/tmp" end,
}

-- UI tracking for testing
_G.ui_tracker = {
    shown = {},
    last_shown = nil,
    closed = {}
}

package.loaded["ui/uimanager"] = {
    show = function(self, widget, refreshtype, region, x, y)
        local w = type(self) == "table" and widget or self
        local posX = type(self) == "table" and x or refreshtype
        local posY = type(self) == "table" and y or region
        table.insert(_G.ui_tracker.shown, w)
        _G.ui_tracker.last_shown = w
        _G.ui_tracker.last_show_x = posX
        _G.ui_tracker.last_show_y = posY
    end,
    close = function(a, b)
        local w = b or a
        table.insert(_G.ui_tracker.closed, w)
    end,
    scheduleIn = function(a, b, c)
        if type(a) == "function" then a()
        elseif type(b) == "function" then b()
        elseif type(c) == "function" then c() end
    end,
    nextTick = function(a, b)
        local f = b or a
        if type(f) == "function" then f() end
    end,
    setDirty = function() end
}
package.loaded["ui/widget/infomessage"] = {
    new = function(a, b) return { type = "InfoMessage", args = b or a } end
}
package.loaded["ui/widget/buttondialog"] = {
    new = function(a, b) 
        local dialog = { type = "ButtonDialog", args = b or a }
        dialog.getSize = function() return { w = 800, h = 100 } end
        return dialog
    end
}
package.loaded["ui/widget/confirmbox"] = {
    new = function(a, b) return { type = "ConfirmBox", args = b or a } end
}
package.loaded["ui/widget/textviewer"] = {
    new = function(a, b)
        local args = b or a or {}
        return {
            type = "TextViewer",
            args = args,
            scroll_text_w = {
                scrolled_to_bottom = false,
                scrollToBottom = function(self)
                    self.scrolled_to_bottom = true
                end,
            },
        }
    end
}
package.loaded["ui/widget/menu"] = {
    new = function(a, b) return { type = "Menu", args = b or a } end
}
package.loaded["ui/widget/verticalgroup"] = {
    new = function(a, b)
        local vg = { type = "VerticalGroup", args = b or a }
        vg.getSize = function() return { w = 360, h = 200 } end
        return vg
    end
}
local function _mockWidgetClass(name)
    local cls = { type = name }
    cls.new = function(self, o)
        if type(self) ~= "table" or self == cls or getmetatable(self) then
            o = o or (type(self) == "table" and self or {})
        end
        o = o or {}
        setmetatable(o, { __index = self or cls })
        if o.init then o:init() end
        o.getSize = o.getSize or function() return { w = 360, h = 200 } end
        return o
    end
    cls.extend = function(self, child)
        child = child or {}
        setmetatable(child, { __index = self })
        child.new = self.new
        child.extend = self.extend
        return child
    end
    return cls
end

package.loaded["ui/widget/widget"] = _mockWidgetClass("Widget")
package.loaded["ui/widget/widgetcontainer"] = _mockWidgetClass("WidgetContainer")
package.loaded["ui/widget/container/widgetcontainer"] = package.loaded["ui/widget/widgetcontainer"]
package.loaded["ui/widget/container/framecontainer"] = _mockWidgetClass("FrameContainer")
package.loaded["ui/widget/container/inputcontainer"] = _mockWidgetClass("InputContainer")
package.loaded["ui/widget/container/scrollablecontainer"] = _mockWidgetClass("ScrollableContainer")
package.loaded["ui/geometry"] = {
    new = function(a, b) return b or a end
}
package.loaded["ui/widget/horizontalgroup"] = {
    new = function(a, b)
        local hg = { type = "HorizontalGroup", args = b or a }
        hg.getSize = function() return { w = 360, h = 50 } end
        return hg
    end
}
package.loaded["ui/widget/table"] = {
    new = function(a, b) return { type = "Table", args = b or a } end
}
package.loaded["ui/widget/textwidget"] = {
    new = function(a, b) 
        local args = b or a or {}
        local tw = { type = "TextWidget", args = args, text = args.text or "" }
        tw.getSize = function() return { w = 100, h = 20 } end
        tw.setText = function(self, t) self.text = t end
        return tw
    end
}
package.loaded["ui/widget/textboxwidget"] = {
    new = function(a, b) 
        local args = b or a or {}
        local tb = { type = "TextBoxWidget", args = args, text = args.text or "" }
        tb.getSize = function() return { w = 200, h = 40 } end
        tb.setText = function(self, t) self.text = t end
        return tb
    end
}
package.loaded["ui/widget/linewidget"] = {
    new = function(a, b) 
        local lw = { type = "LineWidget", args = b or a }
        lw.getSize = function() return { w = 100, h = 1 } end
        return lw
    end
}
package.loaded["ui/widget/verticalspan"] = {
    new = function(a, b) return { type = "VerticalSpan", args = b or a, getSize = function() return { w = 0, h = 0 } end } end
}
package.loaded["ui/widget/horizontalspan"] = {
    new = function(a, b) return { type = "HorizontalSpan", args = b or a, getSize = function() return { w = 0, h = 0 } end } end
}
package.loaded["ui/widget/overlapgroup"] = {
    new = function(a, b) return { type = "OverlapGroup", args = b or a, getSize = function() return { w = 200, h = 50 } end } end
}
package.loaded["ui/widget/container/scrollablecontainer"] = {
    new = function(a, b) return { type = "ScrollableContainer", args = b or a, getSize = function() return { w = 600, h = 700 } end } end
}
package.loaded["ui/widget/container/centercontainer"] = {
    new = function(a, b) return { type = "CenterContainer", args = b or a, getSize = function() return { w = 200, h = 200 } end } end
}
package.loaded["ui/widget/container/bottomcontainer"] = {
    new = function(a, b) return { type = "BottomContainer", args = b or a, getSize = function() return { w = 600, h = 100 } end } end
}
package.loaded["ui/widget/container/leftcontainer"] = {
    new = function(a, b) return { type = "LeftContainer", args = b or a, getSize = function() return { w = 200, h = 50 } end } end
}
package.loaded["ui/widget/container/rightcontainer"] = {
    new = function(a, b) return { type = "RightContainer", args = b or a, getSize = function() return { w = 80, h = 30 } end } end
}
package.loaded["ui/widget/imagewidget"] = {
    new = function(a, b) return { type = "ImageWidget", args = b or a, getSize = function() return { w = 50, h = 50 } end } end
}
package.loaded["ui/renderimage"] = {
    renderImageFile = function() return nil end,
    scaleBlitBuffer = function() return nil end
}
package.loaded["ui/widget/button"] = {
    new = function(a, b) 
        local btn = { type = "Button", args = b or a }
        btn.getSize = function() return { w = 60, h = 30 } end
        return btn
    end
}
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0,
    COLOR_WHITE = 1,
    COLOR_DARK_GRAY = 2,
    COLOR_LIGHT_GRAY = 3,
    COLOR_GRAY = 4,
    TYPE_BPP24 = 24,
    Color8 = function(c) return c end,
    new = function(w, h, t)
        return {
            getWidth = function() return w end,
            getHeight = function() return h end,
            getType = function() return t end,
            fill = function() end,
            blitFrom = function() end,
            free = function() end
        }
    end
}
package.loaded["ui/font"] = {
    getFace = function() return {} end
}
package.loaded["ui/event"] = {
    new = function(a, b, c) 
        if type(a) == "string" then return { name = a, args = b } end
        return { name = b, args = c }
    end
}
package.loaded["ui/gesturerange"] = {
    new = function(a, b) return { type = "GestureRange", args = b or a } end
}
package.loaded["gettext"] = {
    _ = function(s) return s end,
    getLanguage = function() return "en" end
}
package.loaded["ui/trapper"] = {
    wrap = function(self, fn) fn() end,
    dismissableRunInSubprocess = function(self, task, widget)
        local pack = table.pack or function(...) return { n = select("#", ...), ... } end
        local unpack_fn = table.unpack or unpack
        local results = pack(task())
        return true, unpack_fn(results, 1, results.n)
    end,
}

_G.dispatcher_tracker = {
    actions = {},
}

package.loaded["dispatcher"] = {
    registerAction = function(self, name, value)
        local n = type(self) == "string" and self or name
        local v = type(self) == "table" and value or name
        if type(self) == "table" and type(name) == "string" then
            n = name
            v = value
        end
        _G.dispatcher_tracker.actions[n] = v
        return true
    end,
}

package.loaded["libbee_logger"] = {
    init  = function(path) end,
    info  = function(m) end,
    warn  = function(m) end,
    err   = function(m) end,
    debug = function(m) end,
    path  = function()  return "/tmp/libbee_debug.log" end,
}
package.loaded["ffi/util"] = {}
package.loaded["ffi.sha2"] = {
    base642bin = function(s) return s end,
    bin2base64 = function(s) return s end,
}
package.loaded["socket.http"] = {}
package.loaded["ssl.https"] = {}
package.loaded["ltn12"] = {}
package.loaded["socket"] = {}
package.loaded["socketutil"] = {
    USER_AGENT = "KOReader",
    file_sink = function(handle)
        return function(chunk, err)
            if chunk and handle then handle:write(chunk) end
            return 1
        end
    end,
    table_sink = function(t)
        return function(chunk, err)
            if chunk then table.insert(t, chunk) end
            return 1
        end
    end,
    set_timeout = function() end,
    reset_timeout = function() end,
}
local json_lib = nil
pcall(function() json_lib = require("rapidjson") end)
if not json_lib then
    pcall(function() json_lib = require("dkjson") end)
end
if not json_lib then
    local function simple_encode(val)
        local t = type(val)
        if t == "table" then
            local is_array = (#val > 0)
            local parts = {}
            if is_array then
                for _, v in ipairs(val) do
                    table.insert(parts, simple_encode(v))
                end
                return "[" .. table.concat(parts, ",") .. "]"
            else
                for k, v in pairs(val) do
                    local safe_k = tostring(k):gsub('\\', '\\\\'):gsub('"', '\\"')
                    table.insert(parts, '"' .. safe_k .. '":' .. simple_encode(v))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        elseif t == "string" then
            local safe_v = tostring(val):gsub('\\', '\\\\'):gsub('"', '\\"')
            return '"' .. safe_v .. '"'
        elseif t == "number" or t == "boolean" then
            return tostring(val)
        else
            return "null"
        end
    end

    -- Proper recursive-descent JSON decoder.
    -- Handles nested objects, arrays, strings, numbers, booleans and null.
    local function simple_decode(str)
        if not str or str == "" then return nil end

        local pos = 1

        local function skip_ws()
            while pos <= #str and str:sub(pos,pos):match("%s") do pos = pos + 1 end
        end

        local parse_value  -- forward declaration

        local function parse_string()
            pos = pos + 1  -- skip opening "
            local buf = {}
            while pos <= #str do
                local ch = str:sub(pos, pos)
                if ch == '"' then
                    pos = pos + 1
                    return table.concat(buf)
                elseif ch == '\\' then
                    pos = pos + 1
                    local esc = str:sub(pos, pos)
                    if     esc == '"'  then table.insert(buf, '"')
                    elseif esc == '\\' then table.insert(buf, '\\')
                    elseif esc == '/'  then table.insert(buf, '/')
                    elseif esc == 'n'  then table.insert(buf, '\n')
                    elseif esc == 'r'  then table.insert(buf, '\r')
                    elseif esc == 't'  then table.insert(buf, '\t')
                    else                    table.insert(buf, esc)
                    end
                    pos = pos + 1
                else
                    table.insert(buf, ch)
                    pos = pos + 1
                end
            end
            return table.concat(buf)
        end

        local function parse_object()
            pos = pos + 1  -- skip {
            local obj = {}
            skip_ws()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while pos <= #str do
                skip_ws()
                local key = parse_string()
                skip_ws()
                pos = pos + 1  -- skip :
                skip_ws()
                obj[key] = parse_value()
                skip_ws()
                local sep = str:sub(pos, pos)
                if sep == "}" then pos = pos + 1; break end
                if sep == "," then pos = pos + 1 end
            end
            return obj
        end

        local function parse_array()
            pos = pos + 1  -- skip [
            local arr = {}
            skip_ws()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while pos <= #str do
                skip_ws()
                table.insert(arr, parse_value())
                skip_ws()
                local sep = str:sub(pos, pos)
                if sep == "]" then pos = pos + 1; break end
                if sep == "," then pos = pos + 1 end
            end
            return arr
        end

        local function parse_number()
            local numstr = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
            if numstr then pos = pos + #numstr; return tonumber(numstr) end
            return nil
        end

        parse_value = function()
            skip_ws()
            local ch = str:sub(pos, pos)
            if ch == '"' then
                return parse_string()
            elseif ch == '{' then
                return parse_object()
            elseif ch == '[' then
                return parse_array()
            elseif ch == 't' then
                pos = pos + 4; return true
            elseif ch == 'f' then
                pos = pos + 5; return false
            elseif ch == 'n' then
                pos = pos + 4; return nil
            else
                return parse_number()
            end
        end

        local ok, result = pcall(parse_value)
        if ok then return result end
        return nil
    end

    json_lib = {
        encode = simple_encode,
        decode = simple_decode
    }
end
package.loaded["json"] = json_lib
package.loaded["rapidjson"] = json_lib

-- Provide a pure-Lua base64 decoder for the mime module so JWT decode works
-- in environments where the system mime library is absent.
if not package.loaded["mime"] or type((package.loaded["mime"] or {}).unb64) ~= "function" then
    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local b64map = {}
    for i = 1, #b64chars do b64map[b64chars:sub(i,i)] = i - 1 end

    local function pure_unb64(s)
        s = (s or ""):gsub("[^%w%+%/%=]", "")
        local result = {}
        for i = 1, #s, 4 do
            local c1 = b64map[s:sub(i,   i)]   or 0
            local c2 = b64map[s:sub(i+1, i+1)] or 0
            local c3 = b64map[s:sub(i+2, i+2)]
            local c4 = b64map[s:sub(i+3, i+3)]
            local byte1 = c1 * 4 + math.floor(c2 / 16)
            table.insert(result, string.char(byte1))
            if c3 then
                local byte2 = (c2 % 16) * 16 + math.floor(c3 / 4)
                table.insert(result, string.char(byte2))
            end
            if c4 then
                local byte3 = (c3 % 4) * 64 + c4
                table.insert(result, string.char(byte3))
            end
        end
        return table.concat(result)
    end

    package.loaded["mime"] = {
        unb64 = pure_unb64,
        b64   = function(s) return s end,  -- stub; not needed for tests
    }
end

if not package.loaded["ltn12"] or not (package.loaded["ltn12"] or {}).sink then
    package.loaded["ltn12"] = {
        sink = {
            table = function(t)
                return function(chunk, err)
                    if chunk then table.insert(t, chunk) end
                    return 1
                end
            end,
            file = function(handle)
                return function(chunk, err)
                    if chunk and handle then handle:write(chunk) end
                    return 1
                end
            end,
        },
        source = {
            string = function(s)
                local sent = false
                return function()
                    if sent then return nil end
                    sent = true
                    return s
                end
            end
        }
    }
end

function _G.createMockPlugin()
    local plugin = {
        ui = {
            document = {
                file = "test_book.epub",
                getToc = function() return {} end,
                getProps = function() return { title = "Test Title", authors = "Test Author" } end
            },
            paging = {
                getCurrentPage = function() return 10 end
            },
            handleEvent = function() end
        },
        loc = {
            t = function(s, ...)
                local fmt = s
                local args = {...}
                if type(s) == "table" then
                    fmt = args[1]
                    table.remove(args, 1)
                end
                if type(fmt) == "string" and #args > 0 then
                    if fmt:find("%%") then
                        local status, res = pcall(string.format, fmt, unpack(args))
                        if status then return res end
                    end
                    -- Fallback for testing: just append args
                    for i = 1, #args do
                        fmt = fmt .. " " .. tostring(args[i])
                    end
                end
                return fmt
            end,
            getLanguage = function() return "en" end,
            setLanguage = function() end
        },
        log = function(...) end,
    }
    return plugin
end
