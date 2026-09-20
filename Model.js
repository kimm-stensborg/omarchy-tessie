// Pure helpers for the Tessie panel: units, formatting, and map tile math.
// Nothing here touches QML, so test.sh can run it under node.
//
// A snapshot is what `bin/tessie state` prints: {ok, vin, fetchedAt, state,
// location, tires, lastCharge, status}. `state` is Tessie's vehicle state,
// which reports distances in miles, speeds in mph and temperatures in °C
// whatever the car's display units are.

var KM_PER_MILE = 1.609344
var PSI_PER_BAR = 14.5038

function number(value) {
  if (value === null || value === undefined || value === "") return null
  var n = parseFloat(value)
  return isFinite(n) ? n : null
}

// "metric"/"imperial" force the units; anything else follows the car.
function useImperial(unitSetting, guiDistanceUnits) {
  var unit = String(unitSetting || "").toLowerCase()
  if (unit === "imperial") return true
  if (unit === "metric") return false
  return /^mi/.test(String(guiDistanceUnits || ""))
}

function groupThousands(n) {
  var digits = String(Math.round(Math.abs(n))).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return (n < 0 ? "-" : "") + digits
}

function formatDistance(miles, imperial) {
  var m = number(miles)
  if (m === null) return "—"
  return groupThousands(imperial ? m : m * KM_PER_MILE) + (imperial ? " mi" : " km")
}

function formatSpeed(mph, imperial) {
  var v = number(mph)
  if (v === null) return ""
  return Math.round(imperial ? v : v * KM_PER_MILE) + (imperial ? " mph" : " km/h")
}

function formatTemp(celsius, imperial) {
  var c = number(celsius)
  if (c === null) return "—"
  return Math.round(imperial ? c * 9 / 5 + 32 : c) + (imperial ? " °F" : " °C")
}

function formatPercent(value) {
  var n = number(value)
  return n === null ? "—" : Math.round(n) + "%"
}

function formatEnergy(kwh) {
  var n = number(kwh)
  return n === null ? "—" : n.toFixed(1) + " kWh"
}

function formatDuration(minutes) {
  var m = Math.round(number(minutes) || 0)
  var h = Math.floor(m / 60)
  if (h === 0) return m + " min"
  return m % 60 === 0 ? h + " h" : h + " h " + (m % 60) + " min"
}

function yesNo(value) {
  return value === true ? "yes" : value === false ? "no" : "—"
}

function onOff(value) {
  return value === true ? "on" : value === false ? "off" : "—"
}

// Tyre pressures as a "min–max" range. Tessie's tire_pressure endpoint is
// preferred (it carries low-pressure flags); vehicle_state's TPMS fields are
// the fallback. Both are in bar.
function tyres(tires, vehicleState, imperial) {
  var raw = tires
    ? [tires.front_left, tires.front_right, tires.rear_left, tires.rear_right]
    : vehicleState
      ? [vehicleState.tpms_pressure_fl, vehicleState.tpms_pressure_fr,
         vehicleState.tpms_pressure_rl, vehicleState.tpms_pressure_rr]
      : []
  var values = []
  for (var i = 0; i < raw.length; i++) {
    var v = number(raw[i])
    if (v !== null && v > 0) values.push(imperial ? v * PSI_PER_BAR : v)
  }
  var low = !!tires && ["front_left", "front_right", "rear_left", "rear_right"].some(function(k) {
    return tires[k + "_status"] === "low"
  })
  if (values.length === 0) return { text: "—", low: low }

  var digits = imperial ? 0 : 1
  var lo = Math.min.apply(null, values).toFixed(digits)
  var hi = Math.max.apply(null, values).toFixed(digits)
  return { text: (lo === hi ? lo : lo + "–" + hi) + (imperial ? " psi" : " bar"), low: low }
}

