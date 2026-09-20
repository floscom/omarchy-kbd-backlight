// Pure helpers for the keyboard backlight plugin. Everything here is free of
// QML and of I/O so the curve can be reasoned about (and eyeballed in qmlscene
// or node) without a running shell.

// Runtime source of truth for settings. manifest.json repeats these in its
// `barWidget.defaults` / `barWidget.schema` block for hosts that render a
// generic settings form; keep the two in step when adding a key.
var DEFAULTS = {
  auto: true,
  manualPercent: 40,
  maxPercent: 100,
  minPercent: 0,
  luxDark: 5,
  luxBright: 150,
  pollIntervalMs: 2000,
  smoothing: 0.65,
  showPercent: false
}

function clamp(value, low, high) {
  var n = Number(value)
  if (isNaN(n)) return low
  return n < low ? low : (n > high ? high : n)
}

function clampPercent(value) {
  return Math.round(clamp(value, 0, 100))
}

// Merge a shell.json entry over the defaults. Unknown keys (`id`, plus
// whatever the bar adds to a layout entry) are ignored rather than carried,
// so a stale key in shell.json can never reach the curve.
function withDefaults(settings) {
  var out = {}
  for (var key in DEFAULTS) {
    var value = settings ? settings[key] : undefined
    out[key] = value === undefined || value === null ? DEFAULTS[key] : value
  }
  out.auto = out.auto !== false
  out.showPercent = out.showPercent === true
  out.manualPercent = clampPercent(out.manualPercent)
  out.maxPercent = clampPercent(out.maxPercent)
  out.minPercent = clampPercent(out.minPercent)
  out.luxDark = Math.round(clamp(out.luxDark, 0, 100000))
  out.luxBright = Math.round(clamp(out.luxBright, 1, 100000))
  // A collapsed or inverted range would make the curve divide by ~zero or run
  // backwards. Push `bright` above `dark` rather than rejecting the entry.
  if (out.luxBright <= out.luxDark) out.luxBright = out.luxDark + 1
  out.pollIntervalMs = Math.round(clamp(out.pollIntervalMs, 500, 60000))
  out.smoothing = clamp(out.smoothing, 0, 0.95)
  return out
}

// Exponentially-weighted mean of the raw sensor, so a hand passing over the
// sensor or a flickering bulb doesn't pump the LED. `smoothing` is the weight
// kept from the previous reading: 0 tracks the sensor exactly, 0.9 crawls.
function smoothLux(previous, reading, smoothing) {
  var next = Number(reading)
  if (isNaN(next) || next < 0) return previous
  if (previous === null || previous === undefined || isNaN(previous)) return next
  var keep = clamp(smoothing, 0, 0.95)
  return previous * keep + next * (1 - keep)
}

// Ambient reading -> backlight percent. Bright ambient means a *dim* keyboard,
// so the curve runs downward from `maxPercent` to `minPercent`.
//
// The exponent bends the ramp so most of the travel happens in the first part
// of the range: the difference between a dark room and a dim one matters far
// more to the eye than the difference between "lit" and "very lit", and the
// sensor's own units are compressed at the bottom end.
function autoPercent(lux, settings) {
  var s = settings
  var value = Number(lux)
  if (isNaN(value)) return s.maxPercent
  if (value <= s.luxDark) return s.maxPercent
  if (value >= s.luxBright) return s.minPercent
  var t = (value - s.luxDark) / (s.luxBright - s.luxDark)
  var eased = Math.pow(t, 0.55)
  return clampPercent(s.maxPercent + (s.minPercent - s.maxPercent) * eased)
}

// Percent <-> raw device units. `max` is the LED's own max_brightness (255 on
// applesmc, 3 on some ThinkPads), so the plugin never assumes a scale.
function percentToRaw(percent, max) {
  var m = Math.max(1, Math.round(Number(max) || 1))
  return Math.round(clampPercent(percent) / 100 * m)
}

function rawToPercent(raw, max) {
  var m = Math.max(1, Math.round(Number(max) || 1))
  return clampPercent(Math.round(Number(raw) || 0) / m * 100)
}

// One ramp step from `current` toward `target`, both in raw device units.
// Large jumps are split into roughly `steps` hops so a sunrise doesn't land as
// a visible snap; small ones close immediately rather than crawling the last
// unit at timer resolution.
function rampStep(current, target, steps) {
  var from = Math.round(Number(current) || 0)
  var to = Math.round(Number(target) || 0)
  if (from === to) return to
  var hops = Math.max(1, Math.round(Number(steps) || 1))
  var delta = to - from
  var step = Math.max(1, Math.ceil(Math.abs(delta) / hops))
  return delta > 0 ? Math.min(to, from + step) : Math.max(to, from - step)
}

// The poll prints "<raw> <max> <lux>" on one line; lux is -1 when no ambient
// light sensor was found. Returns null for anything unparseable so a truncated
// read leaves the last good sample in place.
function parseSample(text) {
  var parts = String(text || "").replace(/^\s+|\s+$/g, "").split(/\s+/)
  if (parts.length < 3) return null
  var raw = parseInt(parts[0], 10)
  var max = parseInt(parts[1], 10)
  var lux = parseInt(parts[2], 10)
  if (isNaN(raw) || isNaN(max) || max <= 0) return null
  return { raw: raw, max: max, lux: isNaN(lux) ? -1 : lux }
}

// Detection prints the LED directory and the sensor file, one per line, either
// possibly blank.
function parseDevices(text) {
  var lines = String(text || "").split("\n")
  return {
    ledPath: String(lines[0] || "").replace(/^\s+|\s+$/g, ""),
    sensorPath: String(lines[1] || "").replace(/^\s+|\s+$/g, "")
  }
}

function ledName(ledPath) {
  var path = String(ledPath || "").replace(/\/+$/, "")
  var cut = path.lastIndexOf("/")
  return cut === -1 ? path : path.slice(cut + 1)
}

// Bar glyph. Nerd Font keyboard glyphs; the "off" variant reads as a plain
// keyboard so a dark bar doesn't look broken when the backlight is at zero.
function icon(percent, auto) {
  if (percent <= 0) return "󰌌"
  return auto ? "󰌌" : "󰥻"
}

function statusLine(percent, lux, hasSensor, auto) {
  var head = clampPercent(percent) + "%"
  if (!hasSensor) return head + " · no sensor"
  return head + " · " + Math.round(Number(lux) || 0) + " lx · " + (auto ? "auto" : "manual")
}
