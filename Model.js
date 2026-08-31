// Pure scheduling, statistics and meter math for the eye-break plugin.
//
// Deliberately Qt- and locale-free so test/model-test.sh can run the whole
// file under plain node, with no compositor and no shell. Anything that needs
// Qt.formatDateTime, a theme color, or a QML type belongs in the .qml files.
//
// Every function here is a pure transform. State objects are never mutated;
// a transition returns a fresh object. That is what lets several bar
// instances — one per monitor — derive the same countdown from one file on
// disk without any of them owning a mutable clock of its own.

var MS_PER_SECOND = 1000
var MS_PER_MINUTE = 60000
var MS_PER_HOUR = 3600000
var MS_PER_DAY = 86400000

// A week is enough history for the panel's rolling graph and the day's
// stats, and short enough that the state file never becomes something the
// user has to think about.
var HISTORY_DAYS = 7
var HISTORY_LIMIT = 600

// How far past due a cycle may run before we conclude nobody was there to
// take the break. Under normal operation the widget fires within a second of
// due, so an overshoot this large means the machine was suspended or the
// shell was down — reviving a break for a laptop lid that just opened would
// be interrupting the wrong moment.
var STALE_GRACE_MS = 5 * MS_PER_MINUTE

// Eight levels of vertical block. btop draws its per-core history this way
// and the glyphs are in every Nerd Font, so the graph costs nothing beyond
// the string it renders into.
var SPARK_LEVELS = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
var METER_FILLED = "█"
var METER_EMPTY = "░"

// ---------------------------------------------------------------- settings
//
// Each setting is clamped rather than rejected. A hand-edited shell.json with
// `intervalMinutes: 0` should give the user a working plugin at the nearest
// sane value, not a widget that divides by zero.

function clampInt(value, min, max, fallback) {
  // An absent key and a garbage one both mean "the user did not choose", and
  // Number(null) is 0 — which would silently clamp to the floor instead.
  if (value === undefined || value === null || value === "") return fallback
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.round(n)
  return Math.max(min, Math.min(max, n))
}

// Three hours is the ceiling: past that the plugin is no longer reminding
// anyone of anything.
function intervalMinutes(raw) { return clampInt(raw, 1, 180, 20) }

// Ten minutes of enforced looking-away is already absurd, but it is the
// user's screen.
function breakSeconds(raw) { return clampInt(raw, 5, 600, 20) }

// Five minutes, not one. A minute without input is reading, thinking, or
// being on a call — all of which are screen time. Only a much longer silence
// is evidence of having left the desk.
function idleGraceSeconds(raw) { return clampInt(raw, 10, 3600, 300) }

// 0 means no heads-up at all, which is the default: an unannounced break is
// less clutter than two interruptions.
function preNotifySeconds(raw) { return clampInt(raw, 0, 300, 0) }

function boolSetting(raw, fallback) {
  if (raw === undefined || raw === null) return fallback === true
  if (typeof raw === "boolean") return raw
  var text = String(raw).toLowerCase()
  if (text === "true" || text === "1" || text === "yes" || text === "on") return true
  if (text === "false" || text === "0" || text === "no" || text === "off") return false
  return fallback === true
}

// ------------------------------------------------------------------- state
//
// The whole schedule is one absolute timestamp plus the pause spans excluded
// from it. Nothing counts down; every reader subtracts. A shell restart, a
// second monitor, and the break overlay all arrive at the same number from
// the same file.
//
//   cycleStartedAt  epoch ms the current work cycle began
//   pausedAt        epoch ms the current pause began, or 0 when running
//   pausedBy        "manual" | "idle" — who owns the pause (see resume rules)
//   pausedAccumMs   pause time already excluded from this cycle
//   breakStartedAt  epoch ms the break overlay went up, or 0
//   history         [{ at, outcome }] with outcome "taken" | "skipped"

function defaultState(now) {
  return {
    cycleStartedAt: sanitizeTime(now, 0),
    pausedAt: 0,
    pausedBy: "",
    pausedAccumMs: 0,
    breakStartedAt: 0,
    history: []
  }
}

function sanitizeTime(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : fallback
}

