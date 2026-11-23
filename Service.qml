import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property var strings: null
  property bool panelOpen: false
  property bool includeCompleted: false

  property bool initialized: false
  property bool cupsRunning: true
  property bool systemConfigInstalled: true
  property string defaultPrinter: ""
  property var printers: []
  property var jobs: []
  property var completedJobs: []
  property int activeJobCount: 0
  property var serverSettings: ({ sharePrinters: false, userCancelAny: false, webInterface: true })
  property var discoveredDevices: []
  property bool hasScannedDevices: false
  property var recentFiles: []

  property bool refreshing: false
  property bool discovering: false
  property bool loadingFiles: false
  property bool actionBusy: false
  property string actionStatus: ""
  property string lastError: ""

  property bool _fullRefreshPending: false
  property string _pendingActionTag: ""
  property string _pendingActionSubject: ""
  property string _pendingActionExtra: ""

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("cups_ctl.py")).replace(/^file:\/\//, ""))

  readonly property int refreshIntervalSec: Model.clampInt(setting("refreshIntervalSec", 15), 15, 0, 300)
  readonly property bool notifyEvents: setting("notifyEvents", true) !== false
  readonly property int maxHistoryJobs: Model.clampInt(setting("maxHistoryJobs", 20), 20, 5, 50)

  readonly property int errorPrinterCount: {
    var count = 0
    for (var i = 0; i < printers.length; i++) {
      if (printers[i] && printers[i].hasError) count++
    }
    return count
  }

  readonly property bool allPaused: {
    if (printers.length === 0) return false
    for (var i = 0; i < printers.length; i++) {
      if (printers[i] && printers[i].stateKey !== "stopped") return false
    }
    return true
  }

  readonly property var primaryPrinter: {
    if (!printers || printers.length === 0) return null
    for (var i = 0; i < printers.length; i++) {
      if (printers[i].name === defaultPrinter || printers[i].isDefault) return printers[i]
    }
    return printers[0]
  }

  function setting(name, fallback) {
    var val = settings ? settings[name] : undefined
    return val === undefined || val === null ? fallback : val
  }

  function tr(key) {
    return strings ? strings.t(key) : key
  }

  function setStatusMessage(text) {
    lastError = ""
    actionStatus = Model.sanitizePlainText(text, 160)
    actionStatusTimer.restart()
  }

  function setErrorMessage(text) {
    actionStatus = ""
    lastError = Model.sanitizePlainText(text, 180)
  }

  function sendNotification(glyph, urgency, headline, body) {
    if (!notifyEvents) return
    var safeHead = Model.sanitizeNotificationArg(headline, 80)
    var safeBody = Model.sanitizeNotificationArg(body, 160)
    if (!safeHead) return
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "Printers",
      "-g", String(glyph || "󰐪"),
      "-u", String(urgency || "low"),
      safeHead,
      safeBody,
      "--exec", "omarchy-shell", "ivanilton.printers", "open"
    ])
  }

  function refresh(statusOnly) {
    if (statusProcess.running) {
      if (statusOnly !== true) _fullRefreshPending = true
      return
    }
    if (statusOnly !== true) _fullRefreshPending = false
    refreshing = true
    var cmd = ["python3", helperPath, "status", "--max-history", String(maxHistoryJobs)]
    if (includeCompleted || panelOpen) cmd.push("--include-completed")
    if (statusOnly === true) cmd.push("--status-only")
    statusProcess.command = cmd
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      setErrorMessage(tr("error.readFailed"))
      return
    }

    var prevJobs = jobs
    var prevPrinters = printers
    var wasInitialized = initialized

    cupsRunning = parsed.cupsRunning
    systemConfigInstalled = parsed.systemConfigInstalled
    defaultPrinter = parsed.defaultPrinter
    printers = parsed.printers
    jobs = parsed.jobs
    activeJobCount = parsed.activeJobCount
    serverSettings = parsed.serverSettings
    if (!parsed.statusOnly) {
      completedJobs = parsed.completedJobs
    }
    initialized = true

    if (wasInitialized && notifyEvents && parsed.cupsRunning) {
      var events = Model.detectNotificationEvents(prevJobs, parsed.jobs, parsed.completedJobs, prevPrinters, parsed.printers, tr)
      for (var i = 0; i < events.length; i++) {
        var ev = events[i]
        sendNotification(ev.glyph, ev.urgency, ev.headline, ev.body)
      }
    }
  }

  function discoverPrinters() {
    if (discoverProcess.running) return
    discovering = true
    lastError = ""
    discoverProcess.command = ["python3", helperPath, "discover", "--timeout", "4"]
    discoverProcess.running = true
  }

  function loadRecentFiles() {
    if (recentFilesProcess.running) return
    loadingFiles = true
    recentFilesProcess.command = ["python3", helperPath, "recent-files", "--limit", "10"]
    recentFilesProcess.running = true
  }

  function runAction(argv, tag, subject, extra) {
    if (actionProcess.running) return
    actionBusy = true
    lastError = ""
    actionStatus = tr("status.working")
    _pendingActionTag = tag || ""
    _pendingActionSubject = Model.sanitizePlainText(subject || "", 80)
    _pendingActionExtra = Model.sanitizePlainText(extra || "", 80)
    actionProcess.command = ["python3", helperPath].concat(argv)
    actionProcess.running = true
  }

  function printerByName(name) {
    for (var i = 0; i < printers.length; i++) {
      if (printers[i].name === name) return printers[i]
    }
    return null
  }

  function resolveTargetPrinter(name) {
    if (name && Model.isValidQueueName(name)) return name
    if (primaryPrinter) return primaryPrinter.name
    return ""
  }

  function setDefaultPrinter(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["set-default", target], "set-default", target)
  }

  function setPrinterEnabled(printerName, enableFlag) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction([enableFlag ? "enable" : "disable", target], enableFlag ? "enable" : "disable", target)
  }

  function togglePrinterPause(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    var p = printerByName(target)
    var shouldEnable = p ? p.stateKey === "stopped" : true
    setPrinterEnabled(target, shouldEnable)
  }

  function setPrinterAccepting(printerName, acceptFlag) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction([acceptFlag ? "accept" : "reject", target], acceptFlag ? "accept" : "reject", target)
  }

  function setPrinterShared(printerName, sharedFlag) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["set-shared", target, sharedFlag ? "true" : "false"], sharedFlag ? "shared-on" : "shared-off", target)
  }

  function printTestPage(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["test-page", target], "test-page", target)
  }

  function printFile(printerName, filePath, copies) {
    var target = resolveTargetPrinter(printerName)
    var cleanPath = String(filePath || "").trim()
    if (!target || !cleanPath) {
      setErrorMessage(tr("error.invalidFile"))
      return
    }
    var nCopies = Model.clampInt(copies, 1, 1, 99)
    var baseName = cleanPath.split("/").pop() || cleanPath
    runAction(["print-file", target, cleanPath, "--copies", String(nCopies)], "print-file", baseName, target)
  }

  function setPrinterOption(printerName, key, value) {
    var target = resolveTargetPrinter(printerName)
    if (!target || !key || !value) return
    runAction(["set-option", target, String(key), String(value)], "set-option", target)
  }

  function updatePrinterDetails(printerName, info, location, errorPolicy) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    var argv = ["update-printer", target]
    if (info !== undefined && info !== null) argv.push("--info", String(info))
    if (location !== undefined && location !== null) argv.push("--location", String(location))
    if (errorPolicy !== undefined && errorPolicy !== null && errorPolicy !== "") argv.push("--error-policy", String(errorPolicy))
    runAction(argv, "update-printer", target)
  }

  function addPrinter(name, uri, info, makeModel, driverless, setAsDefault) {
    var qName = String(name || "").trim()
    var qUri = String(uri || "").trim()
    if (!Model.isValidQueueName(qName) || !Model.isValidPrinterUri(qUri)) {
      setErrorMessage(tr("error.invalidManualInput"))
      return
    }
    var argv = ["add-printer", qName, qUri, "--info", String(info || qName)]
    if (makeModel) argv.push("--make-model", String(makeModel))
    argv.push("--model", driverless ? "everywhere" : "auto")
    if (setAsDefault) argv.push("--set-default")
    runAction(argv, "add-printer", qName)
  }

  function deletePrinter(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["delete-printer", target], "delete-printer", target)
  }

  function cancelJob(jobId) {
    var jid = Model.clampInt(jobId, 0, 0, 2147483647)
    if (jid <= 0) return
    runAction(["cancel-job", String(jid)], "cancel-job", String(jid))
  }

  function cancelAllJobs(printerName) {
    if (printerName && Model.isValidQueueName(printerName)) {
      runAction(["cancel-all", printerName], "cancel-all", printerName)
    } else {
      runAction(["cancel-all"], "cancel-all", "")
    }
  }

  function holdJob(jobId) {
    var jid = Model.clampInt(jobId, 0, 0, 2147483647)
    if (jid <= 0) return
    runAction(["hold-job", String(jid)], "hold-job", String(jid))
  }

  function releaseJob(jobId) {
    var jid = Model.clampInt(jobId, 0, 0, 2147483647)
    if (jid <= 0) return
    runAction(["release-job", String(jid)], "release-job", String(jid))
  }

  function restartJob(jobId) {
    var jid = Model.clampInt(jobId, 0, 0, 2147483647)
    if (jid <= 0) return
    runAction(["restart-job", String(jid)], "restart-job", String(jid))
  }

  function moveJob(jobId, destPrinter) {
    var jid = Model.clampInt(jobId, 0, 0, 2147483647)
    if (jid <= 0 || !Model.isValidQueueName(destPrinter)) return
    runAction(["move-job", String(jid), destPrinter], "move-job", String(jid), destPrinter)
  }

  function setServerSetting(key, enabledFlag) {
    runAction(["set-server-setting", String(key), enabledFlag ? "true" : "false"], "server-setting", String(key))
  }

  function cleanPrintHeads(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["maintenance", target, "clean-heads"], "maint-clean", target)
  }

  function printNozzleCheck(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["maintenance", target, "nozzle-check"], "maint-nozzle", target)
  }

  function printAlignmentPage(printerName, alignPass) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    var passNum = Model.clampInt(alignPass, 0, 0, 4)
    runAction(["maintenance", target, "print-alignment", "--align-pass", String(passNum)], "maint-print-align", target)
  }

  function setHeadAlignment(printerName, alignPass, alignValue) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    var passNum = Model.clampInt(alignPass, 1, 1, 4)
    var valNum = Model.clampInt(alignValue, 7, 1, 15)
    runAction(
      ["maintenance", target, "set-alignment", "--align-pass", String(passNum), "--align-value", String(valNum)],
      "maint-set-align",
      target,
      String(passNum)
    )
  }

  function reportInkLevels(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["maintenance", target, "report-levels"], "maint-levels", target)
  }

  function autoConfigurePrinter(printerName) {
    var target = resolveTargetPrinter(printerName)
    if (!target) return
    runAction(["maintenance", target, "auto-configure"], "maint-auto", target)
  }

  function startCups() {
    runAction(["start-cups"], "start-cups", "")
  }

  function restartCups() {
    runAction(["restart-cups"], "restart-cups", "")
  }

  function openSystemConfigPrinter() {
    Quickshell.execDetached(["uwsm-app", "--", "system-config-printer"])
  }

  function openCupsWeb() {
    Qt.openUrlExternally("http://localhost:631")
  }

  function successMessageFor(tag, subject, extra) {
    if (tag === "set-default") return tr("status.defaultSet").arg(subject)
    if (tag === "enable") return tr("status.enabled").arg(subject)
    if (tag === "disable") return tr("status.disabled").arg(subject)
    if (tag === "accept") return tr("status.accepting").arg(subject)
    if (tag === "reject") return tr("status.rejecting").arg(subject)
    if (tag === "shared-on") return tr("status.sharedOn").arg(subject)
    if (tag === "shared-off") return tr("status.sharedOff").arg(subject)
    if (tag === "test-page") return tr("status.testPageSent").arg(subject)
    if (tag === "print-file") return tr("status.fileSent").arg(subject).arg(extra)
    if (tag === "set-option") return tr("status.optionSaved").arg(subject)
    if (tag === "update-printer") return tr("status.detailsSaved").arg(subject)
    if (tag === "add-printer") return tr("status.printerAdded").arg(subject)
    if (tag === "delete-printer") return tr("status.printerDeleted").arg(subject)
    if (tag === "cancel-job") return tr("status.jobCanceled").arg(subject)
    if (tag === "cancel-all") return tr("status.jobsCanceled")
    if (tag === "hold-job") return tr("status.jobHeld").arg(subject)
    if (tag === "release-job") return tr("status.jobReleased").arg(subject)
    if (tag === "restart-job") return tr("status.jobRestarted").arg(subject)
    if (tag === "move-job") return tr("status.jobMoved").arg(subject).arg(extra)
    if (tag === "server-setting") return tr("status.serverUpdated")
    if (tag === "maint-clean") return tr("status.cleanHeads").arg(subject)
    if (tag === "maint-nozzle") return tr("status.nozzleCheck").arg(subject)
    if (tag === "maint-print-align") return tr("status.printAlignment").arg(subject)
    if (tag === "maint-set-align") return tr("status.setAlignment").arg(subject).arg(extra)
    if (tag === "maint-levels") return tr("status.reportLevels").arg(subject)
    if (tag === "maint-auto") return tr("status.autoConfigure").arg(subject)
    if (tag === "start-cups") return tr("status.cupsStarted")
    if (tag === "restart-cups") return tr("status.cupsRestarted")
    return ""
  }

  // Live 3s poll while the panel is open OR while jobs are actively printing/queued.
  Timer {
    id: liveTimer
    interval: 3000
    repeat: true
    running: root.panelOpen || root.activeJobCount > 0
    onTriggered: root.refresh(!root.panelOpen)
  }

  // Gentle idle background poll (disabled completely if user sets refreshIntervalSec = 0).
  Timer {
    id: idleTimer
    interval: Math.max(5, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.refreshIntervalSec > 0 && !root.panelOpen && root.activeJobCount === 0
    onTriggered: root.refresh(true)
  }

  Timer {
    id: actionStatusTimer
    interval: 3200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: postActionRefresh
    interval: 350
    repeat: false
    onTriggered: root.refresh(false)
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) {
        root.applyStatus(statusStdout.text)
      } else {
        var msg = Model.sanitizePlainText(statusStderr.text || statusStdout.text, 160)
        root.setErrorMessage(msg || root.tr("error.readFailed"))
      }
      if (root._fullRefreshPending) root.refresh(false)
    }
  }

  Process {
    id: discoverProcess
    running: false
    command: []
    stdout: StdioCollector { id: discoverStdout; waitForEnd: true }
    stderr: StdioCollector { id: discoverStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.discovering = false
      root.hasScannedDevices = true
      var parsed = Model.parseDiscover(discoverStdout.text)
      if (exitCode === 0 && parsed.ok) {
        root.discoveredDevices = parsed.devices
        root.lastError = ""
      } else {
        root.setErrorMessage(parsed.error || Model.sanitizePlainText(discoverStderr.text, 160) || root.tr("error.actionFailed"))
      }
    }
  }

  Process {
    id: recentFilesProcess
    running: false
    command: []
    stdout: StdioCollector { id: recentFilesStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.loadingFiles = false
      if (exitCode === 0) {
        var parsed = Model.parseRecentFiles(recentFilesStdout.text)
        if (parsed.ok) root.recentFiles = parsed.files
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionBusy = false
      var parsed = Model.parseActionResult(actionStdout.text)
      var tag = root._pendingActionTag
      var subject = root._pendingActionSubject
      var extra = root._pendingActionExtra
      if (exitCode === 0 && parsed.ok) {
        var msg = root.successMessageFor(tag, subject, extra)
        if (msg) root.setStatusMessage(msg)
        else root.actionStatus = ""
        if (tag === "add-printer" || tag === "delete-printer") {
          root.hasScannedDevices = false
          root.discoveredDevices = []
        }
      } else {
        var err = parsed.error || Model.sanitizePlainText(actionStderr.text || actionStdout.text, 160)
        root.setErrorMessage(err || root.tr("error.actionFailed"))
      }
      postActionRefresh.restart()
    }
  }

  Component.onCompleted: refresh(true)
}
