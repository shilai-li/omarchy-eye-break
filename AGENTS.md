# AGENTS.md — omarchy-eye-break

Maintenance notes for anyone (agent or human) editing this repo. The plugin is
built and working; this file covers what is *not* obvious from the code.
User-facing docs — install, keys, settings, IPC, screenshots — live in
`README.md`. Don't duplicate them here.

## What it is

**Omarchy Eye Break** (`shilai_li.eye-break`) — a 20-20-20 eye-break reminder
that is QML running inside the already-running `omarchy-shell` Quickshell
process. Two kinds: `bar-widget` + `overlay`.

Non-negotiables:

- **No Electron, no second Quickshell, no bundled runtime.**
- **No accounts, no network, no telemetry.** State is one local JSON file.
- **No clutter.** One bar glyph, one panel, one break overlay.
- **Keyboard-driven.** Every action has a key; the mouse is optional.
- **Themed, never styled.** Zero hex literals, zero raw pixel sizes — only
  `Color.*` and `Style.*`, so `omarchy theme set` repaints the plugin.
- **Minimal is the feature.** Ask before adding a surface, a kind, or changing
  the interval defaults.

## Layout

```
manifest.json      two kinds; barWidget.schema mirrors every setting
BarWidget.qml      bar glyph + countdown; owns state, IPC, Panel loader
Panel.qml          btop-style dashboard (loaded via Loader, NOT a declared kind)
Break.qml          fullscreen overlay, kind "overlay"
Model.js           pure logic: schedule, transitions, stats, string builders
test/model-test.sh unit tests for Model.js — plain node, no compositor
```

`Model.js` stays **Qt- and locale-free** so it runs under `node`. Anything
needing `Qt.formatDateTime`, `Qt.locale()` or a QML type belongs in the `.qml`.
Add a test alongside any logic you add there.

## Ground truth — read it, don't guess

| What | Path |
|---|---|
| Shell source / UI kit / theme singletons | `/usr/share/omarchy/shell/{,Ui/,Commons/}` |
| Plugin contract + IPC table | `/usr/share/omarchy/shell/README.md` |
| Bar host (`bar.*` API) | `/usr/share/omarchy/shell/plugins/bar/Bar.qml` |
| Closest structural reference | `~/.config/omarchy/plugins/shilai_li.clock/` |
| Overlay reference | `shell/plugins/reminders/ReminderFlow.qml` |
| `IdleMonitor` usage | `shell/plugins/services/idle/Service.qml` |
| Installed copy / user config | `~/.config/omarchy/plugins/<id>/`, `~/.config/omarchy/shell.json` |

## Architecture invariants

**Time is derived, never counted.** A bar surface is instantiated once per
monitor, so a per-instance `Timer` mutating state would give a two-monitor user
two drifting countdowns. The single source of truth is
`~/.local/state/omarchy/eye-break/state.json`:

```json
{ "cycleStartedAt": 0, "pausedAt": 0, "pausedBy": "", "pausedAccumMs": 0,
  "breakStartedAt": 0, "history": [ { "at": 0, "outcome": "taken" } ] }
```

Every instance reads it via `FileView { watchChanges: true; atomicWrites: true }`
and computes `remaining = intervalMs - (now - cycleStartedAt - pausedAccumMs)`.
`SystemClock` only drives repaints; it never advances state. Any instance may
write — the file change fans out for free. Consequences to preserve: a shell
restart does not reset the countdown, and two monitors always agree.

**One writer advances the cycle automatically**, elected with no coordination:
`amWriter()` takes `bar.moduleWidgets(moduleName)[0]`, which every instance
resolves identically. Without this, two monitors raise two break screens.

**`pausedBy` distinguishes the two pause sources.** A manual pause outranks an
idle one and is never cleared by returning to the keyboard.

**Idle credit needs a whole interval.** Input idleness can't tell "away from
the desk" from "reading without typing", and reading is exactly the screen time
this plugin interrupts. An earlier version credited any idle span longer than
`breakSeconds`; since idle is only *reported* after `idleGraceSeconds`, every
detected idle qualified and the reminder never fired. `idleGraceSeconds`
defaults to 300 for the same reason. Do not lower either threshold.

**Never charge the user for the shell's problems.** Only two things write
`"skipped"`: the user dismissing a break screen they were shown, and an overlay
that was shown then vanished. A break that could not be *raised* (`summon`
false during a hot reload, no shell handle) restarts the cycle and records
nothing. Adherence is a claim about the user's habits.

**Degrade to a working timer.** Missing state file, unreadable JSON, no
Hyprland, no `IdleMonitor` → defaults and keep running, never a broken widget.
`try/catch` every `JSON.parse` and keep the previous value on failure.

**Bar-widget shape contract.** `Bar.findPanelWidget` routes `summon`/`hide`/
`toggle` by looking for `opened`, `open()`, `close()`, `toggle()`,
`closeForPopoutSwitch()` and `popoutSwitchClosing` on the widget **root** — all
forward to the loaded panel. The panel is injected with `bar`, `settings`,
`anchorItem`, `hostWidget`; `KeyboardPanel.owner` must be `hostWidget || root`,
because the bar identifies panels by the widget in its slot.

