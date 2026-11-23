.pragma library

var MAX_PRINTERS = 50
var MAX_JOBS = 100
var MAX_DISCOVERED = 50
var MAX_FILES = 20
var MAX_TEXT = 180

var QUEUE_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$/
var ALLOWED_SCHEMES = [
  "ipp://", "ipps://", "dnssd://", "usb://", "socket://",
  "http://", "https://", "lpd://", "smb://", "hp://",
  "hpfax://", "serial://", "parallel://"
]

// Neutralizes untrusted dynamic text before passing it to any shared tooltip,
// notification, or Omarchy-owned component whose internal Text format cannot
// be pinned to Text.PlainText. Eliminates HTML/XML tag delimiters and entity
// sequences so Qt AutoText or notification markup parsers can never promote
// the string to rich text or fetch remote resources.
function sanitizePlainText(value, maxLen) {
  var limit = (typeof maxLen === "number" && maxLen > 0) ? Math.floor(maxLen) : MAX_TEXT
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\u0000-\u001f\u007f]+/g, " ")
  text = text.replace(/\s+/g, " ").trim()
  text = text.replace(/</g, "\u2039").replace(/>/g, "\u203A")
  text = text.replace(/&(#?[A-Za-z0-9]+);/g, "&\u200B$1;")
  if (text.length > limit) text = text.substring(0, Math.max(1, limit - 1)) + "\u2026"
  return text
}

// Notification headlines/bodies passed to omarchy-notification-send must also
// never look like a CLI flag (leading "-").
function sanitizeNotificationArg(value, maxLen) {
  var text = sanitizePlainText(value, maxLen || 160)
  if (text.charAt(0) === "-") text = "\u2022 " + text.replace(/^-+/, "").trim()
  return text
}

function clampInt(value, fallback, minVal, maxVal) {
  var n = parseInt(String(value), 10)
  if (!isFinite(n)) n = fallback
  if (minVal !== undefined && n < minVal) n = minVal
  if (maxVal !== undefined && n > maxVal) n = maxVal
  return n
}

function isValidQueueName(name) {
  return QUEUE_NAME_RE.test(String(name || "").trim())
}

function isValidPrinterUri(uri) {
  var s = String(uri || "").trim()
  if (!s || s.length > 512 || /[\u0000-\u001f\u007f\s]/.test(s)) return false
  var low = s.toLowerCase()
  for (var i = 0; i < ALLOWED_SCHEMES.length; i++) {
    if (low.indexOf(ALLOWED_SCHEMES[i]) === 0) return true
  }
  return false
}

function sanitizeQueueName(raw) {
  var s = String(raw || "").trim().replace(/[^A-Za-z0-9._-]+/g, "-").replace(/-{2,}/g, "-").replace(/^[._-]+|[._-]+$/g, "")
  if (!s || !/^[A-Za-z0-9]/.test(s)) s = "Printer" + (s ? "-" + s : "")
  return s.substring(0, 64)
}

function sanitizeOptionsMap(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  var slots = ["paperSize", "colorMode", "quality", "duplex"]
  for (var i = 0; i < slots.length; i++) {
    var slot = slots[i]
    var item = raw[slot]
    if (!item || typeof item !== "object" || !Array.isArray(item.choices) || item.choices.length === 0) continue
    var choices = []
    for (var j = 0; j < Math.min(item.choices.length, 64); j++) {
      var c = sanitizePlainText(item.choices[j], 128)
      if (c !== "") choices.push(c)
    }
    if (choices.length === 0) continue
    var cur = sanitizePlainText(item.current, 128)
    out[slot] = {
      key: sanitizePlainText(item.key, 64),
      label: sanitizePlainText(item.label, 80),
      current: choices.indexOf(cur) >= 0 ? cur : choices[0],
      choices: choices
    }
  }
  return out
}

function sanitizeMarkers(raw) {
  var out = []
  if (!Array.isArray(raw)) return out
  for (var i = 0; i < Math.min(raw.length, 12); i++) {
    var m = raw[i]
    if (!m || typeof m !== "object") continue
    var color = String(m.color || "")
    if (!/^#[0-9A-Fa-f]{6}$/.test(color)) color = ""
    out.push({
      name: sanitizePlainText(m.name || ("Marker " + (i + 1)), 64),
      level: clampInt(m.level, -1, -3, 100),
      color: color,
      type: sanitizePlainText(m.type || "", 40)
    })
  }
  return out
}

function sanitizeMaintenance(raw) {
  if (!raw || typeof raw !== "object") {
    return {
      backend: "none",
      cleanHeads: false,
      nozzleCheck: false,
      alignment: false,
      reportLevels: false,
      autoConfigure: false
    }
  }
  var backend = String(raw.backend || "none")
  if (backend !== "cups-command" && backend !== "escpx-raw" && backend !== "hplip") backend = "none"
  return {
    backend: backend,
    cleanHeads: raw.cleanHeads === true,
    nozzleCheck: raw.nozzleCheck === true,
    alignment: raw.alignment === true,
    reportLevels: raw.reportLevels === true,
    autoConfigure: raw.autoConfigure === true
  }
}

function sanitizePrinter(p) {
  if (!p || typeof p !== "object") return null
  var name = String(p.name || "").trim()
  if (!isValidQueueName(name)) return null
  var reasons = []
  if (Array.isArray(p.stateReasons)) {
    for (var i = 0; i < Math.min(p.stateReasons.length, 10); i++) {
      var r = sanitizePlainText(p.stateReasons[i], 80)
      if (r !== "") reasons.push(r)
    }
  }
  var policy = String(p.errorPolicy || "stop-printer")
  if (policy !== "stop-printer" && policy !== "retry-job" && policy !== "abort-job") policy = "stop-printer"
  return {
    name: name,
    info: sanitizePlainText(p.info || name, 140) || name,
    location: sanitizePlainText(p.location || "", 140),
    makeModel: sanitizePlainText(p.makeModel || "", 160),
    deviceUri: sanitizePlainText(p.deviceUri || "", 320),
    isDefault: p.isDefault === true,
    printerState: clampInt(p.state, 0, 0, 9),
    stateKey: sanitizePlainText(p.stateKey || "unknown", 24),
    stateMessage: sanitizePlainText(p.stateMessage || "", 180),
    stateReasons: reasons,
    hasError: p.hasError === true,
    hasWarning: p.hasWarning === true,
    acceptingJobs: p.acceptingJobs !== false,
    shared: p.shared === true,
    errorPolicy: policy,
    activeJobCount: clampInt(p.activeJobCount, 0, 0, 9999),
    markers: sanitizeMarkers(p.markers),
    options: sanitizeOptionsMap(p.options),
    maintenance: sanitizeMaintenance(p.maintenance)
  }
}

function sanitizeJob(j) {
  if (!j || typeof j !== "object") return null
  var id = clampInt(j.id, 0, 0, 2147483647)
  if (id <= 0) return null
  var reasons = []
  if (Array.isArray(j.stateReasons)) {
    for (var i = 0; i < Math.min(j.stateReasons.length, 6); i++) {
      var r = sanitizePlainText(j.stateReasons[i], 80)
      if (r !== "") reasons.push(r)
    }
  }
  return {
    id: id,
    title: sanitizePlainText(j.title || "", 140),
    printer: sanitizePlainText(j.printer || "", 128),
    user: sanitizePlainText(j.user || "", 64),
    jobState: clampInt(j.state, 0, 0, 9),
    stateKey: sanitizePlainText(j.stateKey || "unknown", 24),
    stateReasons: reasons,
    copies: clampInt(j.copies, 1, 1, 9999),
    sizeKb: clampInt(j.sizeKb, 0, 0, 10000000),
    pagesCompleted: clampInt(j.pagesCompleted, 0, 0, 100000),
    createdAt: clampInt(j.createdAt, 0, 0, 4102444800),
    completedAt: clampInt(j.completedAt, 0, 0, 4102444800),
    documentFormat: sanitizePlainText(j.documentFormat || "", 64),
    isActive: j.isActive === true,
    canHold: j.canHold === true,
    canRelease: j.canRelease === true,
    canRestart: j.canRestart === true
  }
}

function parseStatus(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (!data || typeof data !== "object" || data.ok !== true) return { ok: false }
    var printers = []
    if (Array.isArray(data.printers)) {
      for (var i = 0; i < Math.min(data.printers.length, MAX_PRINTERS); i++) {
        var sp = sanitizePrinter(data.printers[i])
        if (sp) printers.push(sp)
      }
    }
    var jobs = []
    if (Array.isArray(data.jobs)) {
      for (var j = 0; j < Math.min(data.jobs.length, MAX_JOBS); j++) {
        var sj = sanitizeJob(data.jobs[j])
        if (sj) jobs.push(sj)
      }
    }
    var completed = []
    if (Array.isArray(data.completedJobs)) {
      for (var c = 0; c < Math.min(data.completedJobs.length, MAX_JOBS); c++) {
        var sc = sanitizeJob(data.completedJobs[c])
        if (sc) completed.push(sc)
      }
    }
    var srv = data.serverSettings && typeof data.serverSettings === "object" ? data.serverSettings : {}
    return {
      ok: true,
      cupsRunning: data.cupsRunning === true,
      systemConfigInstalled: data.systemConfigInstalled === true,
      defaultPrinter: sanitizePlainText(data.defaultPrinter || "", 128),
      printers: printers,
      jobs: jobs,
      completedJobs: completed,
      activeJobCount: jobs.length,
      serverSettings: {
        sharePrinters: srv.sharePrinters === true,
        userCancelAny: srv.userCancelAny === true,
        webInterface: srv.webInterface !== false
      },
      statusOnly: data.statusOnly === true,
      warning: sanitizePlainText(data.warning || "", 180)
    }
  } catch (e) {
    return { ok: false }
  }
}

function parseDiscover(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (!data || typeof data !== "object" || data.ok !== true || !Array.isArray(data.devices)) {
      return { ok: false, error: sanitizePlainText(data && data.error ? data.error : "", 180), devices: [] }
    }
    var devices = []
    for (var i = 0; i < Math.min(data.devices.length, MAX_DISCOVERED); i++) {
      var d = data.devices[i]
      if (!d || typeof d !== "object") continue
      var uri = String(d.uri || "").trim()
      if (!isValidPrinterUri(uri)) continue
      devices.push({
        uri: uri,
        uriDisplay: sanitizePlainText(uri, 240),
        info: sanitizePlainText(d.info || d.makeModel || uri, 140),
        makeModel: sanitizePlainText(d.makeModel || d.info || "", 160),
        deviceClass: sanitizePlainText(d.deviceClass || "network", 32),
        driverless: d.driverless === true,
        alreadyConfigured: d.alreadyConfigured === true,
        suggestedName: sanitizeQueueName(d.suggestedName || d.info || "Printer")
      })
    }
    return { ok: true, devices: devices, error: "" }
  } catch (e) {
    return { ok: false, devices: [], error: "" }
  }
}

