// Run with: bash test/model-test.sh
const M = require("../Model.js")

let passed = 0
const failures = []

function check(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failures.push(name + "\n    " + e.message)
  }
}

function eq(actual, expected, what) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) throw new Error((what || "value") + ": expected " + b + ", got " + a)
}

function ok(value, what) {
  if (!value) throw new Error((what || "assertion") + " was falsy")
}

const MIN = M.MS_PER_MINUTE
const HOUR = M.MS_PER_HOUR
const T0 = new Date(2026, 7, 31, 14, 37, 0, 0).getTime()  // a fixed local afternoon
const INTERVAL = 20 * MIN
const BREAK = 20 * 1000

// ---------------------------------------------------------------- settings

check("settings clamp into range", () => {
  eq(M.intervalMinutes(20), 20, "nominal")
  eq(M.intervalMinutes(0), 1, "floor")
  eq(M.intervalMinutes(9999), 180, "ceiling")
  eq(M.intervalMinutes("abc"), 20, "garbage falls back")
  eq(M.intervalMinutes(null), 20, "null falls back")
  eq(M.breakSeconds(1), 5, "break floor")
  eq(M.idleGraceSeconds(3), 10, "idle floor")
  eq(M.idleGraceSeconds(null), 300, "idle default is five minutes, not one")
  eq(M.preNotifySeconds(-4), 0, "pre-notify floor")
})

check("boolSetting accepts what shell.json actually contains", () => {
  eq(M.boolSetting(true, false), true)
  eq(M.boolSetting("on", false), true)
  eq(M.boolSetting("off", true), false)
  eq(M.boolSetting(undefined, true), true, "missing keeps the default")
  eq(M.boolSetting("nonsense", true), true, "garbage keeps the default")
})

// ------------------------------------------------------------------- state

check("a missing or torn state file yields a fresh cycle", () => {
  eq(M.parseState("", T0), M.defaultState(T0), "empty")
  eq(M.parseState("{not json", T0), M.defaultState(T0), "torn")
  eq(M.parseState("[]", T0), M.defaultState(T0), "wrong shape")
  eq(M.parseState(null, T0), M.defaultState(T0), "null")
})

check("a cycle stamped in the future is treated as a moved clock", () => {
  const s = M.parseState(JSON.stringify({ cycleStartedAt: T0 + HOUR }), T0)
  eq(s.cycleStartedAt, T0, "reset to now")
})

check("state round-trips through serialize/parse", () => {
  let s = M.startCycle(M.defaultState(T0), T0)
  s = M.recordBreak(s, "taken", T0 + INTERVAL)
  eq(M.parseState(M.serializeState(s), T0 + INTERVAL), s)
})

check("history is trimmed, sorted and de-garbaged", () => {
  const raw = {
    cycleStartedAt: T0,
    history: [
      { at: T0 - 1000, outcome: "skipped" },
      { at: T0 - 9 * M.MS_PER_DAY, outcome: "taken" },   // too old
      { at: T0 - 5000, outcome: "taken" },
      { at: T0 + HOUR, outcome: "taken" },               // in the future
      "junk",
      { outcome: "taken" }                               // no timestamp
    ]
  }
  const s = M.normalizeState(raw, T0)
  eq(s.history.length, 2, "kept count")
  eq(s.history[0].at, T0 - 5000, "sorted oldest first")
  eq(s.history[1].outcome, "skipped", "outcome preserved")
})

check("an unknown outcome is recorded as taken", () => {
  const s = M.recordBreak(M.defaultState(T0), "wat", T0)
  eq(s.history[0].outcome, "taken")
})

// --------------------------------------------------------------- countdown

check("the countdown drains in real time", () => {
  const s = M.startCycle(M.defaultState(T0), T0)
  eq(M.remainingMs(s, INTERVAL, T0), INTERVAL, "at the start")
  eq(M.remainingMs(s, INTERVAL, T0 + 5 * MIN), 15 * MIN, "five minutes in")
  eq(M.remainingMs(s, INTERVAL, T0 + INTERVAL), 0, "at due")
  eq(M.remainingMs(s, INTERVAL, T0 + INTERVAL + HOUR), 0, "never goes negative")
  eq(M.cycleProgress(s, INTERVAL, T0 + 10 * MIN), 0.5, "progress")
})