// What the car is doing, for the status dot. Sleep wins over everything:
// a sleeping car's cached state can still say it was driving.
function activity(snapshot) {
  var s = snapshot && snapshot.state
  if (!s) return "unknown"
  if (snapshot.status === "asleep" || s.state === "asleep") return "asleep"
  if (s.state === "offline") return "offline"
  var drive = s.drive_state || {}
  var shift = drive.shift_state
  if (shift === "D" || shift === "R" || shift === "N" || (number(drive.speed) || 0) > 0) return "driving"
  if ((s.charge_state || {}).charging_state === "Charging") return "charging"
  return "parked"
}

// Seconds (or Tesla's milliseconds) → "just now", "4 min ago", "2 h ago"…
function relativeTime(then, nowSeconds) {
  var t = number(then)
  if (t === null) return ""
  if (t > 1e12) t = t / 1000
  var d = Math.max(0, Math.round(nowSeconds - t))
  if (d < 45) return "just now"
  if (d < 90) return "a minute ago"
  if (d < 3600) return Math.round(d / 60) + " min ago"
  if (d < 86400) return Math.round(d / 3600) + " h ago"
  if (d < 172800) return "yesterday"
  return Math.floor(d / 86400) + " days ago"
}

// "Oudegracht 158, 3511 AZ Utrecht, Netherlands" → "Oudegracht 158, Utrecht".
// A saved location ("Home", "Work") wins over the street address.
function placeName(location) {
  if (!location) return ""
  if (location.saved_location) return String(location.saved_location)
  var parts = String(location.address || "").split(",")
    .map(function(p) { return p.replace(/^\s+|\s+$/g, "") })
    .filter(function(p) { return p !== "" })
  if (parts.length === 0) return ""
  if (parts.length > 2) parts.pop()
  if (parts.length === 1) return parts[0]
  var city = parts[1]
    .replace(/^\d{4}\s?[A-Z]{2}\s+/, "")                  // Dutch 3511 AZ
    .replace(/^[A-Z]{0,2}-?\d{3,5}\s+/, "")                // 1620, D-10115
    .replace(/\s+[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}$/, "")  // UK SW1A 2AA
    .replace(/\s+\d{4,5}(-\d{4})?$/, "")                   // US 94538
  return parts[0] + (city ? ", " + city : "")
}

// When Tessie last heard from the car, in seconds: the newest timestamp any
// part of the state carries. A sleeping car's data stops when it fell asleep.
function dataUpdated(state) {
  var s = state || {}
  var stamps = [(s.drive_state || {}).gps_as_of]
  ;["drive_state", "charge_state", "climate_state", "vehicle_state"].forEach(function(part) {
    stamps.push((s[part] || {}).timestamp)
  })
  var newest = null
  for (var i = 0; i < stamps.length; i++) {
    var t = number(stamps[i])
    if (t === null) continue
    if (t > 1e12) t = t / 1000
    if (newest === null || t > newest) newest = t
  }
  return newest
}

// The line under the place name: "Driving 80 km/h", "Charging 11 kW, full in
// 1 h 30 min". How old the data is lives in the Tessie footer.
function subtitle(snapshot, imperial) {
  if (!snapshot || !snapshot.state) return ""
  var s = snapshot.state
  var drive = s.drive_state || {}
  var charge = s.charge_state || {}
  var what = activity(snapshot)
  var head
  if (what === "driving") {
    var speed = formatSpeed(drive.speed, imperial)
    head = "Driving" + (speed ? " " + speed : "")
  } else if (what === "charging") {
    head = "Charging"
    if (number(charge.charger_power)) head += " " + Math.round(number(charge.charger_power)) + " kW"
    if (number(charge.minutes_to_full_charge) > 0) head += ", full in " + formatDuration(charge.minutes_to_full_charge)
  } else if (what === "asleep") {
    head = "Asleep"
  } else if (what === "offline") {
    head = "Offline"
  } else {
    head = "Parked"
  }
  return head
}

// The car's own name, else its model. Tesla reports the name set in the car
// as display_name (and vehicle_name); unnamed cars have neither.
var MODEL_NAMES = {
  models: "Model S", lychee: "Model S", modelx: "Model X", tamarind: "Model X",
  model3: "Model 3", modely: "Model Y", cybertruck: "Cybertruck"
}

