.pragma library

.import "Art.js" as Art

// The sun as heliodim sees it: the same subsolar-point formula as
// src/sun.zig and Omarchy's Elsewhen clock, so the icon, the panel and the
// daemon agree. Times are JavaScript milliseconds.

var DEG = Math.PI / 180
var HORIZON = -0.833

function mod(a, n) { return ((a % n) + n) % n }
function wrap180(x) { return mod(x + 540, 360) - 180 }

function position(lat, lon, ms) {
  var n = ms / 86400000 + 2440587.5 - 2451545
  var L = mod(280.460 + 0.9856474 * n, 360)
  var g = mod(357.528 + 0.9856003 * n, 360) * DEG
  var lambda = (L + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * DEG
  var eps = (23.44 - 0.0000004 * n) * DEG
  var decl = Math.asin(Math.sin(eps) * Math.sin(lambda))
  var alpha = Math.atan2(Math.cos(eps) * Math.sin(lambda), Math.cos(lambda)) / DEG
  var subLon = wrap180(-15 * (mod(ms / 3600000, 24) - 12) - wrap180(L - alpha))
  var p = lat * DEG
  var h = (subLon - lon) * DEG
  var cosz = Math.sin(p) * Math.sin(decl) + Math.cos(p) * Math.cos(decl) * Math.cos(h)
  var az = Math.atan2(Math.sin(h) * Math.cos(decl),
    Math.cos(p) * Math.sin(decl) - Math.sin(p) * Math.cos(decl) * Math.cos(h)) / DEG
  return {
    elevation: Math.asin(Math.max(-1, Math.min(1, cosz))) / DEG,
    azimuth: mod(az, 360)
  }
}

// Clear-sky irradiance (Haurwitz), then heliodim's curve between min and max.
function clearSky(elevation) {
  if (elevation <= 0) return 0
  var cz = Math.sin(elevation * DEG)
  return 1098 * cz * Math.exp(-0.057 / cz)
}

function curve(elevation, min, max) {
  return min + (max - min) * Math.sqrt(Math.min(1, clearSky(elevation) / 1000))
}

// Which pixel map the bar shows, as an index into Art.states.
function stateIndex(elevation) {
  for (var i = 0; i < Art.upTo.length; i++)
    if (elevation < Art.upTo[i]) return i
  return Art.upTo.length - 1
}

// Rows for the bar: morning maps as drawn, afternoon ones mirrored, so the
// sun climbs from the left and sets on the right.
function iconRows(position) {
  var rows = Art.states[stateIndex(position.elevation)].rows
  if (position.azimuth < 180) return rows
  return rows.map(function(r) { return r.split("").reverse().join("") })
}

// Today in local time: elevation per 5 minutes from midnight, and the
// sunrise, noon and sunset minutes (null where the sun does not cross).
function day(lat, lon, nowMs) {
  var start = new Date(nowMs)
  start.setHours(0, 0, 0, 0)
  var t0 = start.getTime()
  var samples = []
  var rise = null, set = null, noon = 0, best = -91
  for (var m = 0; m <= 1440; m += 5) {
    var el = position(lat, lon, t0 + m * 60000).elevation
    if (samples.length > 0) {
      var prev = samples[samples.length - 1]
      if (prev < HORIZON && el >= HORIZON) rise = m
      if (prev >= HORIZON && el < HORIZON) set = m
    }
    if (el > best) { best = el; noon = m }
    samples.push(el)
  }
  return { start: t0, samples: samples, rise: rise, noon: noon, set: set, peak: best }
}

function clock(ms) {
  var d = new Date(ms)
  return (d.getHours() < 10 ? "0" : "") + d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes()
}

function minutesClock(m) {
  m = Math.round(m)
  var h = Math.floor(m / 60) % 24, mm = m % 60
  return (h < 10 ? "0" : "") + h + ":" + (mm < 10 ? "0" : "") + mm
}

// "+7.0" / "−3.5" / "0"
function signed(v) {
  if (Math.abs(v) < 0.05) return "0"
  return (v > 0 ? "+" : "−") + Math.abs(v).toFixed(1)
}
