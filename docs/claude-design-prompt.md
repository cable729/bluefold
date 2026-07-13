# Prompt for Claude — polish or validate a Bluefold theme

Paste the block below into Claude. Attach `theme-contact-sheet.png` (all themes
at a glance) and, optionally, `theme-palettes.json`. Swap the palette in
"The theme to work on" for whichever theme you want reviewed.

---

You are a senior product & visual designer with a strong sense for reading
comfort and color harmony. I'm building **Bluefold**, a native macOS / iPadOS
PDF reader for long sessions with dense math textbooks (Axler, Dummit & Foote,
etc.). It has a themeable design system, and I want you to either **validate**
that one theme looks great or **redesign** it so it looks awesome — while
respecting the hard constraints below.

## What a theme is (read carefully — one part is unusual)

A theme = **16 UI colors + one page-render filter + a light/dark flag**. The
unusual part: the "content" is a *rendered PDF page*, and the theme recolors
the actual page pixels with a filter:

- **Light themes** *multiply* a warm/cool paper tint onto the white page, so the
  paper turns cream / tan / oat while black ink stays black — like reading on
  toned paper. Any color the PDF itself contains (blue theorem boxes, etc.)
  darkens toward that tint.
- **Dark themes** *invert* the page (white paper → dark, black text → light),
  then *screen* a tint over it so the "paper" becomes a deep navy / teal / slate
  instead of pure black, with light text floating on it. The PDF's own colored
  boxes and photos invert too (a blue box becomes a glowing light-blue box on
  dark; a color photo goes to its complement).

So the page background you see is the theme's `contentBackground`, produced by
that filter — it is the single most important surface in the whole app.

## The 16 colors and what each paints

**Chrome (the window frame):** `chromeTop`, `chromeBottom` (titlebar / status-bar
gradient), `chromeBorder` (hairline under it), `stripBackground` (tab strip),
`ink` (chrome text + icons).

**Content & text:** `contentBackground` (the PDF page / letterbox — the tinted
paper), `sidebarBackground`, `sidebarBorder`, `textPrimary` (body + outline),
`textSecondary`, `textMuted` (section labels, counts).

**Accent:** `accent` (the highlight — see sidebar below), `accentSoft`
(translucent accent for selection fills), `linkBox` (recolors the PDF's own
hyperref cross-reference boxes; equals `accent` for every theme except the
Bluefold signature, which uses a warm brown).

**Lozenge details:** `activeCellFill`, `lozengeDivider` (inside the tab chips).

## How the sidebar looks

A quiet left column with the book's **table of contents** as an indented tree.
Most rows are `textPrimary` (or `textMuted` for section labels). The **one
section you're currently reading** stands out: its title is drawn in the
**`accent`** color, sits on a faint `accentSoft` wash, and has a 3px `accent`
bar down its left edge. It should read as "you are here" — clearly highlighted
but never loud enough to fight the page.

## How the PDF tinting looks

The reading surface is the tinted paper (`contentBackground`). On top of it: body
text in the page's own ink (light on dark themes), the PDF's colored theorem
boxes passed through the same filter, and hyperref **link boxes** re-bordered in
`linkBox` (the accent) so cross-references match the theme instead of clashing
red. The whole page should feel like one calm, cohesive material — warm paper on
light themes, a deep even-toned "night paper" on dark themes — never muddy,
never so low-contrast the text strains, never so high-contrast it glares.

## The theme to work on — "Bluefold" (example; swap for your current theme)

```json
{
  "name": "Bluefold", "isDark": true, "pageFilter": "invertTinted #0E2849",
  "colors": {
    "chromeTop": "#14294A", "chromeBottom": "#0E2038", "chromeBorder": "#081524",
    "stripBackground": "#11233E", "ink": "#E3DEDA",
    "contentBackground": "#0E2849", "sidebarBackground": "#11233E",
    "sidebarBorder": "#1B3A5E", "textPrimary": "#EDE9E3",
    "textSecondary": "#CBD6E4", "textMuted": "#6E86A6",
    "accent": "#2E7FE5", "accentSoft": "#2E7FE5 @ 0.26",
    "linkBox": "#D2B090",
    "activeCellFill": "#FFFFFF @ 0.13", "lozengeDivider": "#FFFFFF @ 0.15"
  }
}
```

(`pageFilter` note: `invertTinted #0E2849` means the page is inverted then
screened toward navy `#0E2849`, so white pages become that navy and text goes
light. Light themes use `multiply <hex>` instead.)

## Your task

Pick ONE:

**(a) Validate.** Confirm the theme reads as a cohesive, comfortable, beautiful
long-reading surface. Check specifically: text tiers meet a sensible contrast
target on the tinted paper (aim ≥ 4.5:1 for body); `accent` is legible BOTH as
sidebar-selected text on `sidebarBackground` AND as a link box on
`contentBackground`; chrome, sidebar, and page feel like one family; the
tinted-dark paper is dark enough for light text yet not a flat black. Point out
anything off.

**(b) Redesign.** Propose an improved palette that looks more polished and
distinctive while obeying every constraint above (still a calm reading surface;
accent legible in both roles; dark paper dark-but-tinted, not muddy). Explain
the intent in 2–3 sentences.

Either way, **return all 16 fields as JSON in exactly the shape above** (hex,
with `@ alpha` where translucent) so I can paste it straight back into the app.
Keep the field names identical.