**`bar` is a facade, not the Bar.** What gets injected is a `PluginBarApi`
(`shell/Ui/PluginBarApi.qml`): presentation state mirrored as plain properties,
operations delegated through scoped callbacks. First-party panels get the real
`Bar.qml` and can write its properties; a plugin cannot. Anything shared and
mutable is exposed there **readonly** with a `setX()` beside it —
`centerHoverRevealSuppressed` / `setCenterHoverRevealSuppressed()` is the one
this plugin touches. Assigning to a readonly QML property throws a `TypeError`
rather than failing quietly, and the throw takes out the rest of the calling
function, so **call the setter and feature-test it with `typeof … ===
"function"`**, never `"name" in bar` — the `in` check passes on a readonly
property and tells you nothing.

**Closing may not depend on anything.** `close()` hides first and does the rest
after. The panel is a full-screen layer-shell surface holding keyboard focus:
anything that throws ahead of `controller.hide()` strands the user behind a
surface that eats every key and click, including the escape and the
outside-click that would have dismissed it, and the bar reads as frozen.
Omarchy 4.0.3 turned `centerHoverRevealSuppressed` readonly and did exactly
that. Order the function so the release is unconditional.

**Two IPC targets, two meanings.** Declaring an `overlay` kind makes
`shell.isBarWidgetPanelPlugin` false, so shell routing goes to the panel loader:

- `omarchy-shell shilai_li.eye-break toggle` → our own target → the **dashboard**
- `omarchy-shell shell summon shilai_li.eye-break '{}'` → the **break screen**

`status` returns JSON and is a documented public surface — keep it stable.

## Style rules

| Do | Don't |
|---|---|
| `Color.foreground/.accent/.urgent/.popups.*` | any hex literal |
| `Style.space(12)`, `Style.font.caption…displayLarge` | raw pixels, `pixelSize: 14` |
| `Style.cornerRadius` (may be `0`), `Style.normalBorderFor(...)` | always-rounded, `"#333"` |
| `bar ? bar.foreground : Color.foreground` | assuming `bar` is set at construction |

Boxes are `Rectangle`s with hairline borders, not box-drawing characters;
meters and histograms are block glyphs (`▁▂▃▄▅▆▇█`, `█`/`░`) in the monospace
bar font. Never render a panel as one multi-line `Text` — column alignment
comes from the layout. The only sanctioned scale exception is a decorative hero
glyph size, and it must carry a comment saying so.

Comment *why*, not *what*, in full sentences — match the shell's habit of a
few lines above a block explaining the trade-off.

`PanelKeyCatcher` consumes keys before `onTextKey` sees them: `h j k l` are
movement, `x` is delete, `space`/`enter` activate, `esc` closes, `tab`
switches panels. New bindings can't use those. Arrows arrive as `(dx, dy)` with
**down = +1**.

## Dev workflow

```bash
cp -r . ~/.config/omarchy/plugins/shilai_li.eye-break   # no symlinks; validator rejects them
omarchy plugin validate ~/.config/omarchy/plugins/shilai_li.eye-break

# Bare `qmllint` here is a Qt5-era build that chokes on typed QML functions
# and exits 255 silently. Use the Qt6 binary explicitly.
QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell BarWidget.qml
/usr/lib/qt6/bin/qmlformat BarWidget.qml > /dev/null    # pure syntax gate

bash test/model-test.sh
omarchy-shell shell summon shilai_li.eye-break '{}'     # overlay smoke test
```

Saving under `~/.config/omarchy/plugins/` hot-reloads code — the edit loop is
save → look at the bar. **But a hot reload does not re-bind the IPC target:**
the first `IpcHandler` for a target owns it for the life of the shell process
and later ones are refused. So a new IPC method or a new `status` field keeps
answering with the old code until `omarchy-restart-shell`. Visual and
behavioural changes reload fine.

**Reading qmllint output:** `qs.Commons` / `qs.Ui` can't resolve outside
Quickshell, so every file emits a cascade of `[import]`, `[unqualified]`,
`[unresolved-type]`, `[inheritance-cycle]`, `[required]`, `[uncreatable-type]`,
`[signal-handler-parameters]`. That is noise — the shipped built-ins emit the
same. Compare *categories* against a built-in, not counts; a category yours
emits that theirs doesn't is worth chasing.

Shell-side errors go to the `omarchy-shell` journal — check there first when a
widget silently fails to appear.

## Rules for agents

1. Read the real file before writing. The clock clone answers most "how do I…".
2. No new dependencies. QML + Quickshell + the shell's singletons.
3. Plugins run unsandboxed. Write nothing outside
   `~/.local/state/omarchy/eye-break/` and the widget's `shell.json` entry.
   No network, no `sudo`, ever.
4. Keep settings mirrored in three places: `setting()` reads, the panel
   controls, and `manifest.json`'s `barWidget.schema`.
5. Before declaring done: `omarchy plugin validate` clean, qmllint categories
   match a built-in, `bash test/model-test.sh` green, panel opens/closes,
   overlay appears and auto-dismisses, countdown survives a shell restart.