function cloneState(state) {
  return {
    cycleStartedAt: state.cycleStartedAt,
    pausedAt: state.pausedAt,
    pausedBy: state.pausedBy,
    pausedAccumMs: state.pausedAccumMs,
    breakStartedAt: state.breakStartedAt,
    history: state.history.slice()
  }
}

// Parsing lives here rather than in the QML so the failure path is covered by
// the same tests as the happy one. A torn or absent file is not an error
// worth surfacing — it means "first run", and a fresh cycle is the right
// answer to that.
function parseState(text, now) {
  var raw = null
  try {
    raw = JSON.parse(String(text === undefined || text === null ? "" : text))
  } catch (e) {
    raw = null
  }
  return normalizeState(raw, now)
}

function normalizeState(raw, now) {
  var at = sanitizeTime(now, 0)
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return defaultState(at)

  // A cycle stamped in the future is a clock that moved, not a cycle. Start
  // over rather than showing a countdown that grows.
  var started = sanitizeTime(raw.cycleStartedAt, at)
  if (started > at + MS_PER_MINUTE) started = at

  var pausedAt = sanitizeTime(raw.pausedAt, 0)
  if (pausedAt > at + MS_PER_MINUTE) pausedAt = 0

  var breakStartedAt = sanitizeTime(raw.breakStartedAt, 0)
  if (breakStartedAt > at + MS_PER_MINUTE) breakStartedAt = 0

  var accum = Number(raw.pausedAccumMs)
  if (!isFinite(accum) || accum < 0) accum = 0

  var pausedBy = String(raw.pausedBy || "")
  if (pausedBy !== "manual" && pausedBy !== "idle") pausedBy = pausedAt > 0 ? "manual" : ""

  return {
    cycleStartedAt: started,
    pausedAt: pausedAt,
    pausedBy: pausedAt > 0 ? pausedBy : "",
    pausedAccumMs: accum,
    breakStartedAt: breakStartedAt,
    history: trimHistory(raw.history, at)
  }
}

function serializeState(state) {
  return JSON.stringify(state, null, 2) + "\n"
}

function trimHistory(list, now, days) {
  var out = []
  if (!list || !Array.isArray(list)) return out
  var span = Number(days)
  if (!isFinite(span) || span <= 0) span = HISTORY_DAYS
  var cutoff = now - span * MS_PER_DAY

  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry !== "object") continue
    var at = sanitizeTime(entry.at, 0)
    if (at <= 0 || at < cutoff || at > now + MS_PER_MINUTE) continue
    out.push({ at: at, outcome: String(entry.outcome) === "skipped" ? "skipped" : "taken" })
  }

  out.sort(function(a, b) { return a.at - b.at })
  if (out.length > HISTORY_LIMIT) out = out.slice(out.length - HISTORY_LIMIT)
  return out
}

// ------------------------------------------------------------- the countdown

function elapsedMs(state, now) {
  if (!state) return 0
  var at = sanitizeTime(now, 0)
  var elapsed = at - state.cycleStartedAt - state.pausedAccumMs
  // The pause in flight has not landed in pausedAccumMs yet, so subtract it
  // here. Otherwise a paused countdown would keep draining.
  if (state.pausedAt > 0) elapsed -= Math.max(0, at - state.pausedAt)
  return Math.max(0, elapsed)
}

function remainingMs(state, intervalMs, now) {
  return Math.max(0, intervalMs - elapsedMs(state, now))
}

function cycleProgress(state, intervalMs, now) {
  if (!(intervalMs > 0)) return 0
  return clamp01(elapsedMs(state, now) / intervalMs)
}

function isPaused(state) { return !!state && state.pausedAt > 0 }
function isBreaking(state) { return !!state && state.breakStartedAt > 0 }
function isDue(state, intervalMs, now) { return elapsedMs(state, now) >= intervalMs }
function isStale(state, intervalMs, now) { return elapsedMs(state, now) - intervalMs > STALE_GRACE_MS }

// A break overlay that never reported back — the shell was killed mid-break,
// or the plugin reloaded under it. Without this the widget would sit on
// "on break" forever and never schedule again.
function isBreakAbandoned(state, breakMs, now) {
  if (!isBreaking(state)) return false
  return now - state.breakStartedAt > breakMs + MS_PER_MINUTE
}

