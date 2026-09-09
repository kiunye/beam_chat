# Beam Chat — Civic Vanguard Design System

## Brand Identity

A modern, institutional design system for Beacon Chat — clear, data-dense, and mission-critical. Tailored for county-level public administration, inter-departmental operations, and citizen service delivery.

**Tone:** Utilitarian, precise, authoritative without being bureaucratic.

**Key Colors:**
- **Primary (Emerald Green):** `#059669` — actions, focus states, verified markers
- **Secondary (Dark Navy):** `#0f172a` — sidebar rail, navigation, structural elements
- **Tertiary (Amber):** `#d97706` — alerts, warnings, pending status

## Color Palettes

### Light Theme (default)

| Token | Value | Usage |
|-------|-------|-------|
| `base-100` | `#f8f9ff` | Page background |
| `base-200` | `#eff4ff` | Panels, cards |
| `base-300` | `#d5e3fd` | Borders, dividers |
| `base-content` | `#0d1c2f` | Primary text |
| `primary` | `#059669` | Primary buttons, links, CTAs |
| `primary-content` | `#ffffff` | Text on primary |
| `secondary` | `#0f172a` | Sidebar rail |
| `accent` | `#d97706` | Alerts, warnings |
| `neutral` | `#6b7280` | Muted UI elements |

### Dark Theme

| Token | Value | Usage |
|-------|-------|-------|
| `base-100` | `#0f172a` | Page background |
| `base-200` | `#1e293b` | Cards, panels |
| `base-300` | `#334155` | Borders |
| `base-content` | `#e2e8f0` | Primary text |
| `primary` | `#10b981` | Primary buttons (lighter for contrast) |
| `primary-content` | `#0f172a` | Text on primary |
| `secondary` | `#0f172a` | Sidebar rail |
| `accent` | `#fbbf24` | Alerts |
| `neutral` | `#6b7280` | Disabled UI |

## Typography

| Role | Font | Usage |
|------|------|-------|
| **Display** | [Inter](https://fonts.google.com/specimen/Inter) | Page headers |
| **UI / body** | [Inter](https://fonts.google.com/specimen/Inter) | All other text |

Loaded in `root.html.heex` with `display=swap`. Inter supports weights **400–700** for full hierarchy.

### Type Scale

| Level | Classes | Usage |
|-------|---------|-------|
| Display | `text-3xl` `font-bold` | Main headers |
| H1 | `text-2xl` `font-semibold` | Page titles |
| Body | `text-base` | Content |
| Small | `text-sm` `text-xs` | Labels, hints |

## Spacing

Base: 8px grid. Layering based on this:

- **Base padding:** `p-4` (1rem)
- **Element spacing:** `gap-2`, `gap-3`, `gap-4` based on content density
- **Container max-width:** `max-w-6xl` centered (main canvas)

## Layout

### Multi-Pane Layout Model

```
┌─────────────────────────────────────────────┐
│                  Header                     │
├──────┬─────────────────────┬───────────────┤
│Side  │   Main Canvas       │ Inspector     │
│rail  │                     │ Drawer        │
│4.5rem│  Fluid 1fr         │ 20-24rem      │
└──────┴─────────────────────┴───────────────┘
```

- **Sidebar Rail:** Dark navigation (`w-72`), services, tenant switcher
- **Main Canvas:** Primary workspace, fluid
- **Inspector Drawer:** Right-hand panel for details, modal on mobile

### Responsive

- **Desktop:** Full 3-pane
- **Tablet:** Sidebar → overlay, drawer → modal
- **Mobile:** Single column, full-width elements

## Components

### Buttons

| Variant | Classes | Usage |
|---------|---------|-------|
| Primary | `btn btn-primary` | Main actions |
| Secondary | `btn btn-secondary` | Dark nav/footer |
| Outline | `btn btn-outline` | Secondary actions |
| Ghost | `btn btn-ghost` | Links, minimal |

### Cards

- Border: `border-base-300`
- Background: `bg-base-100` or `base-200` for subtle panels
- Shadow: `shadow-sm` on hover

### Message Bubbles

- **Inbound:** `bg-base-200` with `border-primary` left accent
- **Outbound:** `bg-secondary` with `text-secondary-content`

### Forms

- Input height: `h-auto` min-3rem content area
- Labels: `text-sm` `font-medium`
- Error: `text-error` with inline icon

### Tables

- Headers: `bg-base-100` `font-semibold` `uppercase text-xs`
- Rows: alternating `bg-base-100`/`base-200` on hover
- Numeric: right-aligned, tabular-nums

## Accessibility

- **1.4.3 Contrast:** ≥ 4.5:1 for body text
- **2.4.1 Bypass:** Skip link to `#main-content`
- **2.4.7 Focus:** `focus-visible` ring on interactive
- **2.3.3 Motion:** `prefers-reduced-motion` media query

## File Map

| Area | Location |
|------|-----------|
| Themes & CSS | `assets/css/app.css` |
| Document shell, fonts | `lib/beam_chat_web/components/layouts/root.html.heex` |
| App chrome (layout) | `lib/beam_chat_web/components/layouts/app.html.heex` |
| Layout components | `lib/beam_chat_web/components/layouts.ex` |
| Core components | `lib/beam_chat_web/components/core_components.ex` |
| Page content | `lib/beam_chat_web/live/*_live.ex` |