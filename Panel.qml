import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Tessie popup: where the car is, how full it is, and its controls. All
// API traffic goes through bin/tessie; this file runs it and renders the JSON
// it prints. Reads never wake the car (Tessie serves them from its cache), so
// polling costs the car nothing; only the control buttons wake it.
Panel {
  id: root
  moduleName: "io.github.kimm-stensborg.tessie"
  // BarWidget.qml owns the IPC target: only the copy on the focused screen
  // answers it, and there is one of these panels per monitor.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var shell: hostWidget && hostWidget.shell ? hostWidget.shell : null
  property string pluginDir: ""
  // The bar identifies panels by the widget in its slot (BarWidget.qml).
  readonly property var barIdentity: hostWidget || root

  readonly property string cli: pluginDir + "/bin/tessie"
  readonly property string vin: Model.readSetting(settings, "vin")
  // The demo setting swaps the car for bin/tessie's made-up one.
  readonly property bool demo: Model.readSetting(settings, "demo")
  readonly property var cliEnvironment: {
    var env = {}
    if (vin !== "") env.TESSIE_VIN = vin
    if (demo) env.TESSIE_DEMO = "1"
    return env
  }
  onDemoChanged: Qt.callLater(refresh)

  // Last good `tessie state`, kept through failures so stale data stays up.
  property var snapshot: null
  property var failure: null
  property bool loading: false
  property string pendingCommand: ""
  property string armedCommand: ""
  property string commandError: ""
  property int tokenPolls: 0
  property real now: Date.now() / 1000
  readonly property string cartoKey: Model.readSetting(settings, "cartoKey")
  readonly property int maxZoom: Model.mapMaxZoom(cartoKey)
  // The map's own zoom, which the wheel moves for the session; the setting is
  // where it starts, so scrolling around does not rewrite shell.json.
  property int zoom: Math.max(3, Math.min(maxZoom, Model.readSetting(settings, "mapZoom")))
  onSettingsChanged: zoom = Math.max(3, Math.min(maxZoom, Model.readSetting(settings, "mapZoom")))

  // ---- What the settings say. The page itself is SettingsOverlay.qml,
  //      summoned by the gear, because a bar popup has no room for it.
  readonly property bool showMap: Model.readSetting(settings, "showMap")
  readonly property bool showFooter: Model.readSetting(settings, "showFooter")
  readonly property bool showPrices: Model.readSetting(settings, "showPrices")
  readonly property string priceArea: Model.readSetting(settings, "priceArea")
  readonly property string priceGrid: Model.readSetting(settings, "priceGrid")
  readonly property var priceParts: Model.readSetting(settings, "priceParts")
  readonly property bool confirmUnlock: Model.readSetting(settings, "confirmUnlock")
  readonly property string barLabelMode: Model.readSetting(settings, "barLabel")
  readonly property string barLabelText: Model.barLabel(snapshot, imperial, barLabelMode)

  // status.tessie.com, checked when the panel opens, at most every 2 minutes.
  property var tessie: Model.tessieStatus(null)
  property real tessieCheckedAt: 0

  // Day-ahead prices (+ optional tariffs) under the battery. Fetched even when
  // the chart is off, so the summary line still has a number.
  property var priceChart: ({ day: "", area: "", grid: "", bars: [], min: null, max: null, window: null })
  property real pricesCheckedAt: 0
  property int selectedPriceHour: -1
  readonly property var priceBars: priceChart && priceChart.bars ? priceChart.bars : []
  readonly property string resolvedPriceArea: {
    var lat = position ? position.lat : null
    var lon = position ? position.lon : null
    return Model.resolvePriceArea(priceArea, lat, lon)
  }
  readonly property string priceTitle: {
    var bits = []
    if (priceChart.grid) bits.push(priceChart.grid)
    else bits.push("Spot")
    if (priceChart.area || resolvedPriceArea) bits.push(priceChart.area || resolvedPriceArea)
    return bits.join(" ")
  }
  readonly property int priceHour: {
    // Re-evaluate when `now` ticks so the accent bar moves with the clock.
    var _ = now
    return new Date().getHours()
  }
  readonly property string priceSummaryLine: Model.priceSummary(priceChart, priceHour)
  readonly property var selectedPriceBar: {
    if (selectedPriceHour < 0) return null
    for (var i = 0; i < priceBars.length; i++)
      if (priceBars[i].hour === selectedPriceHour) return priceBars[i]
    return null
  }
  readonly property var selectedPriceDetail: selectedPriceBar && selectedPriceBar.detail
    ? selectedPriceBar.detail : null
  readonly property var chargeCostLine: {
    var detail = selectedPriceDetail
    if (!detail || detail.total === null) return ""
    var est = Model.chargeEstimate(snapshot, detail.total)
    return est ? est.label : ""
  }
  onPriceAreaChanged: { pricesCheckedAt = 0; Qt.callLater(refreshPrices) }
  onPriceGridChanged: { pricesCheckedAt = 0; Qt.callLater(refreshPrices) }
  onPricePartsChanged: { pricesCheckedAt = 0; Qt.callLater(refreshPrices) }
  onResolvedPriceAreaChanged: { pricesCheckedAt = 0; Qt.callLater(refreshPrices) }

  readonly property var car: snapshot ? snapshot.state : null
  readonly property string carName: Model.carName(car, Model.readSetting(settings, "name"))
  readonly property real updatedAt: car ? (Model.dataUpdated(car) || 0) : 0
  readonly property var charge: car && car.charge_state ? car.charge_state : ({})
  readonly property bool imperial: Model.useImperial(Model.readSetting(settings, "units"),
    car && car.gui_settings ? car.gui_settings.gui_distance_units : "")
  readonly property string activity: Model.activity(snapshot)
  readonly property int refreshMinutes: Model.readSetting(settings, "refreshMinutes")

  readonly property var position: {
    var loc = snapshot && snapshot.location ? snapshot.location : {}
    var drive = car && car.drive_state ? car.drive_state : {}
    var lat = Model.number(loc.latitude) !== null ? Model.number(loc.latitude) : Model.number(drive.latitude)
    var lon = Model.number(loc.longitude) !== null ? Model.number(loc.longitude) : Model.number(drive.longitude)
    return lat !== null && lon !== null ? { lat: lat, lon: lon } : null
  }
  readonly property real heading: car && car.drive_state ? (Model.number(car.drive_state.heading) || 0) : 0

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property bool darkMap: {
    var c = Color.popups.background
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.5
  }
  readonly property color okColor: "#7cc47f"
  readonly property color warnColor: "#e0b050"
  readonly property color statusColor: failure && !snapshot ? Color.urgent
    : activity === "driving" || activity === "parked" ? okColor
    : activity === "charging" ? Color.accent
    : muted
  readonly property color tessieColor: failure && failure.code === "network" ? Color.urgent
    : tessie.state === "operational" ? okColor
    : tessie.state === "degraded" || tessie.state === "maintenance" ? warnColor
    : tessie.state === "downtime" ? Color.urgent
    : muted
  readonly property string tessieLine: {
    var line = "Tessie " + (failure && failure.code === "network" ? "unreachable" : tessie.label)
    if (tessie.affected.length > 0) line += " (" + tessie.affected.join(", ") + ")"
    if (updatedAt > 0) line += " · updated " + Model.relativeTime(updatedAt, now)
    return line
  }

  readonly property string summary: {
    if (!snapshot && failure)
      return failure.code === "notoken" ? "Tessie: set up your token" : "Tessie: " + failure.error
    if (!car) return "Tessie"
    return carName + " · " + Model.formatPercent(charge.battery_level) + " · " + activity
  }

  readonly property var stats: Model.enabledOnly(Model.stats(snapshot, imperial),
    Model.readSetting(settings, "stats"))
  readonly property var controls: Model.enabledOnly(Model.controls(car, confirmUnlock),
    Model.readSetting(settings, "controls"))

  function open() {
    now = Date.now() / 1000
    root.controller.show()
    refreshStatus()
    refreshPrices()
    // Reopening within half a minute shows what is already there.
    if (!snapshot || now - snapshot.fetchedAt > 30) refresh()
  }

  function refreshStatus() {
    if (!statusProc.running && Date.now() / 1000 - tessieCheckedAt > 120) statusProc.running = true
  }

  // Prices change once a day; refetch at most every 15 minutes, or when a
  // price setting / zone changes. A failed fetch leaves the last good chart up.
  function refreshPrices() {
    if (!pluginDir || pricesProc.running) return
    if (priceBars.length > 0 && Date.now() / 1000 - pricesCheckedAt < 900) return
    var day = Model.calendarDay()
    var plan = Model.priceFetchPlan(resolvedPriceArea, priceGrid, priceParts, day)
    if (!plan.spot) return
    pricesProc.environment = Object.assign({}, root.cliEnvironment, {
      TESSIE_PRICE_PLAN: JSON.stringify(plan)
    })
    pricesProc.command = [root.cli, "prices"]
    pricesProc.running = true
  }

  function selectPriceHour(hour) {
    selectedPriceHour = selectedPriceHour === hour ? -1 : hour
  }

  function takePrices(text) {
    var chart = Model.consumerPrices(text, {
      day: Model.calendarDay(),
      grid: priceGrid,
      parts: priceParts,
      now: Date.now()
    })
    if (chart.bars.length > 0) {
      priceChart = chart
      pricesCheckedAt = Date.now() / 1000
    }
  }

  function close() {
    armedCommand = ""
    selectedPriceHour = -1
    root.controller.hide()
  }

  // The settings are a full overlay, so the popup gets out of the way first.
  // The shell routes a summon of this plugin's id to its overlay entry point.
  function openSettings() {
    root.close()
    var api = root.shell || (bar ? bar.shell : null)
    if (api && typeof api.summon === "function") api.summon(root.moduleName, "{}")
  }

  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function refresh() {
    if (opened) refreshStatus()
    if (!pluginDir || stateProc.running) return
    loading = true
    stateProc.running = true
  }

  function takeState(text) {
    loading = false
    now = Date.now() / 1000
    var parsed = null
    try { parsed = JSON.parse(String(text || "").trim()) } catch (e) {}
    if (parsed && parsed.ok) {
      snapshot = parsed
      failure = null
      tokenPolls = 0
    } else {
      failure = parsed && parsed.error ? parsed : { code: "error", error: "bin/tessie gave no answer" }
    }
  }

  function runControl(control) {
    if (pendingCommand || !car) return
    if (control.confirm && armedCommand !== control.command) {
      armedCommand = control.command
      disarmTimer.restart()
      return
    }
    armedCommand = ""
    commandError = ""
    pendingCommand = control.command
    commandProc.command = [cli, "command", control.command]
    commandProc.running = true
  }

  function takeCommand(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "").trim()) } catch (e) {}
    if (parsed && parsed.ok) {
      snapshot = Object.assign({}, snapshot, { state: Model.afterCommand(snapshot.state, pendingCommand) })
      followUpTimer.restart()
    } else {
      commandError = parsed && parsed.error ? parsed.error : "The command gave no answer"
    }
    pendingCommand = ""
  }

  function openMaps() {
    if (!position) return
    Qt.openUrlExternally(Model.mapsUrl(position.lat, position.lon, Model.readSetting(settings, "mapsUrl")))
    close()
  }

  // `tessie login` is interactive (it reads the token without echo), so it
  // runs in a terminal; the panel then polls until the token works.
  function setupToken() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "'" + cli + "' login"])
    tokenPolls = 60
    close()
  }

  Process {
    id: stateProc
    command: [root.cli, "state"]
    environment: root.cliEnvironment
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeState(text)
    }
  }

  Process {
    id: commandProc
    environment: root.cliEnvironment
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeCommand(text)
    }
  }

  // An unreachable page reads as "status unknown", not as an outage.
  Process {
    id: statusProc
    command: ["curl", "-fsS", "--max-time", "8", "https://status.tessie.com/index.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.tessie = Model.tessieStatus(text)
        root.tessieCheckedAt = Date.now() / 1000
      }
    }
  }

  Process {
    id: pricesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takePrices(text)
    }
  }

  // Poll every refreshMinutes while closed and every 30 s while open.
  Timer {
    interval: root.opened ? 30000 : root.refreshMinutes * 60000
    running: root.pluginDir !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps "fetched 3 min ago" honest while the panel is up.
  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now() / 1000
  }

  // Tessie's cache trails a command by a few seconds.
  Timer {
    id: followUpTimer
    interval: 4000
    onTriggered: root.refresh()
  }

  Timer {
    id: disarmTimer
    interval: 3000
    onTriggered: root.armedCommand = ""
  }

  Timer {
    interval: 5000
    running: root.tokenPolls > 0
    repeat: true
    onTriggered: {
      root.tokenPolls--
      root.refresh()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "m") root.openMaps()
        else if (t === "s") root.openSettings()
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroller.width
          spacing: Style.space(12)

          // ---- Title, status dot, and the gear that flips the page over.
          Item {
            width: parent.width
            height: Math.max(title.implicitHeight, trailing.implicitHeight)

            Text {
              id: title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - trailing.width - Style.space(12)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: (root.car ? root.carName : "Tessie").toUpperCase()
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Row {
              id: trailing
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Row {
                id: statusRow
                rightPadding: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                visible: statusText.text !== ""

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: root.statusColor
                }

                Text {
                  id: statusText
                  textFormat: Text.PlainText
                  text: root.activity !== "unknown" ? root.activity : root.loading ? "fetching" : ""
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              // Refresh and settings: the two things that act on the panel
              // rather than on the car, kept out of the grid of things that do.
              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.loading ? "\uf1ce" : "\uf021"
                iconSpinning: root.loading
                tooltipText: "Refresh"
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                foreground: root.muted
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf013"
                tooltipText: "Settings"
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                foreground: root.muted
                fontFamily: root.fontFamily
                onClicked: root.openSettings()
              }
            }
          }

          // ---- Setup, first load, or an error before any data arrived.
          Column {
            visible: !root.car
            width: parent.width
            spacing: Style.space(12)

            Text {
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: !root.failure ? "Finding your car…"
                : root.failure.code === "notoken"
                  ? "Connect your Tessie account to see and control your car. You'll need an API token from dash.tessie.com/settings/api."
                  : root.failure.error
              color: root.failure && root.failure.code !== "notoken" ? Color.urgent : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              visible: !!root.failure
              bordered: true
              text: root.failure && root.failure.code === "notoken" ? "Set up Tessie token" : "Try again"
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.failure.code === "notoken" ? root.setupToken() : root.refresh()
            }
          }

          // ---- Map: CARTO tiles around the car, marker in the middle.
          Rectangle {
            id: map
            visible: !!root.car && root.showMap
            width: parent.width
            height: Style.space(240)
            color: root.darkMap ? "#1d1f21" : "#e9e7e2"
            radius: Style.cornerRadius
            clip: true

            readonly property var tiles: root.position
              ? Model.tileGrid(root.position.lat, root.position.lon, Math.min(root.zoom, root.maxZoom), width, height, 256) : []

            Repeater {
              model: map.tiles

              Image {
                required property var modelData
                x: modelData.left
                y: modelData.top
                width: 256
                height: 256
                source: Model.tileUrl(modelData, root.darkMap, root.cartoKey)
                asynchronous: true
                cache: true
                smooth: true
              }
            }

            Text {
              anchors.centerIn: parent
              visible: !root.position
              textFormat: Text.PlainText
              text: "No location yet"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Item {
              visible: !!root.position
              anchors.centerIn: parent
              width: Style.space(34)
              height: width

              Rectangle {
                id: halo
                anchors.centerIn: parent
                width: Style.space(26)
                height: width
                radius: width / 2
                color: Util.alpha(Color.accent, 0.28)

                SequentialAnimation on scale {
                  running: root.activity === "driving" && root.opened
                  loops: Animation.Infinite
                  NumberAnimation { from: 1; to: 1.35; duration: 900; easing.type: Easing.OutQuad }
                  NumberAnimation { from: 1.35; to: 1; duration: 900; easing.type: Easing.InQuad }
                }
              }

              // Heading: a small wedge on the ring, pointing where the car faces.
              Canvas {
                anchors.fill: parent
                rotation: root.heading
                visible: root.activity === "driving"
                property color ink: Color.accent
                onInkChanged: requestPaint()
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  ctx.fillStyle = ink
                  ctx.beginPath()
                  ctx.moveTo(width / 2, 0)
                  ctx.lineTo(width / 2 + width * 0.14, height * 0.2)
                  ctx.lineTo(width / 2 - width * 0.14, height * 0.2)
                  ctx.closePath()
                  ctx.fill()
                }
              }

              Rectangle {
                anchors.centerIn: parent
                width: Style.space(14)
                height: width
                radius: width / 2
                color: Color.accent
                border.width: Math.max(2, Style.space(2))
                border.color: "#ffffff"
              }
            }

            // Required by the Esri and CARTO tile terms.
            Rectangle {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              width: attribution.implicitWidth + Style.space(8)
              height: attribution.implicitHeight + Style.space(2)
              color: Util.alpha(map.color, 0.7)

              Text {
                id: attribution
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: Model.mapAttribution(root.cartoKey)
                color: root.darkMap ? "#9a9a9a" : "#555555"
                font.family: root.fontFamily
                font.pixelSize: Math.max(8, Style.font.caption - 1)
              }
            }

            MouseArea {
              anchors.fill: parent
              enabled: !!root.position
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openMaps()
              onWheel: function(wheel) {
                var step = wheel.angleDelta.y > 0 ? 1 : wheel.angleDelta.y < 0 ? -1 : 0
                root.zoom = Math.max(3, Math.min(root.maxZoom, root.zoom + step))
              }
            }
          }

          // ---- Where, and what it's doing.
          Column {
            visible: !!root.car
            width: parent.width
            spacing: Style.space(4)

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: Model.placeName(root.snapshot ? root.snapshot.location : null)
                || (root.position ? root.position.lat.toFixed(4) + ", " + root.position.lon.toFixed(4) : "")
                || (root.car ? root.car.display_name || "" : "")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: Model.subtitle(root.snapshot, root.imperial)
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !!root.failure && !!root.snapshot
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.failure ? "Couldn't refresh: " + root.failure.error : ""
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator { visible: !!root.car; foreground: root.fg }

          // ---- Battery, with a tick at the charge limit.
          Column {
            visible: !!root.car
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Style.space(6)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: Util.alpha(root.fg, 0.12)
              }

              Rectangle {
                width: parent.width * Math.max(0, Math.min(100, Model.number(root.charge.battery_level) || 0)) / 100
                height: parent.height
                radius: height / 2
                color: root.activity === "charging" ? Color.accent : Util.alpha(root.fg, 0.75)
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
              }

              Rectangle {
                visible: Model.number(root.charge.charge_limit_soc) !== null
                x: parent.width * (Model.number(root.charge.charge_limit_soc) || 0) / 100 - width / 2
                y: -Style.space(2)
                width: Math.max(1, Style.space(2))
                height: parent.height + Style.space(4)
                color: root.muted
              }
            }

            Item {
              width: parent.width
              height: batteryText.implicitHeight

              Text {
                id: batteryText
                textFormat: Text.PlainText
                text: Model.formatPercent(root.charge.battery_level) + (root.activity === "charging" ? "  " : "")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: Model.formatDistance(root.charge.battery_range, root.imperial)
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // ---- Price summary (always, when we have data) + optional chart.
            Column {
              visible: root.priceBars.length > 0
              width: parent.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                height: Math.max(priceCaption.implicitHeight, priceSummaryText.implicitHeight)

                Text {
                  id: priceCaption
                  anchors.left: parent.left
                  anchors.right: priceSummaryText.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.showPrices ? root.priceTitle : "Prices"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: priceSummaryText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.priceSummaryLine
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                id: priceChartBox
                visible: root.showPrices
                width: parent.width
                height: visible ? Style.space(52) : 0

                Row {
                  anchors.fill: parent
                  spacing: 1

                  Repeater {
                    model: root.priceBars

                    Item {
                      required property var modelData
                      width: (priceChartBox.width - 23) / 24
                      height: priceChartBox.height

                      Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.max(2, parent.width - 1)
                        height: Math.max(
                          modelData.price === null ? 0 : 2,
                          parent.height * Model.priceBarFraction(
                            modelData.price, root.priceChart.min, root.priceChart.max))
                        radius: 1
                        color: modelData.hour === root.selectedPriceHour ? root.fg
                          : modelData.hour === root.priceHour ? Color.accent
                          : modelData.cheapest ? root.okColor
                          : modelData.inWindow ? Util.alpha(root.okColor, 0.7)
                          : modelData.dearest ? root.warnColor
                          : Util.alpha(root.fg, 0.45)
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectPriceHour(modelData.hour)
                      }
                    }
                  }
                }
              }

              Item {
                visible: root.showPrices
                width: parent.width
                height: visible ? Style.font.caption + Style.space(2) : 0

                Repeater {
                  model: [
                    { hour: 0, text: "00" },
                    { hour: 6, text: "06" },
                    { hour: 12, text: "12" },
                    { hour: 18, text: "18" },
                    { hour: 23, text: "23" }
                  ]

                  Text {
                    required property var modelData
                    x: modelData.hour * (priceChartBox.width - 23) / 24
                    width: (priceChartBox.width - 23) / 24
                    horizontalAlignment: modelData.hour === 0 ? Text.AlignLeft
                      : modelData.hour === 23 ? Text.AlignRight
                      : Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: modelData.text
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // Click a bar to pin its breakdown here (no hover tooltip).
              Rectangle {
                visible: root.showPrices && !!root.selectedPriceDetail
                width: parent.width
                height: visible ? priceDetailColumn.implicitHeight + Style.space(12) : 0
                radius: Style.space(6)
                color: Util.alpha(root.fg, 0.08)

                Column {
                  id: priceDetailColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(3)

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.selectedPriceDetail ? root.selectedPriceDetail.title : ""
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: root.selectedPriceDetail
                      ? root.selectedPriceDetail.lines.join(" · ") : ""
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    visible: root.chargeCostLine !== ""
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: root.chargeCostLine
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.selectedPriceHour = -1
                }
              }
            }
          }

          PanelSeparator { visible: statsGrid.visible; foreground: root.fg }

          // ---- Vitals, two to a row.
          Grid {
            id: statsGrid
            visible: !!root.car && root.stats.length > 0
            width: parent.width
            columns: 2
            columnSpacing: Style.space(12)
            rowSpacing: Style.space(10)

            Repeater {
              model: root.stats

              Column {
                required property var modelData
                width: (statsGrid.width - statsGrid.columnSpacing) / 2
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: modelData.value
                  color: modelData.warn ? Color.urgent : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }

          PanelSeparator { visible: controlsGrid.visible; foreground: root.fg }

          // ---- Controls. Toggles show selected while on; unlocking asks twice.
          Grid {
            id: controlsGrid
            visible: !!root.car && root.controls.length > 0
            width: parent.width
            columns: 3
            spacing: Style.space(8)

            Repeater {
              model: root.controls

              Button {
                required property var modelData
                readonly property bool pending: root.pendingCommand === modelData.command
                readonly property bool armed: root.armedCommand === modelData.command
                width: (controlsGrid.width - controlsGrid.spacing * 2) / 3
                bordered: true
                selected: modelData.active
                enabled: root.pendingCommand === "" || pending
                opacity: enabled ? 1 : 0.5
                iconText: pending ? "\uf1ce" : modelData.icon
                iconSpinning: pending
                text: armed ? "Sure?" : modelData.label
                foreground: armed ? Color.urgent : root.fg
                fontFamily: root.fontFamily
                onClicked: root.runControl(modelData)
              }
            }
          }

          Text {
            visible: root.commandError !== ""
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: root.commandError
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { visible: root.showFooter; foreground: root.fg }

          // ---- Tessie footer: service status, data age, and links out.
          Item {
            visible: root.showFooter
            width: parent.width
            height: Math.max(tessieText.implicitHeight, linksRow.implicitHeight)

            Rectangle {
              id: tessieDot
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(6)
              height: width
              radius: width / 2
              color: root.tessieColor
            }

            Text {
              id: tessieText
              anchors.left: tessieDot.right
              anchors.leftMargin: Style.space(6)
              anchors.right: linksRow.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.tessieLine
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              id: linksRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Repeater {
                model: [
                  { label: "tessie.com", url: "https://tessie.com" },
                  { label: "status", url: "https://status.tessie.com" }
                ]

                Text {
                  required property var modelData
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: linkArea.containsMouse ? root.fg : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.underline: linkArea.containsMouse

                  MouseArea {
                    id: linkArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      Qt.openUrlExternally(modelData.url)
                      root.close()
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
