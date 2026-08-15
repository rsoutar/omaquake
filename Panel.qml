import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "oma.quake"
  ipcTarget: "oma.quake"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var rawEvents: []
  property var events: []
  property string lastError: ""
  property bool refreshing: false
  property bool initialized: false
  property int fetchRetries: 0
  property var seenIds: ({})
  property bool seenSeeded: false
  property bool initialPollDone: false
  // Timestamp of the last successful fetch; the next poll asks FDSN for
  // events updated after this moment (incremental).
  property real lastPollMs: 0

  property real autoLat: 0
  property real autoLon: 0
  property string autoName: ""
  property bool autoResolved: false
  property string autoError: ""
  property bool locating: false

  property bool settingsOpen: false
  readonly property bool settingsHasFocus: settingsOpen
    && ((settingsRangeField && settingsRangeField.activeFocus)
      || (minMagField && minMagField.activeFocus)
      || (alertMagField && alertMagField.activeFocus)
      || (refreshField && refreshField.activeFocus))
  readonly property string unitsLabel: Model.normalizeUnits(setting("units", "auto"))
  property bool editingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""
  property int selectedIndex: 0
  property real nowMs: Date.now()

  readonly property var latitudeSetting: setting("latitude", null)
  readonly property var longitudeSetting: setting("longitude", null)
  readonly property string locationNameSetting: String(setting("locationName", "") || "")
  readonly property bool hasManualOrigin: Model.hasCoordinates(latitudeSetting, longitudeSetting)
  readonly property real originLat: hasManualOrigin
    ? Model.clampNumber(latitudeSetting, -90, 90, 0) : autoLat
  readonly property real originLon: hasManualOrigin
    ? Model.clampNumber(longitudeSetting, -180, 180, 0) : autoLon
  readonly property bool hasOrigin: hasManualOrigin || autoResolved
  readonly property real rangeKm: Model.clampNumber(setting("rangeKm", 1000), 10, 20000, 1000)
  readonly property real minMagnitude: Model.clampNumber(setting("minMagnitude", 2.5), 0, 10, 2.5)
  readonly property real alertMagnitude: Model.clampNumber(setting("alertMagnitude", 6), 0, 10, 6)
  readonly property string scope: Model.normalizeScope(setting("scope", "global"))
  // Poll interval in minutes; fractional values allow sub-minute polling
  // (0.25 = 15s). USGS caches responses for 60s, so faster polls just hit
  // the cache, but a fast local scope stays near-realtime.
  readonly property real refreshMinutes: Model.clampNumber(setting("refreshMinutes", 5), 0.25, 60, 5)
  readonly property int userPollMs: Math.max(1000, Math.round(root.refreshMinutes * 60 * 1000))
  readonly property bool notifyEnabled: Model.booleanValue(setting("notify", true), true)
  readonly property bool useImperial: Model.shouldUseImperial(setting("units", "auto"), Qt.locale().name)

  readonly property var latest: Model.latestEvent(events)
  readonly property var hero: Model.heroEvent(events)
  readonly property var restEvents: Model.listEvents(events, hero)
  readonly property var displayEvents: {
    if (!hero) return events
    return [hero].concat(restEvents)
  }
  readonly property var currentAlert: Model.activeAlert(events, alertMagnitude, nowMs)
  readonly property bool alerting: currentAlert !== null
  readonly property string label: Model.barLabel(latest, false)
  readonly property string glyphLabel: Model.QUAKE_GLYPH
  readonly property string tooltipText: Model.tooltipText(latest, lastError !== "" && events.length === 0)

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.45)
  readonly property string fetchKey: [scope, hasOrigin, originLat, originLon, rangeKm, minMagnitude].join(":")
  readonly property string locationDisplay: Model.locationLabel(locationNameSetting, originLat, originLon, autoName)

  function pillText(vertical) {
    return Model.barLabel(latest, vertical === true)
  }

  function filterOptions() {
    return {
      latitude: hasOrigin ? originLat : null,
      longitude: hasOrigin ? originLon : null,
      rangeKm: rangeKm,
      minMagnitude: minMagnitude,
      scope: scope
    }
  }

  function applyFilter() {
    events = Model.filterEvents(rawEvents, filterOptions())
    if (selectedIndex >= displayEvents.length) selectedIndex = Math.max(0, displayEvents.length - 1)
  }

  // Fire the single-shot poll timer after `ms`, and cancel any pending retry.
  function scheduleNext(ms) {
    retryTimer.stop()
    refreshTimer.interval = Math.max(1000, Math.round(ms > 0 ? ms : root.userPollMs))
    refreshTimer.running = true
  }

  // Delay until the server could serve newer data: never sooner than the
  // user's chosen interval, and never sooner than the response's Expires
  // (USGS caches feed/API responses for 60s, so polling faster is wasted).
  function nextPollMs(headers) {
    var expires = Model.expiresAtMs(headers, Date.now())
    if (expires <= 0) return root.userPollMs
    return Math.max(root.userPollMs, expires - Date.now() + 600)
  }

  function ingestFeed(raw, headers) {
    var parsed = Model.parseFeed(raw)
    if (!parsed.ok) {
      scheduleRetry()
      return
    }
    lastError = ""
    fetchRetries = 0
    root.lastPollMs = Date.now()
    // Merge incremental polls into the existing list; updatedafter requests
    // only return events that changed since the last fetch, so replacing
    // rawEvents would wipe the panel between quakes.
    rawEvents = Model.mergeFeed(rawEvents, parsed.events, Date.now())
    applyFilter()
    if (!seenSeeded) {
      seenIds = Model.seedSeenIds(events)
      seenSeeded = true
    } else if (notifyEnabled) {
      var alerts = Model.alertCandidates(events, seenIds, {
        alertMagnitude: alertMagnitude,
        nowMs: Date.now(),
        requireInRange: hasOrigin
      })
      for (var i = 0; i < alerts.length; i++) sendAlertNotification(alerts[i])
      seenIds = Model.mergeSeen(seenIds, events)
    }
    nowMs = Date.now()
    root.scheduleNext(root.nextPollMs(headers))
  }

  function refresh() {
    nowMs = Date.now()
    if (!hasManualOrigin && !autoResolved && !locateProc.running) resolveLocation()
    var urls = Model.feedUrls({
      scope: scope,
      latitude: hasOrigin ? originLat : null,
      longitude: hasOrigin ? originLon : null,
      rangeKm: rangeKm,
      minMagnitude: minMagnitude,
      nowMs: Date.now(),
      updatedAfter: root.lastPollMs > 0 ? root.lastPollMs : null
    })
    if (!urls.length) return
    refreshing = true
    // -i keeps HTTP headers so we can read Expires/Cache-Control/Retry-After
    // and schedule the next poll against the server's cache. -f is dropped:
    // we need the status code (429 etc.) to back off sensibly.
    fetchProc.running = false
    fetchProc.command = ["curl", "-sS", "-i", "--max-time", "10", urls[0]]
    fetchProc.running = true
  }

  // Exponential backoff between retries, capped at a minute. After the cap,
  // drop back to the normal poll schedule rather than hammering the service.
  function scheduleRetry(backoffMs) {
    if (events.length === 0) lastError = "Could not reach USGS"
    if (fetchRetries >= 4) {
      refreshing = false
      fetchRetries = 0
      scheduleNext(root.userPollMs)
      return
    }
    fetchRetries++
    var delay = backoffMs > 0 ? backoffMs : Math.min(60000, 5000 * Math.pow(2, fetchRetries - 1))
    retryTimer.interval = delay
    retryTimer.running = true
  }

  // HTTP errors (429 rate-limit, 4xx/5xx) land here with the raw response
  // parsed for its status and Retry-After header.
  function handleHttpError(http) {
    refreshing = false
    if (!http || http.status === 0) {
      scheduleRetry()
      return
    }
    if (http.status === 429) {
      if (events.length === 0) lastError = "USGS rate limited"
      fetchRetries = 0
      var backoff = Model.retryAfterMs(http.headers, Date.now())
      scheduleNext(backoff > 0 ? backoff : 120000)
    } else {
      scheduleRetry()
    }
  }

  function resolveLocation() {
    if (locateProc.running) return
    locating = true
    locateProc.running = true
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function startEditingLocation() {
    editingLocation = true
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = hasOrigin
        ? (Number(originLat).toFixed(2) + ", " + Number(originLon).toFixed(2))
        : locationDisplay
      rangeField.text = String(Math.round(rangeKm))
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var range = Model.clampNumber(rangeField.text, 10, 20000, rangeKm)
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (!location) {
      persistSettings({ rangeKm: range })
      cancelEditingLocation()
      return
    }
    persistSettings({
      latitude: location.latitude,
      longitude: location.longitude,
      locationName: location.name || "",
      rangeKm: range
    })
    autoResolved = true
    autoLat = location.latitude
    autoLon = location.longitude
    autoName = location.name || ""
    cancelEditingLocation()
  }

  function clearLocation() {
    persistSettings({ latitude: null, longitude: null, locationName: "" })
    autoResolved = false
    autoName = ""
    autoError = ""
    cancelEditingLocation()
    resolveLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    persistSettings({
      latitude: suggestion.latitude,
      longitude: suggestion.longitude,
      locationName: suggestion.name || "",
      rangeKm: Model.clampNumber(rangeField.text, 10, 20000, rangeKm)
    })
    autoResolved = true
    autoLat = suggestion.latitude
    autoLon = suggestion.longitude
    autoName = suggestion.name || ""
    cancelEditingLocation()
  }

  function requestGeocode() {
    var query = locationField.text.replace(/^\s+|\s+$/g, "")
    if (query.length < 2 || Model.parseLatLonText(query)) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name="
        + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  function selectedEvent() {
    return displayEvents.length ? displayEvents[Math.max(0, Math.min(selectedIndex, displayEvents.length - 1))] : null
  }

  function moveCursor(dx, dy) {
    if (!displayEvents.length) return
    selectedIndex = Math.max(0, Math.min(displayEvents.length - 1, selectedIndex + dy))
  }

  function activateSelected() {
    var event = selectedEvent()
    if (event) openUrl(Model.eventPageUrl(event))
  }

  function sendAlertNotification(event) {
    var text = Model.notificationText(event, useImperial, Date.now())
    var args = ["omarchy-notification-send", "--app-name", "quake", "-u", "critical", "-g", Model.QUAKE_GLYPH]
    var url = Model.eventPageUrl(event)
    if (url) args.push("--exec", "omarchy-launch-browser " + url)
    args.push(text.headline)
    if (text.body) args.push(text.body)
    notifyProc.running = false
    notifyProc.command = args
    notifyProc.running = true
    playAlertSound()
  }

  function playAlertSound() {
    alertSoundProc.running = false
    alertSoundProc.command = ["pw-play", Model.ALERT_SOUND]
    alertSoundProc.running = true
  }

  function sendStatusNotification() {
    var text = Model.statusNotificationText(latest, events.length, useImperial, Date.now())
    var args = ["omarchy-notification-send", "--app-name", "quake", "-u", "low", "-g", Model.QUAKE_GLYPH]
    if (latest && latest.url) args.push("--exec", "omarchy-launch-browser " + latest.url)
    args.push(text.headline)
    if (text.body) args.push(text.body)
    notifyProc.running = false
    notifyProc.command = args
    notifyProc.running = true
  }

  function roleColor(role) {
    if (role === "urgent") return Color.urgent
    if (role === "accent") return Color.accent
    return Color.muted
  }

  function emptyMessage() {
    if (refreshing && events.length === 0) return "Fetching earthquakes…"
    if (lastError !== "" && events.length === 0) return lastError
    if (scope === "local" && !hasOrigin) return "Set a location to watch nearby quakes"
    if (scope === "local") return "No events in range"
    return "No recent earthquakes"
  }

  function toggleScope() {
    persistSettings({ scope: scope === "local" ? "global" : "local" })
  }

  function toggleSettings() {
    if (editingLocation) cancelEditingLocation()
    settingsOpen = !settingsOpen
    if (settingsOpen) loadSettingsFields()
  }

  function loadSettingsFields() {
    settingsRangeField.text = String(Math.round(rangeKm))
    minMagField.text = String(minMagnitude)
    alertMagField.text = String(alertMagnitude)
    refreshField.text = String(refreshMinutes)
  }
  function applySettings() {
    persistSettings({
      rangeKm: Model.clampNumber(settingsRangeField.text, 10, 20000, rangeKm),
      minMagnitude: Model.clampNumber(minMagField.text, 0, 10, minMagnitude),
      alertMagnitude: Model.clampNumber(alertMagField.text, 0, 10, alertMagnitude),
      refreshMinutes: Model.clampNumber(refreshField.text, 0.25, 60, refreshMinutes)
    })
  }

  function cycleUnits() {
    var current = Model.normalizeUnits(setting("units", "auto"))
    persistSettings({ units: current === "auto" ? "km" : (current === "km" ? "mi" : "auto") })
  }

  component KeyCap: BorderSurface {
    property alias label: keyText.text
    signal activated()

    implicitWidth: Math.max(keyText.implicitWidth + Style.space(8), implicitHeight)
    implicitHeight: keyText.implicitHeight + Style.space(4)
    color: capMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
    borderSpec: Border.flat(Qt.darker(root.contentForeground, 1.5), "1 1 2 1")
    radius: Style.space(3)

    Text {
      id: keyText
      anchors.centerIn: parent
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: capMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.activated()
    }
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.settingsOpen = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  onFetchKeyChanged: {
    applyFilter()
    if (initialized) Qt.callLater(refresh)
  }

  // Kick off the first poll once the bar has injected the real settings.
  onSettingsChanged: {
    if (initialPollDone) return
    initialPollDone = true
    Qt.callLater(function() { root.refresh() })
  }

  Component.onCompleted: initialized = true

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.refreshing = false
        var http = Model.parseHttpResponse(text)
        var body = String(http.body || "").replace(/^\s+|\s+$/g, "")
        if (http.status >= 400 || !body) {
          root.handleHttpError(http)
          return
        }
        root.ingestFeed(body, http.headers)
      }
    }
  }

  Process {
    id: locateProc
    command: ["curl", "-fsS", "--max-time", "8", "https://get.geojs.io/v1/ip/geo.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locating = false
        var parsed = Model.parseGeoJs(text)
        if (parsed.error) {
          root.autoError = parsed.error
          return
        }
        root.autoLat = parsed.latitude
        root.autoLon = parsed.longitude
        root.autoName = parsed.name || ""
        root.autoResolved = true
        root.autoError = ""
      }
    }
    onExited: function(code) {
      if (code === 0) return
      root.locating = false
      if (!root.autoResolved) root.autoError = "Could not determine location"
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Process { id: notifyProc }
  Process { id: alertSoundProc }

  // Single-shot poll timer. `refresh()` reschedules it after every fetch,
  // so the interval adapts to the user's setting and the server's Expires.
  Timer {
    id: refreshTimer
    interval: 1
    repeat: false
    onTriggered: root.refresh()
  }

  // Backoff retry ladder, scheduled by scheduleRetry().
  Timer {
    id: retryTimer
    interval: 5000
    repeat: false
    onTriggered: if (!fetchProc.running) root.refresh()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  IpcHandler {
    target: root.ipcTarget

    function refresh() { root.refresh() }
    function open() { root.openFromHotkey() }
    function close() { root.close() }
    function show() { root.openFromHotkey() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function settings() { root.toggleSettings() }
    function testalert() {
      root.sendAlertNotification({
        id: "test-alert",
        mag: 7.1,
        place: "Test Earthquake",
        timeMs: Date.now(),
        depthKm: 10,
        distanceKm: 100,
        tsunami: false,
        url: ""
      })
    }
  }

  // KeyboardPanel centers on the pill. Sit a 1px pin on the pill, shifted to
  // the bar's trailing edge, so the card clamps to the screen's right edge.
  // The pin tracks the button through a TransformWatcher: mapToItem on its own
  // is a one-shot, so a plain binding would freeze at whatever bar layout the
  // pin first saw (e.g. before the tray's icons load) and the panel would miss
  // the right edge forever.
  Item {
    id: edgeAnchor
    parent: root.anchorItem
    width: 1
    height: 1
    y: 0

    TransformWatcher {
      id: edgeAnchorWatcher
      a: root.anchorItem && root.anchorItem.QsWindow ? root.anchorItem.QsWindow.window.contentItem : null
      b: root.anchorItem
    }

    x: {
      var host = root.anchorItem
      edgeAnchorWatcher.transform
      if (!host || !host.QsWindow || !host.QsWindow.window) return 0
      var win = host.QsWindow.window
      var pos = host.mapToItem(win.contentItem, 0, 0)
      return Math.max(0, win.width - pos.x - width)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem ? edgeAnchor : null
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(quakeColumn.implicitHeight + hintBar.implicitHeight + Style.space(14), Style.space(root.settingsOpen ? 680 : 560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation || root.settingsHasFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.toggleSettings()
        else if (t === "e" || t === "E") root.startEditingLocation()
        else if (t === "g" || t === "G") root.toggleScope()
        else if (t === "u" || t === "U") root.cycleUnits()
      }

      Flickable {
        id: quakeScroll
        anchors.fill: parent
        anchors.bottomMargin: hintBar.height + Style.space(10)
        contentWidth: width
        contentHeight: quakeColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: quakeColumn
          width: quakeScroll.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            height: Math.max(heroMag.height, heroCopy.height)

            Text {
              id: heroMag
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              text: root.hero ? Model.formatMagnitude(root.hero.mag) : "—"
              color: root.hero ? root.roleColor(Model.magnitudeRole(root.hero.mag)) : root.dim
              font.family: root.contentFontFamily
              font.pixelSize: 56
              font.bold: true

              TapHandler {
                enabled: !!root.hero
                onTapped: {
                  root.selectedIndex = 0
                  root.openUrl(Model.eventPageUrl(root.hero))
                }
              }
              HoverHandler {
                enabled: !!root.hero
                cursorShape: Qt.PointingHandCursor
              }
            }

            Column {
              id: heroCopy
              anchors.left: heroMag.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                width: parent.width
                visible: !root.editingLocation
                text: root.hero ? root.hero.place : "Omaquake"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Text {
                visible: !root.editingLocation && !!root.hero
                text: root.hero ? Model.cardMeta(root.hero, root.useImperial, root.nowMs) : ""
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                visible: !root.editingLocation
                spacing: Style.space(6)

                Text {
                  text: ""
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter

                  TapHandler { onTapped: root.startEditingLocation() }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
                Text {
                  text: root.locationDisplay.toUpperCase()
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter

                  TapHandler { onTapped: root.startEditingLocation() }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
                Text {
                  text: root.scope.toUpperCase()
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter

                  TapHandler { onTapped: root.toggleScope() }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
                Text {
                  visible: root.hasOrigin
                  text: (root.scope === "local" ? "WITHIN " : "") + Model.formatDistance(root.rangeKm, root.useImperial).toUpperCase()
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Column {
                visible: root.editingLocation
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: locationField
                  width: parent.width
                  placeholderText: "City or lat, lon"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  onTextChanged: if (root.editingLocation) geocodeDebounce.restart()
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelEditingLocation()
                      event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                      if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                      event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                      if (root.suggestionIndex > 0) root.suggestionIndex--
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.commitLocation()
                      event.accepted = true
                    }
                  }
                }

                Row {
                  spacing: Style.space(8)

                  TextField {
                    id: rangeField
                    width: Style.space(110)
                    placeholderText: "Range km"
                    foreground: root.contentForeground
                    font.family: root.contentFontFamily
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.cancelEditingLocation()
                        event.accepted = true
                      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.commitLocation()
                        event.accepted = true
                      }
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "km"
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Rectangle {
                    width: Style.space(22)
                    height: Style.space(22)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Math.min(4, Style.cornerRadius)
                    color: clearLocationArea.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: "✕"
                      color: root.dim
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                      id: clearLocationArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.clearLocation()
                    }

                    PanelToolTip {
                      visible: clearLocationArea.containsMouse
                      text: "Use IP location"
                      fontFamily: root.contentFontFamily
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.editingLocation && root.locationSuggestions.length > 0
            width: parent.width
            spacing: 0

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: suggestionRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"

                Row {
                  id: suggestionRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: modelData.name
                    color: index === root.suggestionIndex ? Style.hoverStateColor(root.contentForeground, Color.accent) : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    visible: text !== ""
                    text: modelData.description
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }
          }

          Column {
            id: settingsColumn
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(10)
            leftPadding: Style.space(16)
            rightPadding: Style.space(16)

            Rectangle {
              width: parent.width - settingsColumn.leftPadding - settingsColumn.rightPadding
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Grid {
              columns: 2
              columnSpacing: Style.space(12)
              rowSpacing: Style.space(8)
              width: parent.width - settingsColumn.leftPadding - settingsColumn.rightPadding

              Column {
                width: parent.width / 2 - Style.space(6)
                spacing: Style.space(4)
                Text {
                  text: "RANGE KM"
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                TextField {
                  id: settingsRangeField
                  width: parent.width
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhFormattedNumbersOnly
                  onEditingFinished: root.applySettings()
                }
              }
              Column {
                width: parent.width / 2 - Style.space(6)
                spacing: Style.space(4)
                Text {
                  text: "MIN MAG"
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                TextField {
                  id: minMagField
                  width: parent.width
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhFormattedNumbersOnly
                  onEditingFinished: root.applySettings()
                }
              }
              Column {
                width: parent.width / 2 - Style.space(6)
                spacing: Style.space(4)
                Text {
                  text: "ALERT MAG"
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                TextField {
                  id: alertMagField
                  width: parent.width
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhFormattedNumbersOnly
                  onEditingFinished: root.applySettings()
                }
              }
              Column {
                width: parent.width / 2 - Style.space(6)
                spacing: Style.space(4)
                Text {
                  text: "POLL MIN"
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                TextField {
                  id: refreshField
                  width: parent.width
                  placeholderText: "0.25 = 15s"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhFormattedNumbersOnly
                  onEditingFinished: root.applySettings()
                }
              }
            }

            Row {
              spacing: Style.space(16)
              width: parent.width - settingsColumn.leftPadding - settingsColumn.rightPadding

              Row {
                spacing: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: "Notify"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
                ToggleSwitch {
                  checked: root.notifyEnabled
                  foreground: root.contentForeground
                  accent: Color.accent
                  onToggled: root.persistSettings({ notify: !root.notifyEnabled })
                }
              }

              Row {
                spacing: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: "Units"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
                Repeater {
                  model: ["auto", "km", "mi"]

                  Text {
                    required property string modelData
                    text: modelData.toUpperCase()
                    color: root.unitsLabel === modelData ? root.contentForeground : root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: root.unitsLabel === modelData
                    font.letterSpacing: 1
                    anchors.verticalCenter: parent.verticalCenter

                    TapHandler { onTapped: root.persistSettings({ units: modelData }) }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                  }
                }
              }
            }
          }

          Rectangle {
            visible: root.restEvents.length > 0
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          Repeater {
            model: root.restEvents

            Rectangle {
              required property var modelData
              required property int index
              readonly property bool selected: root.hero
                ? root.selectedIndex === index + 1
                : root.selectedIndex === index
              width: parent.width
              height: cardRow.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: selected ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"

              Row {
                id: cardRow
                anchors.left: parent.left
                anchors.right: mapButton.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)

                Rectangle {
                  width: Style.space(44)
                  height: Style.space(28)
                  radius: Style.cornerRadius
                  color: Util.alpha(root.roleColor(Model.magnitudeRole(modelData.mag)), 0.18)

                  Text {
                    anchors.centerIn: parent
                    text: Model.formatMagnitude(modelData.mag)
                    color: root.roleColor(Model.magnitudeRole(modelData.mag))
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                Column {
                  width: parent.width - Style.space(56)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData.place
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: Model.cardMeta(modelData, root.useImperial, root.nowMs)
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
              }

              PanelActionButton {
                id: mapButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰍎"
                tooltipText: "Open map"
                foreground: root.dim
                fontFamily: root.contentFontFamily
                onClicked: root.openUrl(Model.mapsUrl(modelData.lat, modelData.lon))
              }

              MouseArea {
                anchors.fill: parent
                anchors.rightMargin: mapButton.width + Style.space(8)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.selectedIndex = root.hero ? index + 1 : index
                  root.openUrl(Model.eventPageUrl(modelData))
                }
                onEntered: root.selectedIndex = root.hero ? index + 1 : index
              }
            }
          }

          Text {
            visible: root.events.length === 0
            text: root.emptyMessage()
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            leftPadding: Style.space(16)
          }

        }
      }

      Row {
        id: hintBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        spacing: Style.space(10)

        Row {
          spacing: Style.space(6)
          KeyCap { label: "R"; onActivated: root.refresh() }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.refreshing ? "syncing" : "refresh"
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "·"
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)
          KeyCap { label: "S"; onActivated: root.toggleSettings() }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "settings"
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "·"
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)
          KeyCap { label: "G"; onActivated: root.toggleScope() }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.scope
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
