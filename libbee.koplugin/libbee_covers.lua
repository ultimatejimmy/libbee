-- libbee_covers.lua — Cover image downloading, caching, and rendering for Libbee
-- Follows the Storefront image caching and cover widget patterns.

local logger = require("logger")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local theme = require(plugin_path .. "libbee_theme")

local M = {}

local function getHttpModule(url)
    if url and url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and http then return http end
    return nil
end

local function requestWithRedirects(target_url, sink_fn)
    local ltn12 = require("ltn12")
    local current_url = target_url
    local max_redirects = 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local is_https = current_url:match("^https://") ~= nil
        local http_req = getHttpModule(current_url)
        if not http_req then return false, 0, nil end

        local headers = {
            ["User-Agent"] = "KOReader-Libbee",
        }

        local sink = sink_fn()
        if not sink then return false, 0, nil end

        local params = {
            url = current_url,
            method = "GET",
            headers = headers,
            sink = sink,
        }
        if not is_https then params.redirect = true end

        local ok_req, res_code, response_headers = pcall(function()
            local _, c, h = http_req.request(params)
            return c, h
        end)

        local code = tonumber(res_code) or 0
        if ok_req and code == 200 then
            return true, 200, response_headers
        elseif ok_req and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            local loc = response_headers and (response_headers.location or response_headers.Location)
            if loc and loc ~= "" then
                current_url = loc
                redirect_count = redirect_count + 1
            else
                break
            end
        else
            break
        end
    end
    return false, 0, nil
end

function M.getCacheDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir) and DataStorage:getDataDir() or "/tmp"
    local cache_dir = data_dir .. "/cache/libbee_covers"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and not lfs.attributes(cache_dir) then
        pcall(lfs.mkdir, data_dir .. "/cache")
        pcall(lfs.mkdir, cache_dir)
    end
    return cache_dir
end

local function sanitizeFilename(str)
    if not str then return "cover" end
    return str:gsub("[^%w%-_]", "_")
end

function M.getCoverFilePath(loan)
    if not loan then return nil end
    local id_str = tostring(loan.id or loan.reserveId or "")
    if id_str == "" and loan.title then
        id_str = loan.title
    end
    if id_str == "" then return nil end

    local clean_name = sanitizeFilename(id_str)
    local ext = ".jpg"
    if loan.cover_url and loan.cover_url:lower():find("%.png") then
        ext = ".png"
    end
    return M.getCacheDir() .. "/" .. clean_name .. ext
end

function M.getCachedCoverPath(loan)
    local path = M.getCoverFilePath(loan)
    if not path then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes and lfs.attributes(path, "mode") == "file" then
        return path
    end
    -- Fallback file check
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return path
    end
    return nil
end

function M.fetchCover(loan, callback)
    if not loan then
        if callback then callback(nil) end
        return nil
    end

    local cached = M.getCachedCoverPath(loan)
    if cached then
        if callback then callback(cached) end
        return cached
    end

    local url = loan.cover_url
    if not url or url == "" then
        if callback then callback(nil) end
        return nil
    end

    local target_path = M.getCoverFilePath(loan)
    if not target_path then
        if callback then callback(nil) end
        return nil
    end

    local ltn12 = require("ltn12")
    local img_data = {}
    local sink_fn = function()
        img_data = {}
        return ltn12.sink.table(img_data)
    end

    local ok, code = requestWithRedirects(url, sink_fn)
    if ok and code == 200 and #img_data > 0 then
        local tmp_path = target_path .. ".tmp"
        local file = io.open(tmp_path, "wb")
        if file then
            file:write(table.concat(img_data))
            file:close()
            pcall(os.remove, target_path)
            local ok_ren = os.rename(tmp_path, target_path)
            if ok_ren then
                if callback then callback(target_path) end
                return target_path
            end
        end
    end

    if callback then callback(nil) end
    return nil
end