function carName(state, override) {
  var s = state || {}
  var name = String(override || s.display_name || (s.vehicle_state || {}).vehicle_name || "").trim()
  if (name) return name
  return MODEL_NAMES[String((s.vehicle_config || {}).car_type || "").toLowerCase()] || "Tesla"
}

// status.tessie.com (a Better Stack page) → {state, label, affected}. state is
// operational, degraded, downtime, maintenance, or unknown when the page
// could not be read; affected names the services that are not operational.
function tessieStatus(raw) {
  var page = null
  try { page = typeof raw === "string" ? JSON.parse(raw) : raw } catch (e) {}
  var attributes = page && page.data && page.data.attributes ? page.data.attributes : null
  var state = attributes ? String(attributes.aggregate_state || "") : ""
  if (!state) return { state: "unknown", label: "status unknown", affected: [] }
  var affected = (page.included || []).filter(function(r) {
    return r && r.type === "status_page_resource" && r.attributes
      && r.attributes.status && r.attributes.status !== "operational"
  }).map(function(r) { return String(r.attributes.public_name || "") })
    .filter(function(name) { return name !== "" })
  // Short words: the footer shares its line with the links.
  var labels = { operational: "ok", degraded: "degraded", downtime: "down", maintenance: "maintenance" }
  return { state: state, label: labels[state] || state, affected: affected }
}

// The panel's toggles and one-shot buttons, derived from the current state.
// Toggles render selected while on; `confirm` asks for a second click.
// Unlocking asks twice unless the "Ask before unlocking" setting is off.
//
// Every one of these is an option on the settings page, and only the six in
// CONTROL_DEFAULTS are shown until you say otherwise — the grid is three to a
// row, and all of them at once is four rows of buttons under the vitals.
function controls(state, confirmUnlock) {
  var ask = confirmUnlock !== false
  var s = state || {}
  var vs = s.vehicle_state || {}
  var cs = s.climate_state || {}
  var ch = s.charge_state || {}
  var charging = ch.charging_state === "Charging"
  var windowsOpen = ["fd_window", "fp_window", "rd_window", "rp_window"].some(function(k) {
    return (number(vs[k]) || 0) > 0
  })
  var defrosting = (number(cs.defrost_mode) || 0) > 0
  return [
    { id: "lock", icon: vs.locked === false ? "\uf09c" : "\uf023",
      label: vs.locked === false ? "Unlocked" : "Locked",
      command: vs.locked === true ? "unlock" : "lock",
      active: vs.locked === true, confirm: ask && vs.locked === true },
    { id: "climate", icon: "\uf2dc", label: "Climate",
      command: cs.is_climate_on ? "stop_climate" : "start_climate",
      active: cs.is_climate_on === true, confirm: false },
    { id: "sentry", icon: "\uf06e", label: "Sentry",
      command: vs.sentry_mode ? "disable_sentry" : "enable_sentry",
      active: vs.sentry_mode === true, confirm: false },
    { id: "port", icon: "\uf1e6", label: "Port",
      command: ch.charge_port_door_open ? "close_charge_port" : "open_charge_port",
      active: ch.charge_port_door_open === true, confirm: false },
    { id: "flash", icon: "\uf0eb", label: "Flash", command: "flash", active: false, confirm: false },
    { id: "honk", icon: "\uf0a1", label: "Honk", command: "honk", active: false, confirm: false },
    // Stopping a charge is the one of these you might not mean, so it asks.
    { id: "charge", icon: "\uf0e7", label: charging ? "Charging" : "Charge",
      command: charging ? "stop_charging" : "start_charging",
      active: charging, confirm: charging },
    { id: "frunk", icon: "\uf1b9", label: "Frunk",
      command: "activate_front_trunk",
      active: (number(vs.ft) || 0) > 0, confirm: false },
    { id: "trunk", icon: "\uf187", label: "Trunk",
      command: "activate_rear_trunk",
      active: (number(vs.rt) || 0) > 0, confirm: false },
    { id: "windows", icon: "\uf2d0", label: windowsOpen ? "Close up" : "Vent",
      command: windowsOpen ? "close_windows" : "vent_windows",
      active: windowsOpen, confirm: false },
    { id: "defrost", icon: "\uf185", label: "Defrost",
      command: defrosting ? "stop_max_defrost" : "start_max_defrost",
      active: defrosting, confirm: false },
    // Reading never wakes the car, so this is the only way to ask it to come
    // up without giving it something else to do.
    { id: "wake", icon: "\uf011", label: "Wake", command: "wake", active: false, confirm: false }
  ]
}