function parseRecentFiles(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (!data || typeof data !== "object" || data.ok !== true || !Array.isArray(data.files)) {
      return { ok: false, files: [] }
    }
    var files = []
    for (var i = 0; i < Math.min(data.files.length, MAX_FILES); i++) {
      var f = data.files[i]
      if (!f || typeof f !== "object" || !f.path) continue
      files.push({
        name: sanitizePlainText(f.name || "", 120),
        path: String(f.path),
        folder: sanitizePlainText(f.folder || "", 48),
        sizeKb: clampInt(f.sizeKb, 1, 1, 10000000)
      })
    }
    return { ok: true, files: files }
  } catch (e) {
    return { ok: false, files: [] }
  }
}

function parseActionResult(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (!data || typeof data !== "object") return { ok: false, error: "" }
    return {
      ok: data.ok === true,
      action: sanitizePlainText(data.action || "", 40),
      printer: sanitizePlainText(data.printer || "", 128),
      title: sanitizePlainText(data.title || "", 140),
      dest: sanitizePlainText(data.dest || "", 128),
      jobId: clampInt(data.jobId, 0, 0, 2147483647),
      error: sanitizePlainText(data.error || "", 180)
    }
  } catch (e) {
    return { ok: false, error: "" }
  }
}

function printerStateLabel(printer, t) {
  if (!printer) return t("printers.state.unknown")
  if (!printer.acceptingJobs) return t("printers.state.rejecting")
  if (printer.stateKey === "printing") return t("printers.state.printing")
  if (printer.stateKey === "stopped") return t("printers.state.stopped")
  if (printer.stateKey === "idle") return t("printers.state.idle")
  return t("printers.state.unknown")
}

