-- libbee_ui.lua — UI for the Libbee plugin
-- Shelf browser (List and Cover views), setup dialogs, download flow, and about screen.
-- Follows the Storefront style guide and design token system (libbee_theme).
-- Network calls run in Trapper:dismissableRunInSubprocess to keep UI responsive.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Button = require("ui/widget/button")
local ImageWidget = require("ui/widget/imagewidget")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local ok_ffiu, ffiutil = pcall(require, "ffi/util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
local ok_ds, DataStorage = pcall(require, "datastorage")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

-- Configure package.path for embedded DRM & XML dependencies
local info = debug.getinfo(1, "S")
local plugin_root = (info and info.source and info.source:match("^@(.*[/\\])")) or "./"
plugin_root = plugin_root:gsub("[/\\]+$", "")
local extra_paths = {
    plugin_root .. "/?.lua",
}
for _, ep in ipairs(extra_paths) do
    if not package.path:find(ep, 1, true) then
        package.path = ep .. ";" .. package.path
    end
end

local ok_loc, Localization = pcall(require, plugin_path .. "libbee_localization")
if not ok_loc or not Localization then
    ok_loc, Localization = pcall(require, "libbee_localization")
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end
local log = require(plugin_path .. "libbee_logger")
local theme = require(plugin_path .. "libbee_theme")
local Covers = require(plugin_path .. "libbee_covers")

local M = {}
local sc = theme.sc

local function isTouchDevice()
    if Device then
        if Device.isTouchDevice then
            return Device:isTouchDevice()
        elseif Device.isTouch then
            return Device:isTouch()
        end
    end
    return false
end

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local dir = (info and info.source and info.source:match("^@(.*[/\\])")) or ""
    local rel_path = dir .. "assets/" .. filename
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or ""
    local paths_to_try = {
        rel_path,
        (data_dir ~= "") and (data_dir .. "/" .. rel_path) or nil,
        (data_dir ~= "") and (data_dir .. "/plugins/" .. rel_path) or nil,
        (data_dir ~= "") and (data_dir .. "/plugins/libbee.koplugin/assets/" .. filename) or nil,
    }
    for _, p in ipairs(paths_to_try) do
        if p then
            if ok_ffiu and ffiutil and ffiutil.realpath then
                local rp = ffiutil.realpath(p)
                if rp and ok_lfs and lfs and lfs.attributes and lfs.attributes(rp, "mode") == "file" then
                    _asset_path_cache[filename] = rp
                    return rp
                end
            elseif ok_lfs and lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
                _asset_path_cache[filename] = p
                return p
            end
        end
    end
    local fallback = dir .. "assets/" .. filename
    _asset_path_cache[filename] = fallback
    return fallback
end

-- ---------------------------------------------------------------------------
-- Custom Libbee Toast / Progress Widget (Storefront Card Theme)
-- ---------------------------------------------------------------------------

local _active_toast = nil

local LibbeeToastWidget = InputContainer:extend{
    text = "",
    timeout = 3,
    dismissable = true,
}

function LibbeeToastWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local max_toast_w = math.min(sw - sc(32), sc(440))

    local icon = ImageWidget:new{
        file = getAssetPath("info.svg"),
        width = sc(22),
        height = sc(22),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }

    local label = TextBoxWidget:new{
        text = self.text or "",
        face = Font:getFace("cfont", theme.face_label_size or 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = max_toast_w - sc(70),
        alignment = "left",
    }
    self.label_widget = label

    local row = HorizontalGroup:new{
        align = "center",
        icon,
        HorizontalSpan:new{ width = sc(12) },
        label,
    }

    local card = FrameContainer:new{
        padding = sc(12),
        padding_left = sc(16),
        padding_right = sc(16),
        radius = theme.radius_toast or theme.radius_window or sc(4),
        bordersize = theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = theme.color_bg or Blitbuffer.COLOR_WHITE,
        row,
    }

    self.dimen = Geom:new{ w = sw, h = sh }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        card,
    }

    if self.dismissable ~= false then
        if Device and Device.hasKeys and Device:hasKeys() then
            self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
        end
        if Device and Device.isTouchDevice and Device:isTouchDevice() then
            self.ges_events = {
                TapDismiss = {
                    GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } }
                },
            }
        end
    end

    if self.timeout and self.timeout > 0 then
        self._timer = UIManager:scheduleIn(self.timeout, function()
            self:close()
        end)
    end
end

function LibbeeToastWidget:onTapDismiss()
    if self.dismissable ~= false then
        if self.dismiss_callback then
            self.dismiss_callback()
        end
        self:close()
        return true
    end
end

function LibbeeToastWidget:onAnyKeyPressed()
    if self.dismissable ~= false then
        if self.dismiss_callback then
            self.dismiss_callback()
        end
        self:close()
        return true
    end
end

function LibbeeToastWidget:onTap()
    return self:onTapDismiss()
end

function LibbeeToastWidget:close()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    if _active_toast == self then
        _active_toast = nil
    end
    UIManager:close(self, "ui")
end

local function _dismissActiveToast()
    if _active_toast then
        local t = _active_toast
        _active_toast = nil
        t:close()
    end
end

function LibbeeToastWidget:setText(text)
    self.text = text or ""
    if self.label_widget then
        self.label_widget:setText(self.text)
        UIManager:setDirty(self, "ui")
    end
end

local function _toast(msg, timeout, opts)
    _dismissActiveToast()
    opts = opts or {}
    local dismissable = true
    if opts.dismissable == false then
        dismissable = false
    end
    local toast = LibbeeToastWidget:new{
        text = msg or "",
        timeout = timeout or 3,
        dismissable = dismissable,
    }
    _active_toast = toast
    UIManager:show(toast, "ui")
    return toast
end

M.showToast = _toast
M._toast = _toast
M.LibbeeToastWidget = LibbeeToastWidget

local function _close(w)
    if w then
        if w.close then
            w:close()
        else
            UIManager:close(w, "ui")
        end
    end
end

local function _runNetwork(work_fn, on_done, trap_widget)
    local execute = function()
        local ok_trapper, Trapper = pcall(require, "ui/trapper")
        if ok_trapper and Trapper and type(Trapper.wrap) == "function" and type(Trapper.dismissableRunInSubprocess) == "function" then
            Trapper:wrap(function()
                local trap_target = (trap_widget ~= nil) and trap_widget or false
                local completed, wrapped_res = Trapper:dismissableRunInSubprocess(function()
                    local ok, r1, r2 = pcall(work_fn)
                    if ok then
                        return { success = true, r1 = r1, r2 = r2 }
                    else
                        return { success = false, err = tostring(r1 or _("Unknown error")) }
                    end
                end, trap_target)
                if completed and type(wrapped_res) == "table" then
                    if wrapped_res.success then
                        on_done(wrapped_res.r1, wrapped_res.r2)
                    else
                        log.err("libbee ui: download task failed: " .. tostring(wrapped_res.err))
                        on_done(nil, wrapped_res.err)
                    end
                elseif trap_target and trap_target.was_user_cancelled then
                    log.info("libbee ui: download was cancelled by user")
                    on_done(nil, _("Download cancelled"))
                elseif trap_target and trap_target.was_timed_out then
                    log.warn("libbee ui: download timed out (stalled)")
                    on_done(nil, _("Download timed out"))
                elseif not completed then
                    log.info("libbee ui: download was cancelled by user")
                    on_done(nil, _("Download cancelled"))
                else
                    log.err("libbee ui: background process was killed by OS or crashed (possible memory limit)")
                    on_done(nil, _("Download interrupted (possible device memory limit)"))
                end
            end)
        else
            UIManager:scheduleIn(0.05, function()
                local ok, r1, r2 = pcall(work_fn)
                if ok then
                    on_done(r1, r2)
                else
                    on_done(nil, tostring(r1 or _("Unknown error")))
                end
            end)
        end
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        NetworkMgr:runWhenOnline(execute)
    else
        execute()
    end
end

local function _runAsync(work_fn, spinner_text, on_done)
    local spinner = _toast(spinner_text, 180)
    _runNetwork(work_fn, function(r1, r2)
        _close(spinner)
        on_done(r1, r2)
    end)
end

local function _runAsyncSilent(work_fn, on_done)
    _runNetwork(work_fn, on_done)
end

local function makeTapItem(frame, callback)
    local item = InputContainer:new{ frame }
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local dim = item.dimen
                    if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                    local fsize = (frame and frame.getSize and frame:getSize()) or {}
                    return Geom:new{
                        x = dim.x or 0,
                        y = dim.y or 0,
                        w = dim.w or fsize.w or 0,
                        h = dim.h or fsize.h or 0,
                    }
                end
            }
        }
    }
    item.onTap = function()
        if callback then
            local ok, err = pcall(callback)
            if not ok then
                log.err("libbee ui: tap callback error: " .. tostring(err))
            end
        end
        return true
    end
    return item
end

local function createButton(opts)
    opts = opts or {}
    local is_primary = (opts.is_primary == true) or (opts.primary == true) or (opts.background ~= nil and opts.background == Blitbuffer.COLOR_BLACK)
    local is_focused = (opts.is_focused == true)
    local border_sz = opts.bordersize or (is_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)))
    local radius = opts.radius or (theme.radius_btn or sc(4))
    local text_color = is_primary and Blitbuffer.COLOR_WHITE or (opts.text_font_color or Blitbuffer.COLOR_BLACK)

    local btn_opts = {
        text = opts.text or "",
        text_font_size = opts.text_font_size or (theme.subtext_font_size or 15),
        text_font_bold = (opts.bold ~= false),
        bordersize = border_sz,
        radius = radius,
        width = opts.width,
        height = opts.height or sc(36),
        padding = opts.padding or 0,
        padding_h = opts.padding_h,
        callback = opts.callback,
    }

    if is_primary then
        btn_opts.background = Blitbuffer.COLOR_BLACK
        btn_opts.text_font_color = Blitbuffer.COLOR_WHITE
    elseif is_focused then
        btn_opts.background = theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY
        btn_opts.text_font_color = text_color
    else
        btn_opts.background = nil -- nil tells Button:init to render white background with black border
        btn_opts.text_font_color = text_color
    end

    local btn = Button:new(btn_opts)
    if is_primary and btn.label_widget then
        btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end
    if btn.frame then
        btn.frame.color = Blitbuffer.COLOR_BLACK
        btn.frame.bordersize = border_sz
    end
    return btn
end

local function createIconButton(opts)
    opts = opts or {}
    local icon_size = opts.size or sc(32)
    local is_focused = (opts.is_focused == true)
    local icon_widget = ImageWidget:new{
        file = getAssetPath(opts.icon),
        width = icon_size,
        height = icon_size,
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }
    local frame = FrameContainer:new{
        padding = opts.padding or sc(4),
        padding_h = opts.padding_h or sc(6),
        bordersize = is_focused and (theme.border_focus or sc(2)) or (opts.bordersize or 0),
        color = Blitbuffer.COLOR_BLACK,
        radius = is_focused and (theme.radius_focus or sc(4)) or (opts.radius or 0),
        background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or (opts.background or theme.color_bg or Blitbuffer.COLOR_WHITE),
        icon_widget,
    }
    return makeTapItem(frame, opts.callback)
end

-- ---------------------------------------------------------------------------
-- Download Progress Dialog with Cancel Button
-- ---------------------------------------------------------------------------

local function createProgressBar(width, initial_pct)
    local bar_h = sc(12)
    local border_sz = sc(1)
    local max_fill_w = width - (border_sz * 2)
    local fill_w = math.max(sc(2), math.min(max_fill_w, math.floor(max_fill_w * math.min(1, math.max(0, initial_pct or 0)))))
    local fill_line = LineWidget:new{
        dimen = Geom:new{ w = fill_w, h = bar_h - (border_sz * 2) },
        background = theme.color_accent or Blitbuffer.COLOR_BLACK,
    }
    local bar = FrameContainer:new{
        padding = 0,
        padding_top = 0,
        padding_right = 0,
        padding_bottom = 0,
        padding_left = 0,
        margin = 0,
        bordersize = border_sz,
        radius = theme.radius_btn or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = theme.color_focus_bg or Blitbuffer.COLOR_WHITE,
        width = width,
        height = bar_h,
        fill_line,
    }
    bar._padding_top = 0
    bar._padding_right = 0
    bar._padding_bottom = 0
    bar._padding_left = 0
    function bar:getSize()
        self._padding_top = 0
        self._padding_right = 0
        self._padding_bottom = 0
        self._padding_left = 0
        return Geom:new{ w = width, h = bar_h }
    end
    function bar:setPercentage(pct)
        local w = math.max(0, math.min(max_fill_w, math.floor(max_fill_w * math.min(1, math.max(0, pct)))))
        if fill_line then
            if fill_line.dimen then
                fill_line.dimen.w = w
            elseif fill_line.args and fill_line.args.dimen then
                fill_line.args.dimen.w = w
            end
        end
    end
    return bar
end

local function _runDownloadWithProgress(work_fn, loan, on_done, progress_path)
    _dismissActiveToast()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local card_padding = sc(16)
    local card_border = theme.border_window or sc(2)
    local dialog_w = math.min(sw - sc(24), sc(420))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local overlay
    local tick_token
    local is_closed = false

    local function closeDialog()
        if is_closed then return end
        is_closed = true
        if tick_token then
            UIManager:unschedule(tick_token)
            tick_token = nil
        end
        if overlay then
            local ov = overlay
            overlay = nil
            ov.dismiss_callback = nil
            UIManager:close(ov, "ui")
        end
    end

    local title_text = (loan and loan.title) and loan.title or _("Book")
    local status_label = TextBoxWidget:new{
        text = _("Connecting & requesting license…"),
        face = Font:getFace("cfont", theme.face_label_size or 15),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = inner_w,
        alignment = "center",
    }

    local progress_bar = createProgressBar(inner_w, 0.1)

    local btn_w = inner_w
    local btn_h = sc(36)
    local cancel_btn = createButton{
        text = _("Cancel Download"),
        text_font_size = theme.subtext_font_size or 15,
        bold = false,
        bordersize = sc(1),
        radius = theme.radius_btn or sc(4),
        width = btn_w,
        height = btn_h,
        callback = function()
            if overlay then
                overlay.was_user_cancelled = true
            end
            if overlay and overlay.dismiss_callback then
                overlay.dismiss_callback()
            else
                closeDialog()
                log.info("libbee ui: download was cancelled by user")
                on_done(nil, _("Download cancelled"))
            end
        end,
    }

    local card = FrameContainer:new{
        padding = card_padding,
        radius = theme.radius_window or sc(4),
        bordersize = card_border,
        color = Blitbuffer.COLOR_BLACK,
        background = theme.color_bg or Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        VerticalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text = _("Downloading Book"),
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 20),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
                alignment = "center",
            },
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(12) },
            TextBoxWidget:new{
                text = title_text,
                face = Font:getFace("NotoSerif-Regular.ttf", theme.face_label_size or 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
                alignment = "center",
            },
            VerticalSpan:new{ width = sc(14) },
            status_label,
            VerticalSpan:new{ width = sc(12) },
            progress_bar,
            VerticalSpan:new{ width = sc(18) },
            cancel_btn,
        }
    }

    overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        }
    }
    overlay.label_widget = { text = "Downloading & fulfilling " .. title_text }

    -- Consume touches outside the cancel button so accidental taps do not cancel
    overlay.ges_events = {
        Tap = {
            GestureRange:new{
                range = Geom:new{ w = sw, h = sh },
            }
        }
    }
    overlay.onTap = function(self, arg, ges)
        return true
    end

    UIManager:show(overlay, "ui")

    -- Phase timer: smoothly updates status and progress bar based on actual download progress
    -- Phase timer: smoothly and monotonically updates status and progress bar based on actual download progress
    local elapsed = 0
    local max_bytes_seen = 0
    local max_pct_seen = 0.15
    local last_progress_time = 0
    local current_phase = "acsm"

    local function tick()
        if is_closed then return end
        elapsed = elapsed + 0.5

        local pf = progress_path and io.open(progress_path, "r")
        local progress_str = pf and pf:read("*l")
        if pf then pf:close() end

        if progress_str and progress_str ~= "" then
            local phase, detail = progress_str:match("^([^:]+):?(.*)$")
            if phase and phase ~= "" then
                current_phase = phase
            end

            if phase == "download" then
                local bytes = tonumber(detail or "")
                if bytes and bytes > max_bytes_seen then
                    max_bytes_seen = bytes
                    last_progress_time = elapsed
                end
            elseif phase == "decrypt" then
                last_progress_time = elapsed
            elseif phase == "acsm" then
                last_progress_time = elapsed
            end
        end

        if current_phase == "decrypt" then
            status_label:setText(_("Decrypting book…"))
            max_pct_seen = math.max(max_pct_seen, 0.90)
            progress_bar:setPercentage(max_pct_seen)
        elseif current_phase == "download" or max_bytes_seen > 0 then
            local mb = max_bytes_seen / 1048576
            status_label:setText(string.format(_("Downloading book… (%.1f MB)"), mb))
            -- Smooth monotonic curve that gracefully scales across all file sizes (1MB to 400MB+)
            -- Guarantees the progress bar never jumps backward
            local pct = 0.20 + 0.65 * (1 - (1 / (1 + (mb / 30)^0.75)))
            max_pct_seen = math.max(max_pct_seen, math.min(0.85, pct))
            progress_bar:setPercentage(max_pct_seen)
        else
            -- Connecting / ACSM phase
            status_label:setText(_("Connecting & requesting license…"))
            max_pct_seen = math.max(max_pct_seen, math.min(0.20, 0.10 + (elapsed / 4.0) * 0.10))
            progress_bar:setPercentage(max_pct_seen)
        end
        UIManager:setDirty(overlay, "ui")

        -- Timeout protection:
        -- - Hard max: 3 hours (10800s) to handle 750MB+ comic PDFs
        -- - Stall: 90s if no bytes have been received yet (connecting phase)
        --          5 minutes (300s) if bytes are flowing (slow CDN/network)
        local stalled = (elapsed - last_progress_time)
        local stall_limit = (max_bytes_seen > 0) and 300 or 90
        if elapsed >= 10800 or (elapsed > 30 and stalled >= stall_limit) then
            if overlay then
                overlay.was_timed_out = true
            end
            if overlay and overlay.dismiss_callback then
                overlay.dismiss_callback()
            else
                closeDialog()
                log.warn("libbee ui: download timed out (stalled)")
                on_done(nil, _("Download timed out"))
            end
            return
        end

        tick_token = UIManager:scheduleIn(0.5, tick)
    end
    tick_token = UIManager:scheduleIn(0.5, tick)

    -- Run download in subprocess with our dialog as the trap widget
    _runNetwork(work_fn, function(r1, r2)
        closeDialog()
        on_done(r1, r2)
    end, overlay)
