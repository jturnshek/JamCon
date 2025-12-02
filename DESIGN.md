# JamCon Design Language

## Principles

1. **Minimalist** — Essential elements only. Remove anything that doesn't serve a purpose.
2. **Laser Aesthetic** — Saturated rainbow colors, thin precise lines, no heavy fills.
3. **Native Feel** — Integrates seamlessly with macOS. Uses system fonts and respects appearance modes.

---

## Color Palette

### Rainbow Spectrum

Eight saturated colors forming a complete spectrum. Use sparingly for accents, indicators, and interactive elements.

| Name     | Light Mode | Dark Mode  | Usage                        |
|----------|------------|------------|------------------------------|
| Red      | `#FF3B30`  | `#FF453A`  | Destructive, disconnect, error |
| Orange   | `#FF9500`  | `#FF9F0A`  | Warning, caution             |
| Yellow   | `#FFCC00`  | `#FFD60A`  | Highlight, attention         |
| Green    | `#34C759`  | `#30D158`  | Success, connected, enabled  |
| Cyan     | `#00C7BE`  | `#66D4CF`  | Info, accent                 |
| Blue     | `#007AFF`  | `#0A84FF`  | Primary accent, links        |
| Purple   | `#AF52DE`  | `#BF5AF2`  | Secondary accent             |
| Magenta  | `#FF2D55`  | `#FF375F`  | Emphasis, special            |

### Text & UI Colors

| Role           | Value                           |
|----------------|--------------------------------|
| Primary text   | System `.primary`               |
| Secondary text | System `.secondary`             |
| Tertiary text  | System `.tertiary`              |
| Stroke (light) | `.primary.opacity(0.2)`         |
| Stroke (dark)  | `.primary.opacity(0.4)`         |
| Divider        | `.primary.opacity(0.1)`         |

### Backgrounds

Use system defaults. No custom background colors.

- Light mode: System window background
- Dark mode: System window background

---

## Typography

### Font Family

**SF Pro** (system font) for all text. Native, geometric, highly legible.

### Scale

| Style     | Size  | Weight    | Use                          |
|-----------|-------|-----------|------------------------------|
| Title     | 15pt  | `.medium` | Section headers              |
| Headline  | 13pt  | `.medium` | Subsection headers           |
| Body      | 12pt  | `.regular`| General text                 |
| Caption   | 11pt  | `.regular`| Labels, helper text          |
| Small     | 10pt  | `.regular`| Fine print, metadata         |
| Mono      | 11pt  | SF Mono   | Numbers, values, data        |

### Tracking

Add slight letter-spacing to headings for geometric feel:
- Titles/Headlines: `+0.3pt` tracking

---

## Line Styling

### Stroke Widths

| Name     | Width  | Use                              |
|----------|--------|----------------------------------|
| Hairline | 0.5pt  | Subtle dividers, backgrounds     |
| Thin     | 1pt    | Default borders, outlines        |
| Regular  | 1.5pt  | Emphasis, selected states        |
| Bold     | 2pt    | Strong emphasis, active elements |

### Corner Radius

Prefer sharp geometric edges. Use radius sparingly.

| Size    | Radius | Use                              |
|---------|--------|----------------------------------|
| None    | 0pt    | Default for custom elements      |
| Minimal | 2pt    | Badges, tags, small elements     |
| Small   | 4pt    | Buttons, cards                   |

---

## Iconography

### SF Symbols

- **Weight**: `.light` or `.ultraLight` — matches thin line aesthetic
- **Rendering**: `.hierarchical` for multi-color depth
- **Size**: 12-14pt inline, 16-20pt standalone

### Custom Icons

When needed, follow these rules:
- 1pt stroke weight
- No fills, outline only
- Match SF Symbol optical sizing

---

## Component Patterns

### Buttons

**Primary (Outline)**
```
┌─────────────────┐
│     Label       │  ← 1pt stroke, rainbow or accent color
└─────────────────┘     No fill, 2pt corner radius
```

- Hover: Stroke opacity increases
- Pressed: 10% fill appears
- Disabled: 30% opacity

**Secondary (Ghost)**
- No border, just text
- Hover: Subtle underline

### Badges & Tags

```
┌─────────┐
│ Status  │  ← 1pt stroke, appropriate rainbow color
└─────────┘     No fill, 2pt corner radius
```

- Connected: Green stroke
- Warning: Orange stroke
- Primary: Blue stroke

### Sliders

```
──────────●──────────  ← 2pt track height
          │             Circular thumb, 1pt stroke
          ↓             Optional: rainbow gradient on filled portion
```

### Toggle / Switch

Use native macOS toggle. No customization needed for native feel.

### Section Headers

```
Pointer Controls
────────────────────  ← 0.5pt hairline below, subtle
```

- Use thin underline, not background highlight
- Chevron for expand/collapse

### Dividers

```
────────────────────  ← 0.5pt hairline
                        .primary.opacity(0.1)
```

### Radial Menu

```
      ╱───────╲
    ╱    ↑     ╲
   │  ←     →   │    ← Stroke-based segments, not filled
    ╲    ↓     ╱        Rainbow color per segment
      ╲───────╱         1.5pt stroke, 2pt on selection
                        Glow effect on highlighted segment
```

---

## Spacing

### Base Unit

4pt grid. All spacing should be multiples of 4.

| Name   | Value | Use                    |
|--------|-------|------------------------|
| xxs    | 2pt   | Tight inline spacing   |
| xs     | 4pt   | Icon-to-text gap       |
| sm     | 8pt   | Related elements       |
| md     | 12pt  | Section padding        |
| lg     | 16pt  | Between sections       |
| xl     | 24pt  | Major separations      |

### Component Spacing

- Menu padding: 12pt
- Section gap: 16pt
- Item gap within section: 8pt
- Label-to-control gap: 8pt

---

## Animation

### Duration

- Micro (hover, press): 100ms
- Small (expand, reveal): 200ms
- Medium (transitions): 300ms

### Easing

- Default: `.easeInOut`
- Enter: `.easeOut`
- Exit: `.easeIn`

---

## Dark Mode Considerations

- Rainbow colors automatically adapt (use dark mode variants)
- Strokes become slightly more opaque in dark mode
- Maintain contrast ratios for accessibility
- No custom dark backgrounds — use system defaults

---

## Examples

### Good ✓

- Thin 1pt green stroke badge for "Connected"
- Hairline dividers between settings groups
- SF Symbols at `.light` weight
- Rainbow-colored radial menu segments with stroke only

### Avoid ✗

- Solid filled badges
- Heavy shadows
- Bold/black icon weights
- Thick borders (>2pt)
- Custom background colors
