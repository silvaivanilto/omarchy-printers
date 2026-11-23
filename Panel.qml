import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "ivanilton.printers"
  ipcTarget: "ivanilton.printers"
  manageIpc: false

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Active panel view state
  property string activeTab: "queue" // "queue" | "printers" | "maintenance" | "setup"
  property bool showCompleted: setting("showCompletedJobs", false) === true
  property string expandedPrinter: ""
  property string maintenancePrinter: ""
  property int maintAlignPass: 1
  property int maintAlignValue: 7
  property bool printDrawerOpen: false
  property string printTargetPrinter: ""
  property string printFilePath: ""
  property int printCopies: 1
  property int movingJobId: 0

  // Manual printer add form state
  property string manualName: ""
  property string manualUri: ""

  // Inline confirmation dialog state
  property bool confirmOpen: false
  property string confirmMessage: ""
  property string confirmAction: ""
  property string confirmTarget: ""

  // Keyboard cursor state (shared with mouse hover via CursorSurface)
  property bool cursorActive: false
  property int selectedIndex: 0
  property string _openDropdownKey: ""
  property string _focusedInputKey: ""
  readonly property bool anyDropdownOpen: _openDropdownKey !== ""
  readonly property bool anyTextFocused: _focusedInputKey !== ""

  function trackDropdown(key, isOpen) {
    if (isOpen) _openDropdownKey = key
    else if (_openDropdownKey === key) _openDropdownKey = ""
  }

  function trackTextFocus(key, isFocused) {
    if (isFocused) _focusedInputKey = key
    else if (_focusedInputKey === key) _focusedInputKey = ""
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color warning: Commons.Color.warning
  readonly property color dim: Qt.darker(foreground, 1.48)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var visibleJobs: showCompleted ? service.completedJobs : service.jobs
  readonly property int activeJobCount: service.activeJobCount
  readonly property bool barVertical: bar ? bar.vertical : false

  readonly property string barIcon: {
    if (!service.cupsRunning) return "󰹝"
    if (service.errorPrinterCount > 0) return "󰐬"
    if (service.printers.length > 0 && service.allPaused) return "󰹝"
    return "󰐪"
  }

  readonly property string barCountText: (!barVertical && activeJobCount > 0)
    ? Commons.I18n.formatNumber(activeJobCount)
    : ""

  readonly property string barTooltipText: {
    strings.language
    return Model.buildBarTooltip(
      service.cupsRunning,
      service.printers,
      service.defaultPrinter,
      service.activeJobCount,
      function(k) { return strings.t(k) },
      function(k, n) { return strings.tn(k, n) },
      Commons.I18n.formatNumber
    )
  }

  readonly property string heroMetaText: {
    strings.language
    if (!service.cupsRunning) return strings.t("hero.cupsStopped")
    if (service.printers.length === 0) return strings.t("hero.noPrinters")
    var p = service.primaryPrinter
    var name = p ? Model.sanitizePlainText(p.info || p.name, 42) : ""
    var statusLabel = strings.t("hero.ready")
    if (service.errorPrinterCount > 0) statusLabel = strings.t("hero.attention")
    else if (service.activeJobCount > 0) statusLabel = strings.t("hero.printing")
    else if (p && p.stateKey === "stopped") statusLabel = strings.t("hero.paused")
    return name ? (name + " · " + statusLabel) : statusLabel
  }

  readonly property string heroDetailText: {
    strings.language
    if (service.activeJobCount <= 0) return ""
    return strings.tn("hero.jobsBadge", service.activeJobCount).arg(Commons.I18n.formatNumber(service.activeJobCount))
  }

  readonly property int currentListCount: {
    if (activeTab === "queue") return visibleJobs.length
    if (activeTab === "printers") return service.printers.length
    if (activeTab === "setup") return service.discoveredDevices.length
    return 0
  }

  function clampSelection() {
    var count = currentListCount
    if (count <= 0) {
      selectedIndex = 0
      return
    }
    if (selectedIndex >= count) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  readonly property var selectedMaintPrinter: {
    if (maintenancePrinter !== "") {
      var found = service.printerByName(maintenancePrinter)
      if (found) return found
    }
    return service.primaryPrinter
  }

  readonly property var selectedMaintCaps: selectedMaintPrinter && selectedMaintPrinter.maintenance
    ? selectedMaintPrinter.maintenance
    : ({ backend: "none", cleanHeads: false, nozzleCheck: false, alignment: false, reportLevels: false, autoConfigure: false })

  function switchTab(tab) {
    activeTab = tab
    selectedIndex = 0
    cursorActive = false
    movingJobId = 0
    if (tab === "queue" && showCompleted) service.refresh(false)
    if (tab === "setup" && !service.hasScannedDevices && service.cupsRunning) service.discoverPrinters()
  }

  function openMaintenanceFor(printerName) {
    if (printerName) maintenancePrinter = printerName
    switchTab("maintenance")
  }

  function cycleTab(delta) {
    var tabs = ["queue", "printers", "maintenance", "setup"]
    var idx = tabs.indexOf(activeTab)
    if (idx < 0) idx = 0
    switchTab(tabs[(idx + delta + tabs.length) % tabs.length])
  }

  function moveCursor(dy) {
    var count = currentListCount
    if (count <= 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex + dy))
  }

  function activateCurrent() {
    if (!cursorActive) return
    if (activeTab === "queue" && selectedIndex >= 0 && selectedIndex < visibleJobs.length) {
      var job = visibleJobs[selectedIndex]
      if (!job) return
      if (job.canHold) service.holdJob(job.id)
      else if (job.canRelease) service.releaseJob(job.id)
      else if (job.canRestart) service.restartJob(job.id)
    } else if (activeTab === "printers" && selectedIndex >= 0 && selectedIndex < service.printers.length) {
      var printer = service.printers[selectedIndex]
      if (!printer) return
      expandedPrinter = expandedPrinter === printer.name ? "" : printer.name
    } else if (activeTab === "setup" && selectedIndex >= 0 && selectedIndex < service.discoveredDevices.length) {
      var dev = service.discoveredDevices[selectedIndex]
      if (dev && !dev.alreadyConfigured) {
        service.addPrinter(dev.suggestedName, dev.uri, dev.info, dev.makeModel, dev.driverless, service.printers.length === 0)
      }
    }
  }

  function deleteCurrent() {
    if (!cursorActive) return
    if (activeTab === "queue" && selectedIndex >= 0 && selectedIndex < visibleJobs.length) {
      var job = visibleJobs[selectedIndex]
      if (job && job.isActive) service.cancelJob(job.id)
    } else if (activeTab === "printers" && selectedIndex >= 0 && selectedIndex < service.printers.length) {
      var printer = service.printers[selectedIndex]
      if (printer) askDeletePrinter(printer.name)
    }
  }

  function askDeletePrinter(printerName) {
    confirmAction = "delete-printer"
    confirmTarget = printerName
    confirmMessage = Model.sanitizePlainText(strings.t("confirm.deletePrinter").arg(printerName), 220)
    confirmOpen = true
    Qt.callLater(function() {
      if (panel.loadedContent && panel.loadedContent.confirmOverlay) {
        panel.loadedContent.confirmOverlay.forceActiveFocus()
      }
    })
  }

  function askCancelAll(printerName) {
    confirmAction = "cancel-all"
    confirmTarget = printerName || ""
    confirmMessage = printerName
      ? Model.sanitizePlainText(strings.t("confirm.cancelAll").arg(printerName), 220)
      : Model.sanitizePlainText(strings.t("confirm.cancelAllGlobal"), 220)
    confirmOpen = true
    Qt.callLater(function() {
      if (panel.loadedContent && panel.loadedContent.confirmOverlay) {
        panel.loadedContent.confirmOverlay.forceActiveFocus()
      }
    })
  }

  function askCleanHeads(printerName) {
    var target = printerName || focusedPrinterName()
    if (!target) return
    confirmAction = "clean-heads"
    confirmTarget = target
    confirmMessage = Model.sanitizePlainText(strings.t("confirm.cleanHeads").arg(target), 220)
    confirmOpen = true
    Qt.callLater(function() {
      if (panel.loadedContent && panel.loadedContent.confirmOverlay) {
        panel.loadedContent.confirmOverlay.forceActiveFocus()
      }
    })
  }

  function closeConfirm() {
    confirmOpen = false
    confirmAction = ""
    confirmTarget = ""
    Qt.callLater(function() {
      if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
    })
  }

  function executeConfirm() {
    var action = confirmAction
    var target = confirmTarget
    closeConfirm()
    if (action === "delete-printer" && target) {
      if (expandedPrinter === target) expandedPrinter = ""
      service.deletePrinter(target)
    } else if (action === "cancel-all") {
      service.cancelAllJobs(target)
    } else if (action === "clean-heads" && target) {
      service.cleanPrintHeads(target)
    }
  }

  function openPrintDrawer(printerName) {
    printTargetPrinter = printerName || (service.primaryPrinter ? service.primaryPrinter.name : "")
    printDrawerOpen = true
    activeTab = "queue"
    service.loadRecentFiles()
  }

  function formatTimestamp(unixSec) {
    if (!unixSec || unixSec <= 0) return ""
    var dt = new Date(unixSec * 1000)
    var loc = Qt.locale(Commons.I18n.formatLocale)
    return dt.toLocaleString(loc, Locale.ShortFormat)
  }

  function focusedPrinterName() {
    if (activeTab === "maintenance" && selectedMaintPrinter) return selectedMaintPrinter.name
    if (activeTab === "printers" && selectedIndex >= 0 && selectedIndex < service.printers.length) {
      return service.printers[selectedIndex].name
    }
    return service.primaryPrinter ? service.primaryPrinter.name : ""
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      selectedIndex = 0
      movingJobId = 0
      confirmOpen = false
      // Land on Queue when active jobs are running, otherwise Printers if none.
      activeTab = service.activeJobCount > 0 ? "queue" : (service.printers.length > 0 ? "printers" : "setup")
      service.refresh(false)
      Qt.callLater(function() {
        if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
      })
    } else {
      confirmOpen = false
      printDrawerOpen = false
      movingJobId = 0
      _openDropdownKey = ""
      _focusedInputKey = ""
    }
  }

  onVisibleJobsChanged: clampSelection()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: service
    settings: root.settings
    strings: strings
    panelOpen: root.opened
    includeCompleted: root.showCompleted || root.opened
  }

  Connections {
    target: service
    function onPrintersChanged() {
      root.clampSelection()
      if (root.expandedPrinter !== "" && !service.printerByName(root.expandedPrinter)) {
        root.expandedPrinter = ""
      }
    }
    function onJobsChanged() { root.clampSelection() }
  }

  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function openTab(tab: string): void {
      if (tab === "queue" || tab === "printers" || tab === "maintenance" || tab === "setup") {
        root.open()
        root.switchTab(tab)
      } else {
        root.open()
      }
    }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(false); return "ok" }
    function discover(): string { service.discoverPrinters(); return "ok" }
    function openApp(): string { service.openSystemConfigPrinter(); return "ok" }
    function testPage(printer: string): string { service.printTestPage(printer || ""); return "ok" }
    function togglePause(printer: string): string { service.togglePrinterPause(printer || ""); return "ok" }
    function setDefault(printer: string): string { service.setDefaultPrinter(printer || ""); return "ok" }
    function cancelAll(printer: string): string { service.cancelAllJobs(printer || ""); return "ok" }
    function cleanHeads(printer: string): string { service.cleanPrintHeads(printer || ""); return "ok" }
    function nozzleCheck(printer: string): string { service.printNozzleCheck(printer || ""); return "ok" }
    function printAlignment(printer: string, alignPass: string): string {
      service.printAlignmentPage(printer || "", parseInt(alignPass || "0", 10) || 0)
      return "ok"
    }
    function setAlignment(printer: string, alignPass: string, alignValue: string): string {
      service.setHeadAlignment(printer || "", parseInt(alignPass || "1", 10) || 1, parseInt(alignValue || "7", 10) || 7)
      return "ok"
    }
    function reportLevels(printer: string): string { service.reportInkLevels(printer || ""); return "ok" }
    function autoConfigure(printer: string): string { service.autoConfigurePrinter(printer || ""); return "ok" }
    function status(): string {
      return JSON.stringify({
        cupsRunning: service.cupsRunning,
        defaultPrinter: service.defaultPrinter,
        printerCount: service.printers.length,
        activeJobCount: service.activeJobCount,
        errorPrinterCount: service.errorPrinterCount
      })
    }
  }

  TextMetrics {
    id: barCountMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: root.barCountText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    labelText: root.barCountText
    slotSize: root.barCountText !== ""
      ? Style.bar.iconSlot + Math.ceil(barCountMetrics.width) + Style.space(6)
      : Style.bar.iconSlot
    active: !service.cupsRunning || service.errorPrinterCount > 0
    dimmed: !service.cupsRunning || (service.printers.length > 0 && service.allPaused && service.activeJobCount === 0)
    tooltipText: root.barTooltipText
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) service.refresh(false)
      else if (mouseButton === Qt.MiddleButton) service.openSystemConfigPrinter()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias confirmOverlay: confirmOverlay
      implicitHeight: Math.max(column.implicitHeight, confirmOverlay.visible ? Style.space(180) : 0)
      anchors.fill: parent
      blocked: root.confirmOpen || root.anyDropdownOpen || root.anyTextFocused

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.moveCursor(dy)
        } else if (dx !== 0) {
          root.cycleTab(dx)
        }
      }
      onActivateRequested: root.activateCurrent()
      onDeleteRequested: root.deleteCurrent()
      onCloseRequested: {
        if (root.printDrawerOpen) root.printDrawerOpen = false
        else if (root.movingJobId > 0) root.movingJobId = 0
        else if (root.expandedPrinter !== "") root.expandedPrinter = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") service.refresh(false)
        else if (t === "o" || t === "O") service.openSystemConfigPrinter()
        else if (t === "t" || t === "T") service.printTestPage(root.focusedPrinterName())
        else if (t === "p" || t === "P") service.togglePrinterPause(root.focusedPrinterName())
        else if (t === "n" || t === "N") {
          var np = service.printerByName(root.focusedPrinterName())
          if (np && np.maintenance && np.maintenance.nozzleCheck) service.printNozzleCheck(np.name)
        }
        else if (t === "c" || t === "C") {
          var cp = service.printerByName(root.focusedPrinterName())
          if (cp && cp.maintenance && cp.maintenance.cleanHeads) root.askCleanHeads(cp.name)
        }
        else if (t === "a" || t === "A") { root.switchTab("setup"); service.discoverPrinters() }
        else if (t === "1") root.switchTab("queue")
        else if (t === "2") root.switchTab("printers")
        else if (t === "3") root.switchTab("maintenance")
        else if (t === "4") root.switchTab("setup")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          x: 1
          width: Math.max(0, panelFlick.width - 2)
          spacing: Style.space(12)

          // ---------- Hero header ----------
          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("plugin.title")
            meta: root.heroMetaText
            detail: root.heroDetailText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: service.cupsRunning ? 1.0 : 0.55

            iconComponent: Component {
              PlainText {
                text: root.barIcon
                color: (!service.cupsRunning || service.errorPrinterCount > 0) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "󰑐"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: strings.t("hero.refreshTooltip")
                  enabled: !service.refreshing
                  onClicked: service.refresh(false)
                }

                PanelActionButton {
                  visible: service.systemConfigInstalled
                  iconText: "󰏌"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: strings.t("hero.openAppTooltip")
                  onClicked: service.openSystemConfigPrinter()
                }
              }
            }
          }

          // ---------- Transient action status or error banner ----------
          PlainText {
            visible: service.actionStatus !== "" || service.lastError !== ""
            width: parent.width
            text: service.actionStatus !== "" ? service.actionStatus : service.lastError
            color: (service.lastError !== "" && service.actionStatus === "") ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- CUPS stopped recovery banner ----------
          CursorSurface {
            visible: !service.cupsRunning
            width: parent.width
            bordered: true
            foreground: root.foreground
            implicitHeight: cupsStoppedCol.implicitHeight + Style.space(20)

            Column {
              id: cupsStoppedCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              PlainText {
                width: parent.width
                text: strings.t("cups.stoppedTitle")
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                wrapMode: Text.WordWrap
              }

              PlainText {
                width: parent.width
                text: strings.t("cups.stoppedHelp")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Button {
                iconText: "󰐊"
                text: strings.t("cups.startService")
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                enabled: !service.actionBusy
                onClicked: service.startCups()
              }
            }
          }

          // ---------- Navigation tabs ----------
          RowLayout {
            visible: service.cupsRunning
            width: parent.width
            spacing: Style.space(4)

            Button {
              Layout.fillWidth: true
              iconText: "󰉹"
              text: service.activeJobCount > 0
                ? (strings.t("tabs.queue") + " (" + Commons.I18n.formatNumber(service.activeJobCount) + ")")
                : strings.t("tabs.queue")
              selected: root.activeTab === "queue"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.iconSmall
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(5)
              onClicked: root.switchTab("queue")
            }

            Button {
              Layout.fillWidth: true
              iconText: "󰐪"
              text: service.printers.length > 0
                ? (strings.t("tabs.printers") + " (" + Commons.I18n.formatNumber(service.printers.length) + ")")
                : strings.t("tabs.printers")
              selected: root.activeTab === "printers"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.iconSmall
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(5)
              onClicked: root.switchTab("printers")
            }

            Button {
              Layout.fillWidth: true
              iconText: "󰖷"
              text: strings.t("tabs.maintenance")
              selected: root.activeTab === "maintenance"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.iconSmall
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(5)
              onClicked: root.switchTab("maintenance")
            }

            Button {
              Layout.fillWidth: true
              iconText: "󰘮"
              text: strings.t("tabs.setup")
              selected: root.activeTab === "setup"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.iconSmall
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(5)
              onClicked: root.switchTab("setup")
            }
          }

          PanelSeparator {
            visible: service.cupsRunning
            foreground: root.foreground
          }

          // =================================================================
          // TAB 1: PRINT QUEUE
          // =================================================================
          Column {
            visible: service.cupsRunning && root.activeTab === "queue"
            width: parent.width
            spacing: Style.space(10)

            // Queue filter & bulk actions row
            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: strings.t("queue.active")
                selected: !root.showCompleted
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.space(4)
                onClicked: root.showCompleted = false
              }

              Button {
                text: strings.t("queue.history")
                selected: root.showCompleted
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.space(4)
                onClicked: {
                  root.showCompleted = true
                  service.refresh(false)
                }
              }

              Item { Layout.fillWidth: true }

              Button {
                visible: service.printers.length > 0
                iconText: "󰈙"
                text: strings.t("queue.printFile")
                selected: root.printDrawerOpen
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.iconSmall
                verticalPadding: Style.space(4)
                onClicked: {
                  if (root.printDrawerOpen) root.printDrawerOpen = false
                  else root.openPrintDrawer("")
                }
              }

              PanelActionButton {
                visible: !root.showCompleted && service.activeJobCount > 0
                iconText: "󰗩"
                foreground: root.foreground
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                tooltipText: strings.t("queue.cancelAll")
                enabled: !service.actionBusy
                onClicked: root.askCancelAll("")
              }
            }

            // Inline Quick Print File drawer
            BorderSurface {
              visible: root.printDrawerOpen && service.printers.length > 0
              width: parent.width
              implicitHeight: printDrawerCol.implicitHeight + Style.space(20)
              color: Style.normalFillFor(root.foreground, root.accent)
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
              radius: Style.cornerRadius

              Column {
                id: printDrawerCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)

                  PlainText {
                    Layout.fillWidth: true
                    text: strings.t("printFile.targetPrinter").arg(
                      Model.sanitizePlainText(root.printTargetPrinter || service.defaultPrinter || (service.printers[0] ? service.printers[0].name : ""), 48)
                    )
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  PanelActionButton {
                    iconText: "󰅖"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    tooltipText: strings.t("printFile.cancel")
                    onClicked: root.printDrawerOpen = false
                  }
                }

                Dropdown {
                  visible: service.printers.length > 1
                  width: parent.width
                  showLabel: false
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  value: root.printTargetPrinter || service.defaultPrinter || (service.printers[0] ? service.printers[0].name : "")
                  options: {
                    var list = []
                    for (var i = 0; i < service.printers.length; i++) {
                      list.push({ value: service.printers[i].name, label: service.printers[i].info || service.printers[i].name })
                    }
                    return list
                  }
                  onPopupOpenChanged: root.trackDropdown("printTarget", popupOpen)
                  onChanged: function(val) { root.printTargetPrinter = val }
                }

                TextField {
                  id: filePathInput
                  width: parent.width
                  foreground: root.foreground
                  accent: root.accent
                  placeholderText: strings.t("printFile.pathPlaceholder")
                  text: root.printFilePath
                  onTextEdited: root.printFilePath = text
                  onActiveFocusChanged: root.trackTextFocus("filePath", activeFocus)
                  onAccepted: {
                    if (text.trim() !== "") {
                      service.printFile(root.printTargetPrinter, text.trim(), root.printCopies)
                      root.printFilePath = ""
                      filePathInput.text = ""
                      root.printDrawerOpen = false
                    }
                  }
                }

                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)

                  PlainText {
                    text: strings.t("printFile.copiesLabel")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Button {
                    text: "−"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    verticalPadding: Style.space(3)
                    horizontalPadding: Style.space(8)
                    onClicked: if (root.printCopies > 1) root.printCopies--
                  }

                  PlainText {
                    text: Commons.I18n.formatNumber(root.printCopies)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Button {
                    text: "+"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    verticalPadding: Style.space(3)
                    horizontalPadding: Style.space(8)
                    onClicked: if (root.printCopies < 99) root.printCopies++
                  }

                  Item { Layout.fillWidth: true }

                  Button {
                    iconText: "󰐪"
                    text: strings.t("printFile.send")
                    bordered: true
                    selected: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    iconSize: Style.font.iconSmall
                    verticalPadding: Style.space(4)
                    enabled: !service.actionBusy && root.printFilePath.trim() !== ""
                    onClicked: {
                      service.printFile(root.printTargetPrinter, root.printFilePath.trim(), root.printCopies)
                      root.printFilePath = ""
                      root.printDrawerOpen = false
                    }
                  }
                }

                PanelSeparator {
                  foreground: root.foreground
                }

                PanelSectionHeader {
                  text: strings.t("printFile.recentFiles")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                PlainText {
                  visible: !service.loadingFiles && service.recentFiles.length === 0
                  width: parent.width
                  text: strings.t("printFile.noRecentFiles")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Column {
                  visible: service.recentFiles.length > 0
                  width: parent.width
                  spacing: Style.space(4)

                  Repeater {
                    model: service.recentFiles
                    CursorSurface {
                      required property var modelData
                      width: parent.width
                      implicitHeight: recentFileRow.implicitHeight + Style.space(8)
                      foreground: root.foreground
                      accent: root.accent
                      hasCursor: recentFileMouse.containsMouse

                      MouseArea {
                        id: recentFileMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.printFilePath = modelData.path
                          filePathInput.text = modelData.path
                        }
                      }

                      RowLayout {
                        id: recentFileRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(6)
                        spacing: Style.space(8)

                        PlainText {
                          text: "󰈙"
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.iconSmall
                        }

                        ColumnLayout {
                          Layout.fillWidth: true
                          spacing: 1

                          PlainText {
                            Layout.fillWidth: true
                            text: modelData.name
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }

                          PlainText {
                            Layout.fillWidth: true
                            text: modelData.folder + " · " + Model.formatSizeKb(modelData.sizeKb, Commons.I18n.formatNumber, function(k) { return strings.t(k) })
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                          }
                        }

                        PanelActionButton {
                          iconText: "󰐪"
                          foreground: root.foreground
                          hoverColor: root.accent
                          fontFamily: root.fontFamily
                          tooltipText: strings.t("printFile.send")
                          enabled: !service.actionBusy
                          onClicked: {
                            service.printFile(root.printTargetPrinter, modelData.path, root.printCopies)
                            root.printDrawerOpen = false
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // Inline move-job target picker
            BorderSurface {
              visible: root.movingJobId > 0 && service.printers.length > 1
              width: parent.width
              implicitHeight: moveJobCol.implicitHeight + Style.space(16)
              color: Style.normalFillFor(root.foreground, root.accent)
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
              radius: Style.cornerRadius

              Column {
                id: moveJobCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(10)
                spacing: Style.space(6)

                RowLayout {
                  width: parent.width
                  PlainText {
                    Layout.fillWidth: true
                    text: strings.t("queue.moveTo").arg(Commons.I18n.formatNumber(root.movingJobId))
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  PanelActionButton {
                    iconText: "󰅖"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.movingJobId = 0
                  }
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: service.printers
                    Button {
                      required property var modelData
                      text: modelData.info || modelData.name
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      verticalPadding: Style.space(4)
                      onClicked: {
                        var jid = root.movingJobId
                        root.movingJobId = 0
                        service.moveJob(jid, modelData.name)
                      }
                    }
                  }
                }
              }
            }

            // Empty queue state
            Column {
              visible: root.visibleJobs.length === 0
              width: parent.width
              spacing: Style.space(10)

              PlainText {
                width: parent.width
                text: root.showCompleted ? strings.t("queue.emptyHistory") : strings.t("queue.emptyActive")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                topPadding: Style.space(12)
                bottomPadding: Style.space(4)
              }

              Row {
                visible: !root.showCompleted && service.printers.length > 0
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)

                Button {
                  iconText: "󰧮"
                  text: strings.t("queue.testPage")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.iconSmall
                  enabled: !service.actionBusy
                  onClicked: service.printTestPage("")
                }

                Button {
                  iconText: "󰈙"
                  text: strings.t("queue.printFile")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.iconSmall
                  onClicked: root.openPrintDrawer("")
                }
              }
            }

            // Jobs list
            Column {
              visible: root.visibleJobs.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.visibleJobs
                JobRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  job: modelData
                  rowIndex: index
                }
              }
            }
          }

          // =================================================================
          // TAB 2: PRINTERS & INLINE PROPERTIES
          // =================================================================
          Column {
            visible: service.cupsRunning && root.activeTab === "printers"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("printers.section")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PlainText {
              visible: service.printers.length === 0
              width: parent.width
              text: strings.t("printers.empty")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
            }

            Column {
              visible: service.printers.length > 0
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: service.printers
                PrinterCard {
                  required property var modelData
                  required property int index
                  width: parent.width
                  printer: modelData
                  rowIndex: index
                }
              }
            }
          }

          // =================================================================
          // TAB 3: MAINTENANCE (HEAD CLEANING, NOZZLE CHECK, ALIGNMENT, LEVELS)
          // =================================================================
          Column {
            visible: service.cupsRunning && root.activeTab === "maintenance"
            width: parent.width
            spacing: Style.space(12)

            PlainText {
              visible: service.printers.length === 0
              width: parent.width
              text: strings.t("maint.noPrinters")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              topPadding: Style.space(12)
              bottomPadding: Style.space(12)
            }

            Column {
              visible: !!root.selectedMaintPrinter
              width: parent.width
              spacing: Style.space(10)

              // Printer selector / identity header
              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  Layout.fillWidth: true
                  text: root.selectedMaintPrinter
                    ? (strings.t("maint.printerLabel") + ": " + (root.selectedMaintPrinter.info || root.selectedMaintPrinter.name))
                    : strings.t("maint.section")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                PlainText {
                  visible: root.selectedMaintCaps.backend !== "none"
                  text: {
                    strings.language
                    if (root.selectedMaintCaps.backend === "cups-command") return strings.t("maint.backendCups")
                    if (root.selectedMaintCaps.backend === "escpx-raw") return strings.t("maint.backendEscpx")
                    if (root.selectedMaintCaps.backend === "hplip") return strings.t("maint.backendHplip")
                    return ""
                  }
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Dropdown {
                visible: service.printers.length > 1
                width: parent.width
                showLabel: false
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                value: root.selectedMaintPrinter ? root.selectedMaintPrinter.name : ""
                options: {
                  var list = []
                  for (var i = 0; i < service.printers.length; i++) {
                    list.push({ value: service.printers[i].name, label: service.printers[i].info || service.printers[i].name })
                  }
                  return list
                }
                onPopupOpenChanged: root.trackDropdown("maintTarget", popupOpen)
                onChanged: function(val) { root.maintenancePrinter = val }
              }

              PlainText {
                visible: root.selectedMaintCaps.backend === "none"
                width: parent.width
                text: strings.t("maint.unsupported")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // Main 2-column maintenance actions grid
              GridLayout {
                width: parent.width
                columns: 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)

                Button {
                  Layout.fillWidth: true
                  visible: root.selectedMaintCaps.nozzleCheck
                  iconText: "󰖌"
                  text: strings.t("maint.nozzleCheck")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  iconSize: Style.font.icon
                  verticalPadding: Style.space(8)
                  enabled: !service.actionBusy && !!root.selectedMaintPrinter
                  onClicked: if (root.selectedMaintPrinter) service.printNozzleCheck(root.selectedMaintPrinter.name)
                }

                Button {
                  Layout.fillWidth: true
                  visible: root.selectedMaintCaps.cleanHeads
                  iconText: "󰃢"
                  text: strings.t("maint.cleanHeads")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  iconSize: Style.font.icon
                  verticalPadding: Style.space(8)
                  enabled: !service.actionBusy && !!root.selectedMaintPrinter
                  onClicked: if (root.selectedMaintPrinter) root.askCleanHeads(root.selectedMaintPrinter.name)
                }

                Button {
                  Layout.fillWidth: true
                  iconText: "󰧮"
                  text: strings.t("queue.testPage")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  iconSize: Style.font.icon
                  verticalPadding: Style.space(8)
                  enabled: !service.actionBusy && !!root.selectedMaintPrinter
                  onClicked: if (root.selectedMaintPrinter) service.printTestPage(root.selectedMaintPrinter.name)
                }

                Button {
                  Layout.fillWidth: true
                  visible: root.selectedMaintCaps.reportLevels
                  iconText: "󰑐"
                  text: strings.t("maint.reportLevels")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  iconSize: Style.font.icon
                  verticalPadding: Style.space(8)
                  enabled: !service.actionBusy && !!root.selectedMaintPrinter
                  onClicked: if (root.selectedMaintPrinter) service.reportInkLevels(root.selectedMaintPrinter.name)
                }

                Button {
                  Layout.fillWidth: true
                  Layout.columnSpan: 2
                  visible: root.selectedMaintCaps.autoConfigure
                  iconText: "󰒓"
                  text: strings.t("maint.autoConfigure")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  iconSize: Style.font.icon
                  verticalPadding: Style.space(8)
                  enabled: !service.actionBusy && !!root.selectedMaintPrinter
                  onClicked: if (root.selectedMaintPrinter) service.autoConfigurePrinter(root.selectedMaintPrinter.name)
                }
              }

              // Always-visible Guided Head Alignment card
              BorderSurface {
                visible: root.selectedMaintCaps.alignment && !!root.selectedMaintPrinter
                width: parent.width
                implicitHeight: tabAlignCol.implicitHeight + Style.space(20)
                color: Style.normalFillFor(root.foreground, root.accent)
                borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
                radius: Style.cornerRadius

                Column {
                  id: tabAlignCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(10)
                  spacing: Style.space(8)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    PlainText {
                      text: "󰖷"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }

                    PlainText {
                      Layout.fillWidth: true
                      text: strings.t("maint.alignTitle")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }

                  PlainText {
                    width: parent.width
                    text: strings.t("maint.alignHelp")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    PlainText {
                      text: strings.t("maint.alignPass")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Button {
                      text: "−"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      verticalPadding: Style.space(3)
                      horizontalPadding: Style.space(8)
                      onClicked: if (root.maintAlignPass > 1) root.maintAlignPass--
                    }

                    PlainText {
                      text: Commons.I18n.formatNumber(root.maintAlignPass)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Button {
                      text: "+"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      verticalPadding: Style.space(3)
                      horizontalPadding: Style.space(8)
                      onClicked: if (root.maintAlignPass < 4) root.maintAlignPass++
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                      iconText: "󰐪"
                      text: strings.t("maint.printAlignSheet")
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      iconSize: Style.font.iconSmall
                      verticalPadding: Style.space(4)
                      enabled: !service.actionBusy && !!root.selectedMaintPrinter
                      onClicked: if (root.selectedMaintPrinter) service.printAlignmentPage(root.selectedMaintPrinter.name, root.maintAlignPass)
                    }
                  }

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    PlainText {
                      text: strings.t("maint.alignPattern")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Button {
                      text: "−"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      verticalPadding: Style.space(3)
                      horizontalPadding: Style.space(8)
                      onClicked: if (root.maintAlignValue > 1) root.maintAlignValue--
                    }

                    PlainText {
                      text: Commons.I18n.formatNumber(root.maintAlignValue)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Button {
                      text: "+"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      verticalPadding: Style.space(3)
                      horizontalPadding: Style.space(8)
                      onClicked: if (root.maintAlignValue < 15) root.maintAlignValue++
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                      iconText: "󰄬"
                      text: strings.t("maint.saveAlign")
                      bordered: true
                      selected: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      iconSize: Style.font.iconSmall
                      verticalPadding: Style.space(4)
                      enabled: !service.actionBusy && !!root.selectedMaintPrinter
                      onClicked: if (root.selectedMaintPrinter) service.setHeadAlignment(root.selectedMaintPrinter.name, root.maintAlignPass, root.maintAlignValue)
                    }
                  }
                }
              }
            }
          }

          // =================================================================
          // TAB 4: SETUP (DISCOVERY, MANUAL ADD & CUPS SERVER SETTINGS)
          // =================================================================
          Column {
            visible: service.cupsRunning && root.activeTab === "setup"
            width: parent.width
            spacing: Style.space(12)

            // --- Auto-Discover Network & USB Printers ---
            Column {
              width: parent.width
              spacing: Style.space(8)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  Layout.fillWidth: true
                  text: strings.t("setup.discoverSection")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Button {
                  iconText: service.discovering ? "󰑐" : "󰍉"
                  iconSpinning: service.discovering
                  text: service.discovering ? strings.t("setup.scanning") : strings.t("setup.scan")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.iconSmall
                  verticalPadding: Style.space(4)
                  enabled: !service.discovering
                  onClicked: service.discoverPrinters()
                }
              }

              PlainText {
                visible: !service.discovering && service.discoveredDevices.length === 0
                width: parent.width
                text: service.hasScannedDevices ? strings.t("setup.noneFound") : strings.t("setup.noDiscovered")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Column {
                visible: service.discoveredDevices.length > 0
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: service.discoveredDevices
                  DiscoveredDeviceRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    device: modelData
                    rowIndex: index
                  }
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            // --- Add Printer Manually by URI ---
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: strings.t("setup.manualSection")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              TextField {
                id: manualNameInput
                width: parent.width
                foreground: root.foreground
                accent: root.accent
                placeholderText: strings.t("setup.namePlaceholder")
                text: root.manualName
                onTextEdited: root.manualName = text
                onActiveFocusChanged: root.trackTextFocus("manualName", activeFocus)
              }

              TextField {
                id: manualUriInput
                width: parent.width
                foreground: root.foreground
                accent: root.accent
                placeholderText: strings.t("setup.uriPlaceholder")
                text: root.manualUri
                onTextEdited: root.manualUri = text
                onActiveFocusChanged: root.trackTextFocus("manualUri", activeFocus)
                onAccepted: {
                  service.addPrinter(root.manualName, root.manualUri, root.manualName, "", true, service.printers.length === 0)
                  root.manualName = ""
                  root.manualUri = ""
                  manualNameInput.text = ""
                  manualUriInput.text = ""
                }
              }

              Button {
                iconText: "󰐕"
                text: strings.t("setup.addManual")
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.iconSmall
                enabled: !service.actionBusy && root.manualName.trim() !== "" && root.manualUri.trim() !== ""
                onClicked: {
                  service.addPrinter(root.manualName, root.manualUri, root.manualName, "", true, service.printers.length === 0)
                  root.manualName = ""
                  root.manualUri = ""
                  manualNameInput.text = ""
                  manualUriInput.text = ""
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            // --- CUPS Server Settings ---
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: strings.t("setup.serverSection")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              SettingSwitchRow {
                width: parent.width
                label: strings.t("setup.sharePrinters")
                checked: service.serverSettings.sharePrinters === true
                busy: service.actionBusy
                onToggled: service.setServerSetting("_share_printers", !service.serverSettings.sharePrinters)
              }

              SettingSwitchRow {
                width: parent.width
                label: strings.t("setup.userCancelAny")
                checked: service.serverSettings.userCancelAny === true
                busy: service.actionBusy
                onToggled: service.setServerSetting("_user_cancel_any", !service.serverSettings.userCancelAny)
              }

              SettingSwitchRow {
                width: parent.width
                label: strings.t("setup.webInterface")
                checked: service.serverSettings.webInterface === true
                busy: service.actionBusy
                onToggled: service.setServerSetting("WebInterface", !service.serverSettings.webInterface)
              }
            }

            PanelSeparator { foreground: root.foreground }

            // --- Tools & Shortcuts ---
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: strings.t("setup.toolsSection")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)

                Button {
                  visible: service.systemConfigInstalled
                  iconText: "󰏌"
                  text: strings.t("setup.openApp")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.iconSmall
                  onClicked: service.openSystemConfigPrinter()
                }

                Button {
                  iconText: "󰜇"
                  text: strings.t("setup.openWeb")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.iconSmall
                  onClicked: service.openCupsWeb()
                }

                Button {
                  iconText: "󰜉"
                  text: strings.t("cups.restartService")
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.iconSmall
                  enabled: !service.actionBusy
                  onClicked: service.restartCups()
                }
              }
            }
          }
        }
      }

      // Confirmation overlay for destructive actions
      ConfirmDialog {
        id: confirmOverlay
        anchors.fill: parent
        opened: root.confirmOpen
        message: root.confirmMessage
        cancelText: strings.t("confirm.cancel")
        confirmText: strings.t("confirm.confirm")
        background: Commons.Color.popups.background
        foreground: root.foreground
        selectedText: root.accent
        fontFamily: root.fontFamily
        focus: opened
        Keys.onPressed: function(event) {
          if (handleKey(event)) event.accepted = true
        }
        onCanceled: root.closeConfirm()
        onConfirmed: root.executeConfirm()
      }
    }
  }

  // ===========================================================================
  // LOCAL COMPONENTS
  // ===========================================================================

  component PlainText: Text {
    textFormat: Text.PlainText
  }

  component SettingSwitchRow: RowLayout {
    property string label: ""
    property bool checked: false
    property bool busy: false
    signal toggled()

    spacing: Style.space(8)

    PlainText {
      Layout.fillWidth: true
      text: label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    ToggleSwitch {
      checked: parent.checked
      busy: parent.busy
      foreground: root.foreground
      accent: root.accent
      onToggled: parent.toggled()
    }
  }

  component JobRow: CursorSurface {
    id: jobRow
    property var job: null
    property int rowIndex: 0

    readonly property string jobTitle: job && job.title
      ? job.title
      : strings.t("queue.jobTitleFallback").arg(Commons.I18n.formatNumber(job ? job.id : 0))

    readonly property string metaLine: {
      strings.language
      if (!job) return ""
      var parts = ["#" + Commons.I18n.formatNumber(job.id)]
      if (job.printer) parts.push(job.printer)
      if (job.copies > 1) parts.push(strings.tn("queue.copies", job.copies).arg(Commons.I18n.formatNumber(job.copies)))
      if (job.sizeKb > 0) parts.push(Model.formatSizeKb(job.sizeKb, Commons.I18n.formatNumber, function(k) { return strings.t(k) }))
      var ts = root.formatTimestamp(job.completedAt > 0 ? job.completedAt : job.createdAt)
      if (ts) parts.push(ts)
      return parts.join(" · ")
    }

    readonly property color badgeColor: {
      if (!job) return root.dim
      if (job.stateKey === "processing") return root.accent
      if (job.stateKey === "aborted" || job.stateKey === "stopped") return root.urgent
      if (job.stateKey === "held") return root.warning
      return root.dim
    }

    hasCursor: root.cursorActive && root.activeTab === "queue" && root.selectedIndex === rowIndex
    foreground: root.foreground
    accent: root.accent
    bordered: true
    implicitHeight: jobRowLayout.implicitHeight + Style.space(14)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: {
        root.cursorActive = true
        root.selectedIndex = jobRow.rowIndex
      }
    }

    RowLayout {
      id: jobRowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      PlainText {
        text: job && job.stateKey === "processing" ? "󰐪"
          : (job && job.stateKey === "held" ? "󰏤"
          : (job && (job.stateKey === "aborted" || job.stateKey === "stopped") ? "󰗖" : "󰈙"))
        color: jobRow.badgeColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          PlainText {
            Layout.fillWidth: true
            text: jobRow.jobTitle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          PlainText {
            text: Model.jobStateLabel(job, function(k) { return strings.t(k) }).toUpperCase()
            color: jobRow.badgeColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        PlainText {
          Layout.fillWidth: true
          text: jobRow.metaLine
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        spacing: Style.space(2)
        Layout.alignment: Qt.AlignVCenter

        PanelActionButton {
          visible: !!job && (job.canHold || job.canRelease)
          iconText: job && job.canRelease ? "󰐊" : "󰏤"
          foreground: root.foreground
          fontFamily: root.fontFamily
          tooltipText: job && job.canRelease ? strings.t("queue.releaseTooltip") : strings.t("queue.holdTooltip")
          enabled: !service.actionBusy
          onClicked: job.canRelease ? service.releaseJob(job.id) : service.holdJob(job.id)
        }

        PanelActionButton {
          visible: !!job && job.isActive && service.printers.length > 1
          iconText: "󰒗"
          foreground: root.foreground
          fontFamily: root.fontFamily
          tooltipText: strings.t("queue.moveTooltip")
          enabled: !service.actionBusy
          onClicked: root.movingJobId = root.movingJobId === job.id ? 0 : job.id
        }

        PanelActionButton {
          visible: !!job && job.canRestart
          iconText: "󰜉"
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          tooltipText: strings.t("queue.restartTooltip")
          enabled: !service.actionBusy
          onClicked: if (job) service.restartJob(job.id)
        }

        PanelActionButton {
          visible: !!job && job.isActive
          iconText: "󰅖"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          tooltipText: strings.t("queue.cancelTooltip")
          enabled: !service.actionBusy
          onClicked: if (job) service.cancelJob(job.id)
        }
      }
    }
  }

  component PrinterCard: Column {
    id: printerCard
    property var printer: null
    property int rowIndex: 0
    readonly property bool expanded: !!printer && root.expandedPrinter === printer.name

    spacing: Style.space(6)

    CursorSurface {
      id: printerSummary
      width: parent.width
      hasCursor: root.cursorActive && root.activeTab === "printers" && root.selectedIndex === printerCard.rowIndex
      current: !!printer && printer.isDefault
      bordered: true
      foreground: root.foreground
      accent: root.accent
      implicitHeight: summaryCol.implicitHeight + Style.space(16)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: {
          root.cursorActive = true
          root.selectedIndex = printerCard.rowIndex
        }
        onClicked: {
          if (printer) root.expandedPrinter = printerCard.expanded ? "" : printer.name
        }
      }

      Column {
        id: summaryCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(6)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          PlainText {
            text: printer && printer.hasError ? "󰐬"
              : (printer && printer.stateKey === "stopped" ? "󰹝" : "󰐪")
            color: printer && printer.hasError ? root.urgent
              : (printer && printer.hasWarning ? root.warning
              : (printer && printer.stateKey === "printing" ? root.accent
              : (printer && printer.stateKey === "stopped" ? root.dim : root.foreground)))
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            Layout.alignment: Qt.AlignVCenter
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              PlainText {
                Layout.fillWidth: true
                text: printer ? (printer.info || printer.name) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              PlainText {
                visible: !!printer && printer.isDefault
                text: strings.t("printers.defaultBadge").toUpperCase()
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            PlainText {
              Layout.fillWidth: true
              text: {
                strings.language
                if (!printer) return ""
                var parts = [Model.printerStateLabel(printer, function(k) { return strings.t(k) })]
                if (printer.activeJobCount > 0) {
                  parts.push(strings.tn("hero.jobsBadge", printer.activeJobCount).arg(Commons.I18n.formatNumber(printer.activeJobCount)))
                }
                if (printer.makeModel) parts.push(printer.makeModel)
                return parts.join(" · ")
              }
              color: printer && printer.hasError ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PlainText {
              visible: !!printer && (printer.stateMessage !== "" || (printer.hasError && printer.stateReasons.length > 0))
              Layout.fillWidth: true
              text: printer ? (printer.stateMessage || printer.stateReasons.join(", ")) : ""
              color: printer && printer.hasError ? root.urgent : root.warning
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Row {
            spacing: Style.space(2)
            Layout.alignment: Qt.AlignVCenter

            PanelActionButton {
              iconText: printer && printer.isDefault ? "󰓎" : "󰓒"
              foreground: printer && printer.isDefault ? root.accent : root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              tooltipText: printer && printer.isDefault ? strings.t("printers.isDefaultTooltip") : strings.t("printers.setDefaultTooltip")
              enabled: !service.actionBusy && !!printer && !printer.isDefault
              onClicked: if (printer) service.setDefaultPrinter(printer.name)
            }

            PanelActionButton {
              iconText: printer && printer.stateKey === "stopped" ? "󰐊" : "󰏤"
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: printer && printer.stateKey === "stopped" ? strings.t("printers.resumeTooltip") : strings.t("printers.pauseTooltip")
              enabled: !service.actionBusy && !!printer
              onClicked: if (printer) service.setPrinterEnabled(printer.name, printer.stateKey === "stopped")
            }
          }
        }

        // Ink / Toner marker levels (shown automatically when CUPS reports markers)
        Column {
          visible: !!printer && printer.markers && printer.markers.length > 0
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: printer ? printer.markers : []
            RowLayout {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              PlainText {
                text: modelData.name
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                Layout.preferredWidth: Style.space(90)
                elide: Text.ElideRight
              }

              Rectangle {
                Layout.fillWidth: true
                height: Style.space(5)
                radius: height / 2
                color: Qt.alpha(root.foreground, 0.14)

                Rectangle {
                  width: modelData.level >= 0 ? Math.max(parent.height, parent.width * (modelData.level / 100)) : 0
                  height: parent.height
                  radius: height / 2
                  color: modelData.color !== "" ? modelData.color : root.accent
                }
              }

              PlainText {
                text: modelData.level >= 0 ? (Commons.I18n.formatNumber(modelData.level) + "%") : "—"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // Always-visible quick maintenance & options bar on each printer card
        Flow {
          visible: !!printer
          width: parent.width
          spacing: Style.space(6)

          readonly property var cardMaint: printer && printer.maintenance ? printer.maintenance : ({
            backend: "none",
            cleanHeads: false,
            nozzleCheck: false,
            alignment: false
          })

          Button {
            visible: parent.cardMaint.nozzleCheck
            iconText: "󰖌"
            text: strings.t("printers.quickNozzle")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            enabled: !service.actionBusy && !!printer
            onClicked: if (printer) service.printNozzleCheck(printer.name)
          }

          Button {
            visible: parent.cardMaint.cleanHeads
            iconText: "󰃢"
            text: strings.t("printers.quickClean")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            enabled: !service.actionBusy && !!printer
            onClicked: if (printer) root.askCleanHeads(printer.name)
          }

          Button {
            visible: parent.cardMaint.alignment
            iconText: "󰖷"
            text: strings.t("printers.quickAlign")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            enabled: !service.actionBusy && !!printer
            onClicked: if (printer) root.openMaintenanceFor(printer.name)
          }

          Button {
            iconText: "󰧮"
            text: strings.t("printers.quickTest")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            enabled: !service.actionBusy && !!printer
            onClicked: if (printer) service.printTestPage(printer.name)
          }

          Button {
            iconText: printerCard.expanded ? "󰅃" : "󰘮"
            text: strings.t("printers.quickOptions")
            selected: printerCard.expanded
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            onClicked: if (printer) root.expandedPrinter = printerCard.expanded ? "" : printer.name
          }
        }
      }
    }

    // Expandable inline properties & options drawer
    BorderSurface {
      id: propsDrawer
      visible: printerCard.expanded && !!printer
      width: parent.width
      implicitHeight: propsCol.implicitHeight + Style.space(20)
      color: Style.normalFillFor(root.foreground, root.accent)
      borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
      radius: Style.cornerRadius

      onVisibleChanged: {
        if (visible && printer) {
          infoField.text = printer.info
          locationField.text = printer.location
        }
      }

      Column {
        id: propsCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(8)

        SettingSwitchRow {
          width: parent.width
          label: strings.t("printers.prop.enabled")
          checked: !!printer && printer.stateKey !== "stopped"
          busy: service.actionBusy
          onToggled: if (printer) service.setPrinterEnabled(printer.name, printer.stateKey === "stopped")
        }

        SettingSwitchRow {
          width: parent.width
          label: strings.t("printers.prop.accepting")
          checked: !!printer && printer.acceptingJobs
          busy: service.actionBusy
          onToggled: if (printer) service.setPrinterAccepting(printer.name, !printer.acceptingJobs)
        }

        SettingSwitchRow {
          width: parent.width
          label: strings.t("printers.prop.shared")
          checked: !!printer && printer.shared
          busy: service.actionBusy
          onToggled: if (printer) service.setPrinterShared(printer.name, !printer.shared)
        }

        PanelSeparator { foreground: root.foreground }

        // Printer default job options (Paper size, Color mode, Quality, Duplex)
        PrinterOptionDropdown {
          width: parent.width
          visible: !!printer && !!printer.options && !!printer.options.paperSize
          slot: "paperSize"
          optionData: printer && printer.options ? printer.options.paperSize : null
          labelText: strings.t("printers.prop.paperSize")
          printerName: printer ? printer.name : ""
        }

        PrinterOptionDropdown {
          width: parent.width
          visible: !!printer && !!printer.options && !!printer.options.colorMode
          slot: "colorMode"
          optionData: printer && printer.options ? printer.options.colorMode : null
          labelText: strings.t("printers.prop.colorMode")
          printerName: printer ? printer.name : ""
        }

        PrinterOptionDropdown {
          width: parent.width
          visible: !!printer && !!printer.options && !!printer.options.quality
          slot: "quality"
          optionData: printer && printer.options ? printer.options.quality : null
          labelText: strings.t("printers.prop.quality")
          printerName: printer ? printer.name : ""
        }

        PrinterOptionDropdown {
          width: parent.width
          visible: !!printer && !!printer.options && !!printer.options.duplex && printer.options.duplex.choices.length > 1
          slot: "duplex"
          optionData: printer && printer.options ? printer.options.duplex : null
          labelText: strings.t("printers.prop.duplex")
          printerName: printer ? printer.name : ""
        }

        Dropdown {
          width: parent.width
          label: strings.t("printers.prop.errorPolicy")
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          value: printer ? printer.errorPolicy : "stop-printer"
          options: [
            { value: "stop-printer", label: strings.t("printers.policy.stop") },
            { value: "retry-job", label: strings.t("printers.policy.retry") },
            { value: "abort-job", label: strings.t("printers.policy.abort") }
          ]
          onPopupOpenChanged: root.trackDropdown("errorPolicy:" + (printer ? printer.name : ""), popupOpen)
          onChanged: function(val) {
            if (printer && val !== printer.errorPolicy) {
              service.updatePrinterDetails(printer.name, null, null, val)
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // Description & Location metadata
        PlainText {
          text: strings.t("printers.prop.description")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        TextField {
          id: infoField
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          text: printer ? printer.info : ""
          onActiveFocusChanged: root.trackTextFocus("info:" + (printer ? printer.name : ""), activeFocus)
        }

        PlainText {
          text: strings.t("printers.prop.location")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        TextField {
          id: locationField
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          placeholderText: strings.t("printers.prop.locationPlaceholder")
          text: printer ? printer.location : ""
          onActiveFocusChanged: root.trackTextFocus("location:" + (printer ? printer.name : ""), activeFocus)
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Button {
            iconText: "󰄬"
            text: strings.t("printers.prop.saveMeta")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            iconSize: Style.font.iconSmall
            verticalPadding: Style.space(4)
            enabled: !service.actionBusy && !!printer
            onClicked: if (printer) service.updatePrinterDetails(printer.name, infoField.text, locationField.text, null)
          }

          Button {
            iconText: "󰈙"
            text: strings.t("queue.printFile")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            iconSize: Style.font.iconSmall
            verticalPadding: Style.space(4)
            onClicked: if (printer) root.openPrintDrawer(printer.name)
          }

          Button {
            visible: !!printer && printer.activeJobCount > 0
            iconText: "󰗩"
            text: strings.t("printers.prop.cancelQueue")
            bordered: true
            foreground: root.urgent
            accent: root.urgent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            iconSize: Style.font.iconSmall
            verticalPadding: Style.space(4)
            enabled: !service.actionBusy
            onClicked: if (printer) root.askCancelAll(printer.name)
          }

          Button {
            iconText: "󰆴"
            text: strings.t("printers.prop.remove")
            bordered: true
            foreground: root.urgent
            accent: root.urgent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            iconSize: Style.font.iconSmall
            verticalPadding: Style.space(4)
            enabled: !service.actionBusy && !!printer
            onClicked: if (printer) root.askDeletePrinter(printer.name)
          }
        }
      }
    }
  }

  component PrinterOptionDropdown: Dropdown {
    property string slot: ""
    property var optionData: null
    property string labelText: ""
    property string printerName: ""

    label: labelText
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    value: optionData ? optionData.current : ""
    options: {
      strings.language
      if (!optionData || !optionData.choices) return []
      var list = []
      for (var i = 0; i < optionData.choices.length; i++) {
        var c = optionData.choices[i]
        list.push({
          value: c,
          label: Model.normalizeOptionLabel(slot, c, function(k) { return strings.t(k) })
        })
      }
      return list
    }
    onPopupOpenChanged: root.trackDropdown("opt:" + printerName + ":" + slot, popupOpen)
    onChanged: function(val) {
      if (printerName && optionData && optionData.key && val !== optionData.current) {
        service.setPrinterOption(printerName, optionData.key, val)
      }
    }
  }

  component DiscoveredDeviceRow: CursorSurface {
    id: devRow
    property var device: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.activeTab === "setup" && root.selectedIndex === rowIndex
    bordered: true
    foreground: root.foreground
    accent: root.accent
    implicitHeight: devLayout.implicitHeight + Style.space(14)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: {
        root.cursorActive = true
        root.selectedIndex = devRow.rowIndex
      }
    }

    RowLayout {
      id: devLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      PlainText {
        text: device && device.driverless ? "󰨋" : "󰐪"
        color: device && device.alreadyConfigured ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        PlainText {
          Layout.fillWidth: true
          text: device ? device.info : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        PlainText {
          Layout.fillWidth: true
          text: {
            strings.language
            if (!device) return ""
            var tag = device.driverless
              ? strings.t("setup.driverless")
              : (device.deviceClass === "direct" ? strings.t("setup.usb") : strings.t("setup.network"))
            return tag + " · " + device.uriDisplay
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PlainText {
        visible: !!device && device.alreadyConfigured
        text: strings.t("setup.configured").toUpperCase()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Button {
        visible: !!device && !device.alreadyConfigured
        iconText: "󰐕"
        text: strings.t("setup.add")
        bordered: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        iconSize: Style.font.iconSmall
        verticalPadding: Style.space(4)
        horizontalPadding: Style.space(8)
        enabled: !service.actionBusy
        onClicked: service.addPrinter(
          device.suggestedName,
          device.uri,
          device.info,
          device.makeModel,
          device.driverless,
          service.printers.length === 0
        )
      }
    }
  }
}