end

-- ---------------------------------------------------------------------------
-- Styled Card Dialog (Replaces raw ConfirmBox)
-- ---------------------------------------------------------------------------

function M.showCardDialog(opts)
    _dismissActiveToast()
    opts = opts or {}
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local card_padding = sc(14)
    local card_border = theme.border_window or sc(2)
    local dialog_w = opts.width or math.min(sw - sc(20), sc(420))
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local overlay
    local function closeDialog(callback)
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if callback then callback() end
    end

    local buttons = opts.buttons or { { text = _("OK"), is_primary = true } }
    local focused_button_idx = 1
    for i, b in ipairs(buttons) do
        if b.is_primary then
            focused_button_idx = i
            break
        end
    end

    local buildCardWidget
    buildCardWidget = function()
        local content_items = {}

        -- Header / Title
        if opts.title and opts.title ~= "" then
            local title_label = TextBoxWidget:new{
                text = opts.title,
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
                alignment = opts.title_align or "left",
            }
            table.insert(content_items, title_label)
            table.insert(content_items, VerticalSpan:new{ width = sc(6) })
            table.insert(content_items, LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            })
            table.insert(content_items, VerticalSpan:new{ width = sc(10) })
        end

        -- Body
        if opts.body_widget then
            table.insert(content_items, opts.body_widget)
            table.insert(content_items, VerticalSpan:new{ width = sc(10) })
        elseif opts.body_text and opts.body_text ~= "" then
            local body_box = TextBoxWidget:new{
                text = opts.body_text,
                face = Font:getFace("cfont", theme.face_label_size or 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
                alignment = opts.body_align or "left",
            }
            table.insert(content_items, body_box)
            table.insert(content_items, VerticalSpan:new{ width = sc(12) })
        end

        -- Button Row
        local btn_widgets = {}
        local num_btns = #buttons
        local btn_gap = sc(8)
        local btn_w = math.floor((inner_w - (btn_gap * (num_btns - 1))) / num_btns)
        local btn_h = sc(36)

        for i, b in ipairs(buttons) do
            if i > 1 then
                table.insert(btn_widgets, HorizontalSpan:new{ width = btn_gap })
            end

            local is_pri = (b.is_primary == true)
            local is_focused = (i == focused_button_idx)
            local btn = createButton{
                text = b.text,
                text_font_size = theme.subtext_font_size or 15,
                bold = is_pri or b.bold or is_focused,
                is_primary = is_pri,
                is_focused = is_focused,
                bordersize = is_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
                radius = theme.radius_btn or sc(4),
                width = btn_w,
                height = btn_h,
                callback = function()
                    closeDialog(b.callback)
                end,
            }
            table.insert(btn_widgets, btn)
        end

        table.insert(content_items, HorizontalGroup:new(btn_widgets))

        return FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or sc(4),
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                unpack(content_items)
            }
        }
    end

    local key_events = {
        Close = { { "Back" }, { "Escape" } },
        PrevBtn = { { "Left" }, { "Up" } },
        NextBtn = { { "Right" }, { "Down" } },
        Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
    }
    if Device and Device.input and Device.input.group then
        if Device.input.group.Back then table.insert(key_events.Close, { Device.input.group.Back }) end
        if Device.input.group.Left then table.insert(key_events.PrevBtn, { Device.input.group.Left }) end
        if Device.input.group.Up then table.insert(key_events.PrevBtn, { Device.input.group.Up }) end
        if Device.input.group.Right then table.insert(key_events.NextBtn, { Device.input.group.Right }) end
        if Device.input.group.Down then table.insert(key_events.NextBtn, { Device.input.group.Down }) end
        if Device.input.group.Press then table.insert(key_events.Press, { Device.input.group.Press }) end
        if Device.input.group.Enter then table.insert(key_events.Press, { Device.input.group.Enter }) end
    end

    local card = buildCardWidget()

    overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        key_events = key_events,
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        }
    }

    local function refreshCard()
        if overlay and overlay[1] then
            overlay[1][1] = buildCardWidget()
            UIManager:setDirty(overlay, "ui")
        end
    end

    overlay.onPrevBtn = function()
        if #buttons > 1 then
            focused_button_idx = (focused_button_idx > 1) and (focused_button_idx - 1) or #buttons
            refreshCard()
            return true
        end
    end

    overlay.onNextBtn = function()
        if #buttons > 1 then
            focused_button_idx = (focused_button_idx < #buttons) and (focused_button_idx + 1) or 1
            refreshCard()
            return true
        end
    end

    overlay.onPress = function()
        if buttons[focused_button_idx] then
            closeDialog(buttons[focused_button_idx].callback)
            return true
        end
    end

    overlay.onClose = function()
        closeDialog(opts.on_close or opts.cancel_callback)
        return true
    end

    UIManager:show(overlay, "ui")
    return overlay
end

function M.showByteBookDialog()
    local sw = Screen:getWidth()
    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    local qr_size = sc(180)
    local qr_widget = nil
    if ok_qr and QRWidget then
        qr_widget = QRWidget:new{
            text = "https://dtsbytebooks.com/",
            width = qr_size,
            height = qr_size,
        }
    end

    local body_items = VerticalGroup:new{
        align = "center",
    }

    if qr_widget then
        table.insert(body_items, FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            padding = sc(8),
            bordersize = sc(1),
            color = Blitbuffer.COLOR_BLACK,
            qr_widget,
        })
        table.insert(body_items, VerticalSpan:new{ width = sc(12) })
    end

    table.insert(body_items, TextWidget:new{
        text = "https://dtsbytebooks.com/",
        face = Font:getFace("cfont", 17),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    })

    table.insert(body_items, VerticalSpan:new{ width = sc(6) })

    table.insert(body_items, TextWidget:new{
        text = _("Scan with your phone to learn more."),
        face = Font:getFace("cfont", 14),
        fgcolor = theme.color_label_dim,
    })

    local dialog_w = math.min(sw - sc(20), sc(380))
    local body_container = CenterContainer:new{
        dimen = Geom:new{ w = dialog_w - sc(36), h = (qr_widget and sc(260) or sc(80)) },
        body_items,
    }

    M.showCardDialog{
        title = _("ByteBooks"),
        title_align = "center",
        width = dialog_w,
        body_widget = body_container,
        buttons = {
            {
                text = _("Done"),
                is_primary = true,
            }
        }
    }
end

-- ---------------------------------------------------------------------------
-- Setup Dialog
-- ---------------------------------------------------------------------------

function M.showSetupDialog(plugin_dir, on_done)
    local State = require(plugin_path .. "libbee_state")
    local API   = require(plugin_path .. "libbee_api")

    _runAsync(
        function()
            return API.requestSetupCode()
        end,
        _("Connecting to Libby…"),
        function(result, err)
            if not result or not result.code then
                local err_str = err or tostring(result or _("Unknown error"))
                log.warn("setup code request failed: " .. tostring(err_str))
                M.showCardDialog{
                    title = _("Setup Failed"),
                    body_text = _("Could not request setup code.") .. "\n\n" .. tostring(err_str) .. "\n\n" .. _("Make sure your device is connected to Wi-Fi."),
                    buttons = {
                        {
                            text = _("Retry"),
                            is_primary = true,
                            callback = function()
                                M.showSetupDialog(plugin_dir, on_done)
                            end
                        },
                        {
                            text = _("Cancel"),
                            callback = function()
                                if on_done then on_done(false) end
                            end
                        }
                    },
                    on_close = function()
                        if on_done then on_done(false) end
                    end
                }
                return
            end

            local raw_code = result.code
            local display_code = raw_code:sub(1, 4) .. " " .. raw_code:sub(5, 8)

            local is_active = true
            local setup_overlay = nil
            local code_expires_in = 60
            local is_regenerating = false

            local function cleanup()
                is_active = false
                State.clearPendingIdentity()
                if setup_overlay then
                    local ov = setup_overlay
                    setup_overlay = nil
                    ov.onClose = nil
                    UIManager:close(ov, "ui")
                end
            end

            -- Forward declarations for widgets
            local code_text_w
            local waiting_text_w

            local function regenerate_code()
                if not is_active or is_regenerating then return end
                is_regenerating = true
                if waiting_text_w then
                    waiting_text_w:setText(_("Regenerating setup code…"))
                    if setup_overlay then UIManager:setDirty(setup_overlay, "ui") end
                end

                _runAsyncSilent(
                    function()
                        return API.requestSetupCode()
                    end,
                    function(new_res, new_err)
                        is_regenerating = false
                        if not is_active then return end
                        if new_res and new_res.code then
                            raw_code = new_res.code
                            display_code = raw_code:sub(1, 4) .. " " .. raw_code:sub(5, 8)
                            if code_text_w then code_text_w:setText(display_code) end
                            code_expires_in = 60
                            if waiting_text_w then
                                waiting_text_w:setText(_("Waiting for Libby app to authorize… (%ds)", code_expires_in))
                            end
                            if setup_overlay then UIManager:setDirty(setup_overlay, "ui") end
                        else
                            if waiting_text_w then
                                waiting_text_w:setText(_("Code expired. Tap New Code to retry."))
                            end
                            if setup_overlay then UIManager:setDirty(setup_overlay, "ui") end
                        end
                    end
                )
            end

            local function do_tick()
                if not is_active then return end
                if not is_regenerating then
                    code_expires_in = code_expires_in - 1
                    if code_expires_in <= 0 then
                        regenerate_code()
                    else
                        if waiting_text_w then
                            waiting_text_w:setText(_("Waiting for Libby app to authorize… (%ds)", code_expires_in))
                            if setup_overlay then UIManager:setDirty(setup_overlay, "ui") end
                        end
                    end
                end
                if is_active then
                    UIManager:scheduleIn(1, do_tick)
                end
            end

            local poll_count = 0
            local max_polls = 120 -- 6 minutes total allowed
            local function do_poll()
                if not is_active then return end
                if is_regenerating then
                    UIManager:scheduleIn(2, do_poll)
                    return
                end

                poll_count = poll_count + 1
                if poll_count > max_polls then
                    cleanup()
                    M.showCardDialog{
                        title = _("Setup Timed Out"),
                        body_text = _("Authorization timed out.\n\nPlease try again from the Libby app."),
                        buttons = {
                            { text = _("OK"), is_primary = true, callback = function()
                                if on_done then on_done(false) end
                            end }
                        },
                    }
                    return
                end

                _runAsyncSilent(
                    function()
                        return API.pollForCloneResult(raw_code)
                    end,
                    function(poll_res, poll_err)
                        if not is_active then return end
                        if poll_res and poll_res.chip then
                            cleanup()
                            local lib_name = poll_res.library_name or "Libby"
                            M.showCardDialog{
                                title = _("✓ Libbee Connected!"),
                                body_text = _("Library: %s\n\nYour device is now registered. You can browse and download your shelf.", tostring(lib_name)),
                                buttons = {
                                    {
                                        text = _("Open Shelf"),
                                        is_primary = true,
                                        callback = function()
                                            M.showShelfBrowser(plugin_dir)
                                            if on_done then on_done(true) end
                                        end,
                                    }
                                }
                            }
                        elseif poll_err == "pending" then
                            UIManager:scheduleIn(3, do_poll)
                        else
                            -- Temporary network error: keep polling on next cycle
                            UIManager:scheduleIn(3, do_poll)
                        end
                    end
                )
            end

            -- Setup Code Card layout
            local sw = Screen:getWidth()
            local sh = Screen:getHeight()
            local dialog_w = math.min(sw - sc(20), sc(420))
            local inner_w = dialog_w - sc(32)

            code_text_w = TextWidget:new{
                text = display_code,
                face = Font:getFace("cfont", 26),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local code_box = FrameContainer:new{
                padding = sc(10),
                bordersize = sc(2),
                color = Blitbuffer.COLOR_BLACK,
                background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
                radius = theme.radius_btn or sc(4),
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w - sc(20), h = sc(44) },
                    code_text_w,
                }
            }

            local instructions_text = TextBoxWidget:new{
                text = _("1. Open the Libby app on your phone or computer.\n") ..
                       _("2. Tap Menu (☰) → Your Information → Copy To Another Device.\n") ..
                       _("3. Enter the 8-digit setup code below:\n"),
                face = Font:getFace("cfont", 15),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
            }

            waiting_text_w = TextWidget:new{
                text = _("Waiting for Libby app to authorize… (60s)"),
                face = Font:getFace("cfont", 13),
                fgcolor = theme.color_label_dim,
            }

            local waiting_box = CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = sc(20) },
                waiting_text_w,
            }

            local body_vg = VerticalGroup:new{
                align = "center",
                instructions_text,
                VerticalSpan:new{ width = sc(4) },
                code_box,
                VerticalSpan:new{ width = sc(8) },
                waiting_box,
            }

            setup_overlay = M.showCardDialog{
                title = _("Link Libby Account"),
                body_widget = body_vg,
                width = dialog_w,
                buttons = {
                    {
                        text = _("Cancel"),
                        callback = function()
                            cleanup()
                            if on_done then on_done(false) end
                        end
                    }
                },
                on_close = function()
                    cleanup()
                    if on_done then on_done(false) end
                end
            }

            UIManager:scheduleIn(3, do_poll)
            UIManager:scheduleIn(1, do_tick)
        end
    )
end

-- ---------------------------------------------------------------------------
-- Expiry Badge Helper
-- ---------------------------------------------------------------------------

local function _fmtDays(days)
    if not days then return "" end
    if days == 0 then return _("Expires today") end
    if days == 1 then return _("1 day left") end
    return _("%d days left", days)
end

local function _createBadge(text, is_urgent)
    if not text or text == "" then return nil end
    local bg = is_urgent and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = is_urgent and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", 14),
        bold = is_urgent,
        fgcolor = fg,
    }
    return FrameContainer:new{
        padding_top = sc(2),
        padding_bottom = sc(2),
        padding_left = sc(7),
        padding_right = sc(7),
        bordersize = is_urgent and 0 or sc(1),
        color = Blitbuffer.COLOR_BLACK,
        background = bg,
        radius = theme.radius_badge or sc(8),
        label,
    }
end

local function _restrictionBadgeLabel(loan)
    if not loan then return nil end
    local r = loan.restriction_type
    if r == "kindle_or_libby" then
        return _("Libby / Kindle")
    elseif r == "kindle_only" then
        return _("Kindle only")
    elseif r == "libby_only" then
        return _("Libby only")
    elseif r == "audiobook" then
        return _("Audiobook")
    elseif r == "magazine" then
        return _("Magazine")
    elseif loan.is_downloadable == false or loan.is_ebook == false then
        return _("Unsupported")
    end
    return nil
end

local function _loanBadge(loan, is_focused)
    if not loan then return nil end
    local rest_label = _restrictionBadgeLabel(loan)
    if rest_label then
        return _createBadge(rest_label, is_focused or false)
    end
    local days_str = _fmtDays(loan.days_remaining)
    local is_urgent = (loan.days_remaining and loan.days_remaining <= 2)
    return _createBadge(days_str, is_urgent or is_focused)
end

-- ---------------------------------------------------------------------------
-- Shelf Browser (Full-screen Dialog with List & Cover Views)
-- ---------------------------------------------------------------------------

