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
-- Helpers
-- ---------------------------------------------------------------------------

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _close(w)
    if w then UIManager:close(w, "ui") end
end

local function _loadConfig(plugin_dir)
    local config_path = plugin_dir .. "/libbee_config.lua"
    local ok, cfg = pcall(dofile, config_path)
    if ok and type(cfg) == "table" then return cfg end
    log.warn("libbee ui: could not load config from " .. tostring(config_path))
    return {}
end

local function _runAsync(work_fn, spinner_text, on_done)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    local spinner = _toast(spinner_text, 120)

    if ok_tr and Trapper and Trapper.wrap then
        Trapper:wrap(function()
            local completed, ok, r1, r2 = Trapper:dismissableRunInSubprocess(
                function() return pcall(work_fn) end,
                spinner
            )
            _close(spinner)
            if not completed then
                on_done(nil, "Cancelled")
            elseif ok then
                on_done(r1, r2)
            else
                on_done(nil, tostring(r1 or "Unknown error"))
            end
        end)
    else
        UIManager:scheduleIn(0.1, function()
            local ok, r1, r2 = pcall(work_fn)
            _close(spinner)
            if ok then
                on_done(r1, r2)
            else
                on_done(nil, tostring(r1 or "Unknown error"))
            end
        end)
    end
end