check("a paused countdown does not drain", () => {
  let s = M.startCycle(M.defaultState(T0), T0)
  s = M.pause(s, T0 + 5 * MIN, "manual")
  eq(M.remainingMs(s, INTERVAL, T0 + 5 * MIN), 15 * MIN, "at the pause")
  eq(M.remainingMs(s, INTERVAL, T0 + 60 * MIN), 15 * MIN, "an hour later, unchanged")
  ok(M.isPaused(s), "reports paused")
  ok(!M.isDue(s, INTERVAL, T0 + 60 * MIN), "never comes due while paused")
})

check("resuming excludes exactly the paused span", () => {
  let s = M.startCycle(M.defaultState(T0), T0)
  s = M.pause(s, T0 + 5 * MIN, "manual")
  s = M.resume(s, T0 + 35 * MIN, "manual")
  eq(s.pausedAccumMs, 30 * MIN, "accumulated")
  eq(M.remainingMs(s, INTERVAL, T0 + 35 * MIN), 15 * MIN, "picks up where it left off")
  eq(M.remainingMs(s, INTERVAL, T0 + 50 * MIN), 0, "and comes due 15 minutes after that")
})

check("a manual pause survives an idle resume", () => {
  let s = M.pause(M.startCycle(M.defaultState(T0), T0), T0 + MIN, "manual")
  s = M.resume(s, T0 + 2 * MIN, "idle")
  ok(M.isPaused(s), "still paused")
  eq(s.pausedBy, "manual", "still owned by the user")
})

check("an idle pause is promoted, never demoted", () => {
  let s = M.pause(M.startCycle(M.defaultState(T0), T0), T0 + MIN, "idle")
  s = M.pause(s, T0 + 2 * MIN, "manual")
  eq(s.pausedBy, "manual", "manual takes over")
  eq(s.pausedAt, T0 + MIN, "without restarting the pause span")
  const again = M.pause(s, T0 + 3 * MIN, "idle")
  eq(again.pausedBy, "manual", "idle cannot take it back")
})

check("returning from a whole cycle's absence counts as a break taken", () => {
  let s = M.pause(M.startCycle(M.defaultState(T0), T0), T0 + 5 * MIN, "idle")
  s = M.endIdle(s, T0 + 5 * MIN + INTERVAL, INTERVAL)
  eq(s.history.length, 1, "recorded")
  eq(s.history[0].outcome, "taken")
  eq(s.cycleStartedAt, T0 + 5 * MIN + INTERVAL, "and the next cycle starts on return")
  ok(!M.isPaused(s), "no longer paused")
})

check("returning from a short idle only resumes", () => {
  let s = M.pause(M.startCycle(M.defaultState(T0), T0), T0 + 5 * MIN, "idle")
  s = M.endIdle(s, T0 + 5 * MIN + 3000, INTERVAL)
  eq(s.history.length, 0, "nothing recorded")
  eq(s.pausedAccumMs, 3000, "just the gap")
})

// The bug this guards: crediting on `breakMs` meant every detected idle
// credited a break, because idle is only reported minutes after a break's
// length has passed. The reminder then never fired for anyone who looks away
// from the keyboard — which is most people, most of the time.
check("a lull shorter than a cycle never credits a break", () => {
  const base = M.startCycle(M.defaultState(T0), T0)
  for (const lull of [BREAK, 61 * 1000, 5 * MIN, 19 * MIN, INTERVAL - 1000]) {
    let s = M.pause(base, T0 + MIN, "idle")
    s = M.endIdle(s, T0 + MIN + lull, INTERVAL)
    eq(s.history.length, 0, "a " + Math.round(lull / 1000) + "s lull recorded nothing")
    ok(M.remainingMs(s, INTERVAL, T0 + MIN + lull) < INTERVAL,
       "and the cycle kept its progress")
  }
})

