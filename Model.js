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
function controls(state) {
  var s = state || {}
  var vs = s.vehicle_state || {}
  var cs = s.climate_state || {}
  var ch = s.charge_state || {}
  return [
    { id: "lock", icon: vs.locked === false ? "" : "",
      label: vs.locked === false ? "Unlocked" : "Locked",
      command: vs.locked === true ? "unlock" : "lock",
      active: vs.locked === true, confirm: vs.locked === true },
    { id: "climate", icon: "", label: "Climate",
      command: cs.is_climate_on ? "stop_climate" : "start_climate",
      active: cs.is_climate_on === true, confirm: false },
    { id: "sentry", icon: "", label: "Sentry",
      command: vs.sentry_mode ? "disable_sentry" : "enable_sentry",
      active: vs.sentry_mode === true, confirm: false },
    { id: "port", icon: "", label: "Port",
      command: ch.charge_port_door_open ? "close_charge_port" : "open_charge_port",
      active: ch.charge_port_door_open === true, confirm: false },
    { id: "flash", icon: "", label: "Flash", command: "flash", active: false, confirm: false },
    { id: "honk", icon: "", label: "Honk", command: "honk", active: false, confirm: false }
  ]
}

// The state a command should leave behind, so a button flips the moment the
// car accepts it instead of waiting for Tessie's cache to catch up. Returns a
// copy; commands with no lasting state (flash, honk) change nothing.
var COMMAND_EFFECTS = {
  lock: ["vehicle_state", "locked", true],
  unlock: ["vehicle_state", "locked", false],
  start_climate: ["climate_state", "is_climate_on", true],
  stop_climate: ["climate_state", "is_climate_on", false],
  enable_sentry: ["vehicle_state", "sentry_mode", true],
  disable_sentry: ["vehicle_state", "sentry_mode", false],
  open_charge_port: ["charge_state", "charge_port_door_open", true],
  close_charge_port: ["charge_state", "charge_port_door_open", false]
}

function afterCommand(state, command) {
  var next = JSON.parse(JSON.stringify(state || {}))
  var effect = COMMAND_EFFECTS[command]
  if (effect) {
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

if (typeof module !== "undefined") {
  module.exports = {
    number: number, useImperial: useImperial, groupThousands: groupThousands,
    formatDistance: formatDistance, formatSpeed: formatSpeed, formatTemp: formatTemp,
    formatPercent: formatPercent, formatEnergy: formatEnergy, formatDuration: formatDuration,
    yesNo: yesNo, onOff: onOff, tyres: tyres, activity: activity, relativeTime: relativeTime,
    placeName: placeName, subtitle: subtitle, controls: controls, afterCommand: afterCommand,
    dataUpdated: dataUpdated, carName: carName, tessieStatus: tessieStatus,
    tileGrid: tileGrid, tileUrl: tileUrl, mapMaxZoom: mapMaxZoom,
    mapAttribution: mapAttribution, mapsUrl: mapsUrl
  }
}