function jobStateLabel(job, t) {
  if (!job) return t("job.state.unknown")
  var key = "job.state." + String(job.stateKey || "unknown")
  return t(key)
}

function formatSizeKb(kb, formatNumber, t) {
  var val = Number(kb) || 0
  if (val >= 1024) {
    var mb = val / 1024
    return t("queue.sizeMb").arg(formatNumber(mb, mb < 10 ? 1 : 0))
  }
  return t("queue.sizeKb").arg(formatNumber(Math.max(1, Math.round(val))))
}

function normalizeOptionLabel(slot, value, t) {
  var v = String(value || "")
  var low = v.toLowerCase()
  if (slot === "colorMode") {
    if (low === "color" || low === "rgb" || low === "cmyk") return t("printers.option.color")
    if (low === "mono" || low === "monochrome" || low === "gray" || low === "grayscale") return t("printers.option.mono")
  }
  if (slot === "duplex") {
    if (low === "one-sided" || low === "none" || low === "false") return t("printers.option.oneSided")
    if (low === "two-sided-long-edge" || low === "duplexnotumble") return t("printers.option.twoSidedLong")
    if (low === "two-sided-short-edge" || low === "duplextumble") return t("printers.option.twoSidedShort")
  }
  if (slot === "quality") {
    if (low === "3" || low.indexOf("draft") !== -1) return t("printers.option.draft") + (low.indexOf("_") !== -1 ? " (" + v + ")" : "")
    if (low === "4" || low === "plain_normal" || low === "normal") return t("printers.option.normal")
    if (low === "5" || low === "plain_high" || low === "high") return t("printers.option.high")
  }
  if (slot === "paperSize") {
    if (low.indexOf("iso_a4") === 0) return "A4"
    if (low.indexOf("iso_a5") === 0) return "A5"
    if (low.indexOf("iso_a6") === 0) return "A6"
    if (low.indexOf("iso_a3") === 0) return "A3"
    if (low.indexOf("na_letter") === 0) return "Letter"
    if (low.indexOf("na_legal") === 0) return "Legal"
  }
  return sanitizePlainText(v.replace(/_/g, " "), 48)
}

