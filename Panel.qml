import QtQuick
import QtQuick.Controls as QQC
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

  // The web app lives on one host for every data region; only the API is
  // regional.
  readonly property string webBase: "https://app.clockify.me"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Server state, as last reported by the helper.
  property var running: null
  property var projects: []
  property var recent: []
  property var history: []
  property bool historyComplete: true
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
  // "action"), and for an action which one ("start", "update", ...). Kept
  // until the next launch because stdout and exit can arrive in either order.
  property string currentKind: ""
  property string currentAction: ""
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
  property bool pickerFocused: false

  // Which screen the popup shows: "main", "history" or "edit".
  property string view: "main"
  property int historyIndex: -1

  // Entry editor state. editEntry is the entry as last loaded; the fields
  // hold the user's edits and only what differs from it is sent.
  property var editEntry: null
  property string editReturnView: "main"
  property string editDescription: ""
  property string editProjectId: ""
  property string editStartText: ""
  property string editEndText: ""
  property bool confirmDelete: false
  // History row armed for deletion: the next delete press on it deletes.
  property string armedDeleteId: ""
  // The entry an update or delete in flight is about; the editor may have
  // moved on to another one by the time the result arrives.
  property string actionEntryId: ""
  readonly property bool editingRunning: !!editEntry && !editEntry.end

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

  // Descriptions may span several lines; compact places show the first one
  // and mark that there is more.
  function firstLine(description) {
    var lines = String(description || "").split("\n")
    return lines.length > 1 ? lines[0] + " …" : lines[0]
  }

  function entryLabel(e) {
    if (!e) return ""
    var d = firstLine(e.description) || "(no description)"
    return e.project && e.project.name ? d + "  ·  " + e.project.name : d
  }

  function clockText(ms) {
    var d = new Date(ms)
    return pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  function durationText(ms) {
    var minutes = Math.max(0, Math.round(ms / 60000))
    return Math.floor(minutes / 60) + ":" + pad(minutes % 60)
  }

  function dayLabel(ms) {
    var d = new Date(ms)
    var today = new Date()
    today.setHours(0, 0, 0, 0)
    var day = new Date(d.getFullYear(), d.getMonth(), d.getDate())
    var diff = Math.round((today - day) / 86400000)
    if (diff === 0) return "Today"
    if (diff === 1) return "Yesterday"
    return Qt.formatDate(d, "ddd d MMM")
  }

  // History flattened into day headers and entry rows for one ListView.
  readonly property var historyRows: {
    var rows = []
    var header = null
    for (var i = 0; i < history.length; i++) {
      var e = history[i]
      var start = Date.parse(e.start)
      var end = Date.parse(e.end)
      if (!(start > 0) || !(end > 0)) continue
      var label = dayLabel(start)
      if (!header || header.label !== label) {
        header = { kind: "day", label: label, totalMs: 0 }
        rows.push(header)
      }
      header.totalMs += end - start
      rows.push({ kind: "entry", entry: e, startMs: start, endMs: end })
    }
    return rows
  }

  // "9:30", "09:30", "930" or "9.30" on the local day of baseIso, as the
  // UTC form the helper takes; "" when the text is not a time.
  function timeOnDay(text, baseIso) {
    var m = /^\s*(\d{1,2})[:.]?(\d{2})\s*$/.exec(String(text || ""))
    if (!m) return ""
    var h = Number(m[1]), min = Number(m[2])
    if (h > 23 || min > 59) return ""
    var d = new Date(Date.parse(baseIso))
    if (isNaN(d.getTime())) return ""
    d.setHours(h, min, 0, 0)
    return d.toISOString().replace(/\.\d{3}Z$/, "Z")
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
    currentAction = isAction ? args[0] : ""
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
    if (Array.isArray(data.history)) {
      history = data.history
      historyComplete = data.historyComplete !== false
    }
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

  // ---------------------------------------------------------------- views

  function showMain() {
    pickerOpen = false
    view = "main"
  }

  function showHistory() {
    pickerOpen = false
    armedDeleteId = ""
    historyIndex = -1
    actionError = ""
    view = "history"
    if (Date.now() - lastFullMs > staleAfterMs) refreshNow()
  }

  // Hover follows the pointer; it only disarms a delete armed on another row.
  function moveHistoryTo(index) {
    var row = historyRows[index]
    if (armedDeleteId && !(row && row.entry && row.entry.id === armedDeleteId)) armedDeleteId = ""
    historyIndex = index
  }

  function moveHistory(step) {
    armedDeleteId = ""
    var i = historyIndex
    do { i += step } while (i >= 0 && i < historyRows.length && historyRows[i].kind !== "entry")
    if (i >= 0 && i < historyRows.length) historyIndex = i
  }

  // Opens the project's page in Clockify as a web-app window. The id is
  // checked first and passed as one argv element, never through a shell.
  function openProjectPage(projectId) {
    if (!/^[0-9a-f]{24}$/.test(String(projectId || ""))) return
    Util.execArgv(["omarchy-launch-webapp", webBase + "/projects/" + projectId + "/edit"])
    close()
  }

  // Ctrl+E: the highlighted Recent entry, else what is running.
  function editHighlighted() {
    if (recentIndex >= 0 && recentIndex < recent.length) openEditor(recent[recentIndex], "main")
    else if (tracking) openEditor(running, "main")
  }

  function continueEntry(e) {
    if (busy || !e) return
    editEntry = null
    confirmDelete = false
    showMain()
    startEntry(e.description, e.projectId)
  }

  function openEditor(entry, from) {
    if (!entry || !entry.id || !(Date.parse(entry.start) > 0)) return
    editEntry = entry
    editReturnView = from
    editDescription = entry.description || ""
    editProjectId = entry.projectId || ""
    editStartText = clockText(Date.parse(entry.start))
    editEndText = entry.end ? clockText(Date.parse(entry.end)) : ""
    confirmDelete = false
    actionError = ""
    pickerOpen = false
    view = "edit"
  }

  function closeEditor() {
    pickerOpen = false
    confirmDelete = false
    view = editReturnView === "history" ? "history" : "main"
    editEntry = null
  }

  // What the editor changed, as the helper's update payload, or a string
  // explaining what is wrong with the input.
  function editChanges() {
    var e = editEntry
    var changes = { id: e.id }
    var startMs = Date.parse(e.start)
    var endMs = e.end ? Date.parse(e.end) : 0
    if (editDescription !== (e.description || "")) changes.description = editDescription
    if (editProjectId !== (e.projectId || "")) changes.projectId = editProjectId
    // Untouched times are not sent, so their seconds survive.
    if (editStartText.trim() !== clockText(startMs)) {
      changes.start = timeOnDay(editStartText, e.start)
      if (!changes.start) return "Start time should look like 9:30"
      startMs = Date.parse(changes.start)
    }
    if (endMs && editEndText.trim() !== clockText(endMs)) {
      changes.end = timeOnDay(editEndText, e.end)
      if (!changes.end) return "End time should look like 17:45"
      endMs = Date.parse(changes.end)
    }
    if (endMs && endMs <= startMs) return "The end must be after the start"
    if ((changes.start || changes.end) && (endMs || nowMs) - startMs >= 86400000)
      return "That makes the entry longer than a day; edit it in Clockify if you meant that"
    var problem = missingFor(editDescription, editProjectId)
    return problem || changes
  }

  readonly property string editDurationText: {
    if (!editEntry) return ""
    var start = Date.parse(timeOnDay(editStartText, editEntry.start))
    var end = editingRunning ? nowMs : Date.parse(timeOnDay(editEndText, editEntry.end))
    return start > 0 && end > start ? durationText(end - start) : "–"
  }

  function saveEdit() {
    if (busy || !editEntry) return
    var changes = editChanges()
    if (typeof changes === "string") { actionError = changes; return }
    if (Object.keys(changes).length === 1) { closeEditor(); return }
    actionError = ""
    actionEntryId = editEntry.id
    request(["update", "--stdin"], true, JSON.stringify(changes) + "\n")
  }

  // Two clicks: the first arms the button, the second deletes.
  function deleteEdited() {
    if (busy || !editEntry || editingRunning) return
    if (!confirmDelete) { confirmDelete = true; return }
    deleteEntry(editEntry.id)
  }

  // From History: the first press arms the row, a second one on the same
  // row deletes. Arming expires on its own so a stray press later is safe.
  function deleteFromHistory(e) {
    if (busy || !e || !e.id) return
    if (armedDeleteId !== e.id) {
      armedDeleteId = e.id
      disarmTimer.restart()
      return
    }
    armedDeleteId = ""
    deleteEntry(e.id)
  }

  function deleteEntry(id) {
    actionError = ""
    actionEntryId = id
    request(["delete", "--stdin"], true, JSON.stringify({ id: id }) + "\n")
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
    var action = currentAction
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
      if (action === "start") {
        draftDescription = ""
        draftProjectId = ""
        recentIndex = -1
        pickerOpen = false
      } else if (action === "update" || action === "delete") {
        var done = actionEntryId
        // Drop a deleted entry at once; the refresh below fills in the rest.
        if (action === "delete") history = history.filter(function(e) { return e.id !== done })
        if (armedDeleteId === done) armedDeleteId = ""
        if (view === "edit" && editEntry && editEntry.id === done) closeEditor()
      }
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
    id: disarmTimer
    interval: 4000
    onTriggered: root.armedDeleteId = ""
  }

  Timer {
    id: tickTimer
    repeat: false
    onTriggered: {
      root.nowMs = Date.now()
      root.scheduleTick()
    }
  }

  // An armed delete belongs to the History screen it was armed on.
  onViewChanged: armedDeleteId = ""

  // A refresh can reshuffle the rows; never leave the cursor on a header.
  onHistoryRowsChanged: {
    if (historyIndex >= historyRows.length || (historyIndex >= 0 && historyRows[historyIndex].kind !== "entry")) historyIndex = -1
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
      view = "main"
      editEntry = null
      confirmDelete = false
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
    // Open straight into History, or into the editor for the running entry.
    // Neither leaves an open editor: that would drop unsaved changes.
    function history(): string {
      root.open()
      if (root.needsSetup) return "not configured"
      if (root.view === "edit") return "editing"
      root.showHistory()
      return "ok"
    }
    function edit(): string {
      if (!root.tracking) return "idle"
      root.open()
      if (root.view === "edit") return "editing"
      root.openEditor(root.running, "main")
      return "ok"
    }
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

  // Project picker: filter field plus a short scrolling list. Loaded under
  // whichever project button opened it (new entry or editor); the choice
  // goes to the form of the current view.
  Component {
    id: pickerComponent

    Column {
      id: picker
      spacing: Style.space(4)

      signal done()

      property int cursor: 0
      readonly property string selectedId: root.view === "edit" ? root.editProjectId : root.draftProjectId
      readonly property var matches: {
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

      function focusFilter() { filterField.forceActiveFocus() }

      function choose(index) {
        if (index < 0 || index >= matches.length) return
        if (root.view === "edit") root.editProjectId = matches[index].id
        else root.draftProjectId = matches[index].id
        close()
      }

      // Hand focus back before closing: closing destroys this item, and a
      // signal sent after that would reach no Connections.
      function close() {
        done()
        root.pickerOpen = false
      }

      Component.onDestruction: root.pickerFocused = false

      TextField {
        id: filterField
        width: parent.width
        placeholderText: "Filter projects"
        foreground: root.foreground
        font.family: root.fontFamily
        maximumLength: 100
        onActiveFocusChanged: root.pickerFocused = activeFocus
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            picker.close(); event.accepted = true
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
            color: modelData.id === picker.selectedId ? Color.accent : root.foreground
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

  Component {
    id: popupContent

    PanelKeyCatcher {
      id: keyCatcher
      readonly property Item initialFocus: root.needsSetup ? keyCatcher : descField
      implicitHeight: column.implicitHeight
      blocked: descField.activeFocus || root.pickerFocused || editArea.activeFocus || startField.activeFocus || endField.activeFocus
      onCloseRequested: {
        if (root.armedDeleteId) root.armedDeleteId = ""
        else if (root.view === "edit") root.closeEditor()
        else if (root.view === "history") root.showMain()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (root.view === "history" && dy !== 0) root.moveHistory(dy) }
      onActivateRequested: {
        var row = root.historyRows[root.historyIndex]
        if (root.view === "history" && row && row.kind === "entry") root.openEditor(row.entry, "history")
      }
      onDeleteRequested: {
        var row = root.historyRows[root.historyIndex]
        if (root.view === "history" && row && row.kind === "entry") {
          historyList.positionViewAtIndex(root.historyIndex, ListView.Contain)
          root.deleteFromHistory(row.entry)
        }
      }
      onTextKey: function(t) {
        if (t === "r") root.refreshNow()
        if (t === "s" && root.view === "history") {
          var row = root.historyRows[root.historyIndex]
          if (row && row.kind === "entry") root.continueEntry(row.entry)
        }
      }

      // Each view takes the keyboard where it is most useful.
      function focusView() {
        if (root.view === "edit") editArea.forceActiveFocus()
        else if (root.view === "history" || root.needsSetup) keyCatcher.forceActiveFocus()
        else descField.forceActiveFocus()
      }

      Connections {
        target: root
        function onViewChanged() { Qt.callLater(keyCatcher.focusView) }
      }

      // Window-wide, so they work whichever field (if any) has focus. Not
      // in the editor, where leaving would silently drop unsaved changes.
      Shortcut {
        sequence: "Ctrl+H"
        enabled: root.view !== "edit" && !root.needsSetup
        onActivated: root.view === "history" ? root.showMain() : root.showHistory()
      }
      Shortcut {
        sequence: "Ctrl+E"
        enabled: root.view === "main" && !root.needsSetup
        onActivated: root.editHighlighted()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        // ---------- Current timer ----------
        Item {
          width: parent.width
          visible: root.view === "main"
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
            anchors.right: editButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.tracking ? (root.firstLine(root.running.description) || "(no description)") : (root.loaded ? "Not tracking" : (root.error ? "Not connected" : "Loading…"))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight

              // Clicking what is running opens it in the editor.
              MouseArea {
                anchors.fill: parent
                enabled: root.tracking
                cursorShape: root.tracking ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openEditor(root.running, "main")
              }
            }

            // The project opens its page on clockify.me.
            Row {
              id: heroProject
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
                font.underline: projectLinkMouse.containsMouse
                elide: Text.ElideRight
                width: Math.min(implicitWidth, heroLabels.width - Style.space(8) - projectLinkGlyph.implicitWidth - 2 * heroProject.spacing)
              }
              Text {
                id: projectLinkGlyph
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "󰏌"
                color: projectLinkMouse.containsMouse ? Color.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          MouseArea {
            id: projectLinkMouse
            x: heroLabels.x + heroProject.x
            y: heroLabels.y + heroProject.y
            width: heroProject.width
            height: heroProject.height
            visible: heroProject.visible
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openProjectPage(root.running.projectId)
          }

          Button {
            id: editButton
            anchors.right: stopButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.tracking
            width: visible ? implicitWidth : 0
            iconText: "󰏫"
            tooltipText: "Edit (Ctrl+E)"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.openEditor(root.running, "main")
          }

          Button {
            id: stopButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.tracking
            width: visible ? implicitWidth : 0
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

        PanelSeparator { foreground: root.foreground; visible: !root.needsSetup && root.view === "main" }

        // ---------- New entry ----------
        Column {
          width: parent.width
          visible: !root.needsSetup && root.view === "main"
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: Math.max(newHeader.implicitHeight, historyButton.implicitHeight)

            PanelSectionHeader {
              id: newHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "NEW"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Button {
              id: historyButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰋚"
              text: "History"
              tooltipText: "Edit past entries (Ctrl+H)"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.showHistory()
            }
          }

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
              var ctrl = event.modifiers & Qt.ControlModifier
              if (event.key === Qt.Key_Escape) {
                root.close(); event.accepted = true
              } else if (ctrl && event.key === Qt.Key_E) {
                // The field claims Ctrl+E (end of line) before the window
                // Shortcut sees it, so handle it here as well.
                root.editHighlighted(); event.accepted = true
              } else if (ctrl && event.key === Qt.Key_H) {
                root.showHistory(); event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.recentIndex = Math.min(root.recent.length - 1, root.recentIndex + 1); event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.recentIndex = Math.max(-1, root.recentIndex - 1); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.startDraft(); event.accepted = true
              } else if (event.key === Qt.Key_Tab) {
                if (root.pickerOpen && newPicker.item) newPicker.item.focusFilter()
                else root.pickerOpen = true
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
              onClicked: root.pickerOpen = !root.pickerOpen
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

          Loader {
            id: newPicker
            width: parent.width
            active: root.pickerOpen && root.view === "main"
            visible: active
            sourceComponent: pickerComponent
            onLoaded: item.focusFilter()
          }
          Connections {
            target: newPicker.item
            function onDone() { descField.forceActiveFocus() }
          }
        }

        // ---------- Recent ----------
        Column {
          width: parent.width
          visible: !root.needsSetup && root.view === "main" && root.recent.length > 0
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
                color: index === root.recentIndex || recentMouse.containsMouse || recentEditMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, Color.urgent) : "transparent"
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
                anchors.right: recentEdit.left
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
                opacity: recentMouse.containsMouse || recentEditMouse.containsMouse || index === root.recentIndex ? 1 : 0
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              // Left click restarts; right click or the pencil edits that
              // entry (the latest one with this description and project).
              MouseArea {
                id: recentMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                enabled: !root.busy
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.openEditor(modelData, "main")
                  else root.startEntry(modelData.description, modelData.projectId)
                }
              }
              Text {
                id: recentEdit
                anchors.right: playGlyph.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "󰏫"
                color: recentEditMouse.containsMouse ? Color.accent : root.dim
                opacity: recentMouse.containsMouse || recentEditMouse.containsMouse || index === root.recentIndex ? 1 : 0
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                MouseArea {
                  id: recentEditMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  onClicked: root.openEditor(modelData, "main")
                }
              }
            }
          }
        }

        // ---------- History ----------
        Column {
          width: parent.width
          visible: root.view === "history"
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: historyBack.implicitHeight

            Button {
              id: historyBack
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰁍"
              tooltipText: "Back (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.showMain()
            }
            PanelSectionHeader {
              anchors.left: historyBack.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: "HISTORY  ·  LAST 7 DAYS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          Text {
            width: parent.width
            visible: root.historyRows.length === 0
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.loaded ? "Nothing tracked in the last 7 days." : "Loading…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            id: historyList
            width: parent.width
            height: Math.min(count, 14) * Style.spacing.popupRowHeight
            visible: count > 0
            clip: true
            model: root.historyRows
            currentIndex: root.historyIndex
            boundsBehavior: Flickable.StopAtBounds
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: Item {
              required property var modelData
              required property int index
              width: historyList.width
              height: Style.spacing.popupRowHeight

              // Day header: label and the day's total.
              Item {
                anchors.fill: parent
                visible: modelData.kind === "day"
                PanelSectionHeader {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(4)
                  text: modelData.kind === "day" ? modelData.label.toUpperCase() : ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(4)
                  textFormat: Text.PlainText
                  text: modelData.kind === "day" ? root.durationText(modelData.totalMs) : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.features: { "tnum": 1 }
                }
              }

              Item {
                anchors.fill: parent
                visible: modelData.kind === "entry"

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: index === root.historyIndex || historyMouse.containsMouse || continueMouse.containsMouse || trashMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, Color.urgent) : "transparent"
                }
                Rectangle {
                  id: historyDot
                  width: Style.space(8); height: width; radius: width / 2
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.projectColor(modelData.entry ? modelData.entry.project : null)
                  opacity: modelData.entry && modelData.entry.project ? 1 : 0.35
                }
                Text {
                  anchors.left: historyDot.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: historyTimes.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.entryLabel(modelData.entry)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  id: historyTimes
                  anchors.right: historyEdit.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  readonly property bool armed: modelData.kind === "entry" && root.armedDeleteId === modelData.entry.id
                  text: modelData.kind !== "entry" ? ""
                    : armed ? "Delete? press again"
                    : root.clockText(modelData.startMs) + "–" + root.clockText(modelData.endMs) + "  " + root.durationText(modelData.endMs - modelData.startMs)
                  color: armed ? (bar ? bar.urgent : Color.urgent) : root.dim
                  font.bold: armed
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.features: { "tnum": 1 }
                }
                // Left click on the row edits it; this restarts it.
                MouseArea {
                  id: historyMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: if (modelData.kind === "entry" && root.historyIndex !== index) root.moveHistoryTo(index)
                  onClicked: root.openEditor(modelData.entry, "history")
                }
                Text {
                  id: historyEdit
                  anchors.right: historyContinue.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰏫"
                  color: historyMouse.containsMouse && !continueMouse.containsMouse ? Color.accent : root.dim
                  opacity: historyMouse.containsMouse || continueMouse.containsMouse || trashMouse.containsMouse || index === root.historyIndex ? 1 : 0
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: historyContinue
                  anchors.right: historyTrash.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰐊"
                  color: continueMouse.containsMouse ? Color.accent : root.dim
                  opacity: historyMouse.containsMouse || continueMouse.containsMouse || trashMouse.containsMouse || index === root.historyIndex ? 1 : 0
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  MouseArea {
                    id: continueMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    onClicked: root.continueEntry(modelData.entry)
                  }
                }
                Text {
                  id: historyTrash
                  readonly property bool armed: modelData.kind === "entry" && root.armedDeleteId === modelData.entry.id
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰆴"
                  color: armed ? (bar ? bar.urgent : Color.urgent) : (trashMouse.containsMouse ? Color.accent : root.dim)
                  opacity: armed || historyMouse.containsMouse || continueMouse.containsMouse || trashMouse.containsMouse || index === root.historyIndex ? 1 : 0
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  MouseArea {
                    id: trashMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    onClicked: root.deleteFromHistory(modelData.entry)
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.historyRows.length > 0
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: (root.historyComplete ? "" : "Only the latest 100 entries are shown.  ")
              + "Click a row or press Enter to edit it.  󰐊 or s starts it again.  󰆴 or x twice deletes it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Editor ----------
        Column {
          width: parent.width
          visible: root.view === "edit"
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: editBack.implicitHeight

            Button {
              id: editBack
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰁍"
              tooltipText: "Cancel (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.closeEditor()
            }
            PanelSectionHeader {
              anchors.left: editBack.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: root.editingRunning ? "EDIT RUNNING ENTRY" : "EDIT ENTRY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          // Multi-line description: Enter saves, Shift+Enter starts a new line.
          Flickable {
            id: editFlick
            width: parent.width
            height: Math.min(editArea.implicitHeight, Style.space(150))
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            QQC.TextArea.flickable: QQC.TextArea {
              id: editArea
              // Descriptions come from Clockify: never interpret them as markup.
              textFormat: TextEdit.PlainText
              wrapMode: TextEdit.Wrap
              placeholderText: "Description"
              selectByMouse: true
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
              selectedTextColor: root.foreground
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"), root.foreground, Color.accent)
              leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
              rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
              topPadding: Style.spacing.inputPaddingY + Border.top(_borderSpec)
              bottomPadding: Style.spacing.inputPaddingY + Border.bottom(_borderSpec)
              background: BorderSurface {
                color: Style.controlFill(editArea.activeFocus, editArea.hovered, root.foreground, Color.accent)
                borderSpec: editArea._borderSpec
                radius: Style.cornerRadius
              }

              onTextChanged: {
                if (length > 3000) remove(3000, length)
                if (text !== root.editDescription) root.editDescription = text
              }
              Connections {
                target: root
                function onEditDescriptionChanged() {
                  if (editArea.text !== root.editDescription) editArea.text = root.editDescription
                }
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.closeEditor(); event.accepted = true
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                  root.saveEdit(); event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  if (root.pickerOpen && editPicker.item) editPicker.item.focusFilter()
                  else root.pickerOpen = true
                  event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  (root.editingRunning ? startField : endField).forceActiveFocus(); event.accepted = true
                }
              }
            }
            QQC.ScrollBar.vertical: QQC.ScrollBar {}
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Enter saves  ·  Shift+Enter new line  ·  Tab next field"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            id: editProjectButton
            width: parent.width
            leftAlign: true
            iconText: "󰉋"
            text: {
              var p = root.projectById(root.editProjectId)
              return p ? p.name : (root.projectRequired ? "Pick a project (required)" : "No project")
            }
            bordered: true
            selected: root.pickerOpen
            foreground: root.editProjectId ? root.foreground : root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.pickerOpen = !root.pickerOpen
            onRightClicked: root.editProjectId = ""
          }

          Loader {
            id: editPicker
            width: parent.width
            active: root.pickerOpen && root.view === "edit"
            visible: active
            sourceComponent: pickerComponent
            onLoaded: item.focusFilter()
          }
          Connections {
            target: editPicker.item
            function onDone() { startField.forceActiveFocus() }
          }

          // Times are edited on the entry's own day(s); only a changed field
          // is sent, so untouched seconds are kept.
          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.editEntry ? root.dayLabel(Date.parse(root.editEntry.start)) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: startField
              width: Style.space(64)
              horizontalAlignment: TextInput.AlignHCenter
              placeholderText: "9:30"
              foreground: root.foreground
              font.family: root.fontFamily
              font.features: { "tnum": 1 }
              maximumLength: 5
              inputMethodHints: Qt.ImhPreferNumbers
              text: root.editStartText
              onTextEdited: root.editStartText = text
              Connections {
                target: root
                function onEditStartTextChanged() {
                  if (startField.text !== root.editStartText) startField.text = root.editStartText
                }
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.closeEditor(); event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.saveEdit(); event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  (root.editingRunning ? editArea : endField).forceActiveFocus(); event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  editArea.forceActiveFocus(); event.accepted = true
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.editingRunning ? "→ now" : "–"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              // Only for an entry that ends on another day than it starts.
              readonly property string endDay: root.editEntry && root.editEntry.end ? root.dayLabel(Date.parse(root.editEntry.end)) : ""
              visible: endDay !== "" && endDay !== root.dayLabel(Date.parse(root.editEntry.start))
              textFormat: Text.PlainText
              text: endDay
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: endField
              visible: !root.editingRunning
              width: Style.space(64)
              horizontalAlignment: TextInput.AlignHCenter
              placeholderText: "17:45"
              foreground: root.foreground
              font.family: root.fontFamily
              font.features: { "tnum": 1 }
              maximumLength: 5
              inputMethodHints: Qt.ImhPreferNumbers
              text: root.editEndText
              onTextEdited: root.editEndText = text
              Connections {
                target: root
                function onEditEndTextChanged() {
                  if (endField.text !== root.editEndText) endField.text = root.editEndText
                }
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.closeEditor(); event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.saveEdit(); event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  editArea.forceActiveFocus(); event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  startField.forceActiveFocus(); event.accepted = true
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.editDurationText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              font.features: { "tnum": 1 }
            }
          }

          Item {
            width: parent.width
            implicitHeight: saveButton.implicitHeight

            Button {
              id: saveButton
              anchors.left: parent.left
              iconText: "󰄬"
              text: "Save"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              opacity: root.busy ? 0.5 : 1
              onClicked: root.saveEdit()
            }
            Button {
              anchors.left: saveButton.right
              anchors.leftMargin: Style.space(6)
              text: "Cancel"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.closeEditor()
            }
            Button {
              anchors.right: deleteButton.left
              anchors.rightMargin: Style.space(6)
              visible: !root.editingRunning
              iconText: "󰐊"
              tooltipText: "Start a new timer with this description and project"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: if (root.editEntry) root.continueEntry(root.editEntry)
            }
            Button {
              id: deleteButton
              anchors.right: parent.right
              visible: !root.editingRunning
              width: visible ? implicitWidth : 0
              iconText: "󰆴"
              text: root.confirmDelete ? "Really delete?" : "Delete"
              bordered: root.confirmDelete
              foreground: root.confirmDelete ? (bar ? bar.urgent : Color.urgent) : root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              opacity: root.busy ? 0.5 : 1
              onClicked: root.deleteEdited()
            }
          }
        }
      }
    }
  }
}