local function _runAsyncSilent(work_fn, on_done)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    if ok_tr and Trapper and Trapper.wrap then
        Trapper:wrap(function()
            local completed, ok, r1, r2 = Trapper:dismissableRunInSubprocess(
                function() return pcall(work_fn) end,
                nil
            )
            if completed then
                if ok then
                    on_done(r1, r2)
                else
                    on_done(nil, tostring(r1 or "Unknown error"))
                end
            end
        end)
    else
        UIManager:scheduleIn(0.1, function()
            local ok, r1, r2 = pcall(work_fn)
            if ok then
                on_done(r1, r2)
            else
                on_done(nil, tostring(r1 or "Unknown error"))
            end
        end)
    end
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
        if callback then callback() end
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
    local buttons = opts.buttons or { { text = "OK", is_primary = true } }
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
        radius = theme.radius_btn or sc(4),
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
        "Connecting to Libby…",
        function(result, err)
            if not result or not result.code then
                local err_str = err or tostring(result or "Unknown error")
                log.warn("setup code request failed: " .. tostring(err_str))
                M.showCardDialog{
                    title = "Setup Failed",
                    body_text = "Could not request setup code:\n" .. err_str .. "\n\nMake sure your device is connected to Wi-Fi.",
                    buttons = {
                        { text = "OK", is_primary = true, callback = function()
                            if on_done then on_done(false) end
                        end }
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

            local poll_count = 0
            local max_polls = 36 -- 3 minutes (5s interval)
            local function do_poll()
                if not is_active then return end
                poll_count = poll_count + 1
                if poll_count > max_polls then
                    cleanup()
                    M.showCardDialog{
                        title = "Setup Timed Out",
                        body_text = "Authorization timed out.\n\nPlease try again from the Libby app.",
                        buttons = {
                            { text = "OK", is_primary = true, callback = function()
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
                                title = "✓ Libbee Connected!",
                                body_text = "Library: " .. tostring(lib_name) .. "\n\nYour device is now registered. You can browse and download your shelf.",
                                buttons = {
                                    {
                                        text = "Open Shelf",
                                        is_primary = true,
                                        callback = function()
                                            M.showShelfBrowser(plugin_dir)
                                            if on_done then on_done(true) end
                                        end,
                                    },
                                    {
                                        text = "Done",
                                        callback = function()
                                            if on_done then on_done(true) end
                                        end,
                                    }
                                }
                            }
                        elseif poll_err == "pending" then
                            UIManager:scheduleIn(5, do_poll)
                        else
                            cleanup()
                            local err_msg = tostring(poll_err or "Unknown error")
                            M.showCardDialog{
                                title = "Setup Error",
                                body_text = "Setup could not be completed:\n" .. err_msg .. "\n\nPlease try again.",
                                buttons = {
                                    { text = "OK", is_primary = true, callback = function()
                                        if on_done then on_done(false) end
                                    end }
                                },
                            }
                        end
                    end
                )
            end

            -- Setup Code Card layout
            local sw = Screen:getWidth()
            local sh = Screen:getHeight()
            local dialog_w = math.min(sw - sc(20), sc(420))
            local inner_w = dialog_w - sc(32)

            local code_text_w = TextWidget:new{
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
                text = "1. Open the Libby app on your phone or computer.\n" ..
                       "2. Tap Menu (☰) → Settings → Copy To Another Device.\n" ..
                       "3. Enter the 8-digit setup code below:\n",
                face = Font:getFace("cfont", 15),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w,
            }

            local waiting_text = TextBoxWidget:new{
                text = "Waiting for Libby app to authorize…",
                face = Font:getFace("cfont", 13),
                fgcolor = theme.color_label_dim,
                width = inner_w,
                alignment = "center",
            }

            local body_vg = VerticalGroup:new{
                align = "center",
                instructions_text,
                VerticalSpan:new{ width = sc(4) },
                code_box,
                VerticalSpan:new{ width = sc(8) },
                waiting_text,
            }

            setup_overlay = M.showCardDialog{
                title = "Link Libby Account",
                body_widget = body_vg,
                width = dialog_w,
                buttons = {
                    {
                        text = "Cancel",
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

            UIManager:scheduleIn(5, do_poll)
        end
    )
end

-- ---------------------------------------------------------------------------
-- Expiry Badge Helper
-- ---------------------------------------------------------------------------

local function _fmtDays(days)
    if not days then return "" end
    if days == 0 then return "Expires today" end
    if days == 1 then return "1 day left" end
    return string.format("%d days left", days)
end

local function _createBadge(text, is_urgent)
    if not text or text == "" then return nil end
    local bg = is_urgent and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = is_urgent and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("smallinfofont", 12),
        bold = is_urgent,
        fgcolor = fg,
    }
    return FrameContainer:new{
        padding_top = sc(3),
        padding_bottom = sc(3),
        padding_left = sc(6),
        padding_right = sc(6),
        bordersize = is_urgent and 0 or sc(1),
        color = Blitbuffer.COLOR_BLACK,
        background = bg,
        radius = theme.radius_badge or sc(8),
        label,
    }
end

-- ---------------------------------------------------------------------------
-- Shelf Browser (Full-screen Dialog with List & Cover Views)
-- ---------------------------------------------------------------------------

local active_shelf_overlay = nil

function M.showShelfBrowser(plugin_dir)
    local cfg = _loadConfig(plugin_dir)
    local State = require(plugin_path .. "libbee_state")
    local API   = require(plugin_path .. "libbee_api")

    -- Check auth before fetching
    if not State.isAuthenticated() and (not cfg.bearer_token or cfg.bearer_token == "") then
        M.showCardDialog{
            title = "Libbee Setup Required",
            body_text = "Libbee is not connected yet.\n\nConnect with a Libby setup code to browse and download your loans.",
            buttons = {
                {
                    text = "Setup Now",
                    is_primary = true,
                    callback = function()
                        M.showSetupDialog(plugin_dir, function(success)
                            if success then M.showShelfBrowser(plugin_dir) end
                        end)
                    end,
                },
                { text = "Cancel" }
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

        -- Sort by days remaining (soonest first)
        table.sort(loans or {}, function(a, b)
            local da = a.days_remaining or 999
            local db = b.days_remaining or 999
            return da < db
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

        -- Header Action Buttons using Feather SVGs (Storefront style)
        local view_toggle_icon = (view_mode == "cover") and "list.svg" or "grid.svg"
        local view_toggle_btn = createIconButton{
            icon = view_toggle_icon,
            size = sc(22),
            padding = sc(6),
            padding_h = sc(6),
            callback = function()
                local next_mode = (view_mode == "cover") and "list" or "cover"
                State.saveViewMode(next_mode)
                current_page = 1
                renderShelf(loans, from_cache)
            end,
        }

        local refresh_btn = createIconButton{
            icon = "refresh-cw.svg",
            size = sc(20),
            padding = sc(6),
            padding_h = sc(6),
            callback = function()
                State.clearShelfCache()
                _runAsync(
                    function() return API.fetchShelf(cfg) end,
                    "Refreshing shelf from Libby…",
                    function(result, err)
                        if type(result) == "table" then
                            State.saveShelfCache(result)
                            current_page = 1
                            renderShelf(result, false)
                        elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                            M._handleAuthExpired(plugin_dir)
                        else
                            _toast("Refresh failed: " .. tostring(err or "error"), 4)
                        end
                    end
                )
            end,
        }

        local menu_btn = createIconButton{
            icon = "settings.svg",
            size = sc(22),
            padding = sc(6),
            padding_h = sc(6),
            callback = function()
                M.showAbout(plugin_dir)
            end,
        }

        local close_btn = createIconButton{
            icon = "x.svg",
            size = sc(22),
            padding = sc(6),
            padding_h = sc(6),
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
            HorizontalSpan:new{ width = sc(8) },
            refresh_btn,
            HorizontalSpan:new{ width = sc(8) },
            menu_btn,
            HorizontalSpan:new{ width = sc(8) },
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
                text = "Libbee \xC2\xB7 Shelf",
                face = Font:getFace("NotoSerif-Regular.ttf", theme.title_font_size or 22),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        }

        local count_str = string.format("%d %s", loan_count, loan_count == 1 and "loan" or "loans")
        if from_cache then count_str = count_str .. " (cached)" end

        local sub_text = count_str
        if #lib_order == 1 then
            sub_text = count_str .. "  ·  " .. lib_order[1]
        elseif #lib_order > 1 then
            sub_text = count_str .. string.format("  ·  %d libraries", #lib_order)
        elseif lib_name and lib_name ~= "" then
            sub_text = count_str .. "  ·  " .. lib_name
        end

        local actions_w = header_actions:getSize().w
        local header_avail_w = sw - sc(24)
        local max_left_w = math.max(sc(100), header_avail_w - actions_w - sc(12))

        local header_sub = TextWidget:new{
            text = sub_text,
            face = Font:getFace("cfont", 13),
            fgcolor = theme.color_label_dim,
            max_width = max_left_w,
        }

        local header_left = VerticalGroup:new{
            align = "left",
            header_title,
            VerticalSpan:new{ width = sc(2) },
            header_sub,
        }

        local header_left_w = header_left:getSize().w
        local spacer_w = math.max(sc(8), header_avail_w - header_left_w - actions_w)

        local header_row = HorizontalGroup:new{
            header_left,
            HorizontalSpan:new{ width = spacer_w },
            header_actions,
        }

        local header_frame = FrameContainer:new{
            padding = sc(10),
            padding_left = sc(12),
            padding_right = sc(12),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            header_row,
        }

        local header_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        }

        -- Dynamic pagination metrics based on available height
        local header_h = header_frame:getSize().h + sc(2)
        local footer_h = sc(48)
        local top_margin = sc(12)
        local avail_h = sh - header_h - footer_h - top_margin - sc(10)

        local COLS = 3
        local items_per_page

        local content_w = sw - sc(20)
        local content_inner = content_w - sc(16)

        if view_mode == "cover" then
            local grid_gap = sc(8)
            local cell_w = math.floor((content_inner - (grid_gap * (COLS - 1))) / COLS)
            local cover_h = math.floor(cell_w * 1.38)
            local row_h = cover_h + sc(54) + sc(12)
            local num_rows = math.max(1, math.floor((avail_h + sc(12)) / row_h))
            items_per_page = num_rows * COLS
        else
            local list_row_h = sc(68)
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
                face = Font:getFace("cfont", theme.section_header_font_size or 13),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(4),
                padding_left = sc(8),
                bordersize = 0,
                width = content_w,
                background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        local function render_list_loan(loan, loan_idx)
            local days_str = _fmtDays(loan.days_remaining)
            local is_urgent = (loan.days_remaining and loan.days_remaining <= 2)
            local badge_w = _createBadge(days_str, is_urgent)

            local badge_reserve = badge_w and (badge_w:getSize().w + sc(8)) or 0
            local thumb_w_size = sc(38)
            local thumb_h_size = sc(50)
            local thumb_reserve = thumb_w_size + sc(10)
            local text_w = content_inner - badge_reserve - thumb_reserve

            local cached_cover = Covers.getCachedCoverPath(loan)
            local thumb_widget = nil
            if cached_cover then
                thumb_widget = Covers.createCoverImageWidget(cached_cover, thumb_w_size, thumb_h_size)
            end
            if not thumb_widget then
                thumb_widget = Covers.createPlaceholderWidget(thumb_w_size, thumb_h_size, nil)
                UIManager:scheduleIn(loan_idx * 0.2, function()
                    Covers.fetchCover(loan, nil)
                end)
            end

            local title_w = TextWidget:new{
                text = loan.title or "Unknown Title",
                face = Font:getFace("NotoSerif-Regular.ttf", 18),
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
                face = Font:getFace("cfont", 14),
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
                thumb_widget,
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

            table.insert(page_content_vg, row_tap)
            table.insert(page_content_vg, LineWidget:new{
                dimen = Geom:new{ w = content_w, h = sc(1) },
                background = theme.color_bg_dim or Blitbuffer.COLOR_LIGHT_GRAY,
            })
        end

        local function render_cover_grid(page_items, global_start_idx)
            local num_cols = COLS
            local grid_gap = sc(8)
            local avail_grid_w = content_inner
            local cell_w = math.floor((avail_grid_w - (grid_gap * (num_cols - 1))) / num_cols)
            local cover_w = cell_w
            local cover_h = math.floor(cover_w * 1.38)

            local current_row_widgets = {}

            for i, item in ipairs(page_items) do
                local loan = item.loan
                local global_idx = global_start_idx + i
                local cached_cover = Covers.getCachedCoverPath(loan)
                local cover_img = nil

                if cached_cover then
                    cover_img = Covers.createCoverImageWidget(cached_cover, cover_w, cover_h)
                end

                if not cover_img then
                    cover_img = Covers.createPlaceholderWidget(cover_w, cover_h, loan.title)
                    UIManager:scheduleIn(global_idx * 0.3, function()
                        Covers.fetchCover(loan, function(loaded_path)
                            if loaded_path and active_shelf_overlay then
                                UIManager:nextTick(function()
                                    if active_shelf_overlay then
                                        renderShelf(loans, from_cache)
                                    end
                                end)
                            end
                        end)
                    end)
                end

                local cover_frame = FrameContainer:new{
                    bordersize = theme.border_preview or sc(2),
                    color = Blitbuffer.COLOR_BLACK,
                    padding = 0,
                    width = cover_w,
                    height = cover_h,
                    cover_img,
                }

                local title_box = TextBoxWidget:new{
                    text = loan.title or "Unknown Title",
                    face = Font:getFace("NotoSerif-Regular.ttf", 12),
                    bold = true,
                    width = cell_w,
                    alignment = "center",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local days_str = _fmtDays(loan.days_remaining)
                local is_urgent = (loan.days_remaining and loan.days_remaining <= 2)
                local badge_widget = _createBadge(days_str, is_urgent)

                local cell_content = VerticalGroup:new{
                    align = "center",
                    cover_frame,
                    VerticalSpan:new{ width = sc(3) },
                    title_box,
                    VerticalSpan:new{ width = sc(2) },
                    badge_widget or VerticalSpan:new{ width = 0 },
                }

                local cell_tap = makeTapItem(cell_content, function()
                    M.showDownloadConfirm(loan, plugin_dir, function()
                        renderShelf(loans, from_cache)
                    end)
                end)

                table.insert(current_row_widgets, cell_tap)

                if #current_row_widgets == num_cols or i == #page_items then
                    local row_group_items = {}
                    for col_i, cell in ipairs(current_row_widgets) do
                        if col_i > 1 then
                            table.insert(row_group_items, HorizontalSpan:new{ width = grid_gap })
                        end
                        table.insert(row_group_items, cell)
                    end
                    table.insert(page_content_vg, HorizontalGroup:new(row_group_items))
                    table.insert(page_content_vg, VerticalSpan:new{ width = sc(12) })
                    current_row_widgets = {}
                end
            end
        end

        -- Render the current page items
        if #loans == 0 then
            local empty_text = TextBoxWidget:new{
                text = "No active loans found on your Libby shelf.\n\nBorrow a book in the Libby app, then tap ↻ Refresh!",
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
        local body_h = math.max(sc(100), sh - header_h - sc(1) - top_margin - sc(1) - footer_h)

        local page_content_frame = ScrollableContainer:new{
            dimen = Geom:new{ w = sw, h = body_h },
            bordersize = 0,
            padding = 0,
            scroll_bar_width = 0,
            page_content_vg,
        }

        local prev_btn = createButton{
            text = "‹ Prev",
            text_font_size = 14,
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
            text = "Next ›",
            text_font_size = 14,
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
            face = Font:getFace("cfont", 14),
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
            padding = sc(6),
            bordersize = 0,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = sw,
            height = footer_h,
            CenterContainer:new{
                dimen = Geom:new{ w = sw - sc(20), h = footer_h - sc(12) },
                footer_widgets,
            }
        }

        local footer_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
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

    if cached_shelf then
        pcall(Covers.cleanupExpiredCovers, cached_shelf)
        renderShelf(cached_shelf, true)
        -- Silently sync shelf in background
        UIManager:scheduleIn(1, function()
            _runAsyncSilent(
                function() return API.fetchShelf(cfg) end,
                function(result, err)
                    if type(result) == "table" then
                        State.saveShelfCache(result)
                        pcall(Covers.cleanupExpiredCovers, result)
                        if active_shelf_overlay then
                            renderShelf(result, false)
                        end
                    elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                        M._handleAuthExpired(plugin_dir)
                    end
                end
            )
        end)
    else
        _runAsync(
            function() return API.fetchShelf(cfg) end,
            "Loading your Libby shelf…",
            function(result, err)
                if type(result) == "table" then
                    State.saveShelfCache(result)
                    pcall(Covers.cleanupExpiredCovers, result)
                    renderShelf(result, false)
                elseif err == "AUTH_EXPIRED" or result == "AUTH_EXPIRED" then
                    M._handleAuthExpired(plugin_dir)
                else
                    local err_str = err or tostring(result or "Unknown error")
                    M.showCardDialog{
                        title = "Could Not Load Shelf",
                        body_text = "Could not connect to Libby:\n" .. err_str .. "\n\nCheck your Wi-Fi connection.",
                        buttons = {
                            {
                                text = "Retry",
                                is_primary = true,
                                callback = function() M.showShelfBrowser(plugin_dir) end,
                            },
                            { text = "Cancel" }
                        }
                    }
                end
            end
        )
    end
end

-- ---------------------------------------------------------------------------
-- Download Flow (Keeps plugin open)
-- ---------------------------------------------------------------------------

function M.showDownloadConfirm(loan, plugin_dir, after_download_fn)
    local cfg = _loadConfig(plugin_dir)
    local API = require(plugin_path .. "libbee_api")

    local base_dir = (cfg.download_dir and cfg.download_dir ~= "") and cfg.download_dir
                     or API.getDefaultDownloadDir()
    local dest_path = API.getAcsmPath(base_dir, loan)
    local epub_path = dest_path:gsub("%.[Aa][Cc][Ss][Mm]$", ".epub")
    local pdf_path  = dest_path:gsub("%.[Aa][Cc][Ss][Mm]$", ".pdf")

    local existing_book = nil
    local f = io.open(epub_path, "r")
    if f then f:close() existing_book = epub_path end
    if not existing_book then
        f = io.open(pdf_path, "r")
        if f then f:close() existing_book = pdf_path end
    end
    if not existing_book then
        f = io.open(dest_path, "r")
        if f then f:close() existing_book = dest_path end
    end

    if existing_book then
        -- If an .epub/.pdf exists, clean up any leftover .acsm
        if existing_book ~= dest_path then
            pcall(os.remove, dest_path)
        end
        M.showCardDialog{
            title = "Book Already Downloaded",
            body_text = string.format('"%s" is already downloaded:\n\n%s\n\nOpen it now?', loan.title or "Book", existing_book),
            buttons = {
                {
                    text = "Open Book",
                    is_primary = true,
                    callback = function()
                        M._openAcsm(existing_book)
                    end,
                },
                {
                    text = "Close",
                    callback = function()
                        -- Keeps shelf open
                    end
                }
            }
        }
        return
    end

    local days_str = loan.days_remaining and string.format("⏳ %d days remaining on this loan.\n\n", loan.days_remaining) or ""
    local info_text = string.format('"%s"\n%s%sDestination:\n%s\n\nFormat: Adobe EPUB (.acsm)',
        loan.title or "Book",
        loan.author and ("by " .. loan.author .. "\n\n") or "\n",
        days_str,
        dest_path)

    M.showCardDialog{
        title = "Download Loan",
        body_text = info_text,
        buttons = {
            {
                text = "Download",
                is_primary = true,
                callback = function()
                    M._doDownload(loan, dest_path, base_dir, cfg, plugin_dir, after_download_fn)
                end,
            },
            {
                text = "Cancel",
                callback = function()
                    -- Shelf remains open in background
                end,
            }
        }
    }
end

function M._doDownload(loan, dest_path, base_dir, cfg, plugin_dir, after_download_fn)
    local API = require(plugin_path .. "libbee_api")

    local dir_ok, dir_err = API.ensureDownloadDir(base_dir)
    if not dir_ok then
        _toast("Could not create download folder:\n" .. tostring(dir_err), 6)
        return
    end

    _runAsync(
        function()
            return API.downloadACSM(loan, dest_path, cfg)
        end,
        "Downloading " .. string.format('"%s"', loan.title or "ebook") .. "…",
        function(result, err)
            if result == true then
                local State = require(plugin_path .. "libbee_state")
                State.clearShelfCache()

                if after_download_fn then after_download_fn() end

                M.showCardDialog{
                    title = "✓ Downloaded!",
                    body_text = string.format('"%s"\n\nSaved to:\n%s\n\nOpen now with acsm.koplugin?', loan.title or "Book", dest_path),
                    buttons = {
                        {
                            text = "Open Book",
                            is_primary = true,
                            callback = function()
                                M._openAcsm(dest_path)
                            end,
                        },
                        {
                            text = "Done",
                            callback = function()
                                -- Shelf remains open!
                            end,
                        }
                    }
                }
            elseif (err and err:find("AUTH_EXPIRED")) or (type(result) == "string" and result:find("AUTH_EXPIRED")) then
                M._handleAuthExpired(plugin_dir)
            else
                local err_str = err or tostring(result or "Unknown error")
                M.showCardDialog{
                    title = "Download Failed",
                    body_text = "Download failed:\n" .. err_str .. "\n\nIf you see a 403 error, your session may have expired.",
                    buttons = {
                        {
                            text = "Retry",
                            is_primary = true,
                            callback = function()
                                M._doDownload(loan, dest_path, base_dir, cfg, plugin_dir, after_download_fn)
                            end,
                        },
                        {
                            text = "Cancel",
                        }
                    }
                }
            end
        end
    )
end

function M._openAcsm(path)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = (ok_fm and FileManager and FileManager.instance) or
               (ok_r and ReaderUI and ReaderUI.instance) or nil

    if ui then
        if ui.acsm and type(ui.acsm.openFile) == "function" then
            ui.acsm:openFile(path)
            return
        end
        local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
        if ok_fmu and filemanagerutil and filemanagerutil.openFile then
            filemanagerutil.openFile(ui, path, nil, true)
            return
        end
        if type(ui.openFile) == "function" then
            ui:openFile(path)
            return
        end
    end

    local ok2, Event = pcall(require, "ui/event")
    if ok2 then
        UIManager:broadcastEvent(Event:new("SetupShowReader", { file = path }))
    else
        _toast("Saved to:\n" .. path .. "\n\nOpen it from the file browser.", 6)
    end
end

-- ---------------------------------------------------------------------------
-- Auth Expired Handler
-- ---------------------------------------------------------------------------

function M._handleAuthExpired(plugin_dir)
    M.showCardDialog{
        title = "Session Expired",
        body_text = "Your Libby authorization has expired.\n\nPlease re-authenticate to continue downloading.",
        buttons = {
            {
                text = "Re-authenticate",
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
            { text = "Cancel" }
        }
    }
end

-- ---------------------------------------------------------------------------
-- About & Debug Log
-- ---------------------------------------------------------------------------

function M._showDebugLog()
    local path = log.path()
    local fh = io.open(path, "r")
    local content = nil
    if fh then
        fh:seek("end")
        local size = fh:seek()
        local offset = math.max(0, size - 3072)
        fh:seek("set", offset)
        local raw_content = fh:read("*a")
        fh:close()
        if raw_content and raw_content ~= "" then
            if offset > 0 then
                content = "... (truncated)\n" .. raw_content
            else
                content = raw_content
            end
        end
    end

    if not content then
        content = "No log file found yet at:\n" .. path
    end

    M.showCardDialog{
        title = "Libbee Debug Log",
        body_text = content,
        buttons = { { text = "Close", is_primary = true } }
    }
end

function M.showAbout(plugin_dir, on_close_cb)
    plugin_dir = plugin_dir or ""
    local State   = require(plugin_path .. "libbee_state")
    local Updater = require(plugin_path .. "libbee_updater")

    local meta_path = plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if not ok or type(meta) ~= "table" then
        meta = { version = "1.0.0", name = "Libbee", author = "jpautz" }
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(380))

    local ui_font_size = theme.face_label_size or 18
    local title_font_size = theme.title_font_size or 22

    local overlay
    local refresh

    refresh = function()
        if overlay then
            UIManager:close(overlay, "ui")
        end

        -- Title Header (Matching Settings Card style)
        local title_label = TextWidget:new{
            text = "About Libbee",
            face = Font:getFace("NotoSerif-Regular.ttf", title_font_size),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local title_container = FrameContainer:new{
            padding = sc(10),
            bordersize = 0,
            title_label,
        }

        local content_vg = VerticalGroup:new{
            align = "left",
            title_container,
            LineWidget:new{
                dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            }
        }

        -- Helper to create section header (Matching Settings Card style)
        local function create_section_header(title)
            local label = TextWidget:new{
                text = title:upper(),
                face = Font:getFace("cfont", theme.section_header_font_size or 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            return FrameContainer:new{
                padding = sc(5),
                padding_left = sc(8),
                bordersize = 0,
                width = dialog_w - sc(4),
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                label,
            }
        end

        -- Helper to create setting row (Matching Settings Card style)
        local function create_setting_row(left_text, right_widget, callback)
            local frame_padding = sc(10)
            local avail_w = dialog_w - (frame_padding * 2) - sc(4)
            local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or (right_widget.dimen and right_widget.dimen.w) or sc(60)) or 0

            local max_left_w = avail_w - right_w - sc(8)
            if max_left_w < sc(60) then
                max_left_w = sc(60)
            end

            local txt = TextBoxWidget:new{
                text = left_text,
                face = Font:getFace("cfont", ui_font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = max_left_w,
                alignment = "left",
            }

            local left_used_w = (txt.getSize and txt:getSize().w) or (txt.dimen and txt.dimen.w) or max_left_w
            local spacer_w = avail_w - left_used_w - right_w
            if spacer_w < sc(8) then
                spacer_w = sc(8)
            end

            local row_elements = { txt, HorizontalSpan:new{ width = spacer_w } }
            if right_widget then
                table.insert(row_elements, right_widget)
            end

            local frame = FrameContainer:new{
                bordersize = 0,
                padding = frame_padding,
                width = dialog_w - sc(4),
                HorizontalGroup:new(row_elements),
            }

            if not callback then
                return frame
            end

            local item = InputContainer:new{ frame }
            local row_size = (frame.getSize and frame:getSize()) or frame.dimen or { w = dialog_w - sc(4), h = sc(30) }
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
                                w = (dim.w and dim.w > 0 and dim.w) or row_size.w or (dialog_w - sc(4)),
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
        table.insert(content_vg, create_section_header("About"))

        -- Version Row
        local ver_widget = TextWidget:new{
            text = string.format("v%s", meta.version or "1.0.0"),
            face = Font:getFace("cfont", theme.subtext_font_size or 16),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row("Version", ver_widget, nil))

        -- Author Row
        local author_widget = TextWidget:new{
            text = meta.author or "ultimatejimmy",
            face = Font:getFace("cfont", theme.subtext_font_size or 16),
            fgcolor = theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row("Author", author_widget, nil))

        -- SECTION 2: ACCOUNT
        table.insert(content_vg, create_section_header("Account"))

        local is_auth = State.isAuthenticated()
        local auth_status
        local lib_name = nil
        if is_auth then
            lib_name = State.getLibraryName()
            auth_status = "✓ Connected"
        else
            local cfg = _loadConfig(plugin_dir)
            if cfg.bearer_token and cfg.bearer_token ~= "" then
                auth_status = "Manual token"
            else
                auth_status = "✗ Not connected"
            end
        end

        local status_widget = TextWidget:new{
            text = auth_status,
            face = Font:getFace("cfont", theme.subtext_font_size or 16),
            bold = true,
            fgcolor = is_auth and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        table.insert(content_vg, create_setting_row("Status", status_widget, nil))

        if is_auth then
            local cached_loans = State.getShelfCache() or {}
            local seen_libs = {}
            if lib_name and lib_name ~= "" then
                seen_libs[lib_name] = true
                local lib_widget = TextWidget:new{
                    text = lib_name,
                    face = Font:getFace("cfont", theme.subtext_font_size or 16),
                    fgcolor = theme.color_label_dim,
                }
                table.insert(content_vg, create_setting_row("Library", lib_widget, nil))
            end

            for _, l in ipairs(cached_loans) do
                if l.library and l.library ~= "" and not seen_libs[l.library] then
                    seen_libs[l.library] = true
                    local lib_widget = TextWidget:new{
                        text = l.library,
                        face = Font:getFace("cfont", theme.subtext_font_size or 16),
                        fgcolor = theme.color_label_dim,
                    }
                    table.insert(content_vg, create_setting_row("Library", lib_widget, nil))
                end
            end

            -- Link another Libby device (adds library WITHOUT clearing current session)
            table.insert(content_vg, create_setting_row("Link another Libby device", nil, function()
                UIManager:close(overlay, "ui")
                M.showSetupDialog(plugin_dir, function(success)
                    if success then
                        M.showShelfBrowser(plugin_dir)
                    end
                end)
            end))

            -- Re-authenticate / Switch Account (clears existing and re-pairs)
            table.insert(content_vg, create_setting_row("Re-authenticate / Switch device", nil, function()
                UIManager:close(overlay, "ui")
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

            -- Disconnect / Log Out (Interactive)
            table.insert(content_vg, create_setting_row("Disconnect Libby account", nil, function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = "Disconnect Libby account?\n\nYour saved session and cached shelf will be cleared.",
                    ok_text = "Disconnect",
                    cancel_text = "Cancel",
                    ok_callback = function()
                        State.clearChipIdentity()
                        State.clearShelfCache()
                        if active_shelf_overlay then
                            local ov = active_shelf_overlay
                            active_shelf_overlay = nil
                            ov.onClose = nil
                            UIManager:close(ov, "ui")
                        end
                        _toast("Libby account disconnected", 3)
                        refresh()
                    end,
                })
            end))
        else
            -- Connect Libby Account (Interactive)
            table.insert(content_vg, create_setting_row("Connect Libby account", nil, function()
                UIManager:close(overlay, "ui")
                if active_shelf_overlay then
                    local ov = active_shelf_overlay
                    active_shelf_overlay = nil
                    ov.onClose = nil
                    UIManager:close(ov, "ui")
                end
                M.showSetupDialog(plugin_dir, function(success)
                    if success then
                        M.showShelfBrowser(plugin_dir)
                    end
                end)
            end))
        end

        -- SECTION 3: MAINTENANCE
        table.insert(content_vg, create_section_header("Maintenance"))

        -- Check Updates Row (Interactive)
        table.insert(content_vg, create_setting_row("Check for updates", nil, function()
            UIManager:close(overlay, "ui")
            Updater.checkForUpdates(false)
        end))

        -- Debug Logs Row (Interactive)
        table.insert(content_vg, create_setting_row("View debug logs", nil, function()
            UIManager:close(overlay, "ui")
            M._showDebugLog()
        end))

        -- Bottom Divider Line
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) },
            background = Blitbuffer.COLOR_DARK_GRAY,
        })

        -- Close Button at bottom
        local close_btn = createButton{
            text = "Close",
            text_font_size = ui_font_size,
            bold = true,
            bordersize = theme.border_btn or sc(1),
            radius = theme.radius_btn or sc(4),
            width = dialog_w - sc(20),
            height = sc(38),
            callback = function()
                UIManager:close(overlay, "ui")
                if on_close_cb then on_close_cb() end
            end,
        }
        table.insert(content_vg, FrameContainer:new{
            padding = sc(8),
            bordersize = 0,
            width = dialog_w - sc(4),
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w - sc(20), h = sc(38) },
                close_btn,
            }
        })

        -- Build modal card (Matching Settings Card style 1:1)
        local card = FrameContainer:new{
            padding = 0,
            radius = theme.radius_window or 0,
            bordersize = sc(2),
            color = Blitbuffer.COLOR_BLACK,
            background = theme.color_bg or Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            content_vg
        }

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" } } },
            card
        }

        overlay.onClose = function()
            UIManager:close(overlay, "ui")
            if on_close_cb then on_close_cb() end
            return true
        end

        UIManager:show(overlay, "ui")
    end

    refresh()
end

return M