function statusOf(state, intervalMs, now) {
  if (isBreaking(state)) return "break"
  if (isPaused(state)) return state.pausedBy === "idle" ? "idle" : "paused"
  if (isDue(state, intervalMs, now)) return "due"
  return "running"
}

// How alarmed the widget should look, 0 until the last stretch of the cycle
// and 1 at due. The bar blends its foreground toward the theme's urgent color
// by this much, so "nearly time" is legible without a second glyph.
function urgency(progress, threshold) {
  var edge = Number(threshold)
  if (!isFinite(edge) || edge < 0 || edge >= 1) edge = 0.85
  var p = clamp01(progress)
  if (p <= edge) return 0
  return clamp01((p - edge) / (1 - edge))
}

// ------------------------------------------------------------- transitions

function startCycle(state, now) {
  var next = cloneState(state)
  next.cycleStartedAt = sanitizeTime(now, 0)
  next.pausedAt = 0
  next.pausedBy = ""
  next.pausedAccumMs = 0
  next.breakStartedAt = 0
  return next
}

// Manual pause outranks idle: if you deliberately paused, walking away and
// coming back must not quietly start the clock again.
function pause(state, now, by) {
  var owner = by === "idle" ? "idle" : "manual"
  if (isPaused(state)) {
    if (state.pausedBy === "manual" || owner === "idle") return state
    var promoted = cloneState(state)
    promoted.pausedBy = "manual"
    return promoted
  }
  var next = cloneState(state)
  next.pausedAt = sanitizeTime(now, 0)
  next.pausedBy = owner
  return next
}

function resume(state, now, by) {
  if (!isPaused(state)) return state
  // Coming back from idle does not clear a pause the user asked for.
  if (by === "idle" && state.pausedBy !== "idle") return state
  var next = cloneState(state)
  next.pausedAccumMs += Math.max(0, sanitizeTime(now, 0) - state.pausedAt)
  next.pausedAt = 0
  next.pausedBy = ""
  return next
}

function togglePause(state, now) {
  return isPaused(state) ? resume(state, now, "manual") : pause(state, now, "manual")
}

// Returning from an absence long enough to be a whole work cycle means the
// eyes already got what the break was for. Anything shorter only resumes.
//
// `creditMs` is the interval, not the break length, and the difference is the
// whole point. Input idleness cannot tell "away from the desk" from "reading
// the screen without typing", and reading is exactly the screen time this
// plugin exists to interrupt. Crediting every idle span longer than a
// 20-second break — which every detected idle necessarily is — meant a break
// was credited every few minutes and the reminder never fired at all.
// Requiring a full cycle's absence errs the safe way: at worst a break comes
// due shortly after you sit back down, which costs 20 seconds.
function endIdle(state, now, creditMs) {
  if (!isPaused(state) || state.pausedBy !== "idle") return state
  var idleMs = Math.max(0, sanitizeTime(now, 0) - state.pausedAt)
  if (idleMs >= creditMs) return recordBreak(state, "taken", now)
  return resume(state, now, "idle")
}

function beginBreak(state, now) {
  var next = cloneState(state)
  next.breakStartedAt = sanitizeTime(now, 0)
  return next
}

// The end of a break is also the start of the next cycle, so this is the one
// transition that both writes history and resets the clock. Any pause is
// dropped: you were just at the keyboard dismissing an overlay.
function recordBreak(state, outcome, now) {
  var at = sanitizeTime(now, 0)
  var next = startCycle(state, at)
  next.history = trimHistory(state.history.concat([{
    at: at,
    outcome: outcome === "skipped" ? "skipped" : "taken"
  }]), at)
  return next
}

// Push the whole cycle back without touching history — used when the break
// comes due at a moment we agreed not to interrupt (a fullscreen window).
function postpone(state, ms) {
  var delay = Number(ms)
  if (!isFinite(delay) || delay <= 0) return state
  var next = cloneState(state)
  next.cycleStartedAt += delay
  return next
}

function clearHistory(state) {
  var next = cloneState(state)
  next.history = []
  return next
}

// ------------------------------------------------------------------- stats

