# Libbee UI Style Guide

This document defines the visual design language, design tokens, and component conventions for the **Libbee** KOReader plugin. Libbee follows the **Storefront Card & Clean Dialog** design system for high legibility, visual polish, and native look-and-feel on e-ink displays (Kindle, Kobo, Android, Linux).

---

## 1. Design Philosophy

- **High Contrast & Clarity:** Pure black borders and typography on white backgrounds, optimized for 16-level grayscale E-ink screens.
- **Consistent Rounded Geometry:** Rounded corners (`sc(4)`) are standard on all modal dialog boxes, card popups, settings submenus, and toast notifications.
- **Proportional Scaling:** All pixel dimensions (radii, borders, padding, gaps) use KOReader's `sc()` (scaling function) to scale accurately across low-DPI (e.g. Kindle Paperwhite 1) and high-DPI displays (300+ PPI).

---

## 2. Design Tokens (`libbee_theme.lua`)

| Token Name | Value | Purpose |
| :--- | :--- | :--- |
| `radius_window` | `sc(4)` | **Standard radius for all dialog boxes, cards, and modal windows** |
| `radius_toast` | `sc(4)` | **Standard radius for toast and progress notification cards** |
| `radius_btn` | `sc(4)` | Standard radius for action buttons |
| `radius_spec_btn`| `sc(8)` | Radius for special highlight buttons |
| `radius_badge` | `sc(10)` | Pill radius for shelf loan counters / status badges |
| `border_window` | `sc(2)` | Border thickness for dialog box & toast cards |
| `border_btn` | `sc(1)` | Border thickness for buttons |
| `border_line_h` | `sc(1)` | Divider line thickness |
| `color_bg` | `COLOR_WHITE` | Background color for cards and dialogs |
| `color_bg_dim` | `COLOR_LIGHT_GRAY` | Section headers and muted container backgrounds |
| `color_border` | `COLOR_BLACK` | Primary border color |
| `face_label_size` | `18` (scaled) | Base UI label font size |
| `title_font_size` | `22` (scaled) | Dialog and window title font size |
| `subtext_font_size`| `16` (scaled) | Subtitle / description / secondary label size |
| `section_header_font_size` | `16` (scaled) | Submenu section header font size |

---

## 3. Dialog Box Specifications

All dialog boxes (including Setup Dialog, Card Dialogs, Settings Submenus, DRM submenus, and Folder Picker) must follow this container pattern:

```lua
local card_padding = sc(12)
local card_border = theme.border_window or sc(2)
local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

local card = FrameContainer:new{
    padding = card_padding,
    radius = theme.radius_window or sc(4),
    bordersize = card_border,
    color = Blitbuffer.COLOR_BLACK,
    background = theme.color_bg or Blitbuffer.COLOR_WHITE,
    width = dialog_w,
    ...
}
```

> **Note on Corner Clipping:** Always ensure outer rounded `FrameContainer` cards have `padding` (e.g. `sc(10)` to `sc(14)`) and inner child widgets use `inner_w`. If `padding = 0`, inner rectangular backgrounds and lines render at `(x + bordersize, y + bordersize)` and overwrite the rounded border's corner pixels.

### Key Dialog Components:
1. **Title Header:** Serif bold title (`NotoSerif-Regular.ttf`, font size `title_font_size`), followed by a 1px divider rule (`LineWidget`).
2. **Body / Content Area:** Left-aligned text (`cfont`, size `face_label_size` or `subtext_font_size`), clear instructions, or structured row elements.
3. **Action Buttons:** Horizontal group of full-width or proportional buttons at the bottom:
   - **Primary Action:** Solid black background (`COLOR_BLACK`), white text (`COLOR_WHITE`), `radius = theme.radius_btn or sc(4)`.
   - **Secondary / Cancel Action:** White background, black border (`sc(1)`), `radius = theme.radius_btn or sc(4)`.

---

## 4. Toast & Progress Notifications

Toasts and background process indicators (ACSM download, update checking, folder creation, cache clear) must use the standard `LibbeeToastWidget` via `UI.showToast(message, timeout, opts)`:

- **Shape:** Rounded rectangle card with `radius = theme.radius_toast or sc(4)`.
- **Border:** `bordersize = theme.border_window or sc(2)` in `COLOR_BLACK`.
- **Background:** `COLOR_WHITE`.
- **Layout:** Horizontal layout with `info.svg` icon (`sc(22)` x `sc(22)`), followed by `HorizontalSpan:new{ width = sc(12) }`, and left-aligned text.
- **Dismissal:** Auto-dismiss on timeout or dismiss on any tap / keypress.

```lua
-- Toast usage across plugin:
local UI = require(plugin_path .. "libbee_ui")
UI.showToast(_("Libbee is up to date (v%s)", version), 3)
```

---

## 5. Submenu Layouts

Settings submenus (Accounts & DRM, Libby Connection, Maintenance & Logs, About) use full-height input overlays centering a card of `dialog_w = math.min(sw - sc(20), sc(380))`:
- **Card Radius:** `theme.radius_window or sc(4)`
- **Section Headers:** Light gray background bar (`COLOR_LIGHT_GRAY`) with uppercase section titles (`section_header_font_size`, bold).
- **Row Items:** 8px padding, tap gesture ranges, left-aligned title with right-aligned status indicator / chevron (`›`).
- **Footer:** Bottom back/close button (`radius = theme.radius_btn or sc(4)`).