// The vitals grid: one row per fact, each with the id the "Vitals" setting
// names it by. Lives here rather than in the panel so the ids and the values
// cannot drift apart.
function stats(snapshot, imperial) {
  var s = snapshot && snapshot.state
  if (!s) return []
  var vs = s.vehicle_state || {}
  var cs = s.climate_state || {}
  var ch = s.charge_state || {}
  var pressures = tyres(snapshot.tires, vs, imperial)
  var last = snapshot.lastCharge
  return [
    { id: "locked", label: "locked", value: yesNo(vs.locked) },
    { id: "sentry", label: "sentry", value: onOff(vs.sentry_mode) },
    { id: "odometer", label: "odometer", value: formatDistance(vs.odometer, imperial) },
    { id: "tyres", label: "tyres", value: pressures.text, warn: pressures.low },
    { id: "inside", label: "inside", value: formatTemp(cs.inside_temp, imperial) },
    { id: "outside", label: "outside", value: formatTemp(cs.outside_temp, imperial) },
    { id: "chargeLimit", label: "charge limit", value: formatPercent(ch.charge_limit_soc) },
    { id: "lastCharge", label: "last charge", value: last ? formatEnergy(last.energy_added) : "\u2014" },
    { id: "climate", label: "climate", value: onOff(cs.is_climate_on) },
    { id: "software", label: "software", value: vs.car_version ? String(vs.car_version).split(" ")[0] : "\u2014" }
  ]
}

// What rides next to the T in the bar, for the "Next to the T" setting.
function barLabel(snapshot, imperial, mode) {
  var ch = snapshot && snapshot.state && snapshot.state.charge_state
    ? snapshot.state.charge_state : null
  if (!ch) return ""
  if (mode === "battery") return number(ch.battery_level) === null ? "" : formatPercent(ch.battery_level)
  if (mode === "range") return number(ch.battery_range) === null ? "" : formatDistance(ch.battery_range, imperial)
  return ""
}

// The state a command should leave behind, so a button flips the moment the
// car accepts it instead of waiting for Tessie's cache to catch up. Returns a
// copy; commands with no lasting state (flash, honk) change nothing.
var WINDOWS = ["fd_window", "fp_window", "rd_window", "rp_window"]

var COMMAND_EFFECTS = {
  lock: [["vehicle_state", "locked", true]],
  unlock: [["vehicle_state", "locked", false]],
  start_climate: [["climate_state", "is_climate_on", true]],
  stop_climate: [["climate_state", "is_climate_on", false]],
  enable_sentry: [["vehicle_state", "sentry_mode", true]],
  disable_sentry: [["vehicle_state", "sentry_mode", false]],
  open_charge_port: [["charge_state", "charge_port_door_open", true]],
  close_charge_port: [["charge_state", "charge_port_door_open", false]],
  start_charging: [["charge_state", "charging_state", "Charging"]],
  stop_charging: [["charge_state", "charging_state", "Stopped"]],
  start_max_defrost: [["climate_state", "defrost_mode", 2]],
  stop_max_defrost: [["climate_state", "defrost_mode", 0]],
  vent_windows: WINDOWS.map(function(w) { return ["vehicle_state", w, 1] }),
  close_windows: WINDOWS.map(function(w) { return ["vehicle_state", w, 0] })
  // The trunks and wake leave nothing this panel can predict: whether a lid
  // went up or down is the car's answer, which the follow-up refresh brings.
}