check("a break records history and restarts the cycle", () => {
  let s = M.beginBreak(M.startCycle(M.defaultState(T0), T0), T0 + INTERVAL)
  ok(M.isBreaking(s), "in a break")
  eq(M.statusOf(s, INTERVAL, T0 + INTERVAL), "break", "status")
  s = M.recordBreak(s, "skipped", T0 + INTERVAL + 3000)
  ok(!M.isBreaking(s), "break cleared")
  eq(s.history[0].outcome, "skipped")
  eq(M.remainingMs(s, INTERVAL, T0 + INTERVAL + 3000), INTERVAL, "full cycle again")
})

check("an abandoned break is detected, a live one is not", () => {
  const s = M.beginBreak(M.defaultState(T0), T0)
  ok(!M.isBreakAbandoned(s, BREAK, T0 + 10000), "still running")
  ok(M.isBreakAbandoned(s, BREAK, T0 + 5 * MIN), "shell died mid-break")
  ok(!M.isBreakAbandoned(M.defaultState(T0), BREAK, T0 + HOUR), "no break, nothing to abandon")
})

check("a suspended machine goes stale instead of firing on wake", () => {
  const s = M.startCycle(M.defaultState(T0), T0)
  ok(M.isDue(s, INTERVAL, T0 + INTERVAL + 1000), "due just past the interval")
  ok(!M.isStale(s, INTERVAL, T0 + INTERVAL + 1000), "not yet stale")
  ok(M.isStale(s, INTERVAL, T0 + INTERVAL + M.STALE_GRACE_MS + 1000), "stale after the grace")
  ok(M.isStale(s, INTERVAL, T0 + 8 * HOUR), "an overnight suspend is stale")
})

check("postponing pushes the cycle without touching history", () => {
  let s = M.recordBreak(M.defaultState(T0), "taken", T0)
  const before = s.history.length
  s = M.postpone(s, MIN)
  eq(M.remainingMs(s, INTERVAL, T0 + INTERVAL), MIN, "a minute back on the clock")
  eq(s.history.length, before, "history untouched")
  eq(M.postpone(s, -5), s, "a nonsense delay is a no-op")
})

check("togglePause round-trips", () => {
  const s = M.startCycle(M.defaultState(T0), T0)
  const paused = M.togglePause(s, T0 + MIN)
  ok(M.isPaused(paused))
  ok(!M.isPaused(M.togglePause(paused, T0 + 2 * MIN)))
})

// ------------------------------------------------------------------- stats

check("today's stats count only today", () => {
  const yesterday = T0 - M.MS_PER_DAY
  const history = [
    { at: yesterday, outcome: "taken" },
    { at: T0 - 2 * HOUR, outcome: "taken" },
    { at: T0 - HOUR, outcome: "skipped" },
    { at: T0 - 30 * MIN, outcome: "taken" },
    { at: T0 - 10 * MIN, outcome: "taken" }
  ]
  const s = M.statsFor(history, T0, INTERVAL)
  eq(s.taken, 3, "taken today")
  eq(s.skipped, 1, "skipped today")
  eq(s.total, 4, "total today")
  eq(s.adherencePercent, 75, "adherence")
  eq(s.streak, 2, "streak runs back to the skip")
  eq(s.screenMs, 4 * INTERVAL, "screen time")
  eq(s.sinceLastMs, 10 * MIN, "time since the last break")
})

check("empty stats do not divide by zero", () => {
  const s = M.statsFor([], T0, INTERVAL)
  eq(s.adherencePercent, 0)
  eq(s.streak, 0)
  eq(s.sinceLastMs, -1, "never taken reads as -1")
  eq(M.formatAgo(s.sinceLastMs), "never")
})

check("the hourly graph buckets into a rolling window", () => {
  const history = [
    { at: T0 - 30 * MIN, outcome: "taken" },
    { at: T0 - 20 * MIN, outcome: "taken" },
    { at: T0 - 3 * HOUR, outcome: "taken" },
    { at: T0 - 40 * HOUR, outcome: "taken" }   // outside a 16h window
  ]
  const g = M.hourlyCounts(history, T0, 16)
  eq(g.span, 16, "span")
  eq(g.counts.length, 16, "one column per hour")
  eq(g.counts[15], 2, "the current hour")
  eq(g.counts[12], 1, "three hours back")
  eq(g.counts.reduce((a, b) => a + b, 0), 3, "the 40h-old entry is outside the window")
})

