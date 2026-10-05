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

// ---------------------------------------------------------------- spot prices
//
// Day-ahead spot from Energi Data Service, optionally topped with Datahub
// tariffs (netselskab + Energinet + elafgift) and VAT. Spot is DKK/MWh;
// Datahub tariffs are already DKK/kWh. The chart always plots kr/kWh.

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// Local calendar day for `now` (ms or Date), as YYYY-MM-DD.
function calendarDay(now) {
  var d = now instanceof Date ? now : new Date(now === undefined || now === null ? Date.now() : now)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function nextCalendarDay(day) {
  var parts = String(day || "").split("-").map(function(p) { return parseInt(p, 10) })
  if (parts.length !== 3 || parts.some(function(p) { return !isFinite(p) })) return ""
  var d = new Date(parts[0], parts[1] - 1, parts[2] + 1)
  return calendarDay(d)
}

function formatKrKwh(kr) {
  var n = number(kr)
  if (n === null) return "\u2014"
  var fixed = Math.abs(n).toFixed(2)
  return (n < 0 ? "-" : "") + fixed + " kr/kWh"
}

// Spot as kr/kWh. The API reports DKK/MWh; /1000 is the household unit.
function formatSpotPrice(dkkPerMwh) {
  var n = number(dkkPerMwh)
  return n === null ? "\u2014" : formatKrKwh(n / 1000)
}

function hourRangeLabel(hour) {
  var h = Math.max(0, Math.min(23, Math.round(number(hour) || 0)))
  var next = (h + 1) % 24
  return pad2(h) + ":00\u2013" + pad2(next) + ":00"
}

// Grid companies (netselskaber). `codes` are ChargeTypeCode values for the
// household C-tariff in DatahubPricelist. `none` means spot only.
var ENERGINET_GLN = "5790000432752"

var GRID_COMPANIES = {
  none: null,
  trefor: { gln: "5790000392261", codes: ["C"], label: "TREFOR" },
  "trefor-ost": { gln: "5790000706686", codes: ["46"], label: "TREFOR \u00d8st" },
  radius: { gln: "5790000705689", codes: ["DT_C_01"], label: "Radius" },
  cerius: { gln: "5790000705184", codes: ["30TR_C_ET"], label: "Cerius" },
  n1: { gln: "5790001089030", codes: ["CD"], label: "N1" },
  konstant: { gln: "5790000704842", codes: ["C_FBTNTR_B"], label: "Konstant" },
  dinel: { gln: "5790000610099", codes: ["TCL>100_02"], label: "Dinel" },
  "nord-energi": { gln: "5790000610877", codes: ["TAC"], label: "Nord Energi" },
  flow: { gln: "5790000392551", codes: ["FE1 NT-01"], label: "FLOW" },
  "vores-elnet": { gln: "5790000610976", codes: ["TNT1009"], label: "Vores Elnet" },
  rah: { gln: "5790000681327", codes: ["RAH-C"], label: "RAH" },
  "elnet-midt": { gln: "5790001100520", codes: ["T3001"], label: "Elnet Midt" },
  zeanet: { gln: "5790001089375", codes: ["43110"], label: "Zeanet" },
  "l-net": { gln: "5790001090111", codes: ["3000"], label: "L-Net" }
}

var GRID_OPTIONS = [
  { value: "none", label: "Spot only", description: "No net tariff" },
  { value: "trefor", label: "TREFOR El-net", description: "Triangle area / EWII" },
  { value: "trefor-ost", label: "TREFOR El-net \u00d8st", description: "East of TREFOR" },
  { value: "radius", label: "Radius", description: "Copenhagen area" },
  { value: "cerius", label: "Cerius", description: "Zealand" },
  { value: "n1", label: "N1", description: "Central Jutland" },
  { value: "konstant", label: "Konstant", description: "East Jutland" },
  { value: "dinel", label: "Dinel", description: "South Jutland" },
  { value: "nord-energi", label: "Nord Energi Net", description: "North Jutland" },
  { value: "flow", label: "FLOW Elnet", description: "South Funen" },
  { value: "vores-elnet", label: "Vores Elnet", description: "North Funen" },
  { value: "rah", label: "RAH Net", description: "Ringk\u00f8bing area" },
  { value: "elnet-midt", label: "Elnet Midt", description: "Mid Jutland" },
  { value: "zeanet", label: "Zeanet", description: "Lolland-Falster" },
  { value: "l-net", label: "L-Net", description: "Lemvig area" }
]

var PRICE_PART_OPTIONS = [
  { value: "energinet", label: "Energinet" },
  { value: "elafgift", label: "Elafgift" },
  { value: "vat", label: "VAT" }
]

var PRICE_PART_DEFAULTS = ["energinet", "elafgift", "vat"]

// DK1 is west of the Great Belt (Jutland + Funen), DK2 is east (Zealand+).
// Returns null when the point is not in Denmark.
function denmarkPriceArea(lat, lon) {
  var la = number(lat), lo = number(lon)
  if (la === null || lo === null) return null
  if (la < 54.5 || la > 58.0 || lo < 7.5 || lo > 15.6) return null
  return lo < 11.0 ? "DK1" : "DK2"
}

// `setting` is auto / DK1 / DK2. Auto follows the car when it is in Denmark.
function resolvePriceArea(setting, lat, lon) {
  if (setting === "DK1" || setting === "DK2") return setting
  return denmarkPriceArea(lat, lon) || "DK2"
}

function pricesUrl(area, day) {
  var zone = area === "DK1" ? "DK1" : "DK2"
  var start = String(day || calendarDay()) + "T00:00"
  var endDay = nextCalendarDay(String(day || calendarDay()))
  if (!endDay) return ""
  var end = endDay + "T00:00"
  return "https://api.energidataservice.dk/dataset/DayAheadPrices"
    + "?start=" + encodeURIComponent(start)
    + "&end=" + encodeURIComponent(end)
    + "&filter=" + encodeURIComponent(JSON.stringify({ PriceArea: [zone] }))
    + "&sort=TimeDK&limit=200"
}

function datahubPricelistUrl(filter) {
  var columns = ["GLN_Number", "ChargeOwner", "ChargeType", "ChargeTypeCode", "Note",
    "ValidFrom", "ValidTo"]
  for (var i = 1; i <= 24; i++) columns.push("Price" + i)
  return "https://api.energidataservice.dk/dataset/DatahubPricelist"
    + "?limit=50&sort=" + encodeURIComponent("ValidFrom DESC")
    + "&columns=" + encodeURIComponent(columns.join(","))
    + "&filter=" + encodeURIComponent(JSON.stringify(filter))
}

// What bin/tessie prices should download for the current settings.
function priceFetchPlan(area, grid, parts, day) {
  var wanted = String(day || calendarDay())
  var chosen = choiceList(parts === undefined || parts === null ? PRICE_PART_DEFAULTS : parts)
  var plan = {
    day: wanted,
    spot: pricesUrl(area, wanted),
    net: null,
    system: null,
    transmission: null,
    elafgift: null
  }
  var company = GRID_COMPANIES[grid] || null
  if (company) {
    plan.net = datahubPricelistUrl({
      GLN_Number: [company.gln],
      ChargeType: ["D03"],
      ChargeTypeCode: company.codes.slice()
    })
  }
  if (chosen.indexOf("energinet") !== -1) {
    plan.system = datahubPricelistUrl({
      GLN_Number: [ENERGINET_GLN], ChargeTypeCode: ["41000"]
    })
    plan.transmission = datahubPricelistUrl({
      GLN_Number: [ENERGINET_GLN], ChargeTypeCode: ["40000"]
    })
  }
  if (chosen.indexOf("elafgift") !== -1) {
    plan.elafgift = datahubPricelistUrl({
      GLN_Number: [ENERGINET_GLN], ChargeTypeCode: ["EA-001"]
    })
  }
  return plan
}

function parsePriceRecords(raw) {
  if (!raw) return []
  if (Array.isArray(raw)) return raw
  var data = raw
  if (typeof raw === "string") {
    try { data = JSON.parse(raw) } catch (e) { return [] }
  }
  return data && Array.isArray(data.records) ? data.records : []
}

// The Datahub row valid on `day` (ValidFrom inclusive, ValidTo exclusive).
function pickTariffRecord(raw, day) {
  var wanted = String(day || "")
  var records = parsePriceRecords(raw)
  var best = null
  for (var i = 0; i < records.length; i++) {
    var rec = records[i]
    var from = String(rec.ValidFrom || "").slice(0, 10)
    var to = String(rec.ValidTo || "9999-12-31").slice(0, 10)
    if (!from || (wanted && (from > wanted || wanted >= to))) continue
    if (!best || from > String(best.ValidFrom || "").slice(0, 10)) best = rec
  }
  return best
}

// Price1–24 in DKK/kWh. A flat tariff only fills Price1.
function tariffHours(record) {
  if (!record) return null
  var flat = number(record.Price1)
  var hours = []
  var any = false
  for (var i = 1; i <= 24; i++) {
    var p = number(record["Price" + i])
    if (p === null) p = flat
    if (p !== null) any = true
    hours.push(p)
  }
  return any ? hours : null
}

function resolveCurrentHour(options) {
  options = options || {}
  var currentHour = number(options.currentHour)
  if (currentHour === null) {
    var when = options.now instanceof Date ? options.now
      : new Date(options.now === undefined || options.now === null ? Date.now() : options.now)
    currentHour = when.getHours()
  }
  return Math.max(0, Math.min(23, Math.round(currentHour)))
}

// One bar per hour for `day` (YYYY-MM-DD, Danish local TimeDK). `bar.price` is
// still DKK/MWh here; consumerPrices converts to kr/kWh and adds tariffs.
function dayPrices(raw, day, options) {
  var wanted = String(day || "")
  var currentHour = resolveCurrentHour(options)

  var buckets = []
  for (var i = 0; i < 24; i++) buckets.push([])
  var area = ""
  var records = parsePriceRecords(raw)
  for (var r = 0; r < records.length; r++) {
    var rec = records[r]
    var t = String(rec.TimeDK || "")
    if (wanted && t.slice(0, 10) !== wanted) continue
    var hour = parseInt(t.slice(11, 13), 10)
    if (!isFinite(hour) || hour < 0 || hour > 23) continue
    var price = number(rec.DayAheadPriceDKK)
    if (price === null) continue
    buckets[hour].push(price)
    if (!area && rec.PriceArea) area = String(rec.PriceArea)
  }

  var bars = []
  var seen = []
  for (var h = 0; h < 24; h++) {
    var vals = buckets[h]
    if (vals.length === 0) {
      bars.push({
        hour: h, price: null, label: pad2(h), current: h === currentHour,
        cheapest: false, dearest: false, tip: hourRangeLabel(h) + " \u00b7 \u2014"
      })
      continue
    }
    var sum = 0
    for (var j = 0; j < vals.length; j++) sum += vals[j]
    var avg = sum / vals.length
    seen.push(avg)
    bars.push({
      hour: h, price: avg, label: pad2(h), current: h === currentHour,
      cheapest: false, dearest: false, tip: ""
    })
  }

  if (seen.length === 0) {
    return { day: wanted, area: area, bars: [], min: null, max: null }
  }

  var min = Math.min.apply(null, seen)
  var max = Math.max.apply(null, seen)
  for (var b = 0; b < bars.length; b++) {
    var bar = bars[b]
    if (bar.price === null) continue
    bar.cheapest = bar.price === min
    bar.dearest = bar.price === max
    var tip = hourRangeLabel(bar.hour) + " \u00b7 " + formatSpotPrice(bar.price)
    if (area) tip += " \u00b7 " + area
    if (bar.cheapest && min !== max) tip += " \u00b7 cheapest"
    else if (bar.dearest && min !== max) tip += " \u00b7 dearest"
    bar.tip = tip
  }

  return { day: wanted, area: area, bars: bars, min: min, max: max }
}

// Combine spot + optional tariffs into the chart the panel draws. `bundle` is
// what `bin/tessie prices` prints; `options.grid` / `parts` mirror the settings.
function consumerPrices(bundle, options) {
  options = options || {}
  var data = bundle
  if (typeof bundle === "string") {
    try { data = JSON.parse(bundle) } catch (e) { return { day: "", area: "", grid: "", bars: [], min: null, max: null } }
  }
  if (!data || !data.ok) {
    return { day: "", area: "", grid: "", bars: [], min: null, max: null }
  }

  var day = String(options.day || data.day || calendarDay())
  var gridId = String(options.grid || "none")
  var company = GRID_COMPANIES[gridId] || null
  var parts = choiceList(options.parts === undefined || options.parts === null
    ? PRICE_PART_DEFAULTS : options.parts)
  var withVat = parts.indexOf("vat") !== -1
  var spotChart = dayPrices(data.spot, day, options)
  if (spotChart.bars.length === 0) {
    return { day: day, area: spotChart.area, grid: company ? company.label : "", bars: [], min: null, max: null }
  }

  var netHours = company ? tariffHours(pickTariffRecord(data.net, day)) : null
  var systemHours = parts.indexOf("energinet") !== -1
    ? tariffHours(pickTariffRecord(data.system, day)) : null
  var transmissionHours = parts.indexOf("energinet") !== -1
    ? tariffHours(pickTariffRecord(data.transmission, day)) : null
  var taxHours = parts.indexOf("elafgift") !== -1
    ? tariffHours(pickTariffRecord(data.elafgift, day)) : null

  var bars = []
  var seen = []
  for (var h = 0; h < spotChart.bars.length; h++) {
    var src = spotChart.bars[h]
    if (src.price === null) {
      bars.push({
        hour: src.hour, price: null, spot: null, net: null, system: null,
        transmission: null, tax: null, pretax: null, label: src.label,
        current: src.current, cheapest: false, dearest: false, inWindow: false,
        tip: hourRangeLabel(src.hour) + " \u00b7 \u2014",
        detail: { title: hourRangeLabel(src.hour), lines: ["\u2014"], total: null }
      })
      continue
    }
    var spot = src.price / 1000
    var net = netHours ? (number(netHours[src.hour]) || 0) : 0
    var system = systemHours ? (number(systemHours[src.hour]) || 0) : 0
    var transmission = transmissionHours ? (number(transmissionHours[src.hour]) || 0) : 0
    var tax = taxHours ? (number(taxHours[src.hour]) || 0) : 0
    var pretax = spot + net + system + transmission + tax
    var total = withVat ? pretax * 1.25 : pretax
    seen.push(total)
    bars.push({
      hour: src.hour, price: total, spot: spot, net: net, system: system,
      transmission: transmission, tax: tax, pretax: pretax, label: src.label,
      current: src.current, cheapest: false, dearest: false, inWindow: false, tip: "",
      detail: null
    })
  }

  if (seen.length === 0) {
    return { day: day, area: spotChart.area, grid: company ? company.label : "",
      bars: [], min: null, max: null, window: null }
  }

  var min = Math.min.apply(null, seen)
  var max = Math.max.apply(null, seen)
  var extras = !!(netHours || systemHours || transmissionHours || taxHours || withVat)
  var window = cheapestWindow(bars, 0, 3)
  for (var b = 0; b < bars.length; b++) {
    var bar = bars[b]
    if (bar.price === null) continue
    bar.cheapest = bar.price === min
    bar.dearest = bar.price === max
    bar.inWindow = !!(window && bar.hour >= window.start && bar.hour < window.end)
    bar.detail = priceBarDetail(bar, {
      area: spotChart.area, grid: company ? company.label : "", extras: extras,
      net: !!netHours, fees: !!(systemHours || transmissionHours || taxHours), vat: withVat
    })
    bar.tip = bar.detail.lines.join(" \u00b7 ")
  }

  return {
    day: day,
    area: spotChart.area,
    grid: company ? company.label : "",
    bars: bars,
    min: min,
    max: max,
    window: window
  }
}

// Cheapest run of `length` consecutive hours with prices, from `fromHour`.
function cheapestWindow(bars, fromHour, length) {
  var len = Math.max(1, Math.round(number(length) || 3))
  var from = Math.max(0, Math.round(number(fromHour) || 0))
  var best = null
  if (!bars || bars.length < len) return null
  for (var start = from; start <= bars.length - len; start++) {
    var sum = 0
    var ok = true
    for (var i = 0; i < len; i++) {
      var p = number(bars[start + i] && bars[start + i].price)
      if (p === null) { ok = false; break }
      sum += p
    }
    if (!ok) continue
    if (!best || sum < best.sum)
      best = { start: start, end: start + len, sum: sum, avg: sum / len }
  }
  return best
}

// Structured breakdown for the click panel under the chart.
function priceBarDetail(bar, opts) {
  opts = opts || {}
  if (!bar || bar.price === null)
    return { title: hourRangeLabel(bar ? bar.hour : 0), lines: ["—"], total: null }
  var lines = [formatKrKwh(bar.price)]
  if (opts.extras) {
    lines.push("spot " + formatKrKwh(bar.spot))
    if (opts.net) lines.push("net " + formatKrKwh(bar.net))
    if (opts.fees) {
      var fees = (bar.system || 0) + (bar.transmission || 0) + (bar.tax || 0)
      lines.push("fees " + formatKrKwh(fees))
    }
    if (opts.vat) lines.push("incl. VAT")
  } else if (opts.area) {
    lines.push(opts.area)
  }
  if (bar.inWindow) lines.push("cheapest 3 h")
  else if (bar.cheapest) lines.push("cheapest hour")
  else if (bar.dearest) lines.push("dearest hour")
  var title = hourRangeLabel(bar.hour)
  if (opts.grid) title += " · " + opts.grid
  else if (opts.area) title += " · " + opts.area
  return { title: title, lines: lines, total: bar.price }
}

// kWh and cost to reach the charge limit at `priceKrKwh`. Pack size is
// inferred from the current range and battery percent (~0.24 kWh/mi).
function chargeEstimate(snapshot, priceKrKwh) {
  var ch = snapshot && snapshot.state && snapshot.state.charge_state
  if (!ch) return null
  var level = number(ch.battery_level)
  var limit = number(ch.charge_limit_soc)
  var range = number(ch.battery_range)
  if (level === null || limit === null || range === null || level <= 0) return null
  var pct = Math.max(0, limit - level)
  if (pct === 0) {
    return { kwh: 0, cost: 0, pct: 0, label: "Already at the charge limit" }
  }
  var fullMiles = range / (level / 100)
  var kwh = fullMiles * (pct / 100) * 0.24
  var price = number(priceKrKwh)
  var cost = price === null ? null : kwh * price
  var label = formatEnergy(kwh) + " to " + Math.round(limit) + "%"
  if (cost !== null) label += " · ~" + formatKrKwh(cost).replace(" kr/kWh", " kr")
  return { kwh: kwh, cost: cost, pct: pct, label: label }
}

// One-line summary under the battery: now-price and the cheapest 3 h window.
function priceSummary(chart, currentHour) {
  if (!chart || !chart.bars || chart.bars.length === 0) return ""
  var hour = Math.max(0, Math.min(23, Math.round(number(currentHour) || 0)))
  var cur = null
  for (var i = 0; i < chart.bars.length; i++) {
    if (chart.bars[i].hour === hour) { cur = chart.bars[i]; break }
  }
  var bits = []
  if (cur && cur.price !== null) bits.push("now " + formatKrKwh(cur.price))
  var rest = cheapestWindow(chart.bars, hour, 3) || chart.window
  if (rest && rest.avg !== null && rest.avg !== undefined) {
    bits.push("best " + pad2(rest.start) + "\u2013" + pad2(rest.end)
      + " " + formatKrKwh(rest.avg))
  }
  return bits.join(" · ")
}

// Bar height as a fraction of the chart. Anchored at 0 so negative prices stay
// readable; a flat day fills half the chart rather than collapsing to a line.
function priceBarFraction(price, min, max) {
  var p = number(price)
  var rawMin = number(min)
  var rawMax = number(max)
  if (p === null || rawMin === null || rawMax === null) return 0
  if (rawMax === rawMin) return 0.5
  var lo = Math.min(0, rawMin)
  var hi = Math.max(0, rawMax)
  if (hi === lo) return 0.5
  return Math.max(0, Math.min(1, (p - lo) / (hi - lo)))
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

// Left-menu sections. Long choice lists set `picker: "search"`. Rows with
// `when` hide until that setting matches (price extras wait for the chart).
var SETTINGS = [
  { title: "Car", blurb: "Which car to show, and how to read its units.", rows: [
    { key: "name", kind: "text", label: "Name", fallback: "",
      placeholder: "From the car" },
    { key: "vin", kind: "text", label: "VIN", fallback: "",
      placeholder: "First car on the account" },
    { key: "units", kind: "choice", label: "Units", fallback: "",
      options: [{ value: "", label: "Follow the car" }, { value: "metric", label: "Metric" },
                { value: "imperial", label: "Imperial" }] }
  ]},
  { title: "Prices", blurb: "Your netselskab — not your elselskab — plus spot area and fees.", rows: [
    { key: "showPrices", kind: "toggle", label: "Chart under the battery", fallback: true },
    { key: "priceArea", kind: "choice", label: "Spot area", fallback: "auto",
      options: [{ value: "auto", label: "Auto" }, { value: "DK1", label: "DK1 west" },
                { value: "DK2", label: "DK2 east" }] },
    { key: "priceGrid", kind: "choice", label: "Netselskab", fallback: "none",
      picker: "search", options: GRID_OPTIONS },
    { key: "priceParts", kind: "multi", label: "Add on top",
      when: { key: "showPrices", is: true },
      fallback: PRICE_PART_DEFAULTS, options: PRICE_PART_OPTIONS }
  ]},
  { title: "Panel", blurb: "What the popup shows: map, vitals and control buttons.", rows: [
    { key: "barLabel", kind: "choice", label: "Next to the T", fallback: "none",
      options: [{ value: "none", label: "Nothing" }, { value: "battery", label: "Battery" },
                { value: "range", label: "Range" }] },
    { key: "showMap", kind: "toggle", label: "Map", fallback: true },
    { key: "mapZoom", kind: "number", label: "Map zoom", fallback: 16, min: 3, max: 19 },
    { key: "stats", kind: "multi", label: "Vitals",
      fallback: STAT_OPTIONS.map(function(o) { return o.value }), options: STAT_OPTIONS },
    { key: "controls", kind: "multi", label: "Controls",
      hint: "Six fit; the rest are there to swap in",
      fallback: CONTROL_DEFAULTS, options: CONTROL_OPTIONS },
    { key: "confirmUnlock", kind: "toggle", label: "Ask before unlocking", fallback: true },
    { key: "showFooter", kind: "toggle", label: "Status footer", fallback: true }
  ]},
  { title: "Advanced", blurb: "Polling, demo mode, and map links.", rows: [
    { key: "refreshMinutes", kind: "number", label: "Refresh while closed", fallback: 5,
      min: 1, max: 60, hint: "Minutes" },
    { key: "demo", kind: "toggle", label: "Demo car", fallback: false,
      hint: "Never calls Tessie" },
    { key: "cartoKey", kind: "text", label: "CARTO key", fallback: "", secret: true,
      placeholder: "Optional — sharper map, zoom to 19" },
    { key: "mapsUrl", kind: "text", label: "Maps link", fallback: "",
      placeholder: "Google Maps — use {lat} and {lon}" }
  ]}
]

function settingRow(key) {
  for (var s = 0; s < SETTINGS.length; s++) {
    var rows = SETTINGS[s].rows
    for (var r = 0; r < rows.length; r++) if (rows[r].key === key) return rows[r]
  }
  return null
}

// Should this row show for the current settings? Used by the overlay so price
// details do not sit there while the chart itself is off.
function settingVisible(row, settings) {
  if (!row || !row.when) return true
  return readSetting(settings, row.when.key) === row.when.is
}

// Long choice lists become a searchable dropdown rather than a chip wall.
function choiceUsesSearch(row) {
  return !!(row && row.kind === "choice" && (row.picker === "search"
    || (row.options && row.options.length > 5)))
}

// Long multi lists (vitals, controls) become a two-column checklist instead
// of a wrapping pill soup.
function multiUsesGrid(row) {
  return !!(row && row.kind === "multi" && row.options && row.options.length > 6)
}

// "6 / 12" next to Vitals / Controls so the selection size is visible at a glance.
function multiSelectionLabel(row, value) {
  if (!row || row.kind !== "multi" || !row.options) return ""
  var chosen = coerceSetting(row, value)
  var n = Array.isArray(chosen) ? chosen.length : 0
  return n + " / " + row.options.length
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
// a wrapping row of chips takes noticeably more than a switch; a searchable
// choice is one control, not one chip per option.
var ROW_WEIGHT = { text: 3, multi: 3, choice: 2, number: 2, toggle: 2 }

function rowWeight(row) {
  if (!row) return 2
  if (choiceUsesSearch(row)) return 2
  return ROW_WEIGHT[row.kind] || 2
}

function sectionWeight(section) {
  return section.rows.reduce(function(sum, row) {
    return sum + rowWeight(row)
  }, 1)
}

// Does any option in this section differ from its default? Drives the dots
// on the settings left menu.
function sectionHasCustom(section, settings) {
  if (!section || !section.rows) return false
  for (var r = 0; r < section.rows.length; r++) {
    var row = section.rows[r]
    var raw = settings ? settings[row.key] : undefined
    if (raw !== undefined && raw !== null && !isDefaultSetting(row, coerceSetting(row, raw)))
      return true
  }
  return false
}

// The sections dealt into `count` columns, in order, so that the tallest
// column comes out as short as it can. Kept for tests and callers; the
// settings overlay uses a left menu instead.
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
    pad2: pad2, calendarDay: calendarDay, nextCalendarDay: nextCalendarDay,
    formatKrKwh: formatKrKwh, formatSpotPrice: formatSpotPrice, hourRangeLabel: hourRangeLabel,
    ENERGINET_GLN: ENERGINET_GLN, GRID_COMPANIES: GRID_COMPANIES, GRID_OPTIONS: GRID_OPTIONS,
    PRICE_PART_OPTIONS: PRICE_PART_OPTIONS, PRICE_PART_DEFAULTS: PRICE_PART_DEFAULTS,
    denmarkPriceArea: denmarkPriceArea, resolvePriceArea: resolvePriceArea,
    pricesUrl: pricesUrl, datahubPricelistUrl: datahubPricelistUrl, priceFetchPlan: priceFetchPlan,
    parsePriceRecords: parsePriceRecords, pickTariffRecord: pickTariffRecord,
    tariffHours: tariffHours, dayPrices: dayPrices, consumerPrices: consumerPrices,
    cheapestWindow: cheapestWindow, priceBarDetail: priceBarDetail,
    chargeEstimate: chargeEstimate, priceSummary: priceSummary,
    priceBarFraction: priceBarFraction,
    stats: stats, barLabel: barLabel, SETTINGS: SETTINGS, settingRow: settingRow,
    settingVisible: settingVisible, choiceUsesSearch: choiceUsesSearch,
    multiUsesGrid: multiUsesGrid, multiSelectionLabel: multiSelectionLabel,
    rowWeight: rowWeight,
    choiceList: choiceList, coerceSetting: coerceSetting, readSetting: readSetting,
    isDefaultSetting: isDefaultSetting, nextEntry: nextEntry,
    hasCustomSettings: hasCustomSettings, enabledOnly: enabledOnly,
    toggleChoice: toggleChoice, sectionWeight: sectionWeight,
    sectionHasCustom: sectionHasCustom,
    CONTROL_DEFAULTS: CONTROL_DEFAULTS,
    settingsColumns: settingsColumns, entryFor: entryFor,
    settingsSummary: settingsSummary
  }
}