function buildBarTooltip(cupsRunning, printers, defaultPrinterName, activeJobCount, t, tn, formatNumber) {
  if (!cupsRunning) return sanitizePlainText(t("tooltip.cupsStopped"), 160)
  if (!printers || printers.length === 0) return sanitizePlainText(t("tooltip.noPrinters"), 160)

  var primary = printers[0]
  for (var i = 0; i < printers.length; i++) {
    if (printers[i].name === defaultPrinterName || printers[i].isDefault) {
      primary = printers[i]
      break
    }
  }
  var label = sanitizePlainText(primary.info || primary.name, 64)
  if (activeJobCount > 0) {
    return sanitizePlainText(tn("tooltip.activeJobs", activeJobCount).arg(label).arg(formatNumber(activeJobCount)), 160)
  }
  if (primary.hasError) {
    return sanitizePlainText(t("tooltip.error").arg(label), 160)
  }
  if (primary.stateKey === "stopped") {
    return sanitizePlainText(t("tooltip.paused").arg(label), 160)
  }
  return sanitizePlainText(t("tooltip.idle").arg(label), 160)
}

// Diffs previous and current snapshots to emit clean, neutralized notification
// descriptors when a print job completes/fails or a printer enters an alert state.
function detectNotificationEvents(prevJobs, nextJobs, nextCompleted, prevPrinters, nextPrinters, t) {
  var events = []
  var prevJobMap = {}
  for (var i = 0; i < (prevJobs || []).length; i++) prevJobMap[prevJobs[i].id] = prevJobs[i]

  var nextActiveIds = {}
  for (var j = 0; j < (nextJobs || []).length; j++) nextActiveIds[nextJobs[j].id] = true

  var completedMap = {}
  for (var c = 0; c < (nextCompleted || []).length; c++) completedMap[nextCompleted[c].id] = nextCompleted[c]

  for (var idStr in prevJobMap) {
    if (nextActiveIds[idStr]) continue
    var oldJob = prevJobMap[idStr]
    var done = completedMap[idStr]
    var jobTitle = sanitizeNotificationArg(oldJob.title || t("queue.jobTitleFallback").arg(String(oldJob.id)), 80)
    var printerName = sanitizeNotificationArg(oldJob.printer || t("plugin.title"), 64)
    if (done && (done.stateKey === "aborted" || done.stateKey === "stopped")) {
      events.push({
        urgency: "normal",
        glyph: "󰐬",
        headline: sanitizeNotificationArg(t("notify.jobFailedTitle"), 80),
        body: sanitizeNotificationArg(t("notify.jobFailedBody").arg(jobTitle).arg(printerName), 160)
      })
    } else if (!done || done.stateKey === "completed") {
      events.push({
        urgency: "low",
        glyph: "󰐪",
        headline: sanitizeNotificationArg(t("notify.jobCompletedTitle"), 80),
        body: sanitizeNotificationArg(t("notify.jobCompletedBody").arg(jobTitle).arg(printerName), 160)
      })
    }
  }

  var prevErrorMap = {}
  for (var p = 0; p < (prevPrinters || []).length; p++) prevErrorMap[prevPrinters[p].name] = prevPrinters[p].hasError === true
  for (var n = 0; n < (nextPrinters || []).length; n++) {
    var np = nextPrinters[n]
    if (np.hasError && prevErrorMap[np.name] !== true) {
      var reason = np.stateMessage || (np.stateReasons && np.stateReasons.length > 0 ? np.stateReasons[0] : t("hero.attention"))
      events.push({
        urgency: "normal",
        glyph: "󰐬",
        headline: sanitizeNotificationArg(t("notify.printerAlertTitle"), 80),
        body: sanitizeNotificationArg(t("notify.printerAlertBody").arg(sanitizePlainText(np.info || np.name, 64)).arg(sanitizePlainText(reason, 90)), 160)
      })
    }
  }

  return events.slice(0, 3)
}
