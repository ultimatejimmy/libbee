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
    plugin_root .. "/dependencies/?.lua",
    plugin_root .. "/dependencies/xmlhandler/?.lua",
}
for _, ep in ipairs(extra_paths) do
    if not package.path:find(ep, 1, true) then
        package.path = ep .. ";" .. package.path
    end
end

local ok_loc, Localization = pcall(require, plugin_path .. "localization_libbee")
if not ok_loc or not Localization then
    ok_loc, Localization = pcall(require, "localization_libbee")
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
        padding = sc(14),
        padding_left = sc(18),
        padding_right = sc(18),
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
    UIManager:close(self, "ui")
end

function LibbeeToastWidget:setText(text)
    self.text = text or ""
    if self.label_widget then
        self.label_widget:setText(self.text)
        UIManager:setDirty(self, "ui")
    end
end

local function _toast(msg, timeout, opts)
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

local function _runNetwork(work_fn, on_done)
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        NetworkMgr:runWhenOnline(function()
            UIManager:scheduleIn(0.05, function()
                local ok, r1, r2 = pcall(work_fn)
                if ok then
                    on_done(r1, r2)
                else
                    on_done(nil, tostring(r1 or _("Unknown error")))
                end
            end)
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

local function _runAsync(work_fn, spinner_text, on_done)
    local spinner = _toast(spinner_text, 120)
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
    local border_sz = opts.bordersize or (theme.border_btn or sc(1))
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
    local icon_size = opts.size or sc(22)
    local icon_widget = ImageWidget:new{
        file = getAssetPath(opts.icon),
        width = icon_size,
        height = icon_size,
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }
    local frame = FrameContainer:new{
        padding = opts.padding or sc(6),
        padding_h = opts.padding_h or sc(8),
        bordersize = opts.bordersize or 0,
        background = theme.color_bg or Blitbuffer.COLOR_WHITE,
        icon_widget,
    }
    return makeTapItem(frame, opts.callback)
end

-- ---------------------------------------------------------------------------
-- Styled Card Dialog (Replaces raw ConfirmBox)
-- ---------------------------------------------------------------------------

function M.showCardDialog(opts)
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
    local buttons = opts.buttons or { { text = _("OK"), is_primary = true } }
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
        local btn = createButton{
            text = b.text,
            text_font_size = theme.subtext_font_size or 15,
            bold = is_pri or b.bold,
            is_primary = is_pri,
            bordersize = theme.border_btn or sc(1),
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

    local card = FrameContainer:new{
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

    overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        key_events = {
            Close = { { "Back" } }
        },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        }
    }

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
        face = Font:getFace("cfont", 15),
        bold = is_urgent,
        fgcolor = fg,
    }
    return FrameContainer:new{
        padding_top = sc(3),
        padding_bottom = sc(3),
        padding_left = sc(8),
        padding_right = sc(8),
        bordersize = is_urgent and 0 or sc(1),
        color = Blitbuffer.COLOR_BLACK,
        background = bg,
        radius = theme.radius_badge or sc(10),
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

local function _loanBadge(loan)
    if not loan then return nil end
    local rest_label = _restrictionBadgeLabel(loan)
    if rest_label then
        return _createBadge(rest_label, false)
    end
    local days_str = _fmtDays(loan.days_remaining)
    local is_urgent = (loan.days_remaining and loan.days_remaining <= 2)
    return _createBadge(days_str, is_urgent)
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

    local cached_shelf = State.getShelfCache()

    local current_page = 1

    local function renderShelf(loans, from_cache)
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

        -- Determine libraries present across active loans
        local libs_map = {}
        local lib_order = {}
        for _, loan in ipairs(loans) do
            local l_name = loan.library
            if not l_name or l_name == "" then
                l_name = lib_name
            end
            if not libs_map[l_name] then
                libs_map[l_name] = {}
                table.insert(lib_order, l_name)
            end
            table.insert(libs_map[l_name], loan)
        end
        table.sort(lib_order, function(a, b)
            return tostring(a):lower() < tostring(b):lower()
        end)

        -- Flatten loans for pagination (keeps library grouping info)
        local flat_items = {}
        if #lib_order > 1 then
            for _, l_name in ipairs(lib_order) do
                for _, loan in ipairs(libs_map[l_name]) do
                    table.insert(flat_items, { loan = loan, lib = l_name })
                end
            end
        else
            for _, loan in ipairs(loans) do
                table.insert(flat_items, { loan = loan, lib = nil })
            end
        end

        -- Header Action Buttons using Feather SVGs (Storefront style, stroke-width 1.5)
        local btn_size = sc(30)
        local btn_pad = sc(4)

        local view_toggle_icon = (view_mode == "cover") and "list.svg" or "grid.svg"
        local view_toggle_btn = createIconButton{
            icon = view_toggle_icon,
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
            callback = function()
                local next_mode = (view_mode == "cover") and "list" or "cover"
                State.saveViewMode(next_mode)
                current_page = 1
                renderShelf(loans, from_cache)
            end,
        }

        local refresh_btn = createIconButton{
            icon = "refresh-cw.svg",
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
            callback = function()
                State.clearShelfCache()
                _runAsync(
                    function() return API.fetchShelf() end,
                    _("Refreshing shelf from Libby…"),
                    function(result, err)
                        if type(result) == "table" then
                            State.saveShelfCache(result)
                            current_page = 1
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
            callback = function()
                M.showAbout(plugin_dir)
            end,
        }

        local close_btn = createIconButton{
            icon = "x.svg",
            size = btn_size,
            padding = btn_pad,
            padding_h = btn_pad,
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
            HorizontalSpan:new{ width = sc(6) },
            refresh_btn,
            HorizontalSpan:new{ width = sc(6) },
            menu_btn,
            HorizontalSpan:new{ width = sc(6) },
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
        if #lib_order == 1 then
            sub_text = count_str .. "  ·  " .. lib_order[1]
        elseif #lib_order > 1 then
            sub_text = count_str .. "  ·  " .. _("%d libraries", #lib_order)
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
        local footer_h = sc(58)
        local top_margin = sc(12)
        local avail_h = sh - header_h - footer_h - top_margin - sc(10)

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

        local tile_extra_h = (border_w * 2) + sc(4) + sc(46) + sc(4) + sc(24)
        local grid_gap_v = sc(10)

        local cover_inner_w
        local cover_inner_h
        local num_rows

        if view_mode == "cover" then
            local max_row_h_2 = math.floor((avail_h - grid_gap_v) / 2)
            local max_cover_h_2 = max_row_h_2 - tile_extra_h

            if max_cover_h_2 >= sc(110) then
                num_rows = 2
                local max_row_h_3 = math.floor((avail_h - (grid_gap_v * 2)) / 3)
                if (max_row_h_3 - tile_extra_h) >= sc(140) then
                    num_rows = 3
                end
            else
                num_rows = 1
            end

            local max_row_h = math.floor((avail_h - (grid_gap_v * (num_rows - 1))) / num_rows)
            local max_cover_h = math.max(sc(60), max_row_h - tile_extra_h)
            local max_cover_w_by_h = math.floor(max_cover_h / 1.38)
            local max_cover_w_by_cell = cell_w - (border_w * 2)

            cover_inner_w = math.max(sc(40), math.min(max_cover_w_by_cell, max_cover_w_by_h))
            cover_inner_h = math.floor(cover_inner_w * 1.38)
            items_per_page = num_rows * COLS
        else
            local list_row_h = sc(94)
            items_per_page = math.max(3, math.floor(avail_h / list_row_h))
        end

        local total_pages = math.max(1, math.ceil(#flat_items / items_per_page))
        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        local page_start = (current_page - 1) * items_per_page + 1
        local page_end   = math.min(page_start + items_per_page - 1, #flat_items)

        -- 2. Page Content
        local page_content_vg = VerticalGroup:new{ align = "left" }

        local function create_shelf_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 15),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local frame = FrameContainer:new{
                padding = sc(4),
                padding_left = sc(8),
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

        local function render_list_loan(loan, loan_idx)
            local badge_w = _loanBadge(loan)

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

            local title_w = TextWidget:new{
                text = loan.title or _("Unknown Title"),
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
                bordersize = 0,
                width = content_w,
                row_overlap,
            }

            local row_tap = makeTapItem(row_frame, function()
                M.showDownloadConfirm(loan, plugin_dir, function()
                    renderShelf(loans, from_cache)
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

        local function render_cover_grid(page_items, global_start_idx)
            local num_cols = COLS
            local current_row_widgets = {}

            for i, item in ipairs(page_items) do
                local loan = item.loan
                local global_idx = (global_start_idx or 0) + i

                local cached_cover = Covers.getCachedCoverPath(loan)
                local cover_img = nil

                if cached_cover then
                    cover_img = Covers.createCoverImageWidget(cached_cover, cover_inner_w, cover_inner_h)
                end

                if not cover_img then
                    cover_img = Covers.createPlaceholderWidget(cover_inner_w, cover_inner_h, loan.title)
                end

                local cover_frame = FrameContainer:new{
                    bordersize = border_w,
                    color = Blitbuffer.COLOR_BLACK,
                    padding = 0,
                    width = cover_inner_w,
                    height = cover_inner_h,
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

                local title_box = TextBoxWidget:new{
                    text = loan.title or _("Unknown Title"),
                    face = Font:getFace("NotoSerif-Regular.ttf", 15),
                    bold = true,
                    width = cell_w,
                    alignment = "center",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local badge_widget = _loanBadge(loan)

                local cell_content = VerticalGroup:new{
                    align = "center",
                    cover_frame,
                    VerticalSpan:new{ width = sc(3) },
                    title_box,
                    VerticalSpan:new{ width = sc(3) },
                    badge_widget or VerticalSpan:new{ width = 0 },
                }

                local cell_tap = makeTapItem(cell_content, function()
                    M.showDownloadConfirm(loan, plugin_dir, function()
                        renderShelf(loans, from_cache)
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
            local page_items = {}
            for idx = page_start, page_end do
                table.insert(page_items, flat_items[idx])
            end

            if view_mode == "list" then
                local last_lib = nil
                for i, item in ipairs(page_items) do
                    if #lib_order > 1 and item.lib ~= last_lib then
                        table.insert(page_content_vg, create_shelf_section_header(item.lib))
                        last_lib = item.lib
                    end
                    render_list_loan(item.loan, page_start + i - 1)
                end
            else
                if #lib_order > 1 then
                    local lib_pages = {}
                    local last_lib = nil
                    local cur_group = nil
                    for _, item in ipairs(page_items) do
                        if item.lib ~= last_lib then
                            if cur_group then
                                table.insert(lib_pages, { lib = last_lib, items = cur_group })
                            end
                            cur_group = {}
                            last_lib = item.lib
                        end
                        table.insert(cur_group, item)
                    end
                    if cur_group and #cur_group > 0 then
                        table.insert(lib_pages, { lib = last_lib, items = cur_group })
                    end
                    local offset = 0
                    for _, group in ipairs(lib_pages) do
                        table.insert(page_content_vg, create_shelf_section_header(group.lib))
                        table.insert(page_content_vg, VerticalSpan:new{ width = sc(8) })
                        render_cover_grid(group.items, page_start + offset - 1)
                        offset = offset + #group.items
                    end
                else
                    render_cover_grid(page_items, page_start - 1)
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

        local footer_frame = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(14),
            padding_left = sc(10),
            padding_right = sc(10),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            height = footer_h,
            CenterContainer:new{
                dimen = Geom:new{ w = sw - sc(20), h = footer_h - sc(18) },
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

        active_shelf_overlay = InputContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            key_events = {
                Close = { { "Back" } },
                PrevPage = { { "Left" }, { "PgUp" }, { "Prev" }, { "LPgBack" }, { "RPgBack" } },
                NextPage = { { "Right" }, { "PgDn" }, { "Next" }, { "LPgFwd" }, { "RPgFwd" } },
            },
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

        active_shelf_overlay.onPrevPage = function()
            if current_page > 1 then
                current_page = current_page - 1
                renderShelf(loans, from_cache)
                return true
            end
        end

        active_shelf_overlay.onNextPage = function()
            if current_page < total_pages then
                current_page = current_page + 1
                renderShelf(loans, from_cache)
                return true
            end
        end

        active_shelf_overlay.onSwipe = function(self, arg, ges_ev)
            if ges_ev and ges_ev.direction then
                if ges_ev.direction == "east" or ges_ev.direction == "right" then
                    return self:onPrevPage()
                elseif ges_ev.direction == "west" or ges_ev.direction == "left" then
                    return self:onNextPage()
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

    local function loansEqual(a, b)
        if not a or not b then return false end
        if #a ~= #b then return false end
        for i = 1, #a do
            local ida = a[i].id or a[i].reserveId
            local idb = b[i].id or b[i].reserveId
            if ida ~= idb then return false end
            if a[i].days_remaining ~= b[i].days_remaining then return false end
        end
        return true
    end

    local current_rendered_loans = cached_shelf or {}

    -- Always render cached shelf (or loading placeholder) immediately with zero blocking dialogs
    if cached_shelf and #cached_shelf > 0 then
        pcall(Covers.cleanupExpiredCovers, cached_shelf)
    end
    renderShelf(current_rendered_loans, true)

    local is_syncing = false
    local function doBackgroundSync()
        if is_syncing then return end
        is_syncing = true
        UIManager:scheduleIn(0.5, function()
            local ok, result, err = pcall(function()
                return API.fetchShelf()
            end)
            is_syncing = false
            if ok and type(result) == "table" then
                State.saveShelfCache(result)
                if #result > 0 then
                    pcall(Covers.cleanupExpiredCovers, result)
                end
                if active_shelf_overlay then
                    if not loansEqual(current_rendered_loans, result) or #current_rendered_loans == 0 then
                        current_rendered_loans = result
                        renderShelf(result, false)
                    end
                end
            elseif ok and (result == "AUTH_EXPIRED" or err == "AUTH_EXPIRED") then
                if active_shelf_overlay then
                    M._handleAuthExpired(plugin_dir)
                end
            end
        end)
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
    local title = loan.title or ""
    if title == "" then return nil end

    local ok_naming, naming = pcall(require, plugin_path .. "adobe.util.naming")
    if not ok_naming or not naming then
        ok_naming, naming = pcall(require, "adobe.util.naming")
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
    local title_variants = {
        safe_title,
        safe_title_60,
        underscore_title,
        underscore_title_60,
    }

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

    -- 1. Check exact candidate paths
    for _, t in ipairs(title_variants) do
        for _, ext in ipairs(extensions) do
            local p = base_dir .. "/" .. t .. ext
            if isValidBookFile(p) then return p end
            for i = 1, 10 do
                local pi = base_dir .. "/" .. t .. " (" .. i .. ")" .. ext
                if isValidBookFile(pi) then return pi end
            end
        end
    end

    -- 2. Check directory listing with strict normalization match in base_dir
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.dir then
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

function M.showDownloadConfirm(loan, plugin_dir, after_download_fn)
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
    if existing_book then
        _toast(string.format(_("Opening \"%s\"…"), (loan and loan.title) or _("book")), 2)
        local opened = M._openBook(existing_book)
        if opened then
            return
        end
    end

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
                text = _("Cancel"),
                callback = function()
                    -- Shelf remains open in background
                end,
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

    local temp_acsm_path = base_dir .. "/.temp_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".acsm"

    _runAsync(
        function()
            -- Step 1: Download ACSM license token from Libby API
            local dl_ok, dl_err = API.downloadACSM(loan, temp_acsm_path)
            if not dl_ok then
                return nil, dl_err
            end

            -- Step 2: Parse metadata and derive final decrypted book path
            local meta = LibbeeDRM.parseAcsmMetadata(temp_acsm_path)
            local final_path = LibbeeDRM.deriveFinalBookPath(base_dir, loan, meta)

            -- Step 3: Fulfill and decrypt with embedded Adobe/ByteBooks DRM engine
            local ful_ok, ful_err = LibbeeDRM.fulfillAcsm(temp_acsm_path, final_path)
            pcall(os.remove, temp_acsm_path)

            if not ful_ok then
                return nil, ful_err
            end

            return final_path
        end,
        _("Downloading & fulfilling \"%s\"…", loan.title or _("ebook")),
        function(final_book_path, err)
            if type(final_book_path) == "string" and final_book_path ~= "" then
                local State = require(plugin_path .. "libbee_state")
                State.clearShelfCache()

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
        end
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
            for line in raw_content:gmatch("([^\r\n]*)\r?\n?") do
                if line ~= "" then
                    table.insert(lines, line)
                end
            end
            if #lines > max_lines then
                local tail_lines = {}
                for i = #lines - max_lines + 1, #lines do
                    table.insert(tail_lines, lines[i])
                end
                content = _("... [showing last %d log entries] ...\n", max_lines) .. table.concat(tail_lines, "\n")
            elseif offset > 0 then
                content = _("... [showing last %d log entries] ...\n", #lines) .. table.concat(lines, "\n")
            else
                content = table.concat(lines, "\n")
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

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))
    local card_padding = sc(12)
    local card_border = theme.border_window or sc(2)
    local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)
    local ui_font_size = theme.face_label_size or 16
    local title_font_size = theme.title_font_size or 20

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end

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

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
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

        local is_auth = State.isAuthenticated()
        table.insert(content_vg, create_section_header(_("Connected Libraries")))

        if is_auth then
            local lib_name = State.getLibraryName()
            local cards = State.getCards() or {}
            local seen_libs = {}

            for idx, card_item in ipairs(cards) do
                local c_name = card_item.library_name or card_item.name or (card_item.advantage_key and card_item.advantage_key:upper())
                if c_name and c_name ~= "" and not seen_libs[c_name] then
                    seen_libs[c_name] = true
                    local status_badge = TextWidget:new{
                        text = _("✓ Connected"),
                        face = Font:getFace("cfont", theme.subtext_font_size or 14),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    table.insert(content_vg, create_setting_row(c_name, status_badge, nil))
                end
            end

            if lib_name and lib_name ~= "" and not seen_libs[lib_name] then
                seen_libs[lib_name] = true
                local status_badge = TextWidget:new{
                    text = _("✓ Connected"),
                    face = Font:getFace("cfont", theme.subtext_font_size or 14),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                table.insert(content_vg, create_setting_row(lib_name, status_badge, nil))
            end

            table.insert(content_vg, create_section_header(_("Actions")))

            table.insert(content_vg, create_setting_row(_("Link another Libby device"), arrow(), function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                M.showSetupDialog(plugin_dir, function(success)
                    M.showLibbyAccountSubmenu(plugin_dir, on_back_cb)
                end)
            end))

            table.insert(content_vg, create_setting_row(_("Re-authenticate account"), arrow(), function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                if active_shelf_overlay then
                    local ov = active_shelf_overlay
                    active_shelf_overlay = nil
                    ov.onClose = nil
                    UIManager:close(ov, "ui")
                end
                State.clearChipIdentity()
                State.clearShelfCache()
                M.showSetupDialog(plugin_dir, function(success)
                    if success then
                        M.showShelfBrowser(plugin_dir)
                    end
                end)
            end))

            table.insert(content_vg, create_setting_row(_("Disconnect Libby account"), arrow(), function()
                M.showCardDialog{
                    title = _("Disconnect Account"),
                    body_text = _("Disconnect your Libby account?\n\nYour saved session and cached shelf will be cleared."),
                    buttons = {
                        {
                            text = _("Disconnect"),
                            is_primary = true,
                            callback = function()
                                State.clearChipIdentity()
                                State.clearShelfCache()
                                if active_shelf_overlay then
                                    local ov = active_shelf_overlay
                                    active_shelf_overlay = nil
                                    ov.onClose = nil
                                    UIManager:close(ov, "ui")
                                end
                                refresh()
                                UIManager:nextTick(function()
                                    _toast(_("Libby account disconnected"), 3)
                                end)
                            end,
                        },
                        { text = _("Cancel") }
                    }
                }
            end))
        else
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

        local back_btn = createButton{
            text = _("‹ Back to Settings"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = theme.border_btn or sc(1),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                if on_back_cb then on_back_cb() end
            end,
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

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card
        }

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

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end

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

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
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

        local back_btn = createButton{
            text = _("‹ Back to Settings"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = theme.border_btn or sc(1),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                if on_back_cb then on_back_cb() end
            end,
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

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card
        }

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

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
        end

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

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
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

        local back_btn = createButton{
            text = _("‹ Back to Settings"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = theme.border_btn or sc(1),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(36),
            callback = function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                if on_back_cb then on_back_cb() end
            end,
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

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card
        }

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

function M.showAbout(plugin_dir, on_close_cb)
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

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
            overlay = nil
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

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }

            local left_used_w = (txt.getSize and txt:getSize().w) or max_left_w
            local spacer_w = math.max(sc(8), avail_w - left_used_w - right_w)

            local row_elements = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then table.insert(row_elements, right_widget) end

            local frame = FrameContainer:new{
                bordersize = 0,
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
                M.showAbout(plugin_dir, on_close_cb)
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
                M.showAbout(plugin_dir, on_close_cb)
            end)
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
                                M.showAbout(plugin_dir, on_close_cb)
                            end)
                        end,
                        on_cancel = function()
                            UIManager:nextTick(function()
                                M.showAbout(plugin_dir, on_close_cb)
                            end)
                        end,
                    }
                end)
                if not ok then
                    log.err("openFolderPicker error: " .. tostring(err))
                    M.showAbout(plugin_dir, on_close_cb)
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
                _toast(_("Reset to default download folder"), 2)
                refresh()
            end))
        end

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
                M.showAbout(plugin_dir, on_close_cb)
            end)
        end))

        -- Bottom Section: Close Button
        local close_btn = createButton{
            text = _("Close"),
            text_font_size = ui_font_size,
            bold = true,
            bordersize = theme.border_btn or sc(1),
            radius = theme.radius_btn or sc(4),
            width = inner_w,
            height = sc(38),
            callback = function()
                if overlay then
                    UIManager:close(overlay, "ui")
                    overlay = nil
                end
                if on_close_cb then on_close_cb() end
            end,
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

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card
        }

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
