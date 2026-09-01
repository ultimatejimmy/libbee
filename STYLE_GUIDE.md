# Storefront & Libbee Style Guide

This document establishes the UI design tokens, component architecture, and interaction standards for the **Libbee** KOReader plugin, derived from the **Storefront** design system.

---

## 1. Core Principles

1. **Monochrome Clarity on E-Ink**: Every component must look crisp and legible on e-ink Carta and Pearl displays (16 grayscale levels, 1-bit or 8-bit blitbuffers). Avoid mid-gray fills that wash out; prioritize clean black (`Blitbuffer.COLOR_BLACK`), white (`Blitbuffer.COLOR_WHITE`), and defined dark gray lines (`Blitbuffer.COLOR_DARK_GRAY`).
2. **Dynamic Screen Scaling**: All dimensions, paddings, borders, and margins must pass through `sc(value)` (defined as `Device.screen:scaleBySize(value)` or `theme.sc(value)`) to scale proportionally across 6-inch 800×600 e-readers, 300 DPI high-resolution displays, and mobile screens.
3. **Dual Input Support (Touch & Non-Touch)**: Every interface element must be operable via both direct touch/tap gestures and physical 5-way D-pads, hardware buttons, or keyboards.

---

## 2. Design Tokens (`libbee_theme.lua`)

| Token | Type / Value | Description |
| :--- | :--- | :--- |
| `sc(val)` | `function` | Dynamic screen-scaling helper. |
| `border_line_h` | `sc(1)` | Hairline dividers and section rules. |
| `border_btn` | `sc(1)` | Standard button border stroke. |
| `border_window` | `sc(2)` | Outer modal / card border stroke. |
| `border_preview` | `sc(2)` | Book cover thumbnail border stroke. |
| `border_focus` | `sc(3)` | High-contrast focus outline for non-touch navigation. |
| `radius_btn` | `sc(4)` | Standard button corner radius. |
| `radius_window` | `sc(4)` | Modal card corner radius. |
| `radius_toast` | `sc(4)` | Toast notification corner radius. |
| `radius_badge` | `sc(10)` | Status / format badge pill radius. |
| `radius_focus` | `sc(4)` | Focus outline corner radius. |
| `color_bg` | `Blitbuffer.COLOR_WHITE` | Primary container background. |
| `color_bg_dim` | `Blitbuffer.COLOR_LIGHT_GRAY` | Secondary backgrounds and table headers. |
| `color_border` | `Blitbuffer.COLOR_DARK_GRAY` | Subtle structural dividers. |
| `color_label_dim`| `Blitbuffer.Color8(40)` | Muted secondary text and metadata. |
| `color_section_rule`| `Blitbuffer.COLOR_DARK_GRAY`| Section divider rules. |
| `color_focus_border`| `Blitbuffer.COLOR_BLACK` | Non-touch focus ring stroke color. |
| `color_focus_bg` | `Blitbuffer.COLOR_LIGHT_GRAY`| Non-touch focused row background. |
| `gap` | `sc(8)` | Standard widget gap spacing. |

---

## 3. Typography Standards

| Role | Font Face | Base Size | Usage |
| :--- | :--- | :--- | :--- |
| **Title / Header** | `NotoSerif-Regular.ttf` | 20–22 pt | Dialog titles, screen headers, shelf title. |
| **Book Titles** | `NotoSerif-Regular.ttf` | 15–20 pt | Book loan titles in grid and list views. |
| **Body / Labels** | `cfont` (sans-serif) | 16–18 pt | Setting row labels, dialog message text. |
| **Subtext / Meta** | `cfont` (sans-serif) | 13–15 pt | Authors, expiry days, library names, badges. |
| **Section Headers**| `cfont` (bold) | 13–16 pt | Uppercase group headers (e.g. `ACCOUNTS & DRM`). |

---

## 4. Component Patterns

### 4.1 Card Dialogs (`showCardDialog`)
- **Structure**: Title header with divider, optional body widget/text, and a bottom row of action buttons.
- **Button Styling**:
  - **Primary Action** (e.g., *Download*, *Open Shelf*, *OK*): Solid black background (`background = Blitbuffer.COLOR_BLACK`), bold white text (`fgcolor = Blitbuffer.COLOR_WHITE`).
  - **Secondary Action** (e.g., *Cancel*, *Reset*): White background, 1px black border, bold black text.
- **Non-Touch Cycling**: `Left` and `Right` keys move focus between buttons; `Press`/`Enter` activates; `Back` executes dismiss/cancel.

### 4.2 Shelf Browser
- **Grid (Cover) View**: Responsive 3-column grid with book covers, centered multi-line titles, and status badges.
- **List View**: Horizontal rows with cover thumbnails, bold title, author metadata, and right-aligned badges.
- **Pagination**: Dedicated Prev / Next buttons in footer, bound to `Left` / `Right` / `PgUp` / `PgDn` / `PgFwd` / `PgBack` hardware buttons.
- **Header Actions**: Clean Feather SVGs (30×30px) for View Mode, Refresh, Settings, and Close.

### 4.3 Settings & Submenus
- **Section Headers**: Uppercase bold text inside `Blitbuffer.COLOR_LIGHT_GRAY` pill frames.
- **Setting Rows**: Left-aligned primary label with right-aligned status widget or navigation arrow (`›`).
- **Focus Highlighting**: Focused row renders with a light gray background fill or dark selection border.

---

## 5. Non-Touch & Keyboard Interaction Standards

To ensure universal compatibility across classic Kindles (Kindle 2, 3 / Keyboard, 4 NT, DX) and button-only devices:

1. **5-Way D-Pad Mapping**:
   - `Up` / `Down`: Move focus vertically across rows or grid rows.
   - `Left` / `Right`: Move focus across grid columns, dialog buttons, or flip pages.
   - `Press` / `Select` / `Enter`: Activate the selected item.
2. **Direct Number Shortcuts**:
   - Keys `1`–`9` immediately select and open the corresponding item on the active page.
3. **Global Control Keys**:
   - `Back` / `Escape`: Dismiss overlay, navigate up a folder level, or close dialog.
   - `Menu` / `F10`: Open the Libbee Settings menu from the Shelf Browser.
   - `V`: Toggle between Grid and List view.
   - `R`: Refresh shelf from connected Libby libraries.
4. **Visual Focus Indicator**:
   - Must be instantly identifiable on e-ink (minimum 2px solid black border or high-contrast background fill).