function afterCommand(state, command) {
  var next = JSON.parse(JSON.stringify(state || {}))
  var effects = COMMAND_EFFECTS[command] || []
  for (var i = 0; i < effects.length; i++) {
    var effect = effects[i]
    next[effect[0]] = next[effect[0]] || {}
    next[effect[0]][effect[1]] = effect[2]
  }
  return next
}

// Web-mercator tiles covering a width×height viewport centred on lat/lon.
// Each tile carries its x/y/z and where its top-left lands in the viewport.
function tileGrid(lat, lon, zoom, width, height, tileSize) {
  var size = tileSize || 256
  var n = Math.pow(2, zoom)
  var clamped = Math.max(-85.0511, Math.min(85.0511, lat))
  var latRad = clamped * Math.PI / 180
  var px = (lon + 180) / 360 * n * size
  var py = (1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2 * n * size
  var left = px - width / 2
  var top = py - height / 2
  var tiles = []
  for (var ty = Math.floor(top / size); ty <= Math.floor((top + height - 1) / size); ty++) {
    if (ty < 0 || ty >= n) continue
    for (var tx = Math.floor(left / size); tx <= Math.floor((left + width - 1) / size); tx++) {
      tiles.push({ x: ((tx % n) + n) % n, y: ty, z: zoom,
                   left: Math.round(tx * size - left), top: Math.round(ty * size - top) })
    }
  }
  return tiles
}

// Map tiles. Without a key they come from Esri's gray Canvas basemap, which
// needs no signup but stops at zoom 16. CARTO's basemaps need a free key
// (carto.com/basemaps/apikey) and are served at 2× and up to zoom 19; without
// one CARTO answers with "API KEY REQUIRED" tiles.
function tileUrl(tile, dark, cartoKey) {
  if (cartoKey) {
    return "https://" + "abcd".charAt((tile.x + tile.y) % 4) + ".basemaps.cartocdn.com/"
      + (dark ? "dark_all" : "light_all") + "/" + tile.z + "/" + tile.x + "/" + tile.y
      + "@2x.png?key=" + encodeURIComponent(cartoKey)
  }
  return "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/"
    + (dark ? "World_Dark_Gray_Base" : "World_Light_Gray_Base")
    + "/MapServer/tile/" + tile.z + "/" + tile.y + "/" + tile.x
}

function mapMaxZoom(cartoKey) {
  return cartoKey ? 19 : 16
}

// Both sources require their credit on the map.
function mapAttribution(cartoKey) {
  return cartoKey ? "© OpenStreetMap contributors © CARTO"
    : "© Esri, HERE, Garmin, OpenStreetMap contributors"
}

// `template` may use {lat} and {lon}; the default opens Google Maps.
function mapsUrl(lat, lon, template) {
  var t = String(template || "https://www.google.com/maps/search/?api=1&query={lat},{lon}")
  return t.replace(/\{lat\}/g, String(lat)).replace(/\{lon\}/g, String(lon))
}

// ---------------------------------------------------------------- settings
//
// Everything the settings page shows, in the order it shows it. One list
// drives the page, the defaults and the shell.json writes, so a new option is
// a row here and nothing else. `fallback` is what the widget does when the
// key is absent, and a value that equals it is never written out — an option
// left alone stays out of shell.json, and a later default change reaches
// anyone who never touched it.
//
// kinds: text, choice (one of `options`), number (clamped to min/max),
// toggle (on/off), multi (any of `options`; unset means all of them).

var CONTROL_OPTIONS = [
  { value: "lock", label: "Lock" }, { value: "climate", label: "Climate" },
  { value: "sentry", label: "Sentry" }, { value: "port", label: "Charge port" },
  { value: "flash", label: "Flash" }, { value: "honk", label: "Honk" },
  { value: "charge", label: "Charge" }, { value: "frunk", label: "Frunk" },
  { value: "trunk", label: "Trunk" }, { value: "windows", label: "Windows" },
  { value: "defrost", label: "Defrost" }, { value: "wake", label: "Wake" }
]

// The six the panel shows until you pick your own. All twelve would be four
// rows of buttons, so the rest are there to swap in rather than to pile on.
var CONTROL_DEFAULTS = ["lock", "climate", "sentry", "port", "flash", "honk"]

var STAT_OPTIONS = [
  { value: "locked", label: "Locked" }, { value: "sentry", label: "Sentry" },
  { value: "odometer", label: "Odometer" }, { value: "tyres", label: "Tyres" },
  { value: "inside", label: "Inside" }, { value: "outside", label: "Outside" },
  { value: "chargeLimit", label: "Charge limit" }, { value: "lastCharge", label: "Last charge" },
  { value: "climate", label: "Climate" }, { value: "software", label: "Software" }
]

var SETTINGS = [
  { title: "Car", rows: [
    { key: "name", kind: "text", label: "Name", fallback: "",
      placeholder: "From the car", hint: "Empty uses the name set in the car, else its model" },
    { key: "vin", kind: "text", label: "VIN", fallback: "",
      placeholder: "First car on the account", hint: "Which car to show" },
    { key: "units", kind: "choice", label: "Units", fallback: "",
      options: [{ value: "", label: "Follow the car" }, { value: "metric", label: "Metric" },
                { value: "imperial", label: "Imperial" }] }
  ]},
  { title: "In the bar", rows: [
    { key: "barLabel", kind: "choice", label: "Next to the T", fallback: "none",
      options: [{ value: "none", label: "Nothing" }, { value: "battery", label: "Battery" },
                { value: "range", label: "Range" }] }
  ]},
  { title: "In the panel", rows: [
    { key: "showMap", kind: "toggle", label: "Map", fallback: true },
    { key: "mapZoom", kind: "number", label: "Map zoom", fallback: 16, min: 3, max: 19,
      hint: "Past 16 needs a CARTO key" },
    { key: "stats", kind: "multi", label: "Vitals",
      fallback: STAT_OPTIONS.map(function(o) { return o.value }), options: STAT_OPTIONS },
    { key: "controls", kind: "multi", label: "Controls",
      hint: "Six fit under the vitals; the rest are there to swap in",
      fallback: CONTROL_DEFAULTS, options: CONTROL_OPTIONS },
    { key: "confirmUnlock", kind: "toggle", label: "Ask before unlocking", fallback: true },
    { key: "showFooter", kind: "toggle", label: "Tessie status footer", fallback: true }
  ]},
  { title: "Data", rows: [
    { key: "refreshMinutes", kind: "number", label: "Refresh while closed (minutes)",
      fallback: 5, min: 1, max: 60 },
    { key: "demo", kind: "toggle", label: "Demo car", fallback: false,
      hint: "A made-up car; never calls Tessie" }
  ]},
  { title: "Map and links", rows: [
    { key: "cartoKey", kind: "text", label: "CARTO key", fallback: "", secret: true,
      placeholder: "Esri basemap", hint: "Free at carto.com/basemaps/apikey: sharper tiles, zoom to 19" },
    { key: "mapsUrl", kind: "text", label: "Maps link", fallback: "",
      placeholder: "Google Maps", hint: "{lat} and {lon} are filled in" }
  ]}
]

function settingRow(key) {
  for (var s = 0; s < SETTINGS.length; s++) {
    var rows = SETTINGS[s].rows
    for (var r = 0; r < rows.length; r++) if (rows[r].key === key) return rows[r]
  }
  return null
}

// A multi-value setting. Stored as an array, but it may arrive as a string:
// `omarchy bar set` splits its own arguments on commas, so a list typed at a
// terminal has to be space-separated, and a hand-edited shell.json is as
// likely to use commas. Both read the same here.
function choiceList(value) {
  var list = Array.isArray(value)
    ? value
    : String(value === null || value === undefined ? "" : value).split(/[,\s]+/)
  return list.map(function(v) { return String(v).replace(/^\s+|\s+$/g, "") })
             .filter(function(v) { return v !== "" })
}

// A stored value as the widget should use it: absent, out of range or simply
// wrong reads as the default rather than breaking the panel.
function coerceSetting(row, raw) {
  if (!row) return raw
  var missing = raw === undefined || raw === null
  if (row.kind === "toggle") {
    if (missing || raw === "") return row.fallback === true
    // shell.json may hold a real boolean from this page, or the word a
    // hand-edit or `omarchy bar set` left there.
    return raw === true || ["true", "on", "yes", "1"].indexOf(String(raw).toLowerCase()) !== -1
  }
  if (row.kind === "number") {
    var n = parseInt(raw, 10)
    if (!isFinite(n)) n = row.fallback
    return Math.max(row.min, Math.min(row.max, n))
  }
  if (row.kind === "multi") {
    var allowed = row.options.map(function(o) { return o.value })
    // Unset means the default selection, which is a named list rather than
    // every option: a control added later does not barge into the panel.
    if (missing || raw === "") return row.fallback.slice()
    return choiceList(raw).filter(function(v) { return allowed.indexOf(v) !== -1 })
  }
  if (row.kind === "choice") {
    var picked = String(missing ? row.fallback : raw)
    return row.options.some(function(o) { return o.value === picked }) ? picked : row.fallback
  }
  return String(missing ? "" : raw)
}

function readSetting(settings, key) {
  return coerceSetting(settingRow(key), settings ? settings[key] : undefined)
}

// Is this what the widget would do anyway? A multi that holds every option
// counts, so "all of them" keeps meaning all of them as options are added.
function isDefaultSetting(row, value) {
  if (!row) return false
  if (row.kind === "multi") {
    if (value === null || value === undefined) return true
    var chosen = choiceList(value)
    return chosen.length === row.fallback.length
      && row.fallback.every(function(v) { return chosen.indexOf(v) !== -1 })
  }
  if (row.kind === "text") return String(value === null || value === undefined ? "" : value)
    .replace(/^\s+|\s+$/g, "") === ""
  return value === row.fallback
}

// The whole shell.json entry a change leaves behind. updateEntryInline
// replaces the entry rather than merging into it, so every other key has to
// be carried across; a value back at its default is dropped instead of
// written. `changes` of null clears every option this page owns.
function nextEntry(settings, id, changes) {
  var entry = { id: String(id || "") }
  for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
  if (changes === null) {
    for (var s = 0; s < SETTINGS.length; s++)
      SETTINGS[s].rows.forEach(function(row) { delete entry[row.key] })
    return entry
  }
  for (var key in changes) {
    var row = settingRow(key)
    var value = changes[key]
    if (row && isDefaultSetting(row, value)) delete entry[key]
    else if (row && row.kind === "text") entry[key] = String(value).replace(/^\s+|\s+$/g, "")
    else entry[key] = value
  }
  return entry
}

// Does any option differ from the default? Drives the "Reset" button.
function hasCustomSettings(settings) {
  for (var s = 0; s < SETTINGS.length; s++) {
    var rows = SETTINGS[s].rows
    for (var r = 0; r < rows.length; r++) {
      var raw = settings ? settings[rows[r].key] : undefined
      if (raw !== undefined && raw !== null && !isDefaultSetting(rows[r], coerceSetting(rows[r], raw)))
        return true
    }
  }
  return false
}

// Flipping one box in a multi. An unset setting means the default selection,
// so the first box ticked has to start from that; the result keeps the spec's
// order so the panel does not reshuffle as boxes are ticked.
function toggleChoice(row, value, option) {
  var all = row.options.map(function(o) { return o.value })
  var current = value === null || value === undefined ? row.fallback.slice() : choiceList(value)
  if (current.indexOf(option) !== -1)
    return current.filter(function(v) { return v !== option })
  return all.filter(function(v) { return v === option || current.indexOf(v) !== -1 })
}

// How tall a row renders, near enough to balance columns by. A text field or
// a wrapping row of chips takes noticeably more than a switch.
var ROW_WEIGHT = { text: 3, multi: 3, choice: 2, number: 2, toggle: 2 }

function sectionWeight(section) {
  return section.rows.reduce(function(sum, row) {
    return sum + (ROW_WEIGHT[row.kind] || 2)
  }, 1)
}

// The sections dealt into `count` columns, in order, so that the tallest
// column comes out as short as it can. The overlay exists to put every option
// on screen at once, and that only works if the columns are level.
function settingsColumns(count) {
  var wanted = Math.max(1, Math.min(Math.round(count) || 1, SETTINGS.length))
  var weights = SETTINGS.map(sectionWeight)
  var best = null

  function tallestOf(cuts) {
    var tallest = 0
    var from = 0
    for (var i = 0; i < cuts.length; i++) {
      var sum = 0
      for (var j = from; j < cuts[i]; j++) sum += weights[j]
      if (sum > tallest) tallest = sum
      from = cuts[i]
    }
    return tallest
  }

  // Only contiguous splits, so the sections stay in the order they are read.
  function walk(start, left, cuts) {
    if (left === 1) {
      var all = cuts.concat([SETTINGS.length])
      var tallest = tallestOf(all)
      if (best === null || tallest < best.tallest) best = { tallest: tallest, cuts: all }
      return
    }
    for (var cut = start + 1; cut <= SETTINGS.length - (left - 1); cut++)
      walk(cut, left - 1, cuts.concat([cut]))
  }
  walk(0, wanted, [])

  var columns = []
  var from = 0
  for (var i = 0; i < best.cuts.length; i++) {
    columns.push(SETTINGS.slice(from, best.cuts[i]))
    from = best.cuts[i]
  }
  return columns
}

// This widget's entry in the bar config the shell hands a plugin, which is
// where the overlay reads the settings it is about to change. A widget that
// is not in the layout has no entry yet; it behaves as an empty one, and the
// first write puts it wherever the shell keeps it.
function entryFor(barConfig, id) {
  var layout = barConfig && barConfig.layout ? barConfig.layout : {}
  var wanted = String(id || "")
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var arr = layout[sections[s]] || []
    for (var i = 0; i < arr.length; i++) {
      // Clones carry a "#2" suffix; the id in front of it is the plugin's.
      if (arr[i] && String(arr[i].id || "").split("#")[0] === wanted) return arr[i]
    }
  }
  return { id: wanted }
}

