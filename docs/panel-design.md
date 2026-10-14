# Eye Break: design

Redesign of the dashboard, the bar glyph and the break screen against `~/Documents/omarchy-plugin-design-style.md`,
using the Studio Effects panel (`~/.config/omarchy/plugins/shilai_li.studio-effects/`)
as the reference implementation. The pieces here (`Disc`, `Pill`, `PowerTile`,
`Capsule`, `KeyHint`, `cardRadius`) are the same ones, with the same tokens.
Logic is unchanged: `Model.js` scheduling, the idle witnesses and the state
file are not touched.

## What was wrong with the old panel

- Three btop-style boxes with block-glyph meters and sparklines. The shell's
  own panels use cards, tiles, sliders and switches, so this one looked like a
  terminal program placed in the bar.
- The timer, which is the one thing that is on or off, was a text row inside a
  box. It had no shape of its own.
- Every setting was a row in one long column, and the settings stayed visible
  while the timer was paused, so the panel never said "this is off".
- The accent colour was on the sparkline and the frame. It was not on "on".
- Arrow keys changed the interval, so the keyboard could not walk the panel.
- Strict mode could be defeated from the panel: "s" skipped a break that the
  overlay refused to skip.

## Shapes (style guide §1)

| Control | Shape | Why |
|---|---|---|
| The countdown | One large card | It is the thing being watched, like the preview in Studio Effects. |
| Timer, Idle pause, Fullscreen, Strict | Tiles with a round disc, filled with the accent when on | They decide whether the clock runs or a break may interrupt. |
| Interval, break length | Capsules that fill | Amounts |
| Break now, Skip, clear history | Buttons in one row | Actions, not state |
| Today's breaks per hour | Small columns, filled | An amount over time, drawn as a length |

## Layout, top to bottom (§3, §4)

1. **Header.** Eye glyph, title, and the schedule as a pill (`20 min · 30 s`).
   A red `BREAK` badge appears beside it only while a break is on screen (§2: a
   capturing state gets a red badge in the header). While the timer is off the
   pill is replaced by a grey `PAUSED` or `AWAY`.
2. **Countdown card.** 16:9, like the preview it stands in for. Label, the one
   big number, a caption, and the cycle progress along the bottom. During a
   break the label, number and progress turn urgent. Nothing is drawn over the
   number but its own words.
3. **Timer and Idle pause.** Two tiles side by side. Both are lit with the
   accent when on.
4. **Today card.** Hourly columns, "last break" age, and four numbers: taken,
   skipped, streak, kept. Hidden until there is at least one break to show, so
   an empty chart does not read as a working one (§6). Empty hours keep a stub
   so the span still reads as a span.
5. **Schedule.** `Every` and `Look away for`, as capsules.
6. **Fullscreen and Strict.** Two more tiles.
7. **Actions.** Break now, Skip, and a clear-history icon button. Skip is
   hidden in strict mode and the row divides by one fewer.
8. **Key chips.** Under a separator.

The panel is 380 wide, the width the shell's own settings panels use (audio,
bluetooth, network, power, monitor). Studio Effects is 360, so the two differ
by a little when Tab walks between them.

## Only what applies (§6)

When the timer is off, paused by hand or away, the panel shrinks to the
countdown card, the two tiles and a note. The card shows a resume disc, says
why ("Timer paused" or "You stepped away") and how much of the cycle is left.
The note says what resumes it: a manual pause is never cleared by coming back
to the keyboard, an idle pause clears itself. The Today card, sliders,
Fullscreen, Strict and actions are hidden, because none of them change
anything while the clock is stopped.

*Judgment call:* this hides the settings while paused, so you cannot change
the interval from a paused panel. The shell.json entry still works.

## Keyboard (§5)

- `↑` `↓` / `j` `k`: move the cursor through the rows in the order they are
  drawn: timer, idle pause, every, look away for, fullscreen, strict,
  break now, skip, clear.
- `←` `→` / `h` `l`: step the capsule under the cursor.
- `enter` / `space`: act on the row under the cursor.
- `p`: pause or resume, from any row.
- Letter shortcuts stay: `i` idle, `f` fullscreen, `m` strict, `s` skip,
  `b` break now, `r` clear history, `+` `-` interval, `[` `]` break length.
- `esc` closes.

The mouse moves the same cursor, so there is one highlight on screen. Hidden
rows are not walked, so the cursor cannot land on a control that is not there.
`x` is reserved by the key catcher, so it is not used.

Dragging a capsule draws where the pointer is and writes once, on release. A
write goes to shell.json, and a file written on every step of a drag would
reload the plugin under the pointer.

## Colour (§7, §8)

- The accent means "on". It fills a tile's disc and the progress bar while the
  timer runs.
- The urgent colour means "capturing". It colours the break badge, label,
  number and progress.
- Captions use `Commons.Color.muted`, so they recede behind the controls.
- Cards are a tint of the text colour, not a colour of their own. A glyph on
  an accent fill is cut out in the popup background.
- Every colour comes from `Commons.Color` or from `Style` helpers. No hex, no
  raw pixel sizes. Corners follow the theme: `cardRadius` is zero on a theme
  with square corners.

## Judgment calls

- **Fullscreen and Strict are tiles, not switches.** The style guide (§1) says
  on/off settings are switches, and the Studio Effects panel draws Framing as
  a switch row. The design canvas for this plugin drew them as tiles, and with
  Timer and Idle pause that gives a consistent two-by-two. Easy to flip to
  switch rows in a grouped card if you want the guide to win.
- **"Idle pause", not "Pause when away".** The longer label is cut off in a
  tile this wide.
- **No "Away after" or "Warn before" sliders.** The host has setters for the
  interval, break length and the three flags only. `idleGraceSeconds` shows in
  the tile's status text.

## Bar glyph (§8)

One glyph that never changes. It used to swap between two icons on pause and
idle and warm toward the urgent color as a break came due. Now the bar does the
state work it already does for every widget: `dimmed` draws it at reduced
opacity while the timer is off, and the bar's urgent color marks the one
state that captures the display, a break in progress. The countdown stays as
the label, frozen while paused and counting the break's own time while one is
up. The words ("Eye breaks paused", "Paused while you are away") moved to the
tooltip, which also gains today's taken count, the streak and what each click
does.

The urgency ramp is gone: it added a fourth color state to a bar that is meant
to stay quiet. `Model.urgency` is still tested but no longer used.

## Break screen

The same tokens and shapes as the dashboard, at screen size, on the same dense
scrim as before. A red `LOOK AWAY` badge, the countdown, a capsule that fills
in the urgent color, the caption, and two buttons that show their keys:
`esc` Skip and `space` +20 s. Strict mode replaces Skip with a note and keeps
+20 s. The old block-glyph meter and the plain-text key hint are gone.

*Judgment call:* the two buttons can be clicked. The surface still swallows
every other click, because a stray click on something that just covered your
work should not count as done looking away, but pressing a labelled button is
not a stray click. Easy to take back if you want the screen keyboard-only.

## Not changed

- `Model.js` scheduling and the idle witnesses. The `sparkline`, `repeat`,
  `meterFilledCells` and `urgency` helpers are no longer used by any QML but
  are still tested, so they stay until you say to remove them.
- The idle-pause work in `BarWidget.qml`, `Model.js` and `test/model-test.js`.
- Interval and break defaults (AGENTS.md: ask first).
- Any new surface, kind or animation (style guide §8).
