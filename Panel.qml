import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Clockify timer in the bar. All network and credential work happens in
// clockify.py; this file only renders the JSON it prints. The API key never
// enters QML, so nothing else in the shared shell scene can read it.
Panel {
  id: root
  moduleName: "dpsk.clockify"
  ipcTarget: "dpsk.clockify"
  manageIpc: false

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("clockify.py")).replace(/^file:\/\//, ""))
  readonly property int baseIntervalSec: {
    var n = Number(setting("refreshIntervalSec", 30))
    return isFinite(n) ? Math.min(3600, Math.max(10, Math.round(n))) : 30
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Server state, as last reported by the helper.
  property var running: null
  property var projects: []
  property var recent: []
  property var rules: ({})
  property bool loaded: false
  property string error: ""
  property string errorKind: ""
  property int failures: 0
  // A failed start/stop stays visible until the next action or reopen;
  // a later successful poll must not silently hide it.
  property string actionError: ""

  // Request plumbing: one helper process at a time. A user action always
  // wins the queue slot; a poll only takes it when nothing else is waiting.
  property var pendingArgs: null
  property bool pendingIsAction: false
  property string pendingPayload: ""
  // One request to run next even while backing off (a manual refresh, the
  // check after a failed action). Background refreshes never bypass backoff.
  property var followUp: null
  // Output of the last launch has been processed; nothing new is launched
  // before that, so a result can never be read with the wrong currentKind.
  property bool outputHandled: true
  property bool actionInFlight: false
  // What the running helper was asked for ("cached", "light", "full",
  // "action"). Kept until the next launch because stdout and exit can
  // arrive in either order.
  property string currentKind: ""
  readonly property bool busy: actionInFlight || (pendingArgs !== null && pendingIsAction)

  // Background prefetch: recents and projects are refreshed when something
  // changed, not when the popup opens, so opening never waits on Clockify.
  property bool fullWanted: true
  property double lastFullMs: 0
  property string lastRunningId: ""
  readonly property int staleAfterMs: 60000

  // New-entry form state.
  property string draftDescription: ""
  property string draftProjectId: ""
  property int recentIndex: -1
  property bool pickerOpen: false

  property double nowMs: Date.now()
  readonly property double startMs: running ? Date.parse(running.start) : 0
  readonly property bool tracking: !!running && startMs > 0
  readonly property bool needsSetup: errorKind === "config" || errorKind === "auth"
  readonly property bool projectRequired: rules.projectRequired === true
  readonly property bool descriptionRequired: rules.descriptionRequired === true
  readonly property string draftProblem: missingFor(draftDescription, draftProjectId)

  function pad(n) { return n < 10 ? "0" + n : String(n) }

  function elapsedText(withSeconds) {
    if (!tracking) return withSeconds ? "0:00:00" : "0:00"
    var total = Math.max(0, Math.floor((nowMs - startMs) / 1000))
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    return h + ":" + pad(m) + (withSeconds ? ":" + pad(total % 60) : "")
  }

  function projectById(id) {
    if (!id) return null
    for (var i = 0; i < projects.length; i++)
      if (projects[i].id === id) return projects[i]
    return null
  }

  function projectColor(p) {
    return p && /^#[0-9a-fA-F]{6}$/.test(p.color) ? p.color : dim
  }

  function missingFor(description, projectId) {
    if (projectRequired && !projectId) return "Pick a project — this workspace requires one"
    if (descriptionRequired && !String(description || "").trim()) return "Add a description — this workspace requires one"
    return ""
  }

  function entryLabel(e) {
    if (!e) return ""
    var d = e.description || "(no description)"
    return e.project && e.project.name ? d + "  ·  " + e.project.name : d
  }

  // ---------------------------------------------------------------- helper

  function request(args, isAction, payload) {
    if (helperProc.running || !outputHandled) {
      if (isAction || pendingArgs === null) {
        pendingArgs = args
        pendingIsAction = isAction
        pendingPayload = payload || ""
      }
      return
    }
    actionInFlight = isAction
    outputHandled = false
    currentKind = isAction ? "action" : (args[0] === "cached" ? "cached" : (args.indexOf("--light") >= 0 ? "light" : "full"))
    helperProc.stdinPayload = payload || ""
    helperProc.command = ["python3", root.helperPath].concat(args)
    helperProc.running = true
  }

  function refresh() { request(fullWanted ? ["status"] : ["status", "--light"], false) }

  // Background: refresh soon, but only while healthy. When requests are
  // failing, the poll timer retries with backoff instead.
  function wantFull() {
    fullWanted = true
    Qt.callLater(root.refreshIfIdle)
  }

  // Explicit user request (open with stale data, `r`, IPC refresh): one
  // attempt right away even during backoff.
  function refreshNow() {
    fullWanted = true
    followUp = ["status"]
    Qt.callLater(root.refreshIfIdle)
  }

  // Runs queued work once the helper is free and its output was handled.
  // Called after both events, so whichever comes last launches the next.
  function refreshIfIdle() {
    if (helperProc.running || !outputHandled) return
    if (pendingArgs !== null) {
      var args = pendingArgs
      var isAction = pendingIsAction
      var payload = pendingPayload
      pendingArgs = null
      pendingIsAction = false
      pendingPayload = ""
      request(args, isAction, payload)
    } else if (followUp !== null) {
      var next = followUp
      followUp = null
      request(next, false)
    } else if (fullWanted && failures === 0) {
      refresh()
    }
  }

  // The disk snapshot only fills the lists; whether a timer is running is
  // always confirmed live before the bar shows one.
  function applyCached(data) {
    if (Array.isArray(data.projects)) projects = data.projects
    if (Array.isArray(data.recent)) recent = data.recent
    if (data.rules && typeof data.rules === "object") rules = data.rules
  }

  function startEntry(description, projectId) {
    if (busy) return
    var problem = missingFor(description, projectId)
    if (problem) { actionError = problem; return }
    actionError = ""
    // The description goes over stdin: argv is readable by every local user
    // through /proc, and entry text can be client-confidential.
    var payload = JSON.stringify({
      description: String(description || ""),
      projectId: projectId && /^[0-9a-f]{24}$/.test(projectId) ? projectId : ""
    })
    request(["start", "--stdin"], true, payload + "\n")
  }

  function stopEntry() {
    if (busy || !tracking) return
    actionError = ""
    request(["stop"], true)
  }

  function startDraft() {
    if (recentIndex >= 0 && recentIndex < recent.length) {
      var e = recent[recentIndex]
      startEntry(e.description, e.projectId)
    } else {
      startEntry(draftDescription, draftProjectId)
    }
  }

  function handleOutput(text) {
    outputHandled = true
    Qt.callLater(root.refreshIfIdle)
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    var kind0 = currentKind
    var wasAction = kind0 === "action"
    if (!data || typeof data !== "object" || !data.ok) {
      var message = data && data.error ? String(data.error) : "Helper returned no data"
      var kind = data && data.kind ? String(data.kind) : "internal"
      if (wasAction) {
        // The action may have half-happened (start stops the running entry
        // before creating the new one), so re-check what is running now.
        actionError = message
        followUp = ["status", "--light"]
        // Rejected input is about this action, not about connectivity.
        if (kind !== "rejected" && kind !== "input") fail(kind, message)
      } else {
        fail(kind, message)
      }
      return
    }
    if (kind0 === "cached") {
      applyCached(data)
      return
    }
    error = ""
    errorKind = ""
    failures = 0
    loaded = true
    running = data.running || null
    applyCached(data)
    if (kind0 === "full") {
      fullWanted = false
      lastFullMs = Date.now()
    }
    var runningId = running ? String(running.id || "") : ""
    // A timer started or stopped elsewhere changes Recent; fetch it now,
    // in the background, rather than when the popup is next opened.
    if (kind0 === "light" && runningId !== lastRunningId) wantFull()
    lastRunningId = runningId
    if (wasAction) {
      draftDescription = ""
      draftProjectId = ""
      recentIndex = -1
      pickerOpen = false
      wantFull()
    }
  }

  function fail(kind, message) {
    errorKind = kind
    error = message
    failures = Math.min(failures + 1, 6)
  }

  // Back off on failure: 30s, 60s, 120s ... capped at five minutes. A
  // missing or rejected key will not fix itself, so poll it slowly.
  function pollIntervalMs() {
    if (needsSetup) return 300000
    var sec = failures > 0 ? Math.min(300, baseIntervalSec * Math.pow(2, failures - 1)) : baseIntervalSec
    return sec * 1000
  }

  function scheduleTick() {
    if (!tracking) { tickTimer.stop(); return }
    var period = opened ? 1000 : 60000
    var elapsed = Date.now() - startMs
    tickTimer.interval = Math.max(50, period - (elapsed % period) + 20)
    tickTimer.restart()
  }

  function launchSetup() {
    var quoted = "'" + root.helperPath.replace(/'/g, "'\\''") + "'"
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "python3 " + quoted + " setup"])
    root.close()
    setupWatch.remaining = 36
    setupWatch.restart()
  }

  Process {
    id: helperProc
    property string stdinPayload: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleOutput(text)
    }
    onStarted: {
      if (stdinPayload !== "") write(stdinPayload)
      stdinPayload = ""
    }
    // Reset here rather than in onExited: a process that fails to start
    // may never report an exit, and busy must not stick.
    onRunningChanged: {
      if (running) return
      root.actionInFlight = false
      orphanCheck.restart()
      Qt.callLater(root.refreshIfIdle)
    }
  }

  // If a run ends without its stdout ever finishing (failed to start),
  // close it out as an error so the queue keeps moving.
  Timer {
    id: orphanCheck
    interval: 2000
    onTriggered: if (!root.outputHandled && !helperProc.running) root.handleOutput("")
  }

  // After launching setup, check every 5 s for a few minutes so the bar
  // comes alive as soon as the key is saved.
  Timer {
    id: setupWatch
    property int remaining: 0
    interval: 5000
    repeat: true
    onTriggered: {
      if (!root.needsSetup || --remaining <= 0) { stop(); return }
      root.refreshNow()
    }
  }

  Timer {
    id: pollTimer
    interval: root.pollIntervalMs()
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: tickTimer
    repeat: false
    onTriggered: {
      root.nowMs = Date.now()
      root.scheduleTick()
    }
  }

  onTrackingChanged: { nowMs = Date.now(); scheduleTick() }
  onStartMsChanged: { nowMs = Date.now(); scheduleTick() }
  onOpenedChanged: {
    nowMs = Date.now()
    scheduleTick()
    if (opened) {
      actionError = ""
      recentIndex = -1
      pickerOpen = false
      // Show what we have immediately; revalidate in the background only
      // when it is getting old.
      if (Date.now() - lastFullMs > staleAfterMs) refreshNow()
    }
  }

  // Startup: the disk snapshot fills the lists in ~40 ms, then a live full
  // status follows (fullWanted starts true), all before the first open.
  Component.onCompleted: request(["cached"], false)

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function stop(): string { root.stopEntry(); return "ok" }
    // Scriptable start, e.g. a hotkey for a recurring task. Workspace rules
    // apply exactly as in the panel; the result shows up in the bar.
    function start(description: string, projectId: string): string {
      if (root.busy) return "busy"
      var problem = root.missingFor(description, projectId)
      if (problem) return problem
      if (projectId && !/^[0-9a-f]{24}$/.test(projectId)) return "invalid project id"
      root.startEntry(description, projectId)
      return "ok"
    }
    function status(): string { return root.tracking ? root.elapsedText(false) + " " + root.entryLabel(root.running) : "idle" }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.tracking && !vertical ? "󰔛 " + root.elapsedText(false) : "󰔛"
    fontSize: Style.bar.iconFont
    active: root.tracking
    activeColor: Color.accent
    dimmed: root.needsSetup
    tooltipText: root.tracking ? root.entryLabel(root.running) : (root.error || "Clockify")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.stopEntry()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: content.item ? content.item.initialFocus : null
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.item ? content.item.implicitHeight : 0)

    // Content exists only while the popup is on screen and is torn down
    // when it closes, so an idle bar holds nothing but the button.
    Loader {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      active: panel.visible
      sourceComponent: popupContent
    }
  }

  Component {
    id: popupContent

    PanelKeyCatcher {
      id: keyCatcher
      readonly property Item initialFocus: root.needsSetup ? keyCatcher : descField
      implicitHeight: column.implicitHeight
      blocked: descField.activeFocus || filterField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r") root.refreshNow() }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        // ---------- Current timer ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroTime.implicitHeight, heroLabels.implicitHeight, stopButton.implicitHeight)

          Text {
            id: heroTime
            textFormat: Text.PlainText
            text: root.elapsedText(true)
            color: root.tracking ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            font.features: { "tnum": 1 }
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroTime.right
            anchors.leftMargin: Style.space(14)
            anchors.right: stopButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.tracking ? (root.running.description || "(no description)") : (root.loaded ? "Not tracking" : (root.error ? "Not connected" : "Loading…"))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Row {
              visible: root.tracking && !!root.running.project
              spacing: Style.space(6)
              Rectangle {
                width: Style.space(8); height: width; radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.projectColor(root.running ? root.running.project : null)
              }
              Text {
                textFormat: Text.PlainText
                text: root.running && root.running.project ? root.running.project.name : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: Math.min(implicitWidth, heroLabels.width - Style.space(14))
              }
            }
          }

          Button {
            id: stopButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.tracking
            iconText: "󰓛"
            text: "Stop"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.stopEntry()
          }
        }

        // ---------- Error / setup ----------
        Column {
          width: parent.width
          visible: root.error !== "" || root.actionError !== ""
          spacing: Style.space(8)

          Text {
            width: parent.width
            visible: root.actionError !== ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.actionError
            color: bar ? bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.error !== ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.errorKind === "config" && root.error === "Not configured"
              ? "Add your Clockify API key to get started."
              : root.error + (root.loaded && !root.needsSetup ? " — showing last known state" : "")
            color: root.needsSetup ? root.foreground : (bar ? bar.urgent : Color.urgent)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: root.needsSetup
            iconText: "󰌆"
            text: "Set up API key"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.launchSetup()
          }
        }

        PanelSeparator { foreground: root.foreground; visible: !root.needsSetup }

        // ---------- New entry ----------
        Column {
          width: parent.width
          visible: !root.needsSetup
          spacing: Style.space(8)

          PanelSectionHeader { text: "NEW"; foreground: root.foreground; fontFamily: root.fontFamily }

          TextField {
            id: descField
            width: parent.width
            placeholderText: "What are you working on?"
            foreground: root.foreground
            font.family: root.fontFamily
            maximumLength: 3000
            text: root.draftDescription
            onTextEdited: { root.draftDescription = text; root.recentIndex = -1 }
            // Typing breaks the text binding; mirror resets after a start.
            Connections {
              target: root
              function onDraftDescriptionChanged() {
                if (descField.text !== root.draftDescription) descField.text = root.draftDescription
              }
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.close(); event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.recentIndex = Math.min(root.recent.length - 1, root.recentIndex + 1); event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.recentIndex = Math.max(-1, root.recentIndex - 1); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.startDraft(); event.accepted = true
              } else if (event.key === Qt.Key_Tab) {
                root.pickerOpen = true
                filterField.forceActiveFocus()
                event.accepted = true
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: projectButton
              width: parent.width - startButton.width - parent.spacing
              leftAlign: true
              iconText: "󰉋"
              text: {
                var p = root.projectById(root.draftProjectId)
                return p ? p.name : (root.projectRequired ? "Pick a project (required)" : "No project")
              }
              bordered: true
              selected: root.pickerOpen
              foreground: root.draftProjectId ? root.foreground : root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: {
                root.pickerOpen = !root.pickerOpen
                if (root.pickerOpen) filterField.forceActiveFocus()
              }
              onRightClicked: root.draftProjectId = ""
            }

            Button {
              id: startButton
              iconText: "󰐊"
              text: "Start"
              bordered: true
              readonly property bool usable: !root.busy && (root.recentIndex >= 0 || root.draftProblem === "")
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              opacity: usable ? 1 : 0.5
              tooltipText: root.recentIndex < 0 ? root.draftProblem : ""
              onClicked: root.startDraft()
            }
          }

          // Project picker: filter field plus a short scrolling list.
          Column {
            id: picker
            width: parent.width
            visible: root.pickerOpen
            spacing: Style.space(4)

            property int cursor: 0
            readonly property var matches: {
              if (!root.pickerOpen) return []
              var q = filterField.text.trim().toLowerCase()
              var out = root.projectRequired ? [] : [{ id: "", name: "No project", color: "" }]
              for (var i = 0; i < root.projects.length && out.length < 60; i++) {
                var p = root.projects[i]
                if (p.archived) continue
                var name = String(p.name || "")
                if (!q || name.toLowerCase().indexOf(q) >= 0 || String(p.client || "").toLowerCase().indexOf(q) >= 0) out.push(p)
              }
              return out
            }
            onMatchesChanged: cursor = !root.projectRequired && matches.length > 1 && filterField.text !== "" ? 1 : 0

            function choose(index) {
              if (index < 0 || index >= matches.length) return
              root.draftProjectId = matches[index].id
              root.pickerOpen = false
              filterField.text = ""
              descField.forceActiveFocus()
            }

            TextField {
              id: filterField
              width: parent.width
              placeholderText: "Filter projects"
              foreground: root.foreground
              font.family: root.fontFamily
              maximumLength: 100
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.pickerOpen = false; text = ""; descField.forceActiveFocus(); event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  picker.cursor = Math.min(picker.matches.length - 1, picker.cursor + 1); event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  picker.cursor = Math.max(0, picker.cursor - 1); event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
                  picker.choose(picker.cursor); event.accepted = true
                }
              }
            }

            ListView {
              id: projectList
              width: parent.width
              height: Math.min(count, 6) * Style.spacing.popupRowHeight
              clip: true
              model: picker.matches
              currentIndex: picker.cursor
              boundsBehavior: Flickable.StopAtBounds
              onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

              delegate: Item {
                required property var modelData
                required property int index
                width: projectList.width
                height: Style.spacing.popupRowHeight

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: index === picker.cursor || rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, Color.urgent) : "transparent"
                }
                Rectangle {
                  id: dot
                  width: Style.space(8); height: width; radius: width / 2
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.projectColor(modelData)
                  visible: modelData.id !== ""
                }
                Text {
                  anchors.left: dot.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.client ? modelData.name + "  ·  " + modelData.client : modelData.name
                  color: modelData.id === root.draftProjectId ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: picker.choose(index)
                }
              }
            }
          }
        }

        // ---------- Recent ----------
        Column {
          width: parent.width
          visible: !root.needsSetup && root.recent.length > 0
          spacing: Style.space(4)

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "RECENT"
            foreground: root.foreground
            fontFamily: root.fontFamily
            topPadding: Style.space(8)
          }

          Repeater {
            model: root.recent
            delegate: Item {
              required property var modelData
              required property int index
              width: column.width
              height: Style.spacing.popupRowHeight

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: index === root.recentIndex || recentMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, Color.urgent) : "transparent"
              }
              Rectangle {
                id: recentDot
                width: Style.space(8); height: width; radius: width / 2
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                color: root.projectColor(modelData.project)
                opacity: modelData.project ? 1 : 0.35
              }
              Text {
                anchors.left: recentDot.right
                anchors.leftMargin: Style.space(8)
                anchors.right: playGlyph.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.entryLabel(modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                id: playGlyph
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "󰐊"
                color: root.dim
                visible: recentMouse.containsMouse || index === root.recentIndex
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: recentMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.busy
                onClicked: root.startEntry(modelData.description, modelData.projectId)
              }
            }
          }
        }
      }
    }
  }
}
