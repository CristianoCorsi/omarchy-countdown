// Pure countdown logic: dates, states, formatting. No QML in here,
// so that it can be read all together and tested with node.

.pragma library

var MS_DAY = 86400000

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// "2026-09-16" -> Dates at local midnight.
//
// We do not use new Date(string): on an ISO date without timezone some engines
// interpret UTC and others local time, and at midnight the offset becomes a
// whole day of difference in the count. In addition, existing data has
// non-zero-padded formats ("2026-10-3") which `date -d` accepted and which must
// continue to be accepted.
function parseDate(value) {
  var parts = String(value || "").trim().split("-")
  if (parts.length !== 3) return null

  var y = parseInt(parts[0], 10)
  var m = parseInt(parts[1], 10)
  var d = parseInt(parts[2], 10)
  if (!isFinite(y) || !isFinite(m) || !isFinite(d)) return null
  if (m < 1 || m > 12 || d < 1 || d > 31) return null

  var date = new Date(y, m - 1, d)
  // Discard February 31st and similar: the constructor makes them slide to the next month.
  if (date.getFullYear() !== y || date.getMonth() !== m - 1 || date.getDate() !== d) return null
  return date
}

// Canonical format on disk, always zero-padded.
function formatDate(date) {
  if (!(date instanceof Date) || isNaN(date.getTime())) return ""
  var m = date.getMonth() + 1
  var d = date.getDate()
  return date.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d
}

function today() {
  var now = new Date()
  return new Date(now.getFullYear(), now.getMonth(), now.getDate())
}

function clampPercent(value) {
  if (!isFinite(value)) return 0
  return Math.max(0, Math.min(100, value))
}

// "invalid" (unreadable dates or null interval) | "expired" | "active"
function statusOf(entry, nowMs) {
  if (!isObject(entry)) return "invalid"
  var start = parseDate(entry.start)
  var end = parseDate(entry.end)
  if (!start || !end) return "invalid"
  if (end.getTime() <= start.getTime()) return "invalid"
  return nowMs >= end.getTime() ? "expired" : "active"
}

function remainingMs(entry, nowMs) {
  var end = parseDate(entry ? entry.end : null)
  if (!end) return 0
  return Math.max(0, end.getTime() - nowMs)
}

// How much has already elapsed, 0-100. This is what draws the progress
// bar: the old script output it as `percentage` and the "command" type
// of the bar threw it away.
function elapsedPercent(entry, nowMs) {
  if (statusOf(entry, nowMs) === "invalid") return 0
  var start = parseDate(entry.start)
  var end = parseDate(entry.end)
  var total = end.getTime() - start.getTime()
  if (total <= 0) return 0
  return clampPercent(((nowMs - start.getTime()) / total) * 100)
}

// How much remains, 0-100 — the number that the old widget showed with
// format "percentage".
function remainingPercent(entry, nowMs) {
  if (statusOf(entry, nowMs) === "invalid") return 0
  return clampPercent(100 - elapsedPercent(entry, nowMs))
}

function remainingDays(entry, nowMs) {
  return Math.floor(remainingMs(entry, nowMs) / MS_DAY)
}

// "days" | "percentage" | "auto".
//
// "auto" is the new addition: as long as more than a day is left it counts days, then
// switches to hours and finally to minutes. The old "days" format on the last day
// showed "0d left" for twenty-four hours.
function formatRemaining(entry, nowMs, format) {
  var status = statusOf(entry, nowMs)
  if (status === "invalid") return "Invalid"
  if (status === "expired") return "Expired"

  var fmt = String(format || entry.format || "days")
  if (fmt === "percentage") return Math.round(remainingPercent(entry, nowMs)) + "% left"

  var ms = remainingMs(entry, nowMs)
  if (fmt === "auto" && ms < MS_DAY) {
    var hours = Math.floor(ms / 3600000)
    if (hours >= 1) return hours + "h left"
    return Math.max(1, Math.floor(ms / 60000)) + "m left"
  }
  return Math.floor(ms / MS_DAY) + "d left"
}

function shortLabel(label, max) {
  var text = String(label || "")
  var limit = Number(max) > 0 ? Number(max) : 16
  return text.length > limit ? text.substring(0, limit) + "…" : text
}

// The widget text: "Release 1.0 - 51d left".
function barText(entry, nowMs, format, maxLabel) {
  if (!isObject(entry)) return "No countdowns"
  return shortLabel(entry.label, maxLabel) + " - " + formatRemaining(entry, nowMs, format)
}

// Line by line, what the panel shows.
function describe(entry, nowMs) {
  var status = statusOf(entry, nowMs)
  return {
    label: String(entry && entry.label ? entry.label : ""),
    start: String(entry && entry.start ? entry.start : ""),
    end: String(entry && entry.end ? entry.end : ""),
    format: String(entry && entry.format ? entry.format : "days"),
    status: status,
    days: status === "active" ? remainingDays(entry, nowMs) : 0,
    elapsed: elapsedPercent(entry, nowMs),
    remaining: formatRemaining(entry, nowMs, null)
  }
}

// ---- Status on disk -------------------------------------------------------

// Normalizes whatever is in the file. A corrupt or half-written file must
// not make the widget disappear: it restarts from a valid empty state.
function normalize(raw) {
  var out = { state: { current_index: 0 }, countdowns: [] }
  if (!isObject(raw)) return out

  if (Array.isArray(raw.countdowns)) {
    for (var i = 0; i < raw.countdowns.length; i++) {
      var e = raw.countdowns[i]
      if (!isObject(e)) continue
      out.countdowns.push({
        label: String(e.label || ""),
        start: String(e.start || ""),
        end: String(e.end || ""),
        format: String(e.format || "days")
      })
    }
  }

  var idx = isObject(raw.state) ? parseInt(raw.state.current_index, 10) : 0
  if (!isFinite(idx) || idx < 0 || idx >= out.countdowns.length) idx = 0
  out.state.current_index = idx
  return out
}

// Next/previous index, cyclic.
function cycleIndex(current, count, delta) {
  if (count <= 0) return 0
  var next = (Number(current) || 0) + (delta < 0 ? -1 : 1)
  if (next < 0) return count - 1
  if (next >= count) return 0
  return next
}

// Shared validation between the panel form and saving: returns
// "" if it is okay, otherwise the reason.
function validate(entry) {
  if (!isObject(entry)) return "Invalid entry"
  if (String(entry.label || "").trim() === "") return "Label cannot be empty"
  if (!parseDate(entry.start)) return "Invalid start date (YYYY-MM-DD)"
  if (!parseDate(entry.end)) return "Invalid end date (YYYY-MM-DD)"
  if (parseDate(entry.end).getTime() <= parseDate(entry.start).getTime())
    return "End must come after start"
  return ""
}