local active_shelf_overlay = nil

function M.showShelfBrowser(plugin_dir)
    local State = require(plugin_path .. "libbee_state")
    local API   = require(plugin_path .. "libbee_api")

    -- Check auth before fetching
    if not State.isAuthenticated() then
        M.showCardDialog{
            title = _("Libbee Setup Required"),
            body_text = _("Libbee is not connected yet.\n\nConnect with a Libby setup code to browse and download your loans."),
            buttons = {
                {
                    text = _("Setup Now"),
                    is_primary = true,
                    callback = function()
                        M.showSetupDialog(plugin_dir, function(success)
                            if success then M.showShelfBrowser(plugin_dir) end
                        end)
                    end,
                },
                { text = _("Cancel") }
            }
        }
        return
    end

    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device
    local cached_shelf = State.getShelfCache()
    local current_page = 1
    local focused_shelf_idx = 1
    local focused_header_idx = 1
    local focus_zone = "items" -- "items" or "header"
    local current_rendered_loans = cached_shelf or {}
    local doBackgroundSync = nil
    local handleLoanReturned = nil

    local function renderShelf(loans, from_cache)
        current_rendered_loans = loans or current_rendered_loans or {}
        if active_shelf_overlay then
            local ov = active_shelf_overlay
            active_shelf_overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        local view_mode = State.getViewMode() -- "list" or "cover"

        -- Sort loans deterministically:
        -- 1. Days remaining (soonest first)
        -- 2. Title (alphabetical case-insensitive)
        -- 3. Unique ID / reserveId as tiebreaker
        table.sort(loans or {}, function(a, b)
            local da = a.days_remaining or 999
            local db = b.days_remaining or 999
            if da ~= db then
                return da < db
            end
            local ta = tostring(a.title or ""):lower()
            local tb = tostring(b.title or ""):lower()
            if ta ~= tb then
                return ta < tb
            end
            local ia = tostring(a.id or a.reserveId or "")
            local ib = tostring(b.id or b.reserveId or "")
            return ia < ib
        end)

        local lib_name = State.getLibraryName() or "Libby"
        local loan_count = #loans
        local all_cards = State.getAllCards()
        local group_by_card = State.getGroupByCard and State.getGroupByCard() ~= false

        if loan_count == 0 then
            focus_zone = "header"
        end

        -- Determine library cards / accounts present across active loans
        local card_groups = {}
        local group_order = {}
        for _, loan in ipairs(loans) do
            local g_name = group_by_card and State.loanGroupLabel(loan, all_cards) or ""
            if not card_groups[g_name] then
                card_groups[g_name] = {}
                table.insert(group_order, g_name)
            end
            table.insert(card_groups[g_name], loan)
        end
        table.sort(group_order, function(a, b)
            return tostring(a):lower() < tostring(b):lower()
        end)

        -- Flatten loans for pagination (keeps card/library grouping info)
        local flat_items = {}
        if #group_order > 1 then
            for _, g_name in ipairs(group_order) do
                for _, loan in ipairs(card_groups[g_name]) do
                    table.insert(flat_items, { loan = loan, lib = g_name })
                end
            end
        else
            for _, loan in ipairs(loans) do
                table.insert(flat_items, { loan = loan, lib = nil })
            end
        end

        local lib_order = group_order

        -- Header Action Buttons using Feather SVGs (Storefront style, stroke-width 1.2)
        local btn_size = sc(32)
        local btn_pad = sc(4)

        local is_hdr = (focus_zone == "header")

        local view_toggle_icon = (view_mode == "cover") and "list.svg" or "grid.svg"
        local view_toggle_btn = createIconButton{
            icon = view_toggle_icon,
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
            is_focused = (focus_visible and is_hdr and focused_header_idx == 1),
            callback = function()
                focus_zone = "header"
                focused_header_idx = 1
                local next_mode = (view_mode == "cover") and "list" or "cover"
                State.saveViewMode(next_mode)
                current_page = 1
                focused_shelf_idx = 1
                renderShelf(loans, from_cache)
            end,
        }

        local refresh_btn = createIconButton{
            icon = "refresh-cw.svg",
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
            is_focused = (focus_visible and is_hdr and focused_header_idx == 2),
            callback = function()
                focus_zone = "header"
                focused_header_idx = 2
                State.clearShelfCache()
                _runAsync(
                    function() return API.fetchShelf() end,
                    _("Refreshing shelf from Libby…"),
                    function(result, err)
                        if type(result) == "table" then
                            State.saveShelfCache(result)
                            current_page = 1
                            focused_shelf_idx = 1
                            if #result > 0 then focus_zone = "items" end
                            renderShelf(result, false)
                        elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                            M._handleAuthExpired(plugin_dir)
                        else
                            _toast(_("Refresh failed: %s", tostring(err or _("error"))), 4)
                        end
                    end
                )
            end,
        }

        local menu_btn = createIconButton{
            icon = "settings.svg",
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
            is_focused = (focus_visible and is_hdr and focused_header_idx == 3),
            callback = function()
                focus_zone = "header"
                focused_header_idx = 3
                M.showAbout(plugin_dir, function()
                    renderShelf(loans, from_cache)
                end, function()
                    renderShelf(loans, from_cache)
                end)
            end,
        }

        local close_btn = createIconButton{
            icon = "x.svg",
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
            is_focused = (focus_visible and is_hdr and focused_header_idx == 4),
            callback = function()
                if active_shelf_overlay then
                    local ov = active_shelf_overlay
                    active_shelf_overlay = nil
                    ov.onClose = nil
                    UIManager:close(ov, "ui")
                end
            end,
        }

        local header_actions = HorizontalGroup:new{
            view_toggle_btn,
            HorizontalSpan:new{ width = sc(12) },
            refresh_btn,
            HorizontalSpan:new{ width = sc(12) },
            menu_btn,
            HorizontalSpan:new{ width = sc(12) },
            close_btn,
        }

        -- 1. Top Header Bar
        local icon_size = sc(34)
        local bee_icon = ImageWidget:new{
            file = getAssetPath("bee.png"),
            width = icon_size,
            height = icon_size,
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }

        local header_title = HorizontalGroup:new{
            align = "center",
            bee_icon,
            HorizontalSpan:new{ width = sc(8) },
            TextWidget:new{
                text = _("Libbee · Shelf"),
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        }

        local count_str = string.format("%d %s", loan_count, loan_count == 1 and _("loan") or _("loans"))
        if from_cache then count_str = count_str .. " " .. _("(cached)") end

        local sub_text = count_str
        if #lib_order == 1 and group_by_card and lib_order[1] ~= "" then
            sub_text = count_str .. "  ·  " .. lib_order[1]
        elseif #lib_order > 1 and group_by_card then
            sub_text = count_str .. "  ·  " .. string.format(_("%d library cards"), #lib_order)
        elseif lib_name and lib_name ~= "" then
            sub_text = count_str .. "  ·  " .. lib_name
        end

        local actions_w = header_actions:getSize().w
        local header_avail_w = sw - sc(24)

        local header_top_row = HorizontalGroup:new{
            header_title,
            HorizontalSpan:new{ width = math.max(sc(8), header_avail_w - header_title:getSize().w - actions_w) },
            header_actions,
        }

        local header_sub = TextWidget:new{
            text = sub_text,
            face = Font:getFace("cfont", theme.subtext_font_size or 15),
            fgcolor = theme.color_label_dim,
            max_width = header_avail_w,
        }

        local header_content = VerticalGroup:new{
            align = "left",
            header_top_row,
            VerticalSpan:new{ width = sc(2) },
            header_sub,
        }

        local header_frame = FrameContainer:new{
            padding = sc(10),
            padding_left = sc(12),
            padding_right = sc(12),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            header_content,
        }

        local header_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        }

        -- Dynamic pagination metrics based on available height
        local header_h = header_frame:getSize().h + sc(2)
        local footer_h = sc(48)
        local top_margin = sc(6)
        local safety_margin = sc(20)
        local avail_h = sh - header_h - footer_h - top_margin - safety_margin

        local COLS = 3
        local items_per_page

        local grid_gap = sc(10)
        local border_w = theme.border_preview or sc(2)
        local target_margin_h = sc(14)
        local avail_grid_w = sw - (target_margin_h * 2)
        local cell_w = math.floor((avail_grid_w - (grid_gap * (COLS - 1))) / COLS)
        local row_total_w = (cell_w * COLS) + (grid_gap * (COLS - 1))
        local margin_h = math.floor((sw - row_total_w) / 2)

        local content_w = row_total_w
        local content_inner = content_w - sc(16)

        local section_hdr_h = sc(34)
        local section_header_reserve = (#lib_order > 1) and (math.min(#lib_order, 2) * section_hdr_h) or 0
        local avail_grid_h = avail_h - section_header_reserve

        local tile_extra_h = (border_w * 2) + sc(4) + sc(40) + sc(4) + sc(26)
        local grid_gap_v = sc(8)

        local cover_inner_w
        local cover_inner_h
        local num_rows
        local cover_row_h

        if view_mode == "cover" then
            local max_cover_w_by_cell = cell_w - (border_w * 2)
            local ideal_cover_h = math.floor(max_cover_w_by_cell * 1.38)

            local max_row_h_3 = math.floor((avail_grid_h - (grid_gap_v * 2)) / 3)
            local max_cover_h_3 = max_row_h_3 - tile_extra_h

            local max_row_h_2 = math.floor((avail_grid_h - grid_gap_v) / 2)
            local max_cover_h_2 = max_row_h_2 - tile_extra_h

            if max_cover_h_3 >= math.floor(ideal_cover_h * 0.90) then
                num_rows = 3
            elseif max_cover_h_2 >= sc(70) then
                num_rows = 2
            else
                num_rows = 1
            end

            local max_row_h = math.floor((avail_grid_h - (grid_gap_v * (num_rows - 1))) / num_rows)
            local max_cover_h = math.max(sc(45), max_row_h - tile_extra_h)
            local max_cover_w_by_h = math.floor(max_cover_h / 1.38)

            cover_inner_w = math.max(sc(40), math.min(max_cover_w_by_cell, max_cover_w_by_h))
            cover_inner_h = math.floor(cover_inner_w * 1.38)
            cover_row_h = cover_inner_h + tile_extra_h
        end

        -- Build capacity-aware pages ensuring no page exceeds available vertical capacity
        local pages = {}
        local cur_page = {}

        if view_mode == "cover" then
            local max_page_h = avail_h
            local cur_page_h = 0

            for _, g_name in ipairs(group_order) do
                local loans_in_group = card_groups[g_name] or {}
                local loan_idx = 1
                local is_new_section = true

                while loan_idx <= #loans_in_group do
                    local header_cost = (#group_order > 1 and is_new_section) and section_hdr_h or 0
                    local gap_cost = (cur_page_h > 0) and grid_gap_v or 0
                    local row_cost = header_cost + gap_cost + cover_row_h

                    if cur_page_h > 0 and (cur_page_h + row_cost > max_page_h) then
                        table.insert(pages, cur_page)
                        cur_page = {}
                        cur_page_h = 0
                        gap_cost = 0
                        header_cost = (#group_order > 1) and section_hdr_h or 0
                        row_cost = header_cost + cover_row_h
                    end

                    local remaining_h = max_page_h - (cur_page_h + header_cost + gap_cost)
                    local max_rows_can_fit = math.max(1, math.floor((remaining_h + grid_gap_v) / (cover_row_h + grid_gap_v)))
                    local max_items_can_fit = max_rows_can_fit * COLS

                    local items_to_take = math.min(#loans_in_group - loan_idx + 1, max_items_can_fit)
                    local rows_taken = math.ceil(items_to_take / COLS)
                    local actual_row_height_taken = (rows_taken * cover_row_h) + ((rows_taken - 1) * grid_gap_v)

                    local chunk = {}
                    for k = 0, items_to_take - 1 do
                        table.insert(chunk, { loan = loans_in_group[loan_idx + k], lib = (#group_order > 1 and is_new_section and g_name or nil) })
                    end

                    table.insert(cur_page, { lib = (#group_order > 1 and is_new_section and g_name or nil), items = chunk })
                    cur_page_h = cur_page_h + header_cost + gap_cost + actual_row_height_taken
                    loan_idx = loan_idx + items_to_take
                    is_new_section = false
                end
            end
            if #cur_page > 0 then
                table.insert(pages, cur_page)
            end
        else -- list mode
            local list_row_h = sc(92)
            local max_page_h = avail_h
            local cur_page_h = 0

            for _, g_name in ipairs(group_order) do
                local loans_in_group = card_groups[g_name] or {}
                local loan_idx = 1
                local is_new_section = true

                while loan_idx <= #loans_in_group do
                    local header_cost = (#group_order > 1 and is_new_section) and section_hdr_h or 0
                    local item_cost = header_cost + list_row_h

                    if cur_page_h > 0 and (cur_page_h + item_cost > max_page_h) then
                        table.insert(pages, cur_page)
                        cur_page = {}
                        cur_page_h = 0
                        header_cost = (#group_order > 1) and section_hdr_h or 0
                        item_cost = header_cost + list_row_h
                    end

                    local remaining_h = max_page_h - (cur_page_h + header_cost)
                    local items_can_fit = math.max(1, math.floor(remaining_h / list_row_h))
                    local items_to_take = math.min(#loans_in_group - loan_idx + 1, items_can_fit)

                    local chunk = {}
                    for k = 0, items_to_take - 1 do
                        table.insert(chunk, { loan = loans_in_group[loan_idx + k], lib = (#group_order > 1 and is_new_section and g_name or nil) })
                    end

                    table.insert(cur_page, { lib = (#group_order > 1 and is_new_section and g_name or nil), items = chunk })
                    cur_page_h = cur_page_h + header_cost + (items_to_take * list_row_h)
                    loan_idx = loan_idx + items_to_take
                    is_new_section = false
                end
            end
            if #cur_page > 0 then
                table.insert(pages, cur_page)
            end
        end

        local total_pages = math.max(1, #pages)
        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        -- Flatten current page loans for D-Pad focus index tracking
        local cur_page_loans = {}
        if #loans > 0 then
            local cur_page_sections = pages[current_page] or {}
            for _, section in ipairs(cur_page_sections) do
                for _, item in ipairs(section.items) do
                    table.insert(cur_page_loans, item.loan)
                end
            end
        end
        if focused_shelf_idx > #cur_page_loans and #cur_page_loans > 0 then
            focused_shelf_idx = #cur_page_loans
        elseif focused_shelf_idx < 1 then
            focused_shelf_idx = 1
        end

        -- 2. Page Content
        local page_content_vg = VerticalGroup:new{ align = "left" }

        local function create_shelf_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = content_w - sc(16),
            }
            local frame = FrameContainer:new{
                padding = sc(3),
                padding_left = sc(8),
                padding_right = sc(8),
                bordersize = 0,
                width = content_w,
                background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
            return HorizontalGroup:new{
                HorizontalSpan:new{ width = margin_h },
                frame,
                HorizontalSpan:new{ width = margin_h },
            }
        end

        local function render_list_loan(loan, loan_idx, page_item_idx)
            local is_focused = (focus_visible and focus_zone == "items" and page_item_idx == focused_shelf_idx)
            local badge_w = _loanBadge(loan, is_focused)

            local badge_reserve = badge_w and (badge_w:getSize().w + sc(8)) or 0
            local thumb_w_size = sc(54)
            local thumb_h_size = sc(76)
            local thumb_reserve = thumb_w_size + sc(10)
            local text_w = content_inner - badge_reserve - thumb_reserve

            local cached_cover = Covers.getCachedCoverPath(loan)
            local thumb_widget = nil
            if cached_cover then
                thumb_widget = Covers.createCoverImageWidget(cached_cover, thumb_w_size, thumb_h_size)
            end
            if not thumb_widget then
                thumb_widget = Covers.createPlaceholderWidget(thumb_w_size, thumb_h_size, nil)
            end

            local thumb_frame = FrameContainer:new{
                bordersize = 0,
                padding = 0,
                width = thumb_w_size,
                height = thumb_h_size,
                thumb_widget,
            }

            if not cached_cover then
                UIManager:scheduleIn(loan_idx * 0.1, function()
                    Covers.fetchCover(loan, function(loaded_path)
                        if loaded_path and active_shelf_overlay and thumb_frame then
                            UIManager:nextTick(function()
                                if active_shelf_overlay and thumb_frame then
                                    local new_img = Covers.createCoverImageWidget(loaded_path, thumb_w_size, thumb_h_size)
                                    if new_img then
                                        thumb_frame[1] = new_img
                                        UIManager:setDirty(active_shelf_overlay, "ui")
                                    end
                                end
                            end)
                        end
                    end)
                end)
            end

            local display_title = (loan.title or _("Unknown Title")):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
            if not display_title or display_title == "" then display_title = _("Unknown Title") end

            local title_w = TextWidget:new{
                text = display_title,
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 20),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            }

            local meta_parts = {}
            if loan.author and loan.author ~= "" then table.insert(meta_parts, loan.author) end
            if #lib_order == 1 and loan.library and loan.library ~= "" and loan.library ~= lib_name then
                table.insert(meta_parts, loan.library)
            end
            local meta_str = table.concat(meta_parts, "  ·  ")

            local meta_w = TextWidget:new{
                text = meta_str,
                face = Font:getFace("cfont", theme.subtext_font_size or 16),
                fgcolor = theme.color_label_dim,
                max_width = text_w,
            }

            local text_vg = VerticalGroup:new{
                align = "left",
                title_w,
                VerticalSpan:new{ width = sc(2) },
                meta_w,
            }

            local row_left = HorizontalGroup:new{
                thumb_frame,
                HorizontalSpan:new{ width = sc(10) },
                text_vg,
            }

            local total_h = math.max(row_left:getSize().h, badge_w and badge_w:getSize().h or 0)
            local row_overlap
            if badge_w then
                row_overlap = OverlapGroup:new{
                    dimen = Geom:new{ w = content_inner, h = total_h },
                    LeftContainer:new{
                        dimen = Geom:new{ w = content_inner, h = total_h },
                        row_left,
                    },
                    RightContainer:new{
                        dimen = Geom:new{ w = content_inner, h = total_h },
                        badge_w,
                    }
                }
            else
                row_overlap = row_left
            end

            local row_frame = FrameContainer:new{
                padding = sc(8),
                bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                color = Blitbuffer.COLOR_BLACK,
                background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                radius = is_focused and (theme.radius_focus or sc(6)) or 0,
                width = content_w,
                row_overlap,
            }

            local row_tap = makeTapItem(row_frame, function()
                focus_zone = "items"
                focused_shelf_idx = page_item_idx
                if is_touch_device then focus_visible = false end
                M.showDownloadConfirm(loan, plugin_dir, function()
                    renderShelf(current_rendered_loans, false)
                end, function(returned_loan)
                    if handleLoanReturned then
                        handleLoanReturned(returned_loan or loan)
                    end
                end)
            end)

            table.insert(page_content_vg, HorizontalGroup:new{
                HorizontalSpan:new{ width = margin_h },
                row_tap,
                HorizontalSpan:new{ width = margin_h },
            })
            table.insert(page_content_vg, HorizontalGroup:new{
                HorizontalSpan:new{ width = margin_h },
                LineWidget:new{
                    dimen = Geom:new{ w = content_w, h = sc(1) },
                    background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
                },
                HorizontalSpan:new{ width = margin_h },
            })
        end

        local function render_cover_grid(page_items, global_start_idx, page_item_start_idx)
            local num_cols = COLS
            local current_row_widgets = {}

            for i, item in ipairs(page_items) do
                local loan = item.loan
                local global_idx = (global_start_idx or 0) + i
                local page_item_idx = (page_item_start_idx or 0) + i
                local is_focused = (focus_visible and focus_zone == "items" and page_item_idx == focused_shelf_idx)

                local cached_cover = Covers.getCachedCoverPath(loan)
                local cover_img = nil

                if cached_cover then
                    cover_img = Covers.createCoverImageWidget(cached_cover, cover_inner_w, cover_inner_h)
                end

                if not cover_img then
                    cover_img = Covers.createPlaceholderWidget(cover_inner_w, cover_inner_h, loan.title)
                end

                local cover_frame = FrameContainer:new{
                    bordersize = is_focused and (theme.border_focus or sc(3)) or border_w,
                    color = Blitbuffer.COLOR_BLACK,
                    padding = is_focused and sc(3) or 0,
                    background = is_focused and Blitbuffer.COLOR_WHITE or nil,
                    radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                    cover_img,
                }

                if not cached_cover then
                    UIManager:scheduleIn(global_idx * 0.1, function()
                        Covers.fetchCover(loan, function(loaded_path)
                            if loaded_path and active_shelf_overlay and cover_frame then
                                UIManager:nextTick(function()
                                    if active_shelf_overlay and cover_frame then
                                        local new_img = Covers.createCoverImageWidget(loaded_path, cover_inner_w, cover_inner_h)
                                        if new_img then
                                            cover_frame[1] = new_img
                                            UIManager:setDirty(active_shelf_overlay, "ui")
                                        end
                                    end
                                end)
                            end
                        end)
                    end)
                end

                local display_title = (loan.title or _("Unknown Title")):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
                if not display_title or display_title == "" then display_title = _("Unknown Title") end

                local title_w = TextWidget:new{
                    text = display_title,
                    face = Font:getFace("NotoSerif-Regular.ttf", 15),
                    bold = true,
                    max_width = cell_w - sc(4),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local badge_widget = _loanBadge(loan, is_focused)

                local cell_content = VerticalGroup:new{
                    align = "center",
                    cover_frame,
                    VerticalSpan:new{ width = sc(6) },
                    title_w,
                    VerticalSpan:new{ width = sc(4) },
                    badge_widget or VerticalSpan:new{ width = 0 },
                }

                local cell_tap = makeTapItem(cell_content, function()
                    focus_zone = "items"
                    focused_shelf_idx = page_item_idx
                    if is_touch_device then focus_visible = false end
                    M.showDownloadConfirm(loan, plugin_dir, function()
                        renderShelf(current_rendered_loans, false)
                    end, function(returned_loan)
                        if handleLoanReturned then
                            handleLoanReturned(returned_loan or loan)
                        end
                    end)
                end)

                table.insert(current_row_widgets, cell_tap)

                if #current_row_widgets == num_cols or i == #page_items then
                    local row_group_items = { HorizontalSpan:new{ width = margin_h } }
                    for col_i, cell in ipairs(current_row_widgets) do
                        if col_i > 1 then
                            table.insert(row_group_items, HorizontalSpan:new{ width = grid_gap })
                        end
                        table.insert(row_group_items, cell)
                    end
                    table.insert(row_group_items, HorizontalSpan:new{ width = margin_h })
                    local row_group = HorizontalGroup:new(row_group_items)
                    row_group.align = "top"
                    table.insert(page_content_vg, row_group)
                    table.insert(page_content_vg, VerticalSpan:new{ width = grid_gap_v })
                    current_row_widgets = {}
                end
            end
        end

        -- Render the current page items
        if #loans == 0 then
            local empty_msg = from_cache and _("Connecting to Libby…\n\nLoading your active loans…")
                or _("No active loans found on your Libby shelf.\n\nBorrow a book in the Libby app, then tap ↻ Refresh!")
            local empty_text = TextBoxWidget:new{
                text = empty_msg,
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = sw - sc(40),
                alignment = "center",
            }
            table.insert(page_content_vg, FrameContainer:new{
                padding = sc(30),
                bordersize = 0,
                width = sw,
                CenterContainer:new{
                    dimen = Geom:new{ w = sw - sc(40), h = sh - sc(200) },
                    empty_text,
                }
            })
        else
            local cur_page_sections = pages[current_page] or {}
            local global_item_offset = 0
            local cur_loan_idx = 0
            for p = 1, current_page - 1 do
                for _, s in ipairs(pages[p] or {}) do
                    global_item_offset = global_item_offset + #s.items
                end
            end

            if view_mode == "list" then
                for _, section in ipairs(cur_page_sections) do
                    if section.lib then
                        table.insert(page_content_vg, create_shelf_section_header(section.lib))
                    end
                    for _, item in ipairs(section.items) do
                        global_item_offset = global_item_offset + 1
                        cur_loan_idx = cur_loan_idx + 1
                        render_list_loan(item.loan, global_item_offset, cur_loan_idx)
                    end
                end
            else
                for s_idx, section in ipairs(cur_page_sections) do
                    if section.lib then
                        if s_idx > 1 then
                            table.insert(page_content_vg, VerticalSpan:new{ width = sc(8) })
                        end
                        table.insert(page_content_vg, create_shelf_section_header(section.lib))
                        table.insert(page_content_vg, VerticalSpan:new{ width = sc(6) })
                    end
                    render_cover_grid(section.items, global_item_offset, cur_loan_idx)
                    global_item_offset = global_item_offset + #section.items
                    cur_loan_idx = cur_loan_idx + #section.items
                end
            end
        end

        -- 3. Content Frame and Pagination Footer (Fixed to Screen Bottom)
        local page_content_frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            width = sw,
            page_content_vg,
        }

        local prev_btn = createButton{
            text = _("‹ Prev"),
            text_font_size = 16,
            bold = true,
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            padding = sc(4),
            padding_h = sc(12),
            callback = function()
                if current_page > 1 then
                    current_page = current_page - 1
                    focused_shelf_idx = 1
                    renderShelf(loans, from_cache)
                end
            end,
        }

        local next_btn = createButton{
            text = _("Next ›"),
            text_font_size = 16,
            bold = true,
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            padding = sc(4),
            padding_h = sc(12),
            callback = function()
                if current_page < total_pages then
                    current_page = current_page + 1
                    focused_shelf_idx = 1
                    renderShelf(loans, from_cache)
                end
            end,
        }

        local page_label = TextWidget:new{
            text = string.format("%d / %d", current_page, total_pages),
            face = Font:getFace("cfont", 16),
            fgcolor = theme.color_label_dim,
        }

        local prev_w = prev_btn:getSize().w
        local next_w = next_btn:getSize().w
        local label_w = page_label:getSize().w
        local footer_inner_w = sw - sc(40)
        local mid_spacer = math.max(sc(8), (footer_inner_w - prev_w - next_w - label_w) / 2)

        local footer_widgets = HorizontalGroup:new{
            current_page > 1 and prev_btn or HorizontalSpan:new{ width = prev_w },
            HorizontalSpan:new{ width = mid_spacer },
            page_label,
            HorizontalSpan:new{ width = mid_spacer },
            current_page < total_pages and next_btn or HorizontalSpan:new{ width = next_w },
        }

        local footer_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_LIGHT_GRAY,
        }

        local footer_frame = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(6),
            padding_left = sc(10),
            padding_right = sc(10),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            height = footer_h,
            CenterContainer:new{
                dimen = Geom:new{ w = sw - sc(20), h = footer_h - sc(10) },
                footer_widgets,
            }
        }

        local top_vg = VerticalGroup:new{
            align = "left",
            header_frame,
            header_divider,
            VerticalSpan:new{ width = top_margin },
            page_content_frame,
        }

        local bottom_vg = VerticalGroup:new{
            align = "left",
            footer_divider,
            footer_frame,
        }

        local bottom_container = BottomContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            bottom_vg,
        }

        local shelf_background_frame = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            height = sh,
            OverlapGroup:new{
                dimen = Geom:new{ w = sw, h = sh },
                top_vg,
                bottom_container,
            },
        }

        local shelf_key_events = {
            Close = { { "Back" }, { "Escape" } },
            PrevPage = { { "PgUp" }, { "Prev" }, { "LPgBack" }, { "RPgBack" } },
            NextPage = { { "PgDn" }, { "Next" }, { "LPgFwd" }, { "RPgFwd" } },
            Up = { { "Up" } },
            Down = { { "Down" } },
            Left = { { "Left" } },
            Right = { { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
            MenuKey = { { "Menu" }, { "F10" } },
            ViewToggleKey = { { "v" }, { "V" } },
            RefreshKey = { { "r" }, { "R" }, { "F5" } },
            Num1 = { { "1" } },
            Num2 = { { "2" } },
            Num3 = { { "3" } },
            Num4 = { { "4" } },
            Num5 = { { "5" } },
            Num6 = { { "6" } },
            Num7 = { { "7" } },
            Num8 = { { "8" } },
            Num9 = { { "9" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(shelf_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.PgBack then table.insert(shelf_key_events.PrevPage, { Device.input.group.PgBack }) end
            if Device.input.group.PgFwd then table.insert(shelf_key_events.NextPage, { Device.input.group.PgFwd }) end
            if Device.input.group.Up then table.insert(shelf_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(shelf_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(shelf_key_events.Left, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(shelf_key_events.Right, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(shelf_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(shelf_key_events.Press, { Device.input.group.Enter }) end
            if Device.input.group.Menu then table.insert(shelf_key_events.MenuKey, { Device.input.group.Menu }) end
        end

        active_shelf_overlay = InputContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            key_events = shelf_key_events,
            ges_events = {
                Swipe = {
                    GestureRange:new{
                        ges = "swipe",
                        range = function() return Geom:new{ x = 0, y = 0, w = sw, h = sh } end,
                    },
                },
            },
            shelf_background_frame,
        }

        local function activateLoanAtIndex(idx)
            if cur_page_loans[idx] then
                focused_shelf_idx = idx
                local target_loan = cur_page_loans[idx]
                M.showDownloadConfirm(target_loan, plugin_dir, function()
                    renderShelf(current_rendered_loans, false)
                end, function(returned_loan)
                    if handleLoanReturned then
                        handleLoanReturned(returned_loan or target_loan)
                    end
                end)
                return true
            end
        end

        active_shelf_overlay.onPrevPage = function()
            if current_page > 1 then
                current_page = current_page - 1
                focused_shelf_idx = 1
                renderShelf(loans, from_cache)
                return true
            end
        end

        active_shelf_overlay.onNextPage = function()
            if current_page < total_pages then
                current_page = current_page + 1
                focused_shelf_idx = 1
                renderShelf(loans, from_cache)
                return true
            end
        end

        local function ensureFocusVisible()
            if not focus_visible then
                focus_visible = true
                renderShelf(loans, from_cache)
                return true
            end
            return false
        end

        active_shelf_overlay.onUp = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                return true
            end
            local count = #cur_page_loans
            if view_mode == "list" then
                if focused_shelf_idx > 1 then
                    focused_shelf_idx = focused_shelf_idx - 1
                    renderShelf(loans, from_cache)
                    return true
                else
                    focus_zone = "header"
                    focused_header_idx = 1
                    renderShelf(loans, from_cache)
                    return true
                end
            else
                if focused_shelf_idx > COLS then
                    focused_shelf_idx = focused_shelf_idx - COLS
                    renderShelf(loans, from_cache)
                    return true
                else
                    focus_zone = "header"
                    focused_header_idx = math.min(4, math.max(1, focused_shelf_idx))
                    renderShelf(loans, from_cache)
                    return true
                end
            end
        end

        active_shelf_overlay.onDown = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                local count = #cur_page_loans
                if count > 0 then
                    focus_zone = "items"
                    if view_mode == "cover" then
                        if focused_header_idx == 1 then
                            focused_shelf_idx = 1
                        elseif focused_header_idx == 2 then
                            focused_shelf_idx = math.min(2, count)
                        else
                            focused_shelf_idx = math.min(3, count)
                        end
                    else
                        focused_shelf_idx = 1
                    end
                    renderShelf(loans, from_cache)
                    return true
                end
                return true
            end
            local count = #cur_page_loans
            if count == 0 then return end
            if view_mode == "list" then
                if focused_shelf_idx < count then
                    focused_shelf_idx = focused_shelf_idx + 1
                    renderShelf(loans, from_cache)
                    return true
                end
            else
                if focused_shelf_idx + COLS <= count then
                    focused_shelf_idx = focused_shelf_idx + COLS
                    renderShelf(loans, from_cache)
                    return true
                elseif focused_shelf_idx < count and focused_shelf_idx <= math.floor((count - 1) / COLS) * COLS then
                    focused_shelf_idx = count
                    renderShelf(loans, from_cache)
                    return true
                end
            end
        end

        active_shelf_overlay.onLeft = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                if focused_header_idx > 1 then
                    focused_header_idx = focused_header_idx - 1
                    renderShelf(loans, from_cache)
                    return true
                elseif current_page > 1 then
                    return active_shelf_overlay:onPrevPage()
                end
                return true
            end
            if view_mode == "list" then
                return active_shelf_overlay:onPrevPage()
            else
                if focused_shelf_idx > 1 then
                    focused_shelf_idx = focused_shelf_idx - 1
                    renderShelf(loans, from_cache)
                    return true
                elseif current_page > 1 then
                    return active_shelf_overlay:onPrevPage()
                end
            end
        end

        active_shelf_overlay.onRight = function()
            if ensureFocusVisible() then return true end
            if focus_zone == "header" then
                if focused_header_idx < 4 then
                    focused_header_idx = focused_header_idx + 1
                    renderShelf(loans, from_cache)
                    return true
                elseif current_page < total_pages then
                    return active_shelf_overlay:onNextPage()
                end
                return true
            end
            local count = #cur_page_loans
            if view_mode == "list" then
                return active_shelf_overlay:onNextPage()
            else
                if focused_shelf_idx < count then
                    focused_shelf_idx = focused_shelf_idx + 1
                    renderShelf(loans, from_cache)
                    return true
                elseif current_page < total_pages then
                    return active_shelf_overlay:onNextPage()
                end
            end
        end

        active_shelf_overlay.onPress = function()
            if focus_zone == "header" then
                if focused_header_idx == 1 then
                    local next_mode = (view_mode == "cover") and "list" or "cover"
                    State.saveViewMode(next_mode)
                    current_page = 1
                    focused_shelf_idx = 1
                    renderShelf(loans, from_cache)
                    return true
                elseif focused_header_idx == 2 then
                    State.clearShelfCache()
                    _runAsync(
                        function() return API.fetchShelf() end,
                        _("Refreshing shelf from Libby…"),
                        function(result, err)
                            if type(result) == "table" then
                                State.saveShelfCache(result)
                                current_page = 1
                                focused_shelf_idx = 1
                                if #result > 0 then focus_zone = "items" end
                                renderShelf(result, false)
                            elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                                M._handleAuthExpired(plugin_dir)
                            else
                                _toast(_("Refresh failed: %s", tostring(err or _("error"))), 4)
                            end
                        end
                    )
                    return true
                elseif focused_header_idx == 3 then
                    M.showAbout(plugin_dir, function()
                        renderShelf(loans, from_cache)
                    end, function()
                        renderShelf(loans, from_cache)
                    end)
                    return true
                elseif focused_header_idx == 4 then
                    if active_shelf_overlay then
                        local ov = active_shelf_overlay
                        active_shelf_overlay = nil
                        ov.onClose = nil
                        UIManager:close(ov, "ui")
                    end
                    return true
                end
            else
                return activateLoanAtIndex(focused_shelf_idx)
            end
        end

        active_shelf_overlay.onNum1 = function() return activateLoanAtIndex(1) end
        active_shelf_overlay.onNum2 = function() return activateLoanAtIndex(2) end
        active_shelf_overlay.onNum3 = function() return activateLoanAtIndex(3) end
        active_shelf_overlay.onNum4 = function() return activateLoanAtIndex(4) end
        active_shelf_overlay.onNum5 = function() return activateLoanAtIndex(5) end
        active_shelf_overlay.onNum6 = function() return activateLoanAtIndex(6) end
        active_shelf_overlay.onNum7 = function() return activateLoanAtIndex(7) end
        active_shelf_overlay.onNum8 = function() return activateLoanAtIndex(8) end
        active_shelf_overlay.onNum9 = function() return activateLoanAtIndex(9) end

        active_shelf_overlay.onMenuKey = function()
            M.showAbout(plugin_dir, function()
                renderShelf(loans, from_cache)
            end, function()
                renderShelf(loans, from_cache)
            end)
            return true
        end

        active_shelf_overlay.onViewToggleKey = function()
            local next_mode = (view_mode == "cover") and "list" or "cover"
            State.saveViewMode(next_mode)
            current_page = 1
            focused_shelf_idx = 1
            renderShelf(loans, from_cache)
            return true
        end

        active_shelf_overlay.onRefreshKey = function()
            State.clearShelfCache()
            _runAsync(
                function() return API.fetchShelf() end,
                _("Refreshing shelf from Libby…"),
                function(result, err)
                    if type(result) == "table" then
                        State.saveShelfCache(result)
                        current_page = 1
                        focused_shelf_idx = 1
                        if #result > 0 then focus_zone = "items" end
                        renderShelf(result, false)
                    elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                        M._handleAuthExpired(plugin_dir)
                    else
                        _toast(_("Refresh failed: %s", tostring(err or _("error"))), 4)
                    end
                end
            )
            return true
        end

        active_shelf_overlay.onSwipe = function(self, arg, ges)
            if is_touch_device then focus_visible = false end
            if ges and (ges.direction == "west" or ges.direction == "south") then
                if current_page < total_pages then
                    current_page = current_page + 1
                    focused_shelf_idx = 1
                    renderShelf(loans, from_cache)
                    return true
                end
            elseif ges and (ges.direction == "east" or ges.direction == "north") then
                if current_page > 1 then
                    current_page = current_page - 1
                    focused_shelf_idx = 1
                    renderShelf(loans, from_cache)
                    return true
                end
            end
        end

        active_shelf_overlay.onClose = function()
            if active_shelf_overlay then
                local ov = active_shelf_overlay
                active_shelf_overlay = nil
                ov.onClose = nil
                UIManager:close(ov, "ui")
            end
            return true
        end

        UIManager:show(active_shelf_overlay, "ui")
    end

    local current_rendered_loans = cached_shelf or {}

    -- Always render cached shelf (or loading placeholder) immediately with zero blocking dialogs
    if cached_shelf and #cached_shelf > 0 then
        pcall(Covers.cleanupExpiredCovers, cached_shelf)
    end
    renderShelf(current_rendered_loans, true)

    local is_syncing = false
    doBackgroundSync = function(force)
        if is_syncing and not force then return end
        is_syncing = true
        local delay = force and 0.1 or 0.5
        UIManager:scheduleIn(delay, function()
            local ok, result, err = pcall(function()
                return API.fetchShelf()
            end)
            is_syncing = false
            if ok and type(result) == "table" then
                State.saveShelfCache(result)
                if #result > 0 then
                    pcall(Covers.cleanupExpiredCovers, result)
                end
                if State.getAutoDeleteExpired and State.getAutoDeleteExpired() then
                    local ok_ac, AutoClean = pcall(require, plugin_path .. "libbee_autoclean")
                    if ok_ac and AutoClean and AutoClean.checkAndCleanup then
                        local clean_res = AutoClean.checkAndCleanup(result, { is_live_sync = true })
                        if clean_res and clean_res.deleted_count and clean_res.deleted_count > 0 then
                            if clean_res.deleted_count == 1 and clean_res.deleted_titles and clean_res.deleted_titles[1] then
                                _toast(string.format(_("Auto-deleted \"%s\" (loan ended)."), clean_res.deleted_titles[1]), 4)
                            else
                                _toast(string.format(_("Auto-deleted %d expired/returned loan(s)."), clean_res.deleted_count), 4)
                            end
                        end
                    end
                end
                if active_shelf_overlay then
                    current_rendered_loans = result
                    renderShelf(result, false)
                end
            elseif ok and (result == "AUTH_EXPIRED" or err == "AUTH_EXPIRED") then
                if active_shelf_overlay then
                    M._handleAuthExpired(plugin_dir)
                end
            end
        end)
    end

    handleLoanReturned = function(returned_loan)
        local ret_id = returned_loan and (returned_loan.id or returned_loan.loanId or returned_loan.reserveId)
        if ret_id then
            local updated = {}
            for _, l in ipairs(current_rendered_loans or {}) do
                local lid = l.id or l.loanId or l.reserveId
                if tostring(lid) ~= tostring(ret_id) then
                    table.insert(updated, l)
                end
            end
            current_rendered_loans = updated
            State.saveShelfCache(updated)
            renderShelf(updated, false)
        end
        -- Do not immediately block main thread with a second sync; schedule debounced background sync after 4s
        if doBackgroundSync then
            UIManager:scheduleIn(4.0, function()
                if active_shelf_overlay then
                    doBackgroundSync()
                end
            end)
        end
    end

    -- Trigger automatic background refresh
    doBackgroundSync()

    -- Also listen for online status if network connects while shelf is open
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        NetworkMgr:runWhenOnline(function()
            if active_shelf_overlay then
                doBackgroundSync()
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Download Flow (Keeps plugin open)
-- ---------------------------------------------------------------------------

function M.findExistingBook(loan, base_dir)
    if not loan or not base_dir then return nil end

    local function isValidBookFile(p)
        if not p or p == "" then return false end
        local f = io.open(p, "rb")
        if f then
            local size = f:seek("end") or 0
            f:close()
            if size > 0 then
                return true
            end
        end
        return false
    end

    -- 1. Fast O(1) check via State registry if tracked
    local ok_st, State = pcall(require, plugin_path .. "libbee_state")
    if not ok_st or not State then ok_st, State = pcall(require, "libbee_state") end
    if ok_st and State and State.getTrackedDownload then
        local loan_id = loan.id or loan.loanId or loan.reserveId or (loan.raw and (loan.raw.id or loan.raw.loanId or loan.raw.reserveId))
        local tracked = loan_id and State.getTrackedDownload(loan_id)
        if tracked and tracked.path and isValidBookFile(tracked.path) then
            return tracked.path
        end
    end

    local title = loan.title or ""
    if title == "" then return nil end

    local ok_naming, naming = pcall(require, plugin_path .. "libbee_adobe_naming")
    if not ok_naming or not naming then
        ok_naming, naming = pcall(require, "libbee_adobe_naming")
    end

    local safe_title = (ok_naming and naming and naming.sanitizeTitle and naming.sanitizeTitle(title))
        or title:gsub('[/\\:*?"<>|]', " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    local underscore_title = title:gsub('[/\\:*?"<>|]', "_"):gsub("%s+", "_")

    if not safe_title or safe_title == "" then return nil end

    local safe_title_60 = safe_title
    if #safe_title_60 > 60 then safe_title_60 = safe_title_60:sub(1, 60) end

    local underscore_title_60 = underscore_title
    if #underscore_title_60 > 60 then underscore_title_60 = underscore_title_60:sub(1, 60) end

    local extensions = { ".epub", ".pdf" }
    local primary_titles = { safe_title, underscore_title, safe_title_60, underscore_title_60 }

    -- 2. Fast direct candidate path checks
    for _, t in ipairs(primary_titles) do
        for _, ext in ipairs(extensions) do
            local p = base_dir .. "/" .. t .. ext
            if isValidBookFile(p) then return p end
        end
    end

    -- 3. Numbered duplicates (e.g. "Title (1).epub")
    for _, t in ipairs(primary_titles) do
        for _, ext in ipairs(extensions) do
            for i = 1, 5 do
                local pi = base_dir .. "/" .. t .. " (" .. i .. ")" .. ext
                if isValidBookFile(pi) then return pi end
            end
        end
    end

    -- 4. Check directory listing only if base_dir exists and direct checks missed
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.dir and lfs.attributes and lfs.attributes(base_dir, "mode") == "directory" then
        local safe_lower = safe_title:lower()
        local safe_lower_60 = safe_title_60:lower()
        local und_lower = underscore_title:lower()
        local und_lower_60 = underscore_title_60:lower()

        local ok_scan, found_file = pcall(function()
            for entry in lfs.dir(base_dir) do
                if entry ~= "." and entry ~= ".." then
                    local lower = entry:lower()
                    if (lower:sub(-5) == ".epub" or lower:sub(-4) == ".pdf") then
                        local entry_name = lower:gsub("%.epub$", ""):gsub("%.pdf$", ""):gsub("%s*%(%d+%)%s*$", "")
                        local entry_clean_spaces = entry_name:gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
                        if entry_name ~= "" and (
                            entry_name == safe_lower or
                            entry_name == safe_lower_60 or
                            entry_name == und_lower or
                            entry_name == und_lower_60 or
                            entry_clean_spaces == safe_lower or
                            entry_clean_spaces == safe_lower_60
                        ) then
                            local full_path = base_dir .. "/" .. entry
                            if isValidBookFile(full_path) then
                                return full_path
                            end
                        end
                    end
                end
            end
            return nil
        end)

        if ok_scan and found_file then
            return found_file
        end
    end

    return nil
end

function M.showDownloadConfirm(loan, plugin_dir, after_download_fn, after_return_fn)
    local ok_api, API = pcall(require, plugin_path .. "libbee_api")
    if not ok_api or not API then
        ok_api, API = pcall(require, "libbee_api")
    end
    local ok_st, State = pcall(require, plugin_path .. "libbee_state")
    if not ok_st or not State then
        ok_st, State = pcall(require, "libbee_state")
    end

    if loan and (loan.is_downloadable == false or loan.restriction_type) then
        local rest_type = loan.restriction_type or "unsupported"
        local title_str = _("Format Not Supported")
        local desc_str = ""
        local format_display = _("Unsupported")

        if rest_type == "kindle_or_libby" then
            title_str = _("Kindle / Libby Only")
            format_display = _("Libby / Kindle")
            desc_str = _("This book can only be opened in the Libby app or on a Kindle device.\n\nThe publisher does not provide a downloadable EPUB or PDF file for KOReader.\n\nTo read this book, open it in the Libby app on your phone/tablet/computer or choose 'Read with Kindle' on libbyapp.com.")
        elseif rest_type == "kindle_only" then
            title_str = _("Kindle Only")
            format_display = _("Kindle")
            desc_str = _("This book is only available in Amazon Kindle format.\n\nThe publisher does not provide a downloadable EPUB or PDF file for KOReader.\n\nTo read this book, choose 'Read with Kindle' from the Libby app or website.")
        elseif rest_type == "libby_only" then
            title_str = _("Libby App Only")
            format_display = _("Libby Read")
            desc_str = _("This book can only be read directly in the Libby app or browser reader (OverDrive Read).\n\nThe publisher does not provide a downloadable EPUB or PDF file for KOReader.")
        elseif rest_type == "audiobook" then
            title_str = _("Audiobook")
            format_display = _("Audiobook")
            desc_str = _("This title is an audiobook and cannot be played in KOReader.\n\nPlease listen to it in the Libby app.")
        elseif rest_type == "magazine" then
            title_str = _("Magazine")
            format_display = _("Magazine")
            desc_str = _("This magazine is not available as a downloadable EPUB or PDF file for KOReader.\n\nPlease read it in the Libby app.")
        else
            title_str = _("Format Not Supported")
            format_display = loan.format or _("Unsupported")
            desc_str = _("This title is not available in a downloadable format supported by KOReader.")
        end

        local days_str = _fmtDays(loan.days_remaining)
        local body_text = string.format(
            "%s:  %s\n%s: %s\n%s: %s\n%s:   %s\n\n%s",
            _("Title"),
            (loan and loan.title) or _("Unknown Title"),
            _("Author"),
            (loan and loan.author) or _("Unknown Author"),
            _("Available Format"),
            format_display,
            _("Loan"),
            days_str ~= "" and days_str or _("Active"),
            desc_str
        )

        M.showCardDialog{
            title = title_str,
            body_text = body_text,
            buttons = {
                {
                    text = _("Return Early"),
                    callback = function()
                        M.showReturnConfirm(loan, plugin_dir, after_return_fn or after_download_fn)
                    end,
                },
                {
                    text = _("OK"),
                    is_primary = true,
                }
            }
        }
        return
    end

    local base_dir = (ok_st and State and State.getDownloadDir and State.getDownloadDir(plugin_dir)) or "/tmp/Libby"
    local dest_path = (ok_api and API and API.getAcsmPath and API.getAcsmPath(base_dir, loan)) or (base_dir .. "/download.acsm")
    local existing_book = M.findExistingBook(loan, base_dir)

    local days_str = _fmtDays(loan and loan.days_remaining)
    local info_text = string.format(
        "%s:  %s\n%s: %s\n%s: %s\n%s:   %s",
        _("Title"),
        (loan and loan.title) or _("Unknown Title"),
        _("Author"),
        (loan and loan.author) or _("Unknown Author"),
        _("Format"),
        (loan and loan.format) or "ebook-epub-adobe",
        _("Loan"),
        days_str ~= "" and days_str or _("Active")
    )

    if existing_book then
        M.showCardDialog{
            title = _("Loan Details"),
            body_text = info_text,
            buttons = {
                {
                    text = _("Open Book"),
                    is_primary = true,
                    callback = function()
                        _toast(string.format(_("Opening \"%s\"…"), (loan and loan.title) or _("book")), 2)
                        M._openBook(existing_book)
                    end,
                },
                {
                    text = _("Return Early"),
                    callback = function()
                        M.showReturnConfirm(loan, plugin_dir, after_return_fn or after_download_fn)
                    end,
                },
                {
                    text = _("Cancel"),
                }
            }
        }
    else
        M.showCardDialog{
            title = _("Download Loan"),
            body_text = info_text,
            buttons = {
                {
                    text = _("Download"),
                    is_primary = true,
                    callback = function()
                        M._doDownload(loan, dest_path, base_dir, plugin_dir, after_download_fn)
                    end,
                },
                {
                    text = _("Return Early"),
                    callback = function()
                        M.showReturnConfirm(loan, plugin_dir, after_return_fn or after_download_fn)
                    end,
                },
                {
                    text = _("Cancel"),
                }
            }
        }
    end
end

function M.showReturnConfirm(loan, plugin_dir, after_return_fn)
    if not loan then return end

    local title_str = (loan and loan.title) or _("this book")
    local body_text = string.format(
        _("Return \"%s\" early to your library?\n\nThis returns the loan to Libby and removes the downloaded book from this device. Reading history and bookmarks will be preserved."),
        title_str
    )

    M.showCardDialog{
        title = _("Return Early"),
        body_text = body_text,
        buttons = {
            {
                text = _("Return Early"),
                is_primary = true,
                callback = function()
                    _runAsync(
                        function()
                            local API = require(plugin_path .. "libbee_api")
                            local return_ok, return_err = API.returnLoan(loan)
                            if not return_ok then
                                return nil, return_err
                            end
                            return true
                        end,
                        _("Returning \"%s\" to library…", title_str),
                        function(success, err)
                            if success then
                                local State = require(plugin_path .. "libbee_state")
                                local AutoClean = require(plugin_path .. "libbee_autoclean")

                                -- Remove local book file if tracked or found
                                local tracked = State.getTrackedDownload and State.getTrackedDownload(loan.id or loan.loanId or loan.reserveId)
                                if tracked and tracked.path then
                                    AutoClean.removeFileAndSidecar(tracked.path)
                                else
                                    local base_dir = (State and State.getDownloadDir and State.getDownloadDir(plugin_dir)) or "/tmp/Libby"
                                    local existing_book = M.findExistingBook(loan, base_dir)
                                    if existing_book then
                                        AutoClean.removeFileAndSidecar(existing_book)
                                    end
                                end

                                if State.unregisterDownload then
                                    State.unregisterDownload(loan.id or loan.loanId or loan.reserveId)
                                end

                                State.clearShelfCache()

                                if after_return_fn then
                                    after_return_fn(loan)
                                end

                                _toast(string.format(_("Returned \"%s\" to the library."), title_str), 3)
                            elseif err == "AUTH_EXPIRED" or (type(err) == "string" and err:find("AUTH_EXPIRED")) then
                                M._handleAuthExpired(plugin_dir)
                            else
                                local err_str = tostring(err or "Unknown error")
                                M.showCardDialog{
                                    title = _("Return Failed"),
                                    body_text = string.format(_("Could not return loan:\n%s"), err_str),
                                    buttons = {
                                        {
                                            text = _("Retry"),
                                            is_primary = true,
                                            callback = function()
                                                M.showReturnConfirm(loan, plugin_dir, after_return_fn)
                                            end,
                                        },
                                        {
                                            text = _("Close"),
                                        }
                                    }
                                }
                            end
                        end
                    )
                end,
            },
            {
                text = _("Cancel"),
            }
        }
    }
end

function M._doDownload(loan, dest_path, base_dir, plugin_dir, after_download_fn)
    local API = require(plugin_path .. "libbee_api")
    local LibbeeDRM = require(plugin_path .. "libbee_drm")

    local dir_ok, dir_err = API.ensureDownloadDir(base_dir)
    if not dir_ok then
        _toast(_("Could not create download folder:\n%s", tostring(dir_err)), 6)
        return
    end

    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if ok_ffi and ffiutil and type(ffiutil.df) == "function" then
        local ok_df, _, free_bytes = pcall(ffiutil.df, base_dir)
        if ok_df and free_bytes and free_bytes < 20 * 1048576 then
            M.showCardDialog{
                title = _("Storage Space Low"),
                body_text = _("Your device has less than 20 MB of free storage space (%s MB free).\n\nPlease delete some files to free up space before downloading.", string.format("%.1f", free_bytes / 1048576)),
                buttons = {
                    {
                        text = _("OK"),
                        is_primary = true,
                    }
                }
            }
            return
        end
    end

    local temp_acsm_path = base_dir .. "/.temp_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".acsm"
    local ok_tmp = pcall(function() return lfs.attributes("/tmp", "mode") == "directory" end)
    local progress_path = (ok_tmp and "/tmp/.libbee_prog_" or (base_dir .. "/.temp_dl_prog_"))
        .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))

    local function writeProgress(str)
        local tmp = progress_path .. ".tmp"
        local f = io.open(tmp, "w")
        if f then
            f:write(str .. "\n")
            f:close()
            os.rename(tmp, progress_path)
        end
    end

    _runDownloadWithProgress(
        function()
            -- Step 1: Download ACSM license token from Libby API
            writeProgress("acsm")
            local dl_ok, dl_err = API.downloadACSM(loan, temp_acsm_path)
            if not dl_ok then
                return nil, dl_err
            end

            -- Step 2: Parse metadata and derive final decrypted book path
            local meta = LibbeeDRM.parseAcsmMetadata(temp_acsm_path)
            local final_path = LibbeeDRM.deriveFinalBookPath(base_dir, loan, meta)

            -- Step 3: Fulfill and decrypt with embedded Adobe/ByteBooks DRM engine
            local progress_cb = function(val)
                if type(val) == "number" then
                    writeProgress("download:" .. tostring(val))
                else
                    writeProgress(tostring(val))
                end
            end
            local ful_ok, ful_err = LibbeeDRM.fulfillAcsm(temp_acsm_path, final_path, progress_cb)
            pcall(os.remove, temp_acsm_path)
            pcall(os.remove, progress_path)
            pcall(os.remove, progress_path .. ".tmp")

            if not ful_ok then
                return nil, ful_err
            end

            return final_path
        end,
        loan,
        function(final_book_path, err)
            pcall(os.remove, progress_path)
            pcall(os.remove, progress_path .. ".tmp")
            if type(final_book_path) == "string" and final_book_path ~= "" then
                local State = require(plugin_path .. "libbee_state")
                State.clearShelfCache()
                if State.registerDownload then
                    State.registerDownload(loan, final_book_path)
                end

                if after_download_fn then after_download_fn() end

                M.showCardDialog{
                    title = _("✓ Download Complete!"),
                    body_text = _('"%s"\n\nSaved to:\n%s\n\nReady to read.', loan.title or _("Book"), final_book_path),
                    buttons = {
                        {
                            text = _("Open Book"),
                            is_primary = true,
                            callback = function()
                                M._openBook(final_book_path)
                            end,
                        },
                        {
                            text = _("Done"),
                            callback = function()
                                -- Shelf remains open
                            end,
                        }
                    }
                }
            elseif err and (err:find("cancelled") or err:find("Cancelled")) then
                _toast(_("Download cancelled."), 3)
            elseif err == "ALREADY_FULFILLED" or (type(final_book_path) == "string" and final_book_path == "ALREADY_FULFILLED") then
                local sw = Screen:getWidth()
                M.showCardDialog{
                    title = _("Already Fulfilled on Another Device"),
                    width = math.min(sw - sc(20), sc(460)),
                    body_text = _("This book has already been downloaded on another device. Libby only allows each loan to be fulfilled once per Adobe ID.\n\nIf you use multiple e-readers, ByteBooks lets you sync and fulfill loans across all your devices seamlessly."),
                    buttons = {
                        {
                            text = _("About ByteBooks"),
                            is_primary = true,
                            callback = function()
                                M.showByteBookDialog()
                            end,
                        },
                        {
                            text = _("Done"),
                        }
                    }
                }
            elseif (err and err:find("AUTH_EXPIRED")) or (type(final_book_path) == "string" and final_book_path:find("AUTH_EXPIRED")) then
                M._handleAuthExpired(plugin_dir)
            elseif (err and (err:find("400") or err:find("UNSUPPORTED") or err:find("restricted to Libby") or err:find("Format not available") or err:find("only available in Libby"))) or
                   (type(final_book_path) == "string" and (final_book_path:find("400") or final_book_path:find("UNSUPPORTED") or final_book_path:find("restricted to Libby") or final_book_path:find("only available in Libby"))) then
                M.showCardDialog{
                    title = _("Format Not Supported"),
                    body_text = _("This book cannot be downloaded to KOReader.\n\nLibby only provides this title in formats for the Libby app or Kindle devices. Downloadable EPUB/PDF files are not available for this loan from the library."),
                    buttons = {
                        {
                            text = _("OK"),
                            is_primary = true,
                        }
                    }
                }
            elseif (err and (err:find("No space left") or err:find("ENOSPC") or err:find("disk full") or err:find("storage full"))) or
                   (type(final_book_path) == "string" and (final_book_path:find("No space left") or final_book_path:find("ENOSPC") or final_book_path:find("disk full"))) then
                M.showCardDialog{
                    title = _("Storage Space Full"),
                    body_text = _("Your device does not have enough storage space to complete this download.\n\nPlease delete some files or finished books from your device to free up space, and try again."),
                    buttons = {
                        {
                            text = _("OK"),
                            is_primary = true,
                        }
                    }
                }
            else
                local err_str = err or tostring(final_book_path or "Unknown error")
                M.showCardDialog{
                    title = _("Download Failed"),
                    body_text = _("Download/Fulfillment failed:\n%s\n\nIf you see an authorization error, check your Wi-Fi or DRM settings.", err_str),
                    buttons = {
                        {
                            text = _("Retry"),
                            is_primary = true,
                            callback = function()
                                M._doDownload(loan, dest_path, base_dir, plugin_dir, after_download_fn)
                            end,
                        },
                        {
                            text = _("Cancel"),
                        }
                    }
                }
            end
        end,
        progress_path
    )
end

function M._openBook(path)
    if not path or path == "" then
        log.warn("libbee ui: _openBook called with empty path")
        return false
    end

    local f = io.open(path, "rb")
    if not f then
        log.warn("libbee ui: _openBook cannot open file (does not exist): " .. tostring(path))
        return false
    end
    local size = f:seek("end") or 0
    f:close()
    if size <= 0 then
        log.warn("libbee ui: _openBook file is empty (0 bytes): " .. tostring(path))
        return false
    end

    if active_shelf_overlay then
        local ov = active_shelf_overlay
        active_shelf_overlay = nil
        ov.onClose = nil
        UIManager:close(ov, "ui")
    end

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = (ok_fm and FileManager and FileManager.instance) or
               (ok_r and ReaderUI and ReaderUI.instance) or nil

    if ui then
        local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
        if ok_fmu and filemanagerutil and filemanagerutil.openFile then
            local ok_open = pcall(filemanagerutil.openFile, ui, path, nil, true)
            return ok_open
        end
        if type(ui.openFile) == "function" then
            local ok_open = pcall(ui.openFile, ui, path)
            return ok_open
        end
    end

    local ok2, Event = pcall(require, "ui/event")
    if ok2 then
        UIManager:broadcastEvent(Event:new("SetupShowReader", { file = path }))
        return true
    else
        _toast(_("Saved to:\n%s\n\nOpen it from the file browser.", path), 6)
        return true
    end
end

-- ---------------------------------------------------------------------------
-- Auth Expired Handler
-- ---------------------------------------------------------------------------

function M._handleAuthExpired(plugin_dir)
    M.showCardDialog{
        title = _("Session Expired"),
        body_text = _("Your Libby authorization has expired.\n\nPlease re-authenticate to continue downloading."),
        buttons = {
            {
                text = _("Re-authenticate"),
                is_primary = true,
                callback = function()
                    local State = require(plugin_path .. "libbee_state")
                    State.clearChipIdentity()
                    State.clearShelfCache()
                    M.showSetupDialog(plugin_dir, function(success)
                        if success then M.showShelfBrowser(plugin_dir) end
                    end)
                end,
            },
            { text = _("Cancel") }
        }
    }
end

-- ---------------------------------------------------------------------------
-- About & Debug Log
-- ---------------------------------------------------------------------------

function M._showDebugLog(max_lines)
    max_lines = max_lines or 100
    local path = log.path()
    local fh = io.open(path, "r")
    local content = nil
    if fh then
        local size = fh:seek("end") or 0
        local read_bytes = math.min(size, 16384)
        local offset = math.max(0, size - read_bytes)
        fh:seek("set", offset)
        local raw_content = fh:read("*a")
        fh:close()
        if raw_content and raw_content ~= "" then
            local lines = {}
            for line in raw_content:gmatch("([^\r\n]+)") do
                table.insert(lines, line)
            end
            if #lines > 0 then
                local start_idx = math.max(1, #lines - max_lines + 1)
                local reversed_lines = {}
                for i = #lines, start_idx, -1 do
                    table.insert(reversed_lines, lines[i])
                end
                local header = _("-- Libbee Debug Log (Newest first, showing last %d entries) --\n\n", #reversed_lines)
                content = header .. table.concat(reversed_lines, "\n")
            end
        end
    end

    if not content or content == "" then
        content = _("No log file found yet at:\n%s", path)
    end

    local TextViewer = require("ui/widget/textviewer")
    local viewer = TextViewer:new{
        title = _("Libbee Debug Log"),
        text = content,
        text_type = "code",
    }
    UIManager:show(viewer)
    return viewer
end

-- ---------------------------------------------------------------------------
-- ByteBooks Multi-Device Sync Authorization Dialog
-- ---------------------------------------------------------------------------

function M.showByteBooksAuthDialog(plugin_dir, on_done)
    local LibbeeDRM = require(plugin_path .. "libbee_drm")
    local InputDialog = require("ui/widget/inputdialog")

    local function do_auth(email, password)
        if not email or email:gsub("%s+", "") == "" then
            _toast(_("Please enter your ByteBooks email"), 4)
            if on_done then on_done(false) end
            return
        end
        if not password or password == "" then
            _toast(_("Please enter your ByteBooks password"), 4)
            if on_done then on_done(false) end
            return
        end

        _runAsync(
            function()
                return LibbeeDRM.authorizeByteBooks(email:gsub("%s+", ""), password)
            end,
            _("Authorizing ByteBooks account…"),
            function(res, err)
                if res == true then
                    _toast(_("✓ ByteBooks authorized successfully!"), 4)
                    if on_done then on_done(true) end
                elseif err and (err:find("E_ACT_TOO_MANY_ACTIVATIONS") or err:find("TOO_MANY_ACTIVATIONS")) then
                    M.showCardDialog{
                        title = _("Device Activation Limit Reached"),
                        body_text = _("Adobe / ByteBooks DRM allows a maximum of 6 activated devices per account.\n\nYour account has reached its 6-device limit on Adobe's activation server.\n\nTo resolve this:\n• Contact Adobe Support live chat to reset your activation count (they reset it in ~1 minute).\n• Or continue using Libbee in Anonymous Mode on this device (no ByteBooks account is required to borrow and read library books!)."),
                        buttons = {
                            {
                                text = _("OK"),
                                is_primary = true,
                                callback = function()
                                    if on_done then on_done(false) end
                                end,
                            }
                        }
                    }
                else
                    M.showCardDialog{
                        title = _("Authorization Failed"),
                        body_text = _("Could not authorize ByteBooks account:\n\n%s\n\nMake sure your email and password are correct.", tostring(err or _("Unknown error"))),
                        buttons = {
                            {
                                text = _("OK"),
                                is_primary = true,
                                callback = function()
                                    if on_done then on_done(false) end
                                end,
                            }
                        }
                    }
                end
            end
        )
    end

    local existing_info = LibbeeDRM.getAccountInfo()
    local default_email = (existing_info and existing_info.email) or ""

    -- Step 1: Prompt for Email with full PC & on-screen keyboard support
    local email_dialog
    email_dialog = InputDialog:new{
        title = _("ByteBooks Email"),
        description = _("Sign in to sync books across multiple devices.\nPassword is never saved to storage.\n\nEnter your ByteBooks ID email:"),
        input = default_email,
        input_hint = "user@example.com",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(email_dialog)
                        if on_done then on_done(false) end
                    end,
                },
                {
                    text = _("Next"),
                    is_primary = true,
                    is_enter_default = true,
                    callback = function()
                        local email = email_dialog:getInputText()
                        UIManager:close(email_dialog)
                        if not email or email:gsub("%s+", "") == "" then
                            _toast(_("Email cannot be blank"), 3)
                            if on_done then on_done(false) end
                            return
                        end

                        -- Step 2: Prompt for Password (single-field InputDialog supports PC & virtual keyboards reliably)
                        local pass_dialog
                        pass_dialog = InputDialog:new{
                            title = _("ByteBooks Password"),
                            description = _("Enter password for %s:\n(Used in memory only, not stored)", email),
                            input = "",
                            input_hint = _("Password"),
                            text_type = "password",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(pass_dialog)
                                            if on_done then on_done(false) end
                                        end,
                                    },
                                    {
                                        text = _("Authorize"),
                                        is_primary = true,
                                        is_enter_default = true,
                                        callback = function()
                                            local pass = pass_dialog:getInputText()
                                            UIManager:close(pass_dialog)
                                            do_auth(email, pass)
                                        end,
                                    }
                                }
                            }
                        }
                        UIManager:show(pass_dialog)
                        pass_dialog:onShowKeyboard()
                    end,
                }
            }
        }
    }
    UIManager:show(email_dialog)
    email_dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Submenu: Libby Account Management
-- ---------------------------------------------------------------------------

function M.showLibbyAccountSubmenu(plugin_dir, on_back_cb)
    plugin_dir = plugin_dir or ""
    local State = require(plugin_path .. "libbee_state")
    local API   = require(plugin_path .. "libbee_api")

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)
    local ui_font_size = theme.face_label_size or 16
    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device
    local overlay
    local refresh
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}

        local title_label = TextWidget:new{
            text = _("Libby Account"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(4) },
        }

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(4),
                padding_left = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(8)
            local avail_w = inner_w - (frame_padding * 2)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or (right_widget.dimen and right_widget.dimen.w) or sc(40)) or 0

            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then max_left_w = sc(60) end

            local left_w
            if left_text:find("\n") then
                local vg_items = {}
                for line in left_text:gmatch("[^\r\n]+") do
                    if #vg_items > 0 then
                        table.insert(vg_items, VerticalSpan:new{ width = sc(1) })
                    end
                    table.insert(vg_items, TextWidget:new{
                        text = line,
                        face = Font:getFace("cfont", #vg_items == 0 and ui_font_size or (theme.subtext_font_size or 13)),
                        fgcolor = #vg_items == 0 and Blitbuffer.COLOR_BLACK or (theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY),
                        max_width = max_left_w,
                    })
                end
                left_w = VerticalGroup:new{ align = "left", unpack(vg_items) }
            else
                left_w = TextWidget:new{
                    text = left_text,
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = max_left_w,
                }
            end

            local left_used_w = (left_w.getSize and left_w:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { left_w, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local is_focused = false
            local item_idx = nil
            if callback then
                item_idx = #interactive_items + 1
                table.insert(interactive_items, { callback = callback })
                is_focused = (focus_visible and focused_row_idx == item_idx)
            end

            local frame = FrameContainer:new{
                bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                color = Blitbuffer.COLOR_BLACK,
                background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                padding = frame_padding,
                width = inner_w,
                HorizontalGroup:new(row_elements),
            }

            if not callback then return frame end

            local item = InputContainer:new{ frame }
            local row_size = (frame.getSize and frame:getSize()) or frame.dimen or { w = inner_w, h = sc(30) }
            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = (dim.w and dim.w > 0 and dim.w) or row_size.w or inner_w,
                                h = (dim.h and dim.h > 0 and dim.h) or row_size.h or 0,
                            }
                        end
                    }
                }
            }
            item.onTap = function()
                if item_idx then focused_row_idx = item_idx end
                if is_touch_device then focus_visible = false end
                callback()
                return true
            end
            return item
        end

        local arrow = function()
            return TextWidget:new{
                text = "›",
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
            }
        end

        local accounts = State.getAccounts()

        if #accounts > 0 then
            table.insert(content_vg, create_section_header(_("Linked Accounts")))

            local acc_label = (#accounts == 1)
                and (_("1 account linked"))
                or string.format(_("%d accounts linked"), #accounts)

            table.insert(content_vg, create_setting_row(acc_label, arrow(), function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                M.showManageAccountsDialog(plugin_dir, function()
                    M.showLibbyAccountSubmenu(plugin_dir, on_back_cb)
                end)
            end))

            table.insert(content_vg, create_section_header(_("Cards & Libraries")))

            for _, acc in ipairs(accounts) do
                local lib_name = acc.library_name or "Libby"
                local cards = acc.cards or {}
                for _, card in ipairs(cards) do
                    local card_desc = State.cardDetailString(card)
                    local display_str = lib_name
                    if card_desc and card_desc ~= "" then
                        display_str = display_str .. "\n" .. card_desc
                    end
                    table.insert(content_vg, create_setting_row(display_str, nil, nil))
                end
            end

            table.insert(content_vg, create_section_header(_("Actions")))

            table.insert(content_vg, create_setting_row(_("Add another Libby card"), arrow(), function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                M.showSetupDialog(plugin_dir, function(success)
                    M.showLibbyAccountSubmenu(plugin_dir, on_back_cb)
                end)
            end))

            local is_syncing = false
            table.insert(content_vg, create_setting_row(_("Sync account changes now"), nil, function()
                if is_syncing then return end
                is_syncing = true
                _runAsync(
                    function()
                        return API.syncAllAccounts()
                    end,
                    _("Syncing account details…"),
                    function(res, err)
                        is_syncing = false
                        if res == true then
                            _toast(_("✓ Account synced successfully"), 3)
                            refresh()
                        else
                            _toast(_("Sync failed: %s", tostring(err or _("error"))), 4)
                        end
                    end
                )
            end))

            table.insert(content_vg, create_setting_row(_("Disconnect all accounts"), arrow(), function()
                M.showCardDialog{
                    title = _("Disconnect All?"),
                    body_text = _("Disconnect all Libby accounts and remove stored cards from this device?"),
                    buttons = {
                        {
                            text = _("Disconnect All"),
                            is_primary = true,
                            callback = function()
                                State.clearChipIdentity()
                                State.clearShelfCache()
                                if overlay then
                                    UIManager:close(overlay, "ui")
                                    overlay = nil
                                end
                                if on_back_cb then on_back_cb() end
                                _toast(_("All accounts disconnected"), 3)
                            end,
                        },
                        { text = _("Cancel") },
                    }
                }
            end))
        else
            table.insert(content_vg, create_section_header(_("Account Status")))

            local status_badge = TextWidget:new{
                text = _("Not connected"),
                face = Font:getFace("cfont", theme.subtext_font_size or 14),
                fgcolor = theme.color_label_dim,
            }
            table.insert(content_vg, create_setting_row(_("Status"), status_badge, nil))

            table.insert(content_vg, create_section_header(_("Actions")))

            table.insert(content_vg, create_setting_row(_("Connect with Libby code"), arrow(), function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                M.showSetupDialog(plugin_dir, function(success)
                    M.showLibbyAccountSubmenu(plugin_dir, on_back_cb)
                end)
            end))
        end

        local back_cb = function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            if on_back_cb then on_back_cb() end
        end

        local back_idx = #interactive_items + 1
        table.insert(interactive_items, { callback = back_cb })
        local is_back_focused = (focus_visible and focused_row_idx == back_idx)

        local back_btn = createButton{
            text = _("‹ Back to Settings"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_back_focused,
            bordersize = is_back_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = back_cb,
        }

        local back_frame = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            width = inner_w,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = sc(36) },
                back_btn,
            }
        }

        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or 0,
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                content_vg,
                VerticalSpan:new{ width = sc(10) },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = sc(1) },
                    background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
                },
                VerticalSpan:new{ width = sc(8) },
                back_frame,
            }
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh()
            return true
        end

        overlay.onPress = function()
            if interactive_items[focused_row_idx] and interactive_items[focused_row_idx].callback then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            if overlay then
                local ov = overlay
                overlay = nil
                UIManager:close(ov, "ui")
            end
            if on_back_cb then on_back_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

-- ---------------------------------------------------------------------------
-- Dialog: Manage Linked Accounts (Individual Disconnect)
-- ---------------------------------------------------------------------------

function M.showManageAccountsDialog(plugin_dir, on_back_cb)
    plugin_dir = plugin_dir or ""
    local State = require(plugin_path .. "libbee_state")

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(16), sc(420))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)
    local ui_font_size = theme.face_label_size or 16
    local title_font_size = theme.title_font_size or 20

    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device
    local overlay
    local refresh_manage
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}

    refresh_manage = function()
        if overlay then
            local ov = overlay
            overlay = nil
            UIManager:close(ov, "ui")
        end
        interactive_items = {}

        local accounts = State.getAccounts()
        if #accounts == 0 then
            if on_back_cb then on_back_cb() end
            return
        end

        local cached_loans = State.getShelfCache(true) or {}
        local acc_loan_counts = {}
        for l_idx, l in ipairs(cached_loans) do
            local acc_id = tostring(l.account_id or "")
            if acc_id ~= "" then
                acc_loan_counts[acc_id] = (acc_loan_counts[acc_id] or 0) + 1
            end
        end

        local title_label = TextWidget:new{
            text = _("Manage Linked Accounts"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(6) },
        }

        local row_padding = sc(8)
        local row_border = sc(1)
        local row_inner_w = inner_w - (row_padding * 2) - (row_border * 2)

        for acc_idx, acc in ipairs(accounts) do
            local lib_name = acc.library_name or "Libby"
            local cards = acc.cards or {}
            local card_descs = {}
            for c_idx, c in ipairs(cards) do
                local detail = State.cardDetailString(c)
                if detail and detail ~= "" then
                    table.insert(card_descs, detail)
                end
            end
            local card_sub = #card_descs > 0 and table.concat(card_descs, "\n") or nil

            local loan_count = acc_loan_counts[acc.id] or 0
            local loan_text = loan_count > 0
                and ((loan_count == 1) and _("1 active loan") or string.format(_("%d active loans"), loan_count))
                or _("No active loans")

            local btn_w = sc(80)
            local h_gap = sc(8)
            local text_max_w = row_inner_w - btn_w - h_gap

            local info_items = {
                TextWidget:new{
                    text = lib_name,
                    face = Font:getFace("cfont", ui_font_size),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = text_max_w,
                },
            }

            if card_sub then
                table.insert(info_items, VerticalSpan:new{ width = sc(1) })
                for line in card_sub:gmatch("[^\r\n]+") do
                    table.insert(info_items, TextWidget:new{
                        text = line,
                        face = Font:getFace("cfont", theme.subtext_font_size or 13),
                        fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                        max_width = text_max_w,
                    })
                end
            end

            table.insert(info_items, VerticalSpan:new{ width = sc(1) })
            table.insert(info_items, TextWidget:new{
                text = loan_text,
                face = Font:getFace("cfont", theme.subtext_font_size or 12),
                fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                max_width = text_max_w,
            })

            local acc_info_vg = VerticalGroup:new{
                align = "left",
                unpack(info_items),
            }

            local disconnect_action = function()
                local confirm_text = lib_name
                if card_sub then confirm_text = confirm_text .. "\n" .. card_sub end
                M.showCardDialog{
                    title = _("Disconnect Account?"),
                    body_text = _("Disconnect this Libby account and remove its library cards?\n\n%s", confirm_text),
                    buttons = {
                        {
                            text = _("Disconnect"),
                            is_primary = true,
                            callback = function()
                                State.removeAccount(acc.id)
                                State.clearShelfCache()
                                refresh_manage()
                                _toast(_("Account disconnected"), 3)
                            end,
                        },
                        { text = _("Cancel") },
                    }
                }
            end

            local row_btn_idx = #interactive_items + 1
            table.insert(interactive_items, { callback = disconnect_action })
            local is_btn_focused = (focus_visible and focused_row_idx == row_btn_idx)

            local disconnect_btn = createButton{
                text = _("Disconnect"),
                text_font_size = theme.subtext_font_size or 13,
                bold = true,
                is_focused = is_btn_focused,
                bordersize = is_btn_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
                padding = sc(4),
                padding_h = sc(6),
                width = btn_w,
                height = sc(32),
                callback = disconnect_action,
            }

            local row_elements = {
                acc_info_vg,
                HorizontalSpan:new{ width = h_gap },
                disconnect_btn,
            }

            local row_frame = FrameContainer:new{
                padding = row_padding,
                radius = theme.radius_btn or sc(4),
                bordersize = is_btn_focused and (theme.border_focus or sc(2)) or row_border,
                color = Blitbuffer.COLOR_BLACK,
                background = is_btn_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or (theme.color_bg or Blitbuffer.COLOR_WHITE),
                width = inner_w,
                HorizontalGroup:new(row_elements),
            }

            table.insert(content_vg, row_frame)
            table.insert(content_vg, VerticalSpan:new{ width = sc(6) })
        end

        local back_cb = function()
            if overlay then
                local ov = overlay
                overlay = nil
                UIManager:close(ov, "ui")
            end
            if on_back_cb then on_back_cb() end
        end

        local back_btn_idx = #interactive_items + 1
        table.insert(interactive_items, { callback = back_cb })
        local is_back_focused = (focus_visible and focused_row_idx == back_btn_idx)

        local back_btn = createButton{
            text = _("‹ Back"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_back_focused,
            bordersize = is_back_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = back_cb,
        }

        table.insert(content_vg, VerticalSpan:new{ width = sc(4) })
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })
        table.insert(content_vg, back_btn)

        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or 0,
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            content_vg,
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card,
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh_manage()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh_manage()
            return true
        end

        overlay.onPress = function()
            if interactive_items[focused_row_idx] and interactive_items[focused_row_idx].callback then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            if overlay then
                local ov = overlay
                overlay = nil
                UIManager:close(ov, "ui")
            end
            if on_back_cb then on_back_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh_manage()
end

-- ---------------------------------------------------------------------------
-- Submenu: ByteBooks DRM & Sync
-- ---------------------------------------------------------------------------

function M.showByteBooksDRMSubmenu(plugin_dir, on_back_cb)
    plugin_dir = plugin_dir or ""
    local LibbeeDRM = require(plugin_path .. "libbee_drm")

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)
    local ui_font_size = theme.face_label_size or 16
    local title_font_size = theme.title_font_size or 20
    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device

    local overlay
    local refresh
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}

        local drm_info = LibbeeDRM.getAccountInfo()

        local title_label = TextWidget:new{
            text = _("ByteBooks DRM"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(4) },
        }

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(4),
                padding_left = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(8)
            local avail_w = inner_w - (frame_padding * 2)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or (right_widget.dimen and right_widget.dimen.w) or sc(40)) or 0

            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then max_left_w = sc(60) end

            local left_w
            if left_text:find("\n") then
                local vg_items = {}
                for line in left_text:gmatch("[^\r\n]+") do
                    if #vg_items > 0 then
                        table.insert(vg_items, VerticalSpan:new{ width = sc(1) })
                    end
                    table.insert(vg_items, TextWidget:new{
                        text = line,
                        face = Font:getFace("cfont", #vg_items == 0 and ui_font_size or (theme.subtext_font_size or 13)),
                        fgcolor = #vg_items == 0 and Blitbuffer.COLOR_BLACK or (theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY),
                        max_width = max_left_w,
                    })
                end
                left_w = VerticalGroup:new{ align = "left", unpack(vg_items) }
            else
                left_w = TextWidget:new{
                    text = left_text,
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = max_left_w,
                }
            end

            local left_used_w = (left_w.getSize and left_w:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { left_w, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local is_focused = false
            local item_idx = nil
            if callback then
                item_idx = #interactive_items + 1
                table.insert(interactive_items, { callback = callback })
                is_focused = (focus_visible and focused_row_idx == item_idx)
            end

            local frame = FrameContainer:new{
                bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                color = Blitbuffer.COLOR_BLACK,
                background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                padding = frame_padding,
                width = inner_w,
                HorizontalGroup:new{
                    align = "center",
                    unpack(row_elements),
                },
            }

            if not callback then return frame end

            local item = InputContainer:new{ frame }
            local row_size = (frame.getSize and frame:getSize()) or frame.dimen or { w = inner_w, h = sc(30) }
            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = (dim.w and dim.w > 0 and dim.w) or row_size.w or inner_w,
                                h = (dim.h and dim.h > 0 and dim.h) or row_size.h or 0,
                            }
                        end
                    }
                }
            }
            item.onTap = function()
                if item_idx then focused_row_idx = item_idx end
                if is_touch_device then focus_visible = false end
                callback()
                return true
            end
            return item
        end

        local arrow = function()
            return TextWidget:new{
                text = "›",
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
            }
        end

        table.insert(content_vg, create_section_header(_("Activation Status")))

        if drm_info.activated and drm_info.mode == "bytebooks" and drm_info.email ~= "" then
            local status_badge = TextWidget:new{
                text = _("✓ Active"),
                face = Font:getFace("cfont", theme.subtext_font_size or 14),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            table.insert(content_vg, create_setting_row(drm_info.email, status_badge, nil))
        else
            local drm_status_text = drm_info.activated and _("✓ Anonymous Active") or _("Auto on download")
            local drm_status_w = TextWidget:new{
                text = drm_status_text,
                face = Font:getFace("cfont", theme.subtext_font_size or 14),
                bold = drm_info.activated,
                fgcolor = drm_info.activated and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
            }
            table.insert(content_vg, create_setting_row(_("Device DRM"), drm_status_w, nil))
        end

        table.insert(content_vg, create_section_header(_("Actions")))

        if drm_info.mode ~= "bytebooks" or not drm_info.activated then
            table.insert(content_vg, create_setting_row(_("Sign in with ByteBooks ID"), arrow(), function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                M.showByteBooksAuthDialog(plugin_dir, function(ok)
                    M.showByteBooksDRMSubmenu(plugin_dir, on_back_cb)
                end)
            end))
        else
            table.insert(content_vg, create_setting_row(_("Switch to Anonymous DRM"), arrow(), function()
                M.showCardDialog{
                    title = _("Switch DRM Mode"),
                    body_text = _("Switch back to anonymous device DRM?\n\nThis will sign out your ByteBooks ID. Subsequent downloads will be single-device only."),
                    buttons = {
                        {
                            text = _("Switch"),
                            is_primary = true,
                            callback = function()
                                LibbeeDRM.deauthorize()
                                refresh()
                                UIManager:nextTick(function()
                                    _toast(_("Switched to anonymous DRM"), 3)
                                end)
                            end,
                        },
                        { text = _("Cancel") }
                    }
                }
            end))
        end

        if drm_info.activated then
            table.insert(content_vg, create_setting_row(_("Reset DRM activation keys"), arrow(), function()
                M.showCardDialog{
                    title = _("Reset DRM Keys"),
                    body_text = _("Reset saved Adobe / ByteBooks device activation keys?\n\nA fresh activation will be generated automatically on your next download."),
                    buttons = {
                        {
                            text = _("Reset Keys"),
                            is_primary = true,
                            callback = function()
                                LibbeeDRM.deauthorize()
                                refresh()
                                UIManager:nextTick(function()
                                    _toast(_("DRM activation keys reset"), 3)
                                end)
                            end,
                        },
                        { text = _("Cancel") }
                    }
                }
            end))
        end

        local back_cb = function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            if on_back_cb then on_back_cb() end
        end

        local back_btn_idx = #interactive_items + 1
        table.insert(interactive_items, { callback = back_cb })
        local is_back_focused = (focus_visible and focused_row_idx == back_btn_idx)

        local back_btn = createButton{
            text = _("‹ Back to Settings"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_back_focused,
            bordersize = is_back_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = back_cb,
        }

        local back_frame = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            width = inner_w,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = sc(36) },
                back_btn,
            }
        }

        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or 0,
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                content_vg,
                VerticalSpan:new{ width = sc(10) },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = sc(1) },
                    background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
                },
                VerticalSpan:new{ width = sc(8) },
                back_frame,
            }
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh()
            return true
        end

        overlay.onPress = function()
            if interactive_items[focused_row_idx] and interactive_items[focused_row_idx].callback then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            if overlay then
                local ov = overlay
                overlay = nil
                UIManager:close(ov, "ui")
            end
            if on_back_cb then on_back_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

-- ---------------------------------------------------------------------------
-- Submenu: Maintenance & Logs
-- ---------------------------------------------------------------------------

function M.showMaintenanceSubmenu(plugin_dir, on_back_cb)
    plugin_dir = plugin_dir or ""
    local State   = require(plugin_path .. "libbee_state")
    local Updater = require(plugin_path .. "libbee_updater")

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)
    local ui_font_size = theme.face_label_size or 16
    local title_font_size = theme.title_font_size or 20
    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device

    local overlay
    local refresh
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}

        local title_label = TextWidget:new{
            text = _("Maintenance & Logs"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(4) },
        }

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(4),
                padding_left = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(8)
            local avail_w = inner_w - (frame_padding * 2)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or (right_widget.dimen and right_widget.dimen.w) or sc(40)) or 0

            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then max_left_w = sc(60) end

            local left_w
            if left_text:find("\n") then
                local vg_items = {}
                for line in left_text:gmatch("[^\r\n]+") do
                    if #vg_items > 0 then
                        table.insert(vg_items, VerticalSpan:new{ width = sc(1) })
                    end
                    table.insert(vg_items, TextWidget:new{
                        text = line,
                        face = Font:getFace("cfont", #vg_items == 0 and ui_font_size or (theme.subtext_font_size or 13)),
                        fgcolor = #vg_items == 0 and Blitbuffer.COLOR_BLACK or (theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY),
                        max_width = max_left_w,
                    })
                end
                left_w = VerticalGroup:new{ align = "left", unpack(vg_items) }
            else
                left_w = TextWidget:new{
                    text = left_text,
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = max_left_w,
                }
            end

            local left_used_w = (left_w.getSize and left_w:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { left_w, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local is_focused = false
            local item_idx = nil
            if callback then
                item_idx = #interactive_items + 1
                table.insert(interactive_items, { callback = callback })
                is_focused = (focus_visible and focused_row_idx == item_idx)
            end

            local frame = FrameContainer:new{
                bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                color = Blitbuffer.COLOR_BLACK,
                background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                padding = frame_padding,
                width = inner_w,
                HorizontalGroup:new{
                    align = "center",
                    unpack(row_elements),
                },
            }

            if not callback then return frame end

            local item = InputContainer:new{ frame }
            local row_size = (frame.getSize and frame:getSize()) or frame.dimen or { w = inner_w, h = sc(30) }
            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = (dim.w and dim.w > 0 and dim.w) or row_size.w or inner_w,
                                h = (dim.h and dim.h > 0 and dim.h) or row_size.h or 0,
                            }
                        end
                    }
                }
            }
            item.onTap = function()
                if item_idx then focused_row_idx = item_idx end
                if is_touch_device then focus_visible = false end
                callback()
                return true
            end
            return item
        end

        local arrow = function()
            return TextWidget:new{
                text = "›",
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
            }
        end

        table.insert(content_vg, create_section_header(_("Updates")))

        table.insert(content_vg, create_setting_row(_("Check for updates"), arrow(), function()
            Updater.checkForUpdates(false)
        end))

        table.insert(content_vg, create_section_header(_("Diagnostics & Cache")))

        table.insert(content_vg, create_setting_row(_("View debug logs"), arrow(), function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            M._showDebugLog()
        end))

        table.insert(content_vg, create_setting_row(_("Clear local shelf cache"), arrow(), function()
            State.clearShelfCache()
            _toast(_("Local shelf cache cleared"), 3)
        end))

        local back_cb = function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            if on_back_cb then on_back_cb() end
        end

        local back_btn_idx = #interactive_items + 1
        table.insert(interactive_items, { callback = back_cb })
        local is_back_focused = (focus_visible and focused_row_idx == back_btn_idx)

        local back_btn = createButton{
            text = _("‹ Back to Settings"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_back_focused,
            bordersize = is_back_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = back_cb,
        }

        local back_frame = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            width = inner_w,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = sc(36) },
                back_btn,
            }
        }

        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or 0,
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                content_vg,
                VerticalSpan:new{ width = sc(10) },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = sc(1) },
                    background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
                },
                VerticalSpan:new{ width = sc(8) },
                back_frame,
            }
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh()
            return true
        end

        overlay.onPress = function()
            if interactive_items[focused_row_idx] and interactive_items[focused_row_idx].callback then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            if overlay then
                local ov = overlay
                overlay = nil
                UIManager:close(ov, "ui")
            end
            if on_back_cb then on_back_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