function startOfDay(now) {
  var d = new Date(sanitizeTime(now, 0))
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function statsFor(history, now, intervalMs) {
  var list = history && Array.isArray(history) ? history : []
  var since = startOfDay(now)
  var taken = 0
  var skipped = 0
  var lastAt = 0

  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (entry.at > lastAt) lastAt = entry.at
    if (entry.at < since) continue
    if (entry.outcome === "skipped") skipped++
    else taken++
  }

  // The streak runs across days on purpose: it is a habit counter, and
  // midnight is not a reason to lose one.
  var streak = 0
  for (var j = list.length - 1; j >= 0; j--) {
    if (list[j].outcome !== "taken") break
    streak++
  }

  var total = taken + skipped
  return {
    taken: taken,
    skipped: skipped,
    total: total,
    streak: streak,
    adherencePercent: total > 0 ? Math.round((taken / total) * 100) : 0,
    // Every completed cycle is one interval of screen time, which is the only
    // honest number available without watching the session itself.
    screenMs: total * Math.max(0, Number(intervalMs) || 0),
    lastAt: lastAt,
    sinceLastMs: lastAt > 0 ? Math.max(0, sanitizeTime(now, 0) - lastAt) : -1
  }
}

// Breaks per hour over a window ending at the current hour. Rolling rather
// than midnight-to-midnight so the graph still says something at 00:30.
function hourlyCounts(history, now, hours) {
  var span = clampInt(hours, 1, 48, 16)
  var d = new Date(sanitizeTime(now, 0))
  d.setMinutes(0, 0, 0)
  var endHour = d.getTime()
  var startHour = endHour - (span - 1) * MS_PER_HOUR

  var counts = []
  for (var i = 0; i < span; i++) counts.push(0)

  var list = history && Array.isArray(history) ? history : []
  for (var j = 0; j < list.length; j++) {
    var at = list[j].at
    if (at < startHour) continue
    var index = Math.floor((at - startHour) / MS_PER_HOUR)
    if (index < 0 || index >= span) continue
    counts[index]++
  }

  return { startHour: startHour, span: span, counts: counts }
}

// Hour-of-day labels under the graph, thinned to every `step` columns so the
// axis never collides with itself at small panel widths.
function hourAxis(startHour, span, step) {
  var every = clampInt(step, 1, 24, 4)
  var out = []
  for (var i = 0; i < span; i++) {
    if (i % every !== 0) continue
    var d = new Date(startHour + i * MS_PER_HOUR)
    out.push({ index: i, label: pad2(d.getHours()) })
  }
  return out
}

// --------------------------------------------------------------- rendering
//
// String builders, not widgets. They rely on the shell font being monospace
// (Style.fontFamily is "monospace" by default) for column alignment *within*
// one string; alignment between rows is the QML layout's job.

function sparkline(counts, glyphs) {
  var levels = glyphs && glyphs.length > 0 ? glyphs : SPARK_LEVELS
  var list = counts && Array.isArray(counts) ? counts : []
  var max = 0
  for (var i = 0; i < list.length; i++) max = Math.max(max, Number(list[i]) || 0)

  var out = ""
  for (var j = 0; j < list.length; j++) {
    var value = Number(list[j]) || 0
    // An empty hour still draws the floor glyph. A gap in the row would read
    // as "no data" when it means "no breaks", and those are different.
    if (max <= 0 || value <= 0) {
      out += levels[0]
      continue
    }
    var step = Math.ceil((value / max) * (levels.length - 1))
    out += levels[Math.max(1, Math.min(levels.length - 1, step))]
  }
  return out
}

// One glyph repeated. The panel builds its meter from two of these — a
// filled run and an empty one — so the two halves can carry different
// colors instead of being one flat string.
function repeat(glyph, count) {
  var n = Number(count)
  if (!isFinite(n) || n <= 0) return ""
  n = Math.min(400, Math.round(n))
  var out = ""
  for (var i = 0; i < n; i++) out += glyph
  return out
}

function meterFilledCells(progress, cells) {
  return Math.round(clamp01(progress) * clampInt(cells, 1, 400, 40))
}