check("the hour axis is thinned and two digits wide", () => {
  const g = M.hourlyCounts([], T0, 16)
  const axis = M.hourAxis(g.startHour, g.span, 4)
  eq(axis.length, 4, "every fourth column")
  eq(axis.map(a => a.index), [0, 4, 8, 12])
  ok(axis.every(a => a.label.length === 2), "zero padded")
})

// --------------------------------------------------------------- rendering

check("the meter fills proportionally", () => {
  eq(M.meter(0, 10), "░░░░░░░░░░")
  eq(M.meter(1, 10), "██████████")
  eq(M.meter(0.5, 10), "█████░░░░░")
  eq(M.meter(2, 10), "██████████", "over 1 clamps")
  eq(M.meter(-1, 10), "░░░░░░░░░░", "under 0 clamps")
  eq(M.meter(0.5, 10).length, 10, "width is exact")
})

check("repeat and meterFilledCells build the panel's two-tone meter", () => {
  eq(M.repeat("█", 4), "████")
  eq(M.repeat("█", 0), "", "zero cells is an empty string")
  eq(M.repeat("█", -3), "", "so is a negative one")
  eq(M.meterFilledCells(0.5, 40), 20)
  eq(M.meterFilledCells(0, 40), 0)
  eq(M.meterFilledCells(1, 40), 40)
  // The two halves must always add up to the full width, or the meter
  // changes length as it fills.
  for (let p = 0; p <= 1.0001; p += 0.05) {
    const filled = M.meterFilledCells(p, 37)
    eq(M.repeat("█", filled).length + M.repeat("░", 37 - filled).length, 37,
       "width at progress " + p.toFixed(2))
  }
})

check("the sparkline scales to its own maximum", () => {
  eq(M.sparkline([0, 0, 0]), "▁▁▁", "no data draws the floor")
  eq(M.sparkline([1, 2, 4]), "▃▅█", "relative heights")
  eq(M.sparkline([3, 3, 3]), "███", "a flat row is full height")
  eq(M.sparkline([]), "", "nothing in, nothing out")
  eq(M.sparkline([0, 5]).length, 2, "one glyph per column")
})

check("durations read the way a person would say them", () => {
  eq(M.formatCountdown(20 * MIN), "20:00")
  eq(M.formatCountdown(0), "00:00")
  eq(M.formatCountdown(1), "00:01", "any remainder is a whole second")
  eq(M.formatCountdown(999), "00:01", "and rounds up, so 00:00 means zero")
  eq(M.formatCountdown(90 * MIN), "1:30:00")
  eq(M.formatDuration(20 * 1000), "20s")
  eq(M.formatDuration(47 * MIN), "47m")
  eq(M.formatDuration(6 * HOUR + 12 * MIN), "6h 12m")
  eq(M.formatAgo(30 * 1000), "just now")
  eq(M.formatAgo(17 * MIN), "17m ago")
})

check("urgency stays at zero until the end of the cycle", () => {
  eq(M.urgency(0), 0)
  eq(M.urgency(0.85), 0, "at the threshold")
  eq(M.urgency(1), 1, "at due")
  ok(M.urgency(0.925) > 0.4 && M.urgency(0.925) < 0.6, "ramps between")
})

check("the bar label matches the status", () => {
  eq(M.barLabel("running", 12 * MIN + 34 * 1000, true), "12:34")
  eq(M.barLabel("running", 12 * MIN, false), "", "countdown can be turned off")
  eq(M.barLabel("paused", 0, true), "paused")
  eq(M.barLabel("idle", 0, true), "idle")
  eq(M.barLabel("break", 0, true), "▮▮")
})

// -------------------------------------------------------------------- done

if (failures.length > 0) {
  console.error("\n" + failures.length + " failed:\n")
  failures.forEach(f => console.error("  ✗ " + f + "\n"))
  process.exit(1)
}
console.log("model-test: " + passed + " checks passed")
