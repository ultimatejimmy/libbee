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
        -- Basic mock: if it ends in .sdr, it's a directory
        if path:match("%.sdr$") or path:match("%.sdr/$") then
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
    new = function(a, b) return { type = "TextViewer", args = b or a } end
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
    new = function(a, b) return { type = "HorizontalGroup", args = b or a } end
}
package.loaded["ui/widget/table"] = {
    new = function(a, b) return { type = "Table", args = b or a } end
}
package.loaded["ui/widget/textwidget"] = {
    new = function(a, b) 
        local tw = { type = "TextWidget", args = b or a }
        tw.getSize = function() return { w = 100, h = 20 } end
        return tw
    end
}
package.loaded["ui/widget/textboxwidget"] = {
    new = function(a, b) 
        local tb = { type = "TextBoxWidget", args = b or a }
        tb.getSize = function() return { w = 200, h = 40 } end
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
        local results = table.pack(task())
        return true, table.unpack(results, 1, results.n)
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
package.loaded["socketutil"] = {}
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

    local function simple_decode(str)
        if not str or str == "" then return nil end
        -- Basic json parser fallback for test key-values
        local res = {}
        for k, v in str:gmatch('"([%w_%-]+)"%s*:%s*"([^"]*)"') do
            res[k] = v
        end
        for k, v in str:gmatch('"([%w_%-]+)"%s*:%s*([%d%.]+)') do
            res[k] = tonumber(v)
        end
        for k, v in str:gmatch('"([%w_%-]+)"%s*:%s*(true)') do
            res[k] = true
        end
        for k, v in str:gmatch('"([%w_%-]+)"%s*:%s*(false)') do
            res[k] = false
        end
        return res
    end

    json_lib = {
        encode = simple_encode,
        decode = simple_decode
    }
end
package.loaded["json"] = json_lib
package.loaded["rapidjson"] = json_lib

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