-- ---------------------------------------------------------------------------
-- Main Settings Card (Ultra-Clean, Guaranteed Single View, No Scrollbars)
-- ---------------------------------------------------------------------------

function M.showAbout(plugin_dir, on_close_cb, on_change_cb)
    _dismissActiveToast()
    plugin_dir = plugin_dir or ""
    local State     = require(plugin_path .. "libbee_state")
    local LibbeeDRM = require(plugin_path .. "libbee_drm")

    local meta_path = plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if not ok or type(meta) ~= "table" then
        meta = { version = "26.6.16", name = "Libbee", author = "ultimatejimmy" }
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

    local ui_font_size = theme.face_label_size or 16
    local title_font_size = theme.title_font_size or 20
    local is_touch_device = isTouchDevice()
    local focus_visible = not is_touch_device

    local overlay
    local refresh
    local focused_row_idx = focus_visible and 1 or nil
    local interactive_items = {}

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end
        interactive_items = {}

        if on_change_cb then
            on_change_cb()
        end

        -- Title Header
        local title_label = TextWidget:new{
            text = _("Libbee Settings"),
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_label,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = sc(4) },
        }

        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(4),
                padding_left = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(6)
            local avail_w = inner_w - (frame_padding * 2)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or (right_widget.dimen and right_widget.dimen.w) or sc(60)) or 0

            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then max_left_w = sc(60) end

            local left_w
            if left_text:find("\n") then
                local vg_items = {}
                for line in left_text:gmatch("[^\r\n]+") do
                    if #vg_items > 0 then
                        table.insert(vg_items, VerticalSpan:new{ width = sc(1) })
                    end
                    table.insert(vg_items, TextWidget:new{
                        text = line,
                        face = Font:getFace("cfont", #vg_items == 0 and ui_font_size or (theme.subtext_font_size or 13)),
                        fgcolor = #vg_items == 0 and Blitbuffer.COLOR_BLACK or (theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY),
                        max_width = max_left_w,
                    })
                end
                left_w = VerticalGroup:new{ align = "left", unpack(vg_items) }
            else
                left_w = TextWidget:new{
                    text = left_text,
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = max_left_w,
                }
            end

            local left_used_w = (left_w.getSize and left_w:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { left_w, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then table.insert(row_elements, right_widget) end

            local is_focused = false
            local item_idx = nil
            if callback then
                item_idx = #interactive_items + 1
                table.insert(interactive_items, { callback = callback })
                is_focused = (focus_visible and focused_row_idx == item_idx)
            end

            local frame = FrameContainer:new{
                bordersize = is_focused and (theme.border_focus or sc(2)) or 0,
                color = Blitbuffer.COLOR_BLACK,
                background = is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
                radius = is_focused and (theme.radius_focus or sc(4)) or 0,
                padding = frame_padding,
                width = inner_w,
                HorizontalGroup:new(row_elements),
            }

            if not callback then return frame end

            local item = InputContainer:new{ frame }
            local row_size = (frame.getSize and frame:getSize()) or frame.dimen or { w = inner_w, h = sc(30) }
            item.ges_events = {
                Tap = {
                    GestureRange:new{
                        ges = "tap",
                        range = function()
                            local dim = item.dimen
                            if not dim then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
                            return Geom:new{
                                x = dim.x or 0,
                                y = dim.y or 0,
                                w = (dim.w and dim.w > 0 and dim.w) or row_size.w or inner_w,
                                h = (dim.h and dim.h > 0 and dim.h) or row_size.h or 0,
                            }
                        end
                    }
                }
            }
            item.onTap = function()
                if item_idx then focused_row_idx = item_idx end
                if is_touch_device then focus_visible = false end
                callback()
                return true
            end
            return item
        end

        -- SECTION 1: ABOUT
        table.insert(content_vg, create_section_header(_("About")))

        local ver_widget = TextWidget:new{
            text = string.format("v%s", meta.version or "26.6.16"),
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Version"), ver_widget, nil))

        local author_widget = TextWidget:new{
            text = meta.author or "ultimatejimmy",
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Author"), author_widget, nil))

        -- SECTION 2: ACCOUNTS & DRM
        table.insert(content_vg, create_section_header(_("Accounts & DRM")))

        local is_auth = State.isAuthenticated()
        local libby_status_str = is_auth and _("Connected ›") or _("Not Connected ›")
        local libby_right = TextWidget:new{
            text = libby_status_str,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            bold = is_auth,
            fgcolor = is_auth and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Libby Account"), libby_right, function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            M.showLibbyAccountSubmenu(plugin_dir, function()
                M.showAbout(plugin_dir, on_close_cb, on_change_cb)
            end)
        end))

        local drm_info = LibbeeDRM.getAccountInfo()
        local drm_status_str = _("Anonymous ›")
        if drm_info.activated and drm_info.mode == "bytebooks" and drm_info.email ~= "" then
            drm_status_str = _("ByteBooks ID ›")
        end
        local drm_right = TextWidget:new{
            text = drm_status_str,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("ByteBooks DRM"), drm_right, function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            M.showByteBooksDRMSubmenu(plugin_dir, function()
                M.showAbout(plugin_dir, on_close_cb, on_change_cb)
            end)
        end))

        local group_by_card_enabled = State.getGroupByCard and State.getGroupByCard()
        local group_card_status = group_by_card_enabled and _("Enabled ›") or _("Disabled ›")
        local group_card_right = TextWidget:new{
            text = group_card_status,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            bold = group_by_card_enabled,
            fgcolor = group_by_card_enabled and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Group by Library Card"), group_card_right, function()
            local new_val = not group_by_card_enabled
            if State.setGroupByCard then
                State.setGroupByCard(new_val)
            end
            refresh()
        end))

        -- SECTION 3: DOWNLOADS
        table.insert(content_vg, create_section_header(_("Downloads")))

        local current_download_folder = State.getDownloadDir(plugin_dir)
        local is_custom_folder = State.isCustomDownloadDir(plugin_dir)
        local folder_status_label = is_custom_folder and _("Custom folder ›") or _("Default folder ›")

        local function openFolderPicker()
            UIManager:nextTick(function()
                local ok, err = pcall(function()
                    if overlay then
                        local ov = overlay
                        overlay = nil
                        ov.onClose = nil
                        UIManager:close(ov, "ui")
                    end
                    local LibbeeFolderPicker = require(plugin_path .. "libbee_folder_picker")
                    LibbeeFolderPicker.show{
                        title = _("Select Download Folder"),
                        initial_path = State.getDownloadDir(plugin_dir),
                        fallback_path = G_reader_settings and G_reader_settings:readSetting("home_dir"),
                        on_confirm = function(chosen_path)
                            if chosen_path and chosen_path ~= "" then
                                State.setCustomDownloadDir(chosen_path)
                                _toast(string.format(_("Download folder set to '%s'"), chosen_path), 2)
                            end
                            UIManager:nextTick(function()
                                M.showAbout(plugin_dir, on_close_cb, on_change_cb)
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                M.showAbout(plugin_dir, on_close_cb, on_change_cb)
                            end)
                        end,
                    }
                end)
                if not ok then
                    log.err("openFolderPicker error: " .. tostring(err))
                    M.showAbout(plugin_dir, on_close_cb, on_change_cb)
                end
            end)
        end

        local folder_right = TextWidget:new{
            text = folder_status_label,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Download Folder"), folder_right, openFolderPicker))

        if is_custom_folder then
            local reset_right = TextWidget:new{
                text = _("Reset ›"),
                face = Font:getFace("cfont", theme.subtext_font_size or 14),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            table.insert(content_vg, create_setting_row(_("Reset to Default"), reset_right, function()
                State.resetCustomDownloadDir()
                refresh()
            end))
        end

        local auto_del_enabled = State.getAutoDeleteExpired and State.getAutoDeleteExpired()
        local auto_del_status = auto_del_enabled and _("Enabled ›") or _("Disabled ›")
        local auto_del_right = TextWidget:new{
            text = auto_del_status,
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            bold = auto_del_enabled,
            fgcolor = auto_del_enabled and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Auto-delete Expired"), auto_del_right, function()
            local new_val = not auto_del_enabled
            if State.setAutoDeleteExpired then
                State.setAutoDeleteExpired(new_val)
            end
            refresh()
        end))

        -- SECTION 4: SYSTEM
        table.insert(content_vg, create_section_header(_("System")))

        local maint_right = TextWidget:new{
            text = _("Updates & Logs ›"),
            face = Font:getFace("cfont", theme.subtext_font_size or 14),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row(_("Maintenance"), maint_right, function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            M.showMaintenanceSubmenu(plugin_dir, function()
                M.showAbout(plugin_dir, on_close_cb, on_change_cb)
            end)
        end))

        -- Bottom Section: Close Button
        local close_cb = function()
            if overlay then
                UIManager:close(overlay, "ui")
                overlay = nil
            end
            if on_close_cb then on_close_cb() end
        end

        local close_btn_idx = #interactive_items + 1
        table.insert(interactive_items, { callback = close_cb })
        local is_close_focused = (focus_visible and focused_row_idx == close_btn_idx)

        local close_btn = createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            is_focused = is_close_focused,
            bordersize = is_close_focused and (theme.border_focus or sc(3)) or (theme.border_btn or sc(1)),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(38),
            callback = close_cb,
        }

        -- Build bounded modal card
        local card = FrameContainer:new{
            padding = card_padding,
            radius = theme.radius_window or sc(4),
            bordersize = card_border,
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            VerticalGroup:new{
                align = "left",
                content_vg,
                VerticalSpan:new{ width = sc(8) },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = sc(1) },
                    background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
                },
                VerticalSpan:new{ width = sc(8) },
                close_btn,
            }
        }

        local sub_key_events = {
            Close = { { "Back" }, { "Escape" } },
            Up = { { "Up" }, { "Left" } },
            Down = { { "Down" }, { "Right" } },
            Press = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        }
        if Device and Device.input and Device.input.group then
            if Device.input.group.Back then table.insert(sub_key_events.Close, { Device.input.group.Back }) end
            if Device.input.group.Up then table.insert(sub_key_events.Up, { Device.input.group.Up }) end
            if Device.input.group.Down then table.insert(sub_key_events.Down, { Device.input.group.Down }) end
            if Device.input.group.Left then table.insert(sub_key_events.Up, { Device.input.group.Left }) end
            if Device.input.group.Right then table.insert(sub_key_events.Down, { Device.input.group.Right }) end
            if Device.input.group.Press then table.insert(sub_key_events.Press, { Device.input.group.Press }) end
            if Device.input.group.Enter then table.insert(sub_key_events.Press, { Device.input.group.Enter }) end
        end

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = sub_key_events,
            card
        }

        overlay.onUp = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx > 1) and (focused_row_idx - 1) or #interactive_items
            end
            refresh()
            return true
        end

        overlay.onDown = function()
            focus_visible = true
            if not focused_row_idx then
                focused_row_idx = 1
            elseif #interactive_items > 1 then
                focused_row_idx = (focused_row_idx < #interactive_items) and (focused_row_idx + 1) or 1
            end
            refresh()
            return true
        end

        overlay.onPress = function()
            if interactive_items[focused_row_idx] and interactive_items[focused_row_idx].callback then
                interactive_items[focused_row_idx].callback()
                return true
            end
        end

        overlay.onClose = function()
            if overlay then
                local ov = overlay
                overlay = nil
                UIManager:close(ov, "ui")
            end
            if on_close_cb then on_close_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return M