function meter(progress, width, filledGlyph, emptyGlyph) {
  var cells = clampInt(width, 1, 400, 40)
  var filled = Math.round(clamp01(progress) * cells)
  var on = filledGlyph || METER_FILLED
  var off = emptyGlyph || METER_EMPTY
  var out = ""
  for (var i = 0; i < cells; i++) out += i < filled ? on : off
  return out
}

function clamp01(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(1, n))
}

function pad2(value) {
  var n = Math.abs(Math.round(Number(value) || 0))
  return (n < 10 ? "0" : "") + n
}

// Ceil, not round: "00:00" should appear at zero and nowhere else, or the
// widget reads as due for a whole second before it is.
function formatCountdown(ms) {
  var total = Math.max(0, Math.ceil((Number(ms) || 0) / MS_PER_SECOND))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var seconds = total % 60
  if (hours > 0) return hours + ":" + pad2(minutes) + ":" + pad2(seconds)
  return pad2(minutes) + ":" + pad2(seconds)
}

function formatDuration(ms) {
  var total = Math.max(0, Math.round((Number(ms) || 0) / MS_PER_SECOND))
  if (total < 60) return total + "s"
  var minutes = Math.floor(total / 60)
  if (minutes < 60) return minutes + "m"
  return Math.floor(minutes / 60) + "h " + pad2(minutes % 60) + "m"
}

function formatAgo(ms) {
  var n = Number(ms)
  if (!isFinite(n) || n < 0) return "never"
  if (n < MS_PER_MINUTE) return "just now"
  return formatDuration(n) + " ago"
}

// What the bar shows next to the glyph. Kept here so the horizontal label,
// the vertical stack and the tooltip cannot drift apart.
function barLabel(status, remaining, showCountdown) {
  if (status === "break") return "▮▮"
  if (status === "paused") return "paused"
  if (status === "idle") return "idle"
  if (!showCountdown) return ""
  return formatCountdown(remaining)
}

function tooltipFor(status, remaining, intervalMinutesValue, breakSecondsValue) {
  if (status === "break") return "Look away — " + breakSecondsValue + "s break"
  if (status === "paused") return "Eye breaks paused"
  if (status === "idle") return "Paused while you are away"
  if (status === "due") return "Eye break due"
  return "Next eye break in " + formatDuration(remaining)
    + " · every " + intervalMinutesValue + "m for " + breakSecondsValue + "s"
}

if (typeof module !== "undefined") {
  module.exports = {
    MS_PER_MINUTE: MS_PER_MINUTE,
    MS_PER_HOUR: MS_PER_HOUR,
    MS_PER_DAY: MS_PER_DAY,
    STALE_GRACE_MS: STALE_GRACE_MS,
    SPARK_LEVELS: SPARK_LEVELS,
    clampInt: clampInt,
    intervalMinutes: intervalMinutes,
    breakSeconds: breakSeconds,
    idleGraceSeconds: idleGraceSeconds,
    preNotifySeconds: preNotifySeconds,
    boolSetting: boolSetting,
    defaultState: defaultState,
    parseState: parseState,
    normalizeState: normalizeState,
    serializeState: serializeState,
    trimHistory: trimHistory,
    elapsedMs: elapsedMs,
    remainingMs: remainingMs,
    cycleProgress: cycleProgress,
    isPaused: isPaused,
    isBreaking: isBreaking,
    isDue: isDue,
    isStale: isStale,
    isBreakAbandoned: isBreakAbandoned,
    statusOf: statusOf,
    urgency: urgency,
    startCycle: startCycle,
    pause: pause,
    resume: resume,
    togglePause: togglePause,
    endIdle: endIdle,
    beginBreak: beginBreak,
    recordBreak: recordBreak,
    postpone: postpone,
    clearHistory: clearHistory,
    startOfDay: startOfDay,
    statsFor: statsFor,
    hourlyCounts: hourlyCounts,
    hourAxis: hourAxis,
    sparkline: sparkline,
    meter: meter,
    repeat: repeat,
    meterFilledCells: meterFilledCells,
    clamp01: clamp01,
    pad2: pad2,
    formatCountdown: formatCountdown,
    formatDuration: formatDuration,
    formatAgo: formatAgo,
    barLabel: barLabel,
    tooltipFor: tooltipFor
  }
}