function M.createCoverImageWidget(file_path, target_w, target_h)
    local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    local ok_bb, Blitbuffer  = pcall(require, "ffi/blitbuffer")

    if not ok_iw or not ok_ri or not ok_bb or not file_path or not target_w or not target_h then
        return nil
    end

    local ok, orig_bb = pcall(function()
        return RenderImage:renderImageFile(file_path, false)
    end)

    if not ok or not orig_bb then
        return nil
    end

    local orig_w = orig_bb:getWidth()
    local orig_h = orig_bb:getHeight()

    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        if orig_bb.free then pcall(function() orig_bb:free() end) end
        return nil
    end

    -- Scale with aspect fill (cover target area, center cropped)
    local scale = math.max(target_w / orig_w, target_h / orig_h)
    local scaled_w = math.max(1, math.ceil(orig_w * scale))
    local scaled_h = math.max(1, math.ceil(orig_h * scale))

    local ok_scale, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(orig_bb, scaled_w, scaled_h, false)
    end)
    if orig_bb.free then pcall(function() orig_bb:free() end) end
    if not ok_scale or not scaled_bb then return nil end

    local crop_x = math.max(0, math.floor((scaled_bb:getWidth() - target_w) / 2))
    local crop_y = math.max(0, math.floor((scaled_bb:getHeight() - target_h) / 2))

    local bb_type = (scaled_bb.getType and scaled_bb:getType()) or Blitbuffer.TYPE_BPP24
    local dest_bb = Blitbuffer.new(target_w, target_h, bb_type)
    pcall(function() dest_bb:fill(Blitbuffer.COLOR_WHITE) end)

    pcall(function()
        dest_bb:blitFrom(scaled_bb, 0, 0, crop_x, crop_y, target_w, target_h)
    end)

    if scaled_bb.free then
        pcall(function() scaled_bb:free() end)
    end

    return ImageWidget:new{
        image = dest_bb,
        image_disposable = true,
        width = target_w,
        height = target_h,
    }
end

function M.createPlaceholderWidget(target_w, target_h, title)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")

    local sc = theme.sc
    local icon_w = TextWidget:new{
        text = "📖",
        face = Font:getFace("cfont", 24),
    }

    local inner_widgets = { icon_w }
    if title and title ~= "" then
        local label = TextBoxWidget:new{
            text = title,
            face = Font:getFace("smallinfofont", 12),
            width = target_w - sc(12),
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        table.insert(inner_widgets, VerticalSpan:new{ width = sc(4) })
        table.insert(inner_widgets, label)
    end

    return FrameContainer:new{
        bordersize = theme.border_btn or sc(1),
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        width = target_w,
        height = target_h,
        CenterContainer:new{
            dimen = Geom:new{ w = target_w, h = target_h },
            VerticalGroup:new{
                align = "center",
                unpack(inner_widgets)
            }
        }
    }
end

function M.cleanupExpiredCovers(active_loans)
    if not active_loans or #active_loans == 0 then
        return 0
    end
    local cache_dir = M.getCacheDir()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs or not lfs.dir then return 0 end

    -- Build set of valid cover filenames for loans that are active and not expired
    local valid_files = {}
    for _, loan in ipairs(active_loans or {}) do
        local days = loan.days_remaining
        local is_expired = (days ~= nil and days <= 0)
        if not is_expired then
            local path = M.getCoverFilePath(loan)
            if path then
                local filename = path:match("([^/\\]+)$")
                if filename then
                    valid_files[filename] = true
                end
            end
        end
    end

    local deleted_count = 0
    local ok, iter, dir_obj = pcall(lfs.dir, cache_dir)
    if ok and iter then
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                if not valid_files[entry] then
                    local full_path = cache_dir .. "/" .. entry
                    local ok_rm = pcall(os.remove, full_path)
                    if ok_rm then
                        deleted_count = deleted_count + 1
                    end
                end
            end
        end
    end

    if deleted_count > 0 then
        logger.info("libbee covers: cleaned up " .. deleted_count .. " expired/stale cover files")
    end
    return deleted_count
end

return M
