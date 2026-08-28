// Pure helpers for the iPhone panel: parsing the helper's TSV, deciding what
// each pairing state offers, and turning tool vocabulary into words. Kept
// free of QML types so the panel stays a thin renderer.

var STATUS_FIELDS = 7
var DEPS_FIELDS = 2

var MAX_INPUT = 65536    // characters accepted from one helper run
var MAX_ROWS = 16        // devices kept
var MAX_FIELD = 256      // characters kept per field
var MAX_DIAG = 400       // characters of diagnostic text kept

function clip(value) {
  return String(value === undefined || value === null ? "" : value).slice(0, MAX_FIELD)
}

function clipDiag(value) {
  return String(value === undefined || value === null ? "" : value).trim().slice(0, MAX_DIAG)
}

var GLYPH = {
  phone: "󰄜",
  photos: "󰄀",
  import: "󰇚",
  eject: "󰓛",
  pair: "󰌆",
  retry: "󰑓",
  alert: "󰀦",
  fix: "󰐊",
  charging: "󰂄"
}

// Pairing is a conversation with a human holding the phone; each of its
// stops is a state with its own next step, never a bare error. An unknown
// state offers nothing rather than guessing.
var STATES = {
  paired:          { photos: true,  pair: false, retry: false, active: true },
  unpaired:        { photos: false, pair: true,  retry: false, active: false },
  "trust-pending": { photos: false, pair: false, retry: true,  active: false },
  denied:          { photos: false, pair: true,  retry: false, active: false },
  locked:          { photos: false, pair: false, retry: true,  active: false }
}

var UNKNOWN_STATE = { photos: false, pair: false, retry: false, active: false }

function stateRules(state) {
  return STATES[String(state || "")] || UNKNOWN_STATE
}

// One line per device:
//   udid \t name \t state \t battery% \t charging \t mounted \t ios
// Anything shorter is a truncated read and is dropped rather than guessed at.
function parseStatus(raw) {
  var rows = []
  var lines = String(raw || "").slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length && rows.length < MAX_ROWS; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\t")
    if (f.length < STATUS_FIELDS) continue
    var state = clip(f[2])
    var batt = parseInt(f[3], 10)
    rows.push({
      udid: clip(f[0]),
      name: clip(f[1]) || "iPhone",
      state: state,
      battery: isNaN(batt) ? -1 : Math.max(0, Math.min(100, batt)),
      charging: f[4] === "1",
      mounted: f[5] === "1",
      ios: clip(f[6]),
      paired: state === "paired",
      active: stateRules(state).active
    })
  }
  return rows
}

// name \t ok|missing|inactive|stuck → the pieces that are not fine.
function parseDeps(raw) {
  var broken = []
  var lines = String(raw || "").slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length && i < 16; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\t")
    if (f.length < DEPS_FIELDS) continue
    if (f[1] !== "ok") broken.push({ name: clip(f[0]), state: clip(f[1]) })
  }
  return broken
}

// The setup card's one sentence: installing and restarting are different
// promises, and the card must make the one the button will keep.
function depsText(broken) {
  if (!broken || broken.length === 0) return ""
  var missing = [], stuck = []
  for (var i = 0; i < broken.length; i++) {
    if (broken[i].state === "missing") missing.push(broken[i].name)
    else stuck.push(broken[i].name)
  }
  var parts = []
  if (missing.length > 0) parts.push("iPhone support needs " + missing.join(", "))
  if (stuck.length > 0) parts.push(stuck.join(", ") + " needs a restart")
  return parts.join("; ") + "."
}

// The actions a row offers, in the order they are drawn — also the order the
// keyboard cursor walks, so the two can never drift apart.
function rowActions(row) {
  if (!row) return []
  var rules = stateRules(row.state)
  var actions = []
  if (rules.photos)
    actions.push({ id: "photos", icon: GLYPH.photos, tooltip: "Open camera roll (DCIM)", urgent: false })
  if (rules.photos)
    actions.push({ id: "import", icon: GLYPH.import, tooltip: "Import photos to this computer — choose how far back", urgent: false })
  if (rules.photos && row.mounted)
    actions.push({ id: "unmount", icon: GLYPH.eject, tooltip: "Eject (unmount)", urgent: true })
  if (rules.pair)
    actions.push({ id: "pair", icon: GLYPH.pair, tooltip: "Pair with this computer", urgent: false })
  if (rules.retry)
    actions.push({ id: "retry", icon: GLYPH.retry, tooltip: "Check again", urgent: false })
  return actions
}

