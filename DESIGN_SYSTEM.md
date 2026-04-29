# Beam Chat — design system

Product-led UI: **neutral cool-gray surfaces** with a **cyan primary** accent (replaceable when brand hex arrives). **DaisyUI** supplies components; **Tailwind CSS v4** drives layout and tokens in `assets/css/app.css`.

## Figma → code workflow (MCP)

1. Publish **color, radius, and typography variables** in your Figma library (use **modes** for light/dark where possible).
2. Share the file URL: `https://www.figma.com/design/{fileKey}/...?node-id=...` (convert `node-id` dashes to `:` for MCP tools).
3. In Cursor, use the **Figma MCP**:
   - `get_variable_defs` — pull named variables; map names to the DaisyUI `--color-*` and `@theme` entries below.
   - `get_design_context` — align spacing, type scale, and component anatomy with HEEx + DaisyUI classes.
4. Update **`assets/css/app.css`** `@plugin "../vendor/daisyui-theme"` blocks (`name: "light"` / `"dark"`) with OKLCH values derived from Figma (keep **contrast** checks below).

Until a file is linked, the themes in `app.css` are the **source of truth**.

## Color palettes (DaisyUI semantic roles)

Tokens are **OKLCH** in `app.css` for perceptual uniformity. Semantic mapping:

| Token | Role |
|--------|------|
| `base-100` | Page / card background |
| `base-200` | Subtle panels, sidebars |
| `base-300` | Borders, dividers |
| `base-content` | Default text & icons on base |
| `primary` | **Brand accent** (CTAs, key links, focus ring) |
| `primary-content` | Text/icons on primary |
| `secondary` | Muted actions, secondary chrome |
| `accent` | Highlights (badges, tertiary emphasis) |
| `neutral` | Strong neutral fills |
| `info` / `success` / `warning` / `error` | System feedback (alerts, form errors) |

### Light theme (default)

- Surfaces: high lightness, low chroma (~260° hue) for a **cool neutral** base.
- **Primary**: ~`oklch(48% 0.14 235)` — cyan-blue; **primary-content** is near-white for contrast on buttons.
- **base-content** ~`oklch(22% …)` on **base-100** ~`oklch(99% …)` targets **≥ 4.5:1** for body text (WCAG 2.2 **1.4.3 Contrast (Minimum)**).

### Dark theme (`data-theme="dark"` on `<html>`)

- Surfaces: low lightness, similar hue family for consistency.
- **Primary** is slightly **lighter/more chromatic** than in light mode so CTAs remain visible on dark bases.
- **base-content** on **base-100** tuned for **≥ 4.5:1** for normal text.

> **Note:** Exact ratios depend on the user agent’s color management. Re-verify in **Firefox Accessibility** or **Chrome DevTools** after token changes.

### Figma variable naming (suggested)

| Figma variable | Maps to |
|----------------|---------|
| `color/surface/default` | `base-100` |
| `color/surface/raised` | `base-200` |
| `color/border/default` | `base-300` |
| `color/text/default` | `base-content` |
| `color/brand/primary` | `primary` |
| `color/brand/on-primary` | `primary-content` |
| `color/semantic/*` | `info`, `success`, `warning`, `error` (+ `-content`) |

## Typography

| Role | Font | Tailwind | Usage |
|------|------|----------|--------|
| **Display** | [Lexend Deca](https://fonts.google.com/specimen/Lexend+Deca) | `font-display` | Marketing headings, auth titles |
| **UI / body** | [Lexend Deca](https://fonts.google.com/specimen/Lexend+Deca) | `font-sans` (default on `body`) | Paragraphs, labels, UI chrome |

Loaded in `root.html.heex` with `display=swap`. Lexend Deca supports weights **400–700** for hierarchy without extra families.

### Type scale (recommended)

| Level | Approx | Usage |
|-------|--------|--------|
| Display | `text-4xl`–`text-5xl` `font-semibold` | Home hero |
| H1 | `text-2xl` `font-display font-semibold` | Auth pages |
| Body | `text-base` / `text-lg` | Descriptions |
| Small | `text-sm` `text-xs` | Meta, footers, hints |

## Spacing, radius, depth

- **Layout**: `max-w-6xl` main column; auth cards `max-w-md` centered.
- **Radius**: DaisyUI `--radius-field` / `--radius-box` set to **0.5rem / 0.75rem** (softer than default Phoenix starter).
- **Depth**: `--depth: 0` and subtle **shadows** on cards (`shadow-xl shadow-base-300/10`) for a flat, modern look.

## Interaction states

| State | Implementation |
|--------|----------------|
| **Hover** | DaisyUI `btn`, `link-hover`, `opacity` on icons |
| **Focus** | **`:focus-visible`** — `outline: 2px solid var(--color-primary)` + offset (`app.css` `@layer base`) — **WCAG 2.4.7** |
| **Active** | Default browser + DaisyUI button states |
| **Disabled** | Use `disabled` on controls; DaisyUI styles `btn-disabled` where applicable |
| **Error** | `alert-error`, `input-error` / `text-error` from DaisyUI + `CoreComponents` |

## Accessibility (WCAG 2.2 — agreed scope)

- **1.4.3 Contrast (Minimum)** — Aim **AA** for normal text and UI components; re-check when Figma colors land.
- **2.4.1 Bypass Blocks** — Skip link (`.skip-link`) to `#main-content`.
- **2.4.7 Focus Visible** — Global `:focus-visible` ring on interactive elements; no removal of outline without replacement.
- **2.3.3 Animation from Interactions** — `@media (prefers-reduced-motion: reduce)` collapses animations/transitions in `app.css`; LiveView spinners use `motion-safe:animate-spin` where applicable.

## Theming behavior

- **`data-theme`** on `<html>`: `light`, `dark`, or omitted (**system** — follows OS `prefers-color-scheme` via DaisyUI `prefersdark` on the dark theme block).
- **Persistence**: `localStorage` key `phx:theme` (`system` clears explicit theme).

## File map

| Area | Location |
|------|-----------|
| Themes & global CSS | `assets/css/app.css` |
| Document shell, fonts | `lib/beam_chat_web/components/layouts/root.html.heex` |
| App chrome (nav, footer, flash host) | `lib/beam_chat_web/components/layouts/app.html.heex` |
| Flash + theme control | `lib/beam_chat_web/components/layouts.ex` |
| Primitives & forms | `lib/beam_chat_web/components/core_components.ex` |
| Marketing home | `lib/beam_chat_web/controllers/page_html/home.html.heex` |
| Auth surfaces | `lib/beam_chat_web/controllers/*_html/*.html.heex` |

