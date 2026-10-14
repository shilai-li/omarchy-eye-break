# Omarchy Eye Break

A minimal, native eye-break reminder for [Omarchy](https://omarchy.org).

Every 20 minutes, look at something 20 feet away for 20 seconds. That is the
whole product.

- **No Electron.** QML running inside the `omarchy-shell` process you are
  already running. Nothing new is launched.
- **No accounts.** No network calls, no telemetry, no sync. One local JSON file.
- **No clutter.** One bar glyph, one panel, one break screen.
- **Keyboard-driven.** Every action has a key, including on the break screen.
- **Themed.** No hardcoded colors or sizes; it repaints itself when you run
  `omarchy theme set`.

```
󰈈 12:34
```

---

## Install

```bash
omarchy plugin add https://github.com/shilai-li/omarchy-eye-break.git --enable
```

Or by hand, from a clone:

```bash
cp -r . ~/.config/omarchy/plugins/shilai_li.eye-break
omarchy-shell shell rescanPlugins
omarchy plugin enable shilai_li.eye-break
```

The widget lands on the right of the bar. Move it with `omarchy bar move`.

> Plugins run unsandboxed inside your shell. Read the code before you enable it.

---

## Uninstall

```bash
omarchy plugin remove shilai_li.eye-break
```

This disables the plugin and removes its installed copy. Your local break
history is kept at `~/.local/state/omarchy/eye-break/state.json`; remove that
file separately only if you also want to erase the history.

---

## The interface

### Bar

One glyph, never swapped. The bar dims it while the timer is off and draws it
in the theme's urgent color while a break is up; the words for the state are in
the tooltip.

| | |
|---|---|
| `󰈈 12:34` | running: time to the next break |
| `󰈈 12:34`, dimmed | paused by you, or paused because you stepped away: the time is frozen |
| `󰈈 00:17`, urgent color | on break: time left to look away |

The tooltip says what the timer is doing, how many breaks you have taken today
and your streak, and what each click does. **Left click** opens the dashboard ·
**right click** pauses · **middle click** takes the break now. On a vertical bar
the countdown stacks under the glyph. With `showCountdown` off the bar is the
glyph alone.

### Dashboard

Laid out like the Studio Effects panel, so the two read as siblings: a header,
one large card for the thing being watched, tiles for what decides whether the
clock runs, capsules that fill for amounts.

![Eye Break dashboard](assets/dashboard.png)

- **Header.** The schedule as a pill (`20 min · 30 s`). A red `BREAK` badge
  while a break is on screen; a grey `PAUSED` or `AWAY` while the timer is off.
- **Countdown card.** Time to the next break, and the cycle progress along its
  bottom edge.
- **Timer and Idle pause.** Two tiles, filled with the accent when on. Clicking
  Timer pauses or resumes.
- **Today.** Breaks per hour over a rolling window ending at the current hour,
  so it still says something at 00:30, with taken, skipped, streak and the
  share you kept. Hidden until there is a break to show.
- **Every** and **Look away for.** Capsules you can drag, step with the arrow
  keys or roll the wheel over. A drag writes once, when you let go.
- **Fullscreen and Strict.** Two more tiles.
- **Break now, Skip, clear history.** Skip is hidden in strict mode.

While the timer is off the panel shrinks to the countdown card, the two tiles
and a note about what resumes it. Nothing else in it does anything then.

| Key | |
|---|---|
| `↑` `↓` (or `k` `j`) | move through the rows |
| `←` `→` (or `h` `l`) | step the capsule under the cursor ± 5 |
| `space` / `enter` | act on the row under the cursor |
| `p` | pause / resume, from any row |
| `s` | skip this cycle |
| `b` | take the break now |
| `+` `-` | interval ± 5 min |
| `[` `]` | break length ± 5 sec |
| `i` | toggle idle pause |
| `f` | toggle pause-in-fullscreen |
| `m` | toggle strict mode |
| `r` | clear the history |
| `tab` / `shift+tab` | walk to the neighbouring bar panel |
| `esc` | close |

### Break screen

Fullscreen on every monitor: a break you can sit out by looking at the other
screen is not a break.

![Eye Break fullscreen break overlay](assets/fullscreen.png)

A red `LOOK AWAY` badge, the countdown, a bar that fills as the break runs, and
two buttons that show their keys: `esc` **Skip** and `space` **+20 s**.

It dismisses itself when the countdown lands; you never have to click anything.
`esc` skips (recorded as a skip), and so does clicking **Skip**. Clicking
**+20 s** adds time; any other click is ignored. With **strict mode** on, the
Skip button is replaced by a note and `esc` does nothing. `space` still adds 20
seconds.

---

## Settings

Editable from **Setup → Bar**, or by hand in the widget's entry under
`bar.layout` in `~/.config/omarchy/shell.json`.

| key | default | |
|---|---|---|
| `intervalMinutes` | `20` | minutes of screen time between breaks (1–180) |
| `breakSeconds` | `20` | how long to look away (5–600) |
| `showCountdown` | `true` | show `mm:ss` in the bar, or just the glyph |
| `pauseWhenIdle` | `true` | stop the clock when you step away |
| `idleGraceSeconds` | `300` | seconds without input before you count as away (10–3600) |
| `pauseInFullscreen` | `false` | don't interrupt a fullscreen window; retried a minute later |
| `strictMode` | `false` | remove the skip key from the break screen |
| `preNotifySeconds` | `0` | seconds of warning as a desktop notification; `0` is off |

Every value is clamped rather than rejected — a hand-edited `0` gives you the
nearest working number, not a broken widget.

```jsonc
{
  "bar": {
    "layout": {
      "right": [
        { "id": "shilai_li.eye-break", "intervalMinutes": 25, "strictMode": true }
      ]
    }
  }
}
```

---

## Command line

```bash
omarchy-shell shilai_li.eye-break toggle       # the dashboard
omarchy-shell shilai_li.eye-break togglePause
omarchy-shell shilai_li.eye-break pause
omarchy-shell shilai_li.eye-break resume
omarchy-shell shilai_li.eye-break breakNow
omarchy-shell shilai_li.eye-break skip
omarchy-shell shilai_li.eye-break reset        # restart the current cycle
omarchy-shell shilai_li.eye-break status       # JSON
```

`status` is stable and meant for scripting. Branch on `status`;
`remainingSeconds` is always the **work cycle**, which keeps elapsing during a
break, and `breakRemainingSeconds` is the break in flight (`0` otherwise):

```json
{
  "status": "running",
  "remainingSeconds": 754,
  "remainingText": "12:34",
  "breakRemainingSeconds": 0,
  "progress": 0.372,
  "intervalMinutes": 20,
  "breakSeconds": 20,
  "paused": false,
  "pausedBy": "",
  "streak": 9,
  "today": { "taken": 14, "skipped": 2, "adherencePercent": 88 }
}
```

A Hyprland bind:

```
bindd = SUPER CTRL, E, Eye break, exec, omarchy-shell shilai_li.eye-break toggle
```

> Note the two different targets. `omarchy-shell shilai_li.eye-break …` talks to
> the plugin and is what you want. `omarchy-shell shell summon shilai_li.eye-break`
> goes through the shell's panel loader and raises the **break screen**, not the
> dashboard.

---

## How it works

The schedule is **derived, never counted**. A bar surface exists once per
monitor, so a `Timer` inside the widget would give a two-monitor desktop two
drifting countdowns and two break screens.

Instead there is one absolute timestamp on disk:

```
~/.local/state/omarchy/eye-break/state.json
```

Every instance watches that file and computes
`remaining = interval − (now − cycleStartedAt − pausedTime)`. A local clock only
drives repaints. Consequences:

- the countdown survives `omarchy-restart-shell`
- every monitor shows the same number
- the break screen writes the outcome, so the bar's countdown restarts the
  instant the overlay comes down

Some behaviour worth knowing:

- **Idle.** Stepping away pauses the clock. An absence as long as a whole work
  cycle also counts as a break taken — if you were gone for twenty minutes, you
  already had your break. Anything shorter only pauses, because input idleness
  cannot tell *away from the desk* from *reading the screen without typing*,
  and reading is exactly the screen time this plugin exists to interrupt. A
  pause *you* asked for is never cleared by coming back from idle.
- **Suspend.** Waking a laptop does not fire a break that came due while the lid
  was shut. A cycle more than five minutes past due is treated as "nobody was
  here" and starts over.
- **Crash.** A break screen that never reports back (the shell was killed under
  it) is settled as a skip a minute later rather than freezing the countdown.
- **History** is capped at seven days and 600 entries. It is the only thing in
  the file that grows.

---

## Development

```bash
omarchy plugin validate .
QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell BarWidget.qml
bash test/model-test.sh
```

`Model.js` holds all the scheduling, statistics and meter math, and is
deliberately Qt- and locale-free so the test suite runs under plain `node` with
no compositor. Anything needing `Qt.formatDateTime`, a theme color, or a QML
type lives in the `.qml` files.

Saving any file under `~/.config/omarchy/plugins/` hot-reloads plugin code, so
the edit loop is: save, look at the bar.

See [AGENTS.md](AGENTS.md) for the full plugin contract, architecture notes and
house style.

## License

MIT. See [LICENSE](LICENSE).