// "imported \t N \t folder \t partial \t elapsed-seconds" from the import.
function parseImport(raw) {
  var f = String(raw || "").slice(0, MAX_INPUT).trim().split("\t")
  if (f.length < 3 || f[0] !== "imported") return null
  var n = parseInt(f[1], 10)
  var s = parseInt(f[4], 10)
  return {
    count: isNaN(n) ? 0 : n,
    folder: clip(f[2]),
    partial: f[3] === "1",
    seconds: isNaN(s) ? 0 : Math.max(0, s)
  }
}

// Seconds as a person would say them: "45 s", "3 min 12 s", "1 h 8 min".
function elapsedText(seconds) {
  seconds = Math.max(0, Math.round(Number(seconds) || 0))
  if (seconds < 60) return seconds + " s"
  var m = Math.floor(seconds / 60), s = seconds % 60
  if (m < 60) return s > 0 ? m + " min " + s + " s" : m + " min"
  var h = Math.floor(m / 60); m = m % 60
  return m > 0 ? h + " h " + m + " min" : h + " h"
}

// The body of the "import finished" desktop notification: what synced, how
// long it took, and where the files landed.
function importNotifyBody(result) {
  if (!result) return ""
  var text = countPhotos(result.count) + " in " + elapsedText(result.seconds) + "\n" + result.folder
  if (result.partial) text += "\nSome items live only in iCloud and were skipped."
  return text
}

function importNotice(result) {
  if (!result) return ""
  var text
  if (result.count === 0) text = "Nothing new to import"
  else text = result.count + (result.count === 1 ? " new photo" : " new photos") + " → " + result.folder
  // The skipped items are the ones whose originals live only in iCloud:
  // name the cause, or the user will re-click forever chasing them.
  if (result.partial) text += " · some items live only in iCloud and were skipped"
  return text
}

// The import menu: pick how far back to reach. Newest windows first, "all"
// last where it carries a size the others do not need.
var IMPORT_WINDOWS = [
  { id: "5min", label: "Last 5 minutes" },
  { id: "24h",  label: "Last 24 hours" },
  { id: "7d",   label: "Last 7 days" },
  { id: "all",  label: "All photos" }
]

// Roughly what AFC-over-USB moves on this class of phone; only ever used to
// turn a byte count into "~N min", so approximate is the point.
var IMPORT_MBPS = 30

function planNumber(value) {
  var n = parseInt(value, 10)
  return isNaN(n) ? 0 : Math.max(0, n)
}

// "plan \t c5 \t b5 \t c24 \t b24 \t c7 \t b7 \t all-count \t all-bytes"
// Every window carries a count and bytes, all meaning "not already imported",
// so a window is always a subset of "all".
function parseImportPlan(raw) {
  var f = String(raw || "").slice(0, MAX_INPUT).trim().split("\t")
  if (f.length < 9 || f[0] !== "plan") return null
  return {
    "5min": { count: planNumber(f[1]), bytes: planNumber(f[2]) },
    "24h": { count: planNumber(f[3]), bytes: planNumber(f[4]) },
    "7d": { count: planNumber(f[5]), bytes: planNumber(f[6]) },
    all: { count: planNumber(f[7]), bytes: planNumber(f[8]) }
  }
}