// What a multi keeps from `list`, in the list's own order. An empty selection
// keeps nothing; null is only reached before a setting has been read.
function enabledOnly(list, chosen) {
  if (chosen === null || chosen === undefined) return list
  var keep = choiceList(chosen)
  return (list || []).filter(function(item) { return keep.indexOf(item.id) !== -1 })
}

// One line under the page title: what is not at its default, or that nothing
// is. Short enough to share the header.
function settingsSummary(settings) {
  return hasCustomSettings(settings) ? "Changed from the defaults" : "All at their defaults"
}

if (typeof module !== "undefined") {
  module.exports = {
    number: number, useImperial: useImperial, groupThousands: groupThousands,
    formatDistance: formatDistance, formatSpeed: formatSpeed, formatTemp: formatTemp,
    formatPercent: formatPercent, formatEnergy: formatEnergy, formatDuration: formatDuration,
    yesNo: yesNo, onOff: onOff, tyres: tyres, activity: activity, relativeTime: relativeTime,
    placeName: placeName, subtitle: subtitle, controls: controls, afterCommand: afterCommand,
    dataUpdated: dataUpdated, carName: carName, tessieStatus: tessieStatus,
    tileGrid: tileGrid, tileUrl: tileUrl, mapMaxZoom: mapMaxZoom,
    mapAttribution: mapAttribution, mapsUrl: mapsUrl,
    stats: stats, barLabel: barLabel, SETTINGS: SETTINGS, settingRow: settingRow,
    choiceList: choiceList, coerceSetting: coerceSetting, readSetting: readSetting,
    isDefaultSetting: isDefaultSetting, nextEntry: nextEntry,
    hasCustomSettings: hasCustomSettings, enabledOnly: enabledOnly,
    toggleChoice: toggleChoice, sectionWeight: sectionWeight,
    CONTROL_DEFAULTS: CONTROL_DEFAULTS,
    settingsColumns: settingsColumns, entryFor: entryFor,
    settingsSummary: settingsSummary
  }
}
