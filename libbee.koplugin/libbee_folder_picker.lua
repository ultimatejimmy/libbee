local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ok_size, Size = pcall(require, "ui/size")
if not ok_size or not Size then
    Size = { line = { thin = 1, medium = 2, thick = 3 } }
end
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
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
local theme = require(plugin_path .. "libbee_theme")
local log = require(plugin_path .. "libbee_logger")

local function sc(val)
    return (Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local function _showToast(msg, timeout)
    local ok_ui, UI = pcall(require, plugin_path .. "libbee_ui")
    if not ok_ui or not UI then
        ok_ui, UI = pcall(require, "libbee_ui")
    end
    if ok_ui and UI and (UI.showToast or UI._toast) then
        return (UI.showToast or UI._toast)(msg, timeout)
    end
    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_im and InfoMessage then
        local w = InfoMessage:new{ text = msg, timeout = timeout or 2 }
        UIManager:show(w)
        return w
    end
end

local function calcProportionalBtnWidths(button_texts, total_avail_width, gap, font_size, face_name)
    local num_btns = #button_texts
    if num_btns == 0 then return {} end
    if num_btns == 1 then return { total_avail_width } end

    font_size = font_size or 18
    face_name = face_name or "cfont"
    local usable_width = total_avail_width - gap * (num_btns - 1)

    local ideal_widths = {}
    local total_ideal = 0
    local padding_per_btn = sc(16)
    local face = Font:getFace(face_name, font_size)

    for i, text in ipairs(button_texts) do
        local tw = TextWidget:new{ text = text, face = face, bold = true }
        local ideal = (tw.getSize and tw:getSize().w or sc(60)) + padding_per_btn
        ideal_widths[i] = ideal
        total_ideal = total_ideal + ideal
    end

    local widths = {}
    local sum = 0
    for i = 1, num_btns do
        if i == num_btns then
            widths[i] = usable_width - sum
        else
            local w = math.floor(usable_width * (ideal_widths[i] / total_ideal))
            widths[i] = w
            sum = sum + w
        end
    end

    return widths
end

local function createButton(opts)
    opts = opts or {}
    local is_primary = (opts.background == Blitbuffer.COLOR_BLACK) or (opts.primary == true)
    local border_size = opts.bordersize or (theme.border_btn or sc(1))
    local border_color = opts.color or Blitbuffer.COLOR_BLACK
    local radius = opts.radius or (theme.radius_btn or sc(4))

    local face_name = opts.face_name or "cfont"
    local initial_font_size = opts.text_font_size or 18
    local chosen_font_size = initial_font_size
    local btn_w = opts.width
    local btn_h = opts.height or sc(38)

    if btn_w and opts.text and opts.text ~= "" then
        local max_text_w = math.max(10, btn_w - sc(16))
        for sz = initial_font_size, 10, -1 do
            local test_face = Font:getFace(face_name, sz)
            local tw = TextWidget:new{
                text = opts.text,
                face = test_face,
                bold = (opts.bold ~= false),
            }
            if (tw.getSize and tw:getSize().w or 0) <= max_text_w then
                chosen_font_size = sz
                break
            end
            chosen_font_size = sz
        end
    end

    local btn_opts = {
        text = opts.text or "",
        text_font_size = chosen_font_size,
        text_font_bold = (opts.bold ~= false),
        bordersize = border_size,
        border_color = border_color,
        padding = 0,
        radius = radius,
        width = btn_w,
        height = btn_h,
        callback = opts.callback,
    }

    if is_primary then
        btn_opts.background = Blitbuffer.COLOR_BLACK
        btn_opts.text_font_color = Blitbuffer.COLOR_WHITE
    else
        btn_opts.background = nil
        btn_opts.text_font_color = opts.text_font_color or Blitbuffer.COLOR_BLACK
    end

    local btn = Button:new(btn_opts)
    if is_primary and btn.label_widget then
        btn.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end

    return btn
end

local LibbeeFolderPicker = {}

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if ok_lfs and lfs then
        return lfs
    end
    return nil
end

function LibbeeFolderPicker.getParentPath(path)
    if not path or path == "" or path == "/" then
        return nil
    end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if clean == "" or clean == "/" then
        return nil
    end
    local parent = clean:match("^(.-)[/\\]+[^/\\]+$")
    if not parent or parent == "" then
        if clean:match("^/[^/]+$") then
            return "/"
        elseif clean:match("^[a-zA-Z]:$") then
            return nil
        end
        return "/"
    end
    return parent
end

function LibbeeFolderPicker.scanDirectory(path)
    local subdirs = {}
    local book_count = 0
    local lfs = getLfs()

    if not lfs or not lfs.dir then
        return subdirs, book_count
    end

    pcall(function()
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                local full_path = (path == "/" and "/" .. entry) or (path .. "/" .. entry)
                local ok_attr, attr = pcall(lfs.attributes, full_path)
                if ok_attr and attr and attr.mode == "directory" then
                    table.insert(subdirs, {
                        name = entry,
                        path = full_path,
                        mtime = (attr and attr.modification) or 0,
                    })
                elseif ok_attr and attr and attr.mode == "file" then
                    local lower = entry:lower()
                    if lower:match("%.epub$") or lower:match("%.pdf$") or lower:match("%.acsm$") or lower:match("%.mobi$") or lower:match("%.azw3$") or lower:match("%.cbz$") or lower:match("%.cbr$") or lower:match("%.fb2$") then
                        book_count = book_count + 1
                    end
                end
            end
        end
    end)

    table.sort(subdirs, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    return subdirs, book_count
end

function LibbeeFolderPicker.show(options)
    options = options or {}
    local title_text = options.title or _("Select Download Folder")
    local current_path = options.initial_path
    local current_page = 1

    if not current_path or current_path == "" then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/tmp"
    end
    current_path = tostring(current_path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if current_path == "" then
        current_path = "/"
    end

    local lfs = getLfs()
    if lfs and lfs.attributes then
        local ok_attr, attr = pcall(lfs.attributes, current_path)
        if not ok_attr or not attr or attr.mode ~= "directory" then
            -- Try fallback_path (e.g. the user's configured home folder) before datastore
            local fallback = options.fallback_path
            if fallback and fallback ~= "" then
                fallback = tostring(fallback):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
                local ok_fb, fb_attr = pcall(lfs.attributes, fallback)
                if ok_fb and fb_attr and fb_attr.mode == "directory" then
                    current_path = fallback
                else
                    local ok_ds, DataStorage = pcall(require, "datastorage")
                    current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/"
                end
            else
                local ok_ds, DataStorage = pcall(require, "datastorage")
                current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/"
            end
        end
    end

    local on_confirm = options.on_confirm
    local on_cancel = options.on_cancel

    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = math.min(sw - sc(20), sc(460))
    local max_dialog_h = math.min(sh - sc(30), sc(760))

    local overlay
    local refresh

    local function closePicker()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_cancel then
            on_cancel()
        end
    end

    local function confirmPicker()
        local chosen = current_path
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_confirm then
            on_confirm(chosen)
        end
    end

    local function promptNewFolder()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = _("New Folder"),
            description = string.format(_("Create subfolder in '%s':"), current_path),
            input = "",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = _("Create"),
                        is_enter_default = true,
                        callback = function()
                            local folder_name = dialog:getInputText()
                            UIManager:close(dialog)
                            if folder_name and folder_name ~= "" and not folder_name:match("[/\\%:%*%?%\"%<%>%|]") then
                                local new_dir = (current_path == "/" and "/" .. folder_name) or (current_path .. "/" .. folder_name)
                                local lfs_mod = getLfs()
                                if lfs_mod and lfs_mod.mkdir then
                                    local ok_mk = pcall(lfs_mod.mkdir, new_dir)
                                    if ok_mk then
                                        current_path = new_dir
                                        current_page = 1
                                        refresh()
                                        _showToast(string.format(_("Created '%s'"), folder_name), 2)
                                        return
                                    end
                                end
                            end
                            _showToast(_("Failed to create folder."), 2)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        if dialog.onShowKeyboard then
            dialog:onShowKeyboard()
        end
    end

    local function make_row_item(frame, callback)
        local item = InputContainer:new{ frame }
        item.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        return item.dimen or (frame.getSize and frame:getSize()) or Geom:new{ w = dialog_w, h = sc(40) }
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

    refresh = function()
        local ok, err = pcall(function()
            if overlay then
                local ov = overlay
                overlay = nil
                ov.onClose = nil
                UIManager:close(ov, "ui")
            end

            local available_h = sh - sc(24)
            local title_font_size = (available_h >= sc(650)) and 20 or ((available_h >= sc(520)) and 18 or 16)
            local ui_font_size = (available_h >= sc(650)) and 15 or ((available_h >= sc(520)) and 14 or 13)
            local subtext_font_size = (available_h >= sc(650)) and 13 or ((available_h >= sc(520)) and 12 or 11)
            local btn_font_size = (available_h >= sc(650)) and 14 or ((available_h >= sc(520)) and 13 or 12)
            local close_h = (available_h >= sc(650)) and sc(38) or ((available_h >= sc(520)) and sc(34) or sc(30))
            local row_pad_v = (available_h >= sc(650)) and sc(6) or sc(4)

            local subdirs, book_count = LibbeeFolderPicker.scanDirectory(current_path)
            local parent_path = LibbeeFolderPicker.getParentPath(current_path)

            -- Calculate items per page
            local fixed_header_h = sc(130)
            local fixed_footer_h = close_h + sc(50)
            local available_list_h = math.max(sc(180), max_dialog_h - fixed_header_h - fixed_footer_h)
            local row_h = (ui_font_size + subtext_font_size) + (row_pad_v * 2) + sc(14)
            local items_per_page = math.max(4, math.min(7, math.floor((available_list_h - (parent_path and row_h or 0)) / row_h)))

            local total_items = #subdirs
            local total_pages = math.max(1, math.ceil(total_items / items_per_page))
            if current_page > total_pages then current_page = total_pages end
            if current_page < 1 then current_page = 1 end

            local card_padding = sc(10)
            local card_border = theme.border_window or sc(2)
            local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

            -- Title Row
            local title_label = TextWidget:new{
                text = title_text,
                face = Font:getFace("NotoSerif-Regular.ttf", title_font_size) or Font:getFace("cfont", title_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }

            local title_close_btn = Button:new{
                text = "X",
                face = Font:getFace("cfont", title_font_size),
                bordersize = 0,
                padding = sc(4),
                padding_h = sc(8),
                background = Blitbuffer.COLOR_WHITE,
                callback = closePicker,
            }

            local title_left_w = (title_label.getSize and title_label:getSize().w) or sc(150)
            local close_btn_w = (title_close_btn.getSize and title_close_btn:getSize().w) or sc(30)
            local header_avail_w = inner_w

            local title_row = HorizontalGroup:new{
                title_label,
                HorizontalSpan:new{ width = math.max(sc(8), header_avail_w - title_left_w - close_btn_w) },
                title_close_btn,
            }

            local content_vg = VerticalGroup:new{
                align = "left",
                title_row,
                VerticalSpan:new{ width = sc(6) },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = sc(1) },
                    background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
                },
                VerticalSpan:new{ width = sc(6) },
            }

            -- Current Location Header Bar
            local path_display_text = current_path
            local path_label = TextBoxWidget:new{
                text = path_display_text,
                face = Font:getFace("cfont", ui_font_size),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                width = inner_w - sc(16),
            }

            local count_text = string.format(_("%d books found in this folder"), book_count)
            local count_label = TextWidget:new{
                text = count_text,
                face = Font:getFace("cfont", subtext_font_size),
                fgcolor = theme.color_label_dim,
            }

            local path_header_vg = VerticalGroup:new{
                align = "left",
                path_label,
                VerticalSpan:new{ width = sc(2) },
                count_label,
            }

            local path_header_frame = FrameContainer:new{
                padding = sc(6),
                padding_left = sc(8),
                padding_right = sc(8),
                radius = theme.radius_btn or sc(4),
                bordersize = 0,
                width = inner_w,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                path_header_vg,
            }

            table.insert(content_vg, path_header_frame)
            table.insert(content_vg, VerticalSpan:new{ width = sc(4) })

            -- Parent Directory Row (Pinned above folder list if not at root)
            if parent_path then
                local up_title = TextWidget:new{
                    text = _(".. (Parent Folder)"),
                    face = Font:getFace("cfont", ui_font_size),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local up_desc = TextWidget:new{
                    text = parent_path,
                    face = Font:getFace("cfont", subtext_font_size),
                    fgcolor = theme.color_label_dim,
                }

                local up_text_vg = VerticalGroup:new{
                    align = "left",
                    up_title,
                    VerticalSpan:new{ width = sc(1) },
                    up_desc,
                }

                local up_icon = TextWidget:new{
                    text = "<",
                    face = Font:getFace("cfont", ui_font_size + 2),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local up_hg = HorizontalGroup:new{
                    up_icon,
                    HorizontalSpan:new{ width = sc(8) },
                    up_text_vg,
                }

                local up_frame = FrameContainer:new{
                    padding = row_pad_v,
                    padding_left = sc(6),
                    padding_right = sc(6),
                    bordersize = 0,
                    width = inner_w,
                    up_hg,
                }

                table.insert(content_vg, make_row_item(up_frame, function()
                    current_path = parent_path
                    current_page = 1
                    refresh()
                end))

                table.insert(content_vg, LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = Size.line.thin },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end

            -- Paginated Folder List
            if total_items == 0 then
                local empty_label = TextBoxWidget:new{
                    text = _("No subfolders in this directory.\nTap 'Select Folder' below to use it, or '+ New' to create a subfolder."),
                    face = Font:getFace("cfont", ui_font_size),
                    fgcolor = theme.color_label_dim,
                    width = inner_w - sc(20),
                    alignment = "center",
                }
                local empty_frame = FrameContainer:new{
                    padding = sc(24),
                    bordersize = 0,
                    width = inner_w,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w - sc(20), h = sc(120) },
                        empty_label,
                    }
                }
                table.insert(content_vg, empty_frame)
            else
                local start_idx = (current_page - 1) * items_per_page + 1
                local end_idx = math.min(total_items, current_page * items_per_page)

                for i = start_idx, end_idx do
                    local subdir = subdirs[i]
                    local name_w = TextWidget:new{
                        text = subdir.name,
                        face = Font:getFace("cfont", ui_font_size),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }

                    local info_w = TextWidget:new{
                        text = _("Folder"),
                        face = Font:getFace("cfont", subtext_font_size),
                        fgcolor = theme.color_label_dim,
                    }

                    local text_col = VerticalGroup:new{
                        align = "left",
                        name_w,
                        VerticalSpan:new{ width = sc(1) },
                        info_w,
                    }

                    local chevron_w = TextWidget:new{
                        text = ">",
                        face = Font:getFace("cfont", ui_font_size + 2),
                        bold = true,
                        fgcolor = theme.color_label_dim,
                    }

                    local left_w = (text_col.getSize and text_col:getSize().w) or sc(100)
                    local chev_w = (chevron_w.getSize and chevron_w:getSize().w) or sc(16)
                    local avail_row_w = inner_w - sc(16)
                    local span_w = math.max(sc(6), avail_row_w - left_w - chev_w)

                    local row_hg = HorizontalGroup:new{
                        text_col,
                        HorizontalSpan:new{ width = span_w },
                        chevron_w,
                    }

                    local row_frame = FrameContainer:new{
                        padding = row_pad_v,
                        padding_left = sc(6),
                        padding_right = sc(6),
                        bordersize = 0,
                        width = inner_w,
                        row_hg,
                    }

                    table.insert(content_vg, make_row_item(row_frame, function()
                        current_path = subdir.path
                        current_page = 1
                        refresh()
                    end))

                    table.insert(content_vg, LineWidget:new{
                        dimen = Geom:new{ w = inner_w, h = Size.line.thin },
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                    })
                end
            end

            -- Pagination Controls (When more than 1 page exists)
            if total_pages > 1 then
                local is_prev_active = (current_page > 1)
                local is_next_active = (current_page < total_pages)
                local pag_btn_w = sc(48)

                local prev_btn = Button:new{
                    text = "<",
                    text_font_size = 18,
                    bold = true,
                    bordersize = sc(1),
                    color = is_prev_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
                    radius = sc(3),
                    padding = sc(3),
                    width = pag_btn_w,
                    background = is_prev_active and Blitbuffer.COLOR_WHITE or Blitbuffer.Color8(240),
                    text_font_color = is_prev_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(160),
                    callback = function()
                        if current_page > 1 then
                            current_page = current_page - 1
                            refresh()
                        end
                    end,
                }

                local page_text = TextWidget:new{
                    text = string.format(_("Page %d of %d"), current_page, total_pages),
                    face = Font:getFace("cfont", 14),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }

                local next_btn = Button:new{
                    text = ">",
                    text_font_size = 18,
                    bold = true,
                    bordersize = sc(1),
                    color = is_next_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
                    radius = sc(3),
                    padding = sc(3),
                    width = pag_btn_w,
                    background = is_next_active and Blitbuffer.COLOR_WHITE or Blitbuffer.Color8(240),
                    text_font_color = is_next_active and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(160),
                    callback = function()
                        if current_page < total_pages then
                            current_page = current_page + 1
                            refresh()
                        end
                    end,
                }

                local pag_hg = HorizontalGroup:new{
                    prev_btn,
                    HorizontalSpan:new{ width = sc(16) },
                    page_text,
                    HorizontalSpan:new{ width = sc(16) },
                    next_btn,
                }

                local pag_frame = FrameContainer:new{
                    padding = sc(6),
                    bordersize = 0,
                    width = inner_w,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w, h = sc(32) },
                        pag_hg,
                    }
                }
                table.insert(content_vg, pag_frame)
            end

            -- Bottom Toolbar (Cancel, + New Folder, Select Folder)
            table.insert(content_vg, VerticalSpan:new{ width = sc(4) })
            table.insert(content_vg, LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_DARK_GRAY,
            })
            table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

            local btn_gap = sc(8)
            local total_btns_w = inner_w
            local cancel_str = _("Cancel")
            local new_folder_str = _("+ New")
            local select_str = _("Select Folder")

            local btn_widths = calcProportionalBtnWidths(
                { cancel_str, new_folder_str, select_str },
                total_btns_w,
                btn_gap,
                btn_font_size,
                "cfont"
            )

            local cancel_btn = createButton{
                text = cancel_str,
                text_font_size = btn_font_size,
                bold = true,
                bordersize = theme.border_btn or sc(1),
                radius = theme.radius_btn or sc(4),
                width = btn_widths[1],
                height = close_h,
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = closePicker,
            }

            local new_btn = createButton{
                text = new_folder_str,
                text_font_size = btn_font_size,
                bold = true,
                bordersize = theme.border_btn or sc(1),
                radius = theme.radius_btn or sc(4),
                width = btn_widths[2],
                height = close_h,
                background = Blitbuffer.COLOR_WHITE,
                text_font_color = Blitbuffer.COLOR_BLACK,
                callback = promptNewFolder,
            }

            local select_btn = createButton{
                text = select_str,
                text_font_size = btn_font_size,
                bold = true,
                bordersize = theme.border_btn or sc(1),
                radius = theme.radius_btn or sc(4),
                width = btn_widths[3],
                height = close_h,
                background = Blitbuffer.COLOR_BLACK,
                text_font_color = Blitbuffer.COLOR_WHITE,
                callback = confirmPicker,
            }

            local btn_row = FrameContainer:new{
                padding = 0,
                bordersize = 0,
                width = inner_w,
                CenterContainer:new{
                    dimen = Geom:new{ w = total_btns_w, h = close_h },
                    HorizontalGroup:new{
                        cancel_btn,
                        HorizontalSpan:new{ width = btn_gap },
                        new_btn,
                        HorizontalSpan:new{ width = btn_gap },
                        select_btn,
                    }
                }
            }
            table.insert(content_vg, btn_row)

            local card = FrameContainer:new{
                padding = card_padding,
                radius = theme.radius_window or sc(4),
                bordersize = card_border,
                color = Blitbuffer.COLOR_BLACK,
                background = theme.color_bg or Blitbuffer.COLOR_WHITE,
                width = dialog_w,
                content_vg,
            }

            local key_events = {
                Close = { { "Back" } },
                NextPage = {
                    { "Right" },
                    { "PageDown" },
                    { "Down" },
                },
                PrevPage = {
                    { "Left" },
                    { "PageUp" },
                    { "Up" },
                },
            }

            local Device_input = Device.input
            if Device_input and Device_input.group then
                if Device_input.group.PgFwd then
                    table.insert(key_events.NextPage, { Device_input.group.PgFwd })
                end
                if Device_input.group.PgBack then
                    table.insert(key_events.PrevPage, { Device_input.group.PgBack })
                end
                if Device_input.group.Back then
                    table.insert(key_events.Close, { Device_input.group.Back })
                end
            end

            overlay = InputContainer:new{
                align = "center",
                vertical_align = "center",
                dimen = Geom:new{ w = sw, h = sh },
                key_events = key_events,
                ges_events = {
                    Swipe = {
                        GestureRange:new{
                            ges = "swipe",
                            range = function() return Geom:new{ w = sw, h = sh } end,
                        }
                    }
                },
                card,
            }

            overlay.onNextPage = function()
                if current_page < total_pages then
                    current_page = current_page + 1
                    refresh()
                    return true
                end
            end

            overlay.onPrevPage = function()
                if current_page > 1 then
                    current_page = current_page - 1
                    refresh()
                    return true
                end
            end

            overlay.onSwipe = function(self, arg, ges)
                if ges and (ges.direction == "west" or ges.direction == "south") then
                    if current_page < total_pages then
                        current_page = current_page + 1
                        refresh()
                        return true
                    end
                elseif ges and (ges.direction == "east" or ges.direction == "north") then
                    if current_page > 1 then
                        current_page = current_page - 1
                        refresh()
                        return true
                    end
                end
            end

            overlay.onClose = function()
                if parent_path then
                    current_path = parent_path
                    current_page = 1
                    refresh()
                else
                    closePicker()
                end
                return true
            end

            UIManager:show(overlay, "ui")
        end)
        if not ok then
            log.err("LibbeeFolderPicker refresh error: " .. tostring(err))
            if on_cancel then
                on_cancel()
            end
        end
    end

    refresh()
end

return LibbeeFolderPicker