function humanSize(bytes) {
  bytes = Number(bytes) || 0
  if (bytes < 1024) return bytes + " B"
  var units = ["KB", "MB", "GB", "TB"], i = -1, v = bytes
  do { v /= 1024; i++ } while (v >= 1024 && i < units.length - 1)
  return (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + " " + units[i]
}

function estimateText(bytes) {
  var secs = (Number(bytes) || 0) / (IMPORT_MBPS * 1024 * 1024)
  if (secs < 45) return "under a minute"
  if (secs < 5400) return "~" + Math.max(1, Math.round(secs / 60)) + " min"
  return "~" + Math.round(secs / 3600) + " h"
}

function countPhotos(n) {
  return n + (n === 1 ? " photo" : " photos")
}

// The second line under each menu row: a count for the recent windows, and
// count · size · time for "all", where the download is worth sizing up. Null
// plan means "still counting", which the panel shows as an ellipsis.
function importWindowSummary(win, plan) {
  if (!plan) return ""
  if (win === "all") {
    if (plan.all.count === 0) return "nothing new to import"
    return countPhotos(plan.all.count) + " · " + humanSize(plan.all.bytes) + " · " + estimateText(plan.all.bytes)
  }
  var c = plan[win] ? plan[win].count : 0
  return c === 0 ? "none" : countPhotos(c)
}

// The second line under the device name: what to DO next.
function stateText(row) {
  if (!row) return ""
  switch (row.state) {
    case "paired": {
      var parts = []
      if (row.battery >= 0) parts.push((row.charging ? GLYPH.charging + " " : "") + row.battery + "%")
      if (row.ios) parts.push("iOS " + row.ios)
      parts.push(row.mounted ? "mounted" : "connected")
      return parts.join(" · ")
    }
    case "unpaired": return "Not paired yet — press Pair"
    case "trust-pending": return "Unlock the iPhone and tap Trust, then check again"
    case "denied": return "Trust was declined on the phone — press Pair to ask again"
    case "locked": return "Enter the passcode on the phone, then check again"
    default: return row.state
  }
}

function busyLabel(action) {
  if (action === "pair") return "Pairing…"
  if (action === "retry") return "Checking…"
  if (action === "photos") return "Opening photos…"
  if (action === "import") return "Importing new photos…"
  if (action === "unmount") return "Ejecting…"
  return "Working…"
}

function summary(rows) {
  if (rows.length === 0) return "No iPhone connected"
  var paired = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].paired) paired++
  if (paired === rows.length) return rows.length === 1 ? rows[0].name : rows.length + " devices"
  return rows.length + (rows.length === 1 ? " device" : " devices") + " · " + (rows.length - paired) + " to pair"
}

// The one number the bar paints. -1 means nothing worth painting.
function barBattery(rows) {
  for (var i = 0; i < rows.length; i++)
    if (rows[i].paired && rows[i].battery >= 0) return rows[i].battery
  return -1
}

// Devices the user should look at: a pairing conversation waiting on them.
function attentionCount(rows) {
  var n = 0
  for (var i = 0; i < rows.length; i++)
    if (rows[i].state === "trust-pending" || rows[i].state === "denied" || rows[i].state === "locked") n++
  return n
}

function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

// The helper speaks in short codes so the panel owns the wording.
function errorText(code) {
  switch (String(code || "").trim()) {
    case "": return ""
    case "libimobiledevice-missing": return "libimobiledevice is not installed"
    case "usbmuxd-missing": return "usbmuxd is not installed"
    case "ifuse-missing": return "ifuse is not installed"
    case "polkit-missing": return "pkexec is not installed"
    case "pacman-missing": return "pacman is not available"
    case "fix-dismissed": return "Authorization dismissed — nothing was changed"
    case "fix-failed": return "Could not install the missing pieces"
    case "muxd-unreachable": return "usbmuxd is not answering — press Set up, or re-plug the cable"
    case "no-device": return "No iPhone found"
    case "not-paired": return "Pair the iPhone first"
    case "trust-pending": return "Unlock the iPhone and tap Trust"
    case "pair-denied": return "Trust was declined on the phone"
    case "passcode-locked": return "Enter the passcode on the phone first"
    case "device-locked": return "Unlock the iPhone, then try again"
    case "mount-failed": return "Could not mount the iPhone"
    case "unmount-failed": return "Could not eject — something is still using the files"
    case "unpair-failed": return "Could not unpair the device"
    case "rsync-missing": return "rsync is not installed"
    case "bad-folder": return "The import folder is not a valid absolute path"
    case "no-photos": return "No camera roll on this device"
    default: return String(code).trim()
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_INPUT: MAX_INPUT,
    MAX_ROWS: MAX_ROWS,
    MAX_FIELD: MAX_FIELD,
    MAX_DIAG: MAX_DIAG,
    GLYPH: GLYPH,
    clip: clip,
    clipDiag: clipDiag,
    stateRules: stateRules,
    parseStatus: parseStatus,
    parseDeps: parseDeps,
    depsText: depsText,
    rowActions: rowActions,
    parseImport: parseImport,
    importNotice: importNotice,
    elapsedText: elapsedText,
    importNotifyBody: importNotifyBody,
    IMPORT_WINDOWS: IMPORT_WINDOWS,
    parseImportPlan: parseImportPlan,
    humanSize: humanSize,
    estimateText: estimateText,
    importWindowSummary: importWindowSummary,
    stateText: stateText,
    busyLabel: busyLabel,
    summary: summary,
    barBattery: barBattery,
    attentionCount: attentionCount,
    clampIndex: clampIndex,
    errorText: errorText
  }
}
