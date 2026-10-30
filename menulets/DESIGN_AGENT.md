# menulets design

Directives for coding agents changing how the menulet's menu looks. The project's other
directives are in [`../AGENT.md`](../AGENT.md).

The menu copies the system Battery menu. These values were measured from it on
2026-10-30, in light and in dark mode, the way "How the colours were checked"
below describes: every line came out identical to Apple's in text value, width
and height.

Each piece of text is one of four kinds, each made by one helper. Add a new
piece of text through the helper of its kind, never with its own font or
colour.

| Kind | Helper | Font | Colour | Examples |
|---|---|---|---|---|
| Title | `makeHeader` | 13pt semibold | `menuTextColor` | Battery |
| Row | `makeRow` (`MenuRowView`) | 13pt regular (`menuTextFont`) | `menuTextColor` | Charge to Full Now, the modes, the app rows, Settings, Battery Settings…, every submenu option |
| Info line | `InfoItem` | 12pt regular (`infoTextFont`) | `secondaryTextColor` | Power Source, Charged to …, Watch: …, No Apps Using Significant Energy, the boost countdown |
| Heading | `sectionHeader` | 12pt semibold | `secondaryTextColor` | Energy Mode, Using Significant Energy, Menu Bar, Colors, Icons |

The colours, measured (text on the glass behind it, 0–255). The glass is what
the backdrop looks like through the menu, so a white backdrop gives a lighter
glass than a black one:

| Colour | Light, white backdrop | Light, black backdrop | Dark, white backdrop | Dark, black backdrop | What it is |
|---|---|---|---|---|---|
| `menuTextColor` | 38 on 254 | 20 on 136 | 242 on 122 | 233 on 32 | black at 85% (light), white at 90% (dark) |
| `secondaryTextColor` | 152 on 254 | 34 on 136 | 198 on 122 | 110 on 32 | `secondaryLabelColor` with vibrancy |

- **The grays are translucent, not a gray.** Apple's info lines and headings
  shift with whatever is behind the glass (in light mode a fixed ~103 below
  it), so they turn bluish over a blue backdrop. No colour at a single opacity
  does that. They are drawn by `VibrantLabel`, which lets the glass blend
  `secondaryLabelColor` in, and that matched all four cases above without a
  number of ours. Don't give them a fixed colour.
- **The rows are translucent too:** black at 85% in light mode, white at 90%
  in dark. Each fits both of its backdrops with the same opacity, which a flat
  gray does not.
- **The menu from Control Center is the dark-mode menu with one exception:**
  its grays are flat white at 60% (`controlCenterSecondaryTextColor`), not
  vibrant. The glass picks light or dark vibrant text from what is behind it,
  whatever the menu's appearance, and Control Center fades in and out behind
  that menu, so vibrant grays there kept changing colour.
  `VibrantLabel.vibrant` switches every gray label for the opening. The rows
  are the dark-mode colour there too.
- **Light text in light mode** (the glass turns its text light over a dark,
  saturated backdrop) was only seen in one screenshot of Apple's menu, over
  blue. Ours was not compared there.
- **The disabled Automatic row** is dimmed (`disabledControlTextColor`) on
  purpose: it only shows the state, and Turn Off sets it.

Spacing, in points:

| Value | Where | Measured as |
|---|---|---|
| 12 | `menuLeftInset`: left of all text, badges and ticks | |
| 3 | `menuTopMargin`: above the title | |
| 26 + 3 | `makeHeader`: title row, plus `below` under it | Power Source at Apple's height |
| 3 | `lineGap` of Power Source and Charged to … | the two lines 35px apart at 2x, as Apple's |
| 9 | `lineGap` of the other info lines | |
| 11% | `menuHoverColor`: the label colour behind a hovered row | |

## How the colours were checked

By measuring, not by eye: two menus that look alike side by side can still be
a different colour or a size apart.

1. **Cover the screen** with a borderless window at `.floating` level, pure
   black or pure white, so the glass of both menus has the same thing behind
   it. A floating window stays under the menus and the menu bar.
2. **Open each menu and capture it.** Post a click at the menu bar item with
   `CGEvent` (move, down, up), wait 2 s for the menu, capture the region with
   `screencapture -x -R<x>,<y>,<w>,<h>`, then post Escape. Do Apple's Battery
   item and ours in one run, so both see the same backdrop. Control Center's
   menu bar does not show up in Accessibility, so find the items' positions
   in a capture of the bar, not with System Events.
3. **Do it over black and over white,** in light mode and in dark mode. Two
   backdrops tell the kinds of colour apart: a colour at one opacity keeps its
   ratio to the glass (black at 85% gives 38 on 254 and 20 on 136), vibrancy
   keeps a difference (152 on 254, 34 on 136 is not one opacity), and a flat
   colour stays the same number on both.
4. **Measure each line,** in a box around it on both captures (the captures
   are at 2x, so a box is in pixels): the glass is the box's median gray, the
   text is the mean of its 12 most extreme pixels (darkest for dark text,
   lightest for light), and the width is the span of the pixels that differ
   from the glass by more than 40% of that. Compare the same string in both
   menus; a different string only shows the colour.
5. **Measure spacing** by the top and bottom of each line's ink, in a column
   left of the text, so it isn't skewed by the badges.

A size difference shows as a width ratio, the same on every line of a kind
(13.5pt rows were 3.3% wider than Apple's 13pt). A weight difference shows as
more ink than the size explains: ink grows with the square of the size, so
size alone gives about 7% more for 3.3% wider, and more than that is weight.
