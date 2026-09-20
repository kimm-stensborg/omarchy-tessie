#!/bin/bash
# Tests for bin/tessie against a local mock of the Tessie API, and for the
# pure helpers in Model.js under node. Nothing here reaches the real API,
# the keyring, or your stored token.
#
# Run: ./test.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$DIR/bin/tessie"
WORK=$(mktemp -d)
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
clip() { local t=${1//$'\n'/ }; (( ${#t} > 120 )) && printf '%s…' "${t:0:120}" || printf '%s' "$t"; }
no()   { FAIL=$((FAIL+1)); printf '  ✗ %s\n     want: %s\n     got:  %s\n' "$1" "$(clip "$3")" "$(clip "$2")" >&2; }
is()   { [[ $2 == "$3" ]] && ok "$1" || no "$1" "$2" "$3"; }
has()  { [[ $2 == *"$3"* ]] && ok "$1" || no "$1" "contains: $3" "$2"; }
hasnt(){ [[ $2 != *"$3"* ]] && ok "$1" || no "$1" "must not contain: $3" "$2"; }

# ---- mock Tessie: answers from routes.json, logs every request -----------
cat >"$WORK/mock.py" <<'PY'
import http.server, json, os, sys
work = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self, method):
        auth = self.headers.get("Authorization", "")
        with open(os.path.join(work, "requests.log"), "a") as log:
            log.write(f"{method} {self.path} {auth}\n")
        with open(os.path.join(work, "routes.json")) as f:
            routes = json.load(f)
        if auth != "Bearer good-token":
            status, body = 401, {"error": "Unauthorized"}
        else:
            status, body = routes.get(f"{method} {self.path.split('?')[0]}", [404, {"error": "Not found"}])
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self): self.answer("GET")
    def do_POST(self): self.answer("POST")
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(work, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

VIN=5YJ3E7EB0KF000001
routes() {
  cat >"$WORK/routes.json" <<JSON
{
  "GET /vehicles": [200, {"results": [{"vin": "$VIN", "is_active": true}]}],
  "GET /$VIN/state": [200, {"vin": "$VIN", "state": "online", "display_name": "Nimbus",
    "drive_state": {"latitude": 52.0907, "longitude": 5.1214, "speed": 50, "shift_state": "D", "heading": 90},
    "charge_state": {"battery_level": 71, "battery_range": 180.2, "charge_limit_soc": 85, "charging_state": "Disconnected"},
    "climate_state": {"inside_temp": 20.6, "outside_temp": 10, "is_climate_on": true},
    "vehicle_state": {"locked": true, "sentry_mode": false, "odometer": 31250.5, "car_version": "2025.2.1 abc"},
    "gui_settings": {"gui_distance_units": "km/hr"}}],
  "GET /$VIN/location": [200, {"latitude": 52.0907, "longitude": 5.1214,
    "address": "Oudegracht 158, 3511 AZ Utrecht, Netherlands", "saved_location": null}],
  "GET /$VIN/tire_pressure": [200, {"front_left": 3.0, "front_right": 3.1, "rear_left": 3.1, "rear_right": 3.05}],
  "GET /$VIN/charges": [200, {"results": [{"energy_added": 12.3, "location": "Home"}]}],
  "GET /$VIN/status": [200, {"status": "awake"}],
  "POST /$VIN/command/lock": [200, {"result": true}],
  "POST /$VIN/command/honk": [200, {"result": false, "reason": "vehicle unavailable"}]
}
JSON
}
route() { # route 'METHOD /path' '[status, body]'
  jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$WORK/routes.json" >"$WORK/r.tmp" && mv "$WORK/r.tmp" "$WORK/routes.json"
}

routes
python3 "$WORK/mock.py" "$WORK" & MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 50); do [[ -s $WORK/port ]] && break; sleep 0.1; done

export TESSIE_API="http://127.0.0.1:$(<"$WORK/port")" TESSIE_NO_KEYRING=1
export XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache"
unset TESSIE_TOKEN TESSIE_VIN
t()   { TESSIE_TOKEN=good-token "$CLI" "$@" 2>&1; }
log() { cat "$WORK/requests.log" 2>/dev/null; }
reset_log() { : >"$WORK/requests.log"; }

echo "token"
out=$("$CLI" state 2>&1); code=$?
is  "no token is its own error code" "$(jq -r .code <<<"$out")" notoken
is  "and exits non-zero"             "$code" 1
out=$(TESSIE_TOKEN=bad-token "$CLI" state 2>&1)
is  "a rejected token says auth"     "$(jq -r .code <<<"$out")" auth

echo "state"
reset_log
out=$(t state)
is  "snapshot is ok"                 "$(jq -r .ok <<<"$out")" true
is  "VIN found through /vehicles"    "$(jq -r .vin <<<"$out")" "$VIN"
is  "VIN is cached"                  "$(cat "$WORK/cache/omarchy-tessie/vin")" "$VIN"
is  "state is passed through"        "$(jq -r .state.charge_state.battery_level <<<"$out")" 71
is  "location is attached"           "$(jq -r .location.address <<<"$out")" "Oudegracht 158, 3511 AZ Utrecht, Netherlands"
is  "tyres are attached"             "$(jq -r .tires.front_right <<<"$out")" 3.1
is  "last charge is the first result" "$(jq -r .lastCharge.energy_added <<<"$out")" 12.3
is  "status is flattened"            "$(jq -r .status <<<"$out")" awake
has "state reads the cache"          "$(log)" "GET /$VIN/state?use_cache=true"
has "token goes in the header"       "$(log)" "Bearer good-token"
reset_log
t state >/dev/null
hasnt "second run skips /vehicles"   "$(log)" "GET /vehicles"
reset_log
out=$(TESSIE_VIN=OTHERVIN t state)
has "TESSIE_VIN wins over the cache" "$(log)" "GET /OTHERVIN/state"
is  "an unknown VIN is an error"     "$(jq -r .ok <<<"$out")" false
route "GET /$VIN/tire_pressure" '[500, {"error": "boom"}]'
route "GET /$VIN/charges" '[200, {"results": []}]'
out=$(t state)
is  "failed optional part is null"   "$(jq -c .tires <<<"$out")" null
is  "no charges gives null"          "$(jq -c .lastCharge <<<"$out")" null
is  "and the snapshot is still ok"   "$(jq -r .ok <<<"$out")" true
route "GET /$VIN/state" '[404, {"error": "Vehicle not found"}]'
out=$(t state)
is  "a vanished car says novehicle"  "$(jq -r .code <<<"$out")" novehicle
[[ -e $WORK/cache/omarchy-tessie/vin ]] && no "and drops the cached VIN" "cache kept" "cache removed" || ok "and drops the cached VIN"
route "GET /$VIN/state" '[502, {"error": "upstream timeout"}]'
out=$(t state)
is  "other failures carry the reason" "$(jq -r .error <<<"$out")" "Reading the car failed (HTTP 502): upstream timeout"
routes
out=$(TESSIE_TOKEN=good-token TESSIE_API="http://127.0.0.1:1" "$CLI" state 2>&1)
is  "unreachable says network"       "$(jq -r .code <<<"$out")" network

echo "command"
reset_log
out=$(t command lock)
is  "lock succeeds"                  "$(jq -c . <<<"$out")" '{"ok":true,"command":"lock"}'
has "it is a POST that waits"        "$(log)" "POST /$VIN/command/lock?wait_for_completion=true"
out=$(t command honk)
is  "a refused command is not ok"    "$(jq -r .code <<<"$out")" rejected
is  "and says why"                   "$(jq -r .error <<<"$out")" "The car did not honk: vehicle unavailable"
reset_log
# Every command the panel's buttons can send has to be one bin/tessie will
# pass on, and it has to reach the endpoint Tessie names for it. Both lists
# come from Model.js rather than from here, so a button added without a
# matching command fails the tests instead of failing on a real car.
panel_commands=$(node -e '
  const M = require(process.argv[1] + "/Model.js")
  const ids = new Set()
  const states = [{}, {vehicle_state: {locked: true, ft: 255, rt: 255, rd_window: 1, sentry_mode: true}},
                  {charge_state: {charging_state: "Charging", charge_port_door_open: true}},
                  {climate_state: {is_climate_on: true, defrost_mode: 2}}]
  for (const state of states) for (const c of M.controls(state)) ids.add(c.command)
  console.log([...ids].join(" "))
' "$DIR")

bad=""
for name in $panel_commands; do
  route "POST /$VIN/command/$name" '[200, {"result": true}]'
  reset_log
  out=$(t command "$name")
  [[ $(jq -r .command <<<"$out" 2>/dev/null) == "$name" ]] || bad="$bad $name(refused)"
  [[ $(log) == *"POST /$VIN/command/$name?wait_for_completion=true"* ]] || bad="$bad $name(endpoint)"
done
is  "every button's command reaches Tessie" "${bad:- none}" " none"
is  "the panel sends 19 distinct commands"  "$(wc -w <<<"$panel_commands")" 19
reset_log

out=$(t command "lock; rm -rf /")
is  "unknown commands are refused"   "$(jq -r .code <<<"$out")" usage
is  "without touching the API"       "$(log)" ""
out=$(t command)
is  "a missing command is refused"   "$(jq -r .code <<<"$out")" usage

echo "demo"
reset_log
out=$(TESSIE_DEMO=1 "$CLI" state 2>&1)
is  "demo needs no token"            "$(jq -r .ok <<<"$out")" true
is  "demo car has a name"            "$(jq -r .state.display_name <<<"$out")" Sparky
is  "demo car is driving"            "$(jq -r .state.drive_state.shift_state <<<"$out")" D
is  "demo car is on the bridge"      "$(jq -r .location.address <<<"$out")" "E20, Storebæltsbroen, 4220 Korsør, Denmark"
is  "demo data is fresh"             "$(jq -r '(now - .fetchedAt) < 60' <<<"$out")" true
out=$(TESSIE_DEMO=1 "$CLI" command lock 2>&1)
is  "demo commands succeed"          "$(jq -r .ok <<<"$out")" true
out=$(TESSIE_DEMO=1 "$CLI" command bogus 2>&1)
is  "demo still refuses unknown ones" "$(jq -r .code <<<"$out")" usage
is  "demo never calls Tessie"        "$(log)" ""

echo "login"
out=$(printf 'bad-token\n' | "$CLI" login 2>&1); code=$?
has "a bad token is not stored"      "$out" "rejected that token"
is  "and exits non-zero"             "$code" 1
[[ -e $WORK/config/omarchy-tessie/token ]] && no "nothing written" "token file exists" "no file" || ok "nothing written"
out=$(printf '  good-token \n' | "$CLI" login 2>&1)
has "a good token is stored"         "$out" "Token saved to"
has "and lists the vehicles"         "$out" "$VIN"
is  "token file is private"          "$(stat -c %a "$WORK/config/omarchy-tessie/token")" 600
is  "whitespace is stripped"         "$(cat "$WORK/config/omarchy-tessie/token")" good-token
out=$("$CLI" state 2>&1)
is  "state uses the stored token"    "$(jq -r .ok <<<"$out")" true
"$CLI" logout >/dev/null
out=$("$CLI" state 2>&1)
is  "logout forgets it"              "$(jq -r .code <<<"$out")" notoken

echo "qml"
# The node tests below never touch the .qml files, and omarchy-shell swallows
# the reason a plugin entry point failed to load -- its own error handler
# throws (`errorString is not defined`, shell.qml), so a missing import shows
# up as a panel that silently does not open. qmllint resolves the same imports
# the shell does and says what is wrong.
#
# `qs.Commons` and `qs.Ui` are the shell's own directories, reached through
# the `qs` prefix, so the lint needs an import root where `qs` is the shell.
QMLLINT=$(command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
if [[ ! -x $QMLLINT ]]; then
  echo "  - skipped: no qmllint (pacman -S qt6-declarative)"
else
  mkdir -p "$WORK/imports"
  ln -sfn /usr/share/omarchy/shell "$WORK/imports/qs"
  # `bar`, `shell` and `manifest` are injected as plain objects, so every
  # property read off them is unqualified by design; those categories would
  # drown the ones that mean the file will not load.
  lint() { "$QMLLINT" -I "$WORK/imports" \
    --unqualified disable --missing-property disable --uncreatable-type disable "$@" 2>&1; }

  out=$(cd "$DIR" && lint ./*.qml)
  is  "every QML file resolves and parses" "$out" ""

  # A check that cannot fail is not a check: drop an import from a copy and
  # the lint has to notice. IpcHandler comes from Quickshell.Io, which is the
  # import this very plugin once shipped without.
  cp "$DIR"/*.qml "$DIR/Model.js" "$WORK/"
  sed -i '/^import Quickshell.Io$/d' "$WORK/SettingsOverlay.qml"
  out=$(cd "$WORK" && lint ./SettingsOverlay.qml)
  has "a missing import is caught"        "$out" "IpcHandler was not found"
  rm -f "$WORK"/*.qml "$WORK/Model.js"
fi

# A singleton is reached from JavaScript rather than declared as an element,
# so dropping its import is not a missing type -- qmllint files it under
# `unqualified`, together with all the delegate-scope noise the lint above
# has to silence to be readable. So they are checked by name instead.
missing=""
for f in "$DIR"/*.qml; do
  body=$(grep -v '^import ' "$f")
  for pair in "Hyprland:Quickshell.Hyprland" "Quickshell:Quickshell"; do
    name=${pair%%:*}; needs=${pair##*:}
    grep -qE "(^|[^.A-Za-z_])$name\." <<<"$body" || continue
    grep -qE "^import $needs\$" "$f" || missing="$missing $(basename "$f"):$needs"
  done
done
is  "every singleton used is imported"  "${missing:- none}" " none"

echo
echo "Model.js"
node - "$DIR/Model.js" <<'JS' || FAIL=$((FAIL+1))
const M = require(process.argv[2])
const snap = {
  ok: true, status: "awake",
  state: {
    drive_state: {shift_state: null},
    charge_state: {battery_level: 71, battery_range: 180.2, charge_limit_soc: 85},
    climate_state: {inside_temp: 20.6, outside_temp: 10, is_climate_on: true},
    vehicle_state: {locked: true, sentry_mode: false, odometer: 31250.5, car_version: "2025.2.1 abc"}
  },
  tires: {front_left: 3.0, front_right: 3.1, rear_left: 3.1, rear_right: 3.05},
  lastCharge: {energy_added: 12.3}
}

const cases = [
  ["distance km",        M.formatDistance(31250.5, false), "50,293 km"],
  ["distance mi",        M.formatDistance(31250.5, true), "31,251 mi"],
  ["distance missing",   M.formatDistance(null, false), "—"],
  ["speed km/h",         M.formatSpeed(50, false), "80 km/h"],
  ["speed mph",          M.formatSpeed(50, true), "50 mph"],
  ["temp °C",            M.formatTemp(20.6, false), "21 °C"],
  ["temp °F",            M.formatTemp(10, true), "50 °F"],
  ["energy",             M.formatEnergy(12.3), "12.3 kWh"],
  ["duration",           M.formatDuration(135), "2 h 15 min"],
  ["duration short",     M.formatDuration(40), "40 min"],
  ["units follow car",   M.useImperial("", "mi/hr"), true],
  ["units forced",       M.useImperial("metric", "mi/hr"), false],
  ["tyre range",         M.tyres({front_left: 3.0, front_right: 3.1, rear_left: 3.1, rear_right: 3.05}, null, false).text, "3.0–3.1 bar"],
  ["tyres equal",        M.tyres(null, {tpms_pressure_fl: 3.1, tpms_pressure_fr: 3.1, tpms_pressure_rl: 3.1, tpms_pressure_rr: 3.1}, false).text, "3.1 bar"],
  ["tyres psi",          M.tyres({front_left: 3.1, front_right: 3.1, rear_left: 3.1, rear_right: 3.1}, null, true).text, "45 psi"],
  ["tyre low flag",      M.tyres({front_left: 2.1, rear_left_status: "low"}, null, false).low, true],
  ["no tyres",           M.tyres(null, null, false).text, "—"],
  ["place nl",           M.placeName({address: "Oudegracht 158, 3511 AZ Utrecht, Netherlands"}), "Oudegracht 158, Utrecht"],
  ["place no",           M.placeName({address: "Kirsten Flagstads plass 1, 0150 Oslo, Norway"}), "Kirsten Flagstads plass 1, Oslo"],
  ["place bridge",       M.placeName({address: "E20, Storebæltsbroen, 4220 Korsør, Denmark"}), "E20, Storebæltsbroen"],
  ["place us",           M.placeName({address: "45500 Fremont Blvd, Fremont, California 94538, United States"}), "45500 Fremont Blvd, Fremont"],
  ["place dk",           M.placeName({address: "Vesterbrogade 1, 1620 København V, Denmark"}), "Vesterbrogade 1, København V"],
  ["place saved",        M.placeName({address: "x", saved_location: "Home"}), "Home"],
  ["place empty",        M.placeName({address: ""}), ""],
  ["time just now",      M.relativeTime(1000, 1010), "just now"],
  ["time minutes",       M.relativeTime(1000, 1000 + 240), "4 min ago"],
  ["time ms",            M.relativeTime(1700000000 * 1000, 1700000000 + 7200), "2 h ago"],
  ["time days",          M.relativeTime(0, 3 * 86400), "3 days ago"],
  ["asleep wins",        M.activity({status: "asleep", state: {drive_state: {shift_state: "D"}}}), "asleep"],
  ["driving",            M.activity({status: "awake", state: {drive_state: {shift_state: "D"}}}), "driving"],
  ["charging",           M.activity({state: {drive_state: {shift_state: "P"}, charge_state: {charging_state: "Charging"}}}), "charging"],
  ["parked",             M.activity({state: {drive_state: {shift_state: null}}}), "parked"],
  ["subtitle driving",   M.subtitle({status: "awake", state: {drive_state: {shift_state: "D", speed: 50}}}, false), "Driving 80 km/h"],
  ["subtitle charging",  M.subtitle({state: {charge_state: {charging_state: "Charging", charger_power: 11, minutes_to_full_charge: 90}}}, false), "Charging 11 kW, full in 1 h 30 min"],
  ["subtitle asleep",    M.subtitle({status: "asleep", state: {drive_state: {shift_state: "D"}}}, false), "Asleep"],
  ["updated newest",     M.dataUpdated({drive_state: {timestamp: 1700000000000, gps_as_of: 1700000100}, charge_state: {timestamp: 1700000050000}}), 1700000100],
  ["updated ms",         M.dataUpdated({vehicle_state: {timestamp: 1700000000000}}), 1700000000],
  ["updated none",       M.dataUpdated({}), null],
  ["name override",      M.carName({display_name: "Nimbus"}, "Blue"), "Blue"],
  ["name from car",      M.carName({display_name: "Nimbus"}, ""), "Nimbus"],
  ["name vehicle_name",  M.carName({display_name: null, vehicle_state: {vehicle_name: "Sparky"}}), "Sparky"],
  ["name falls to model", M.carName({display_name: null, vehicle_config: {car_type: "model3"}}), "Model 3"],
  ["name unknown model", M.carName({vehicle_config: {car_type: "roadster9"}}), "Tesla"],
  ["name no state",      M.carName(null), "Tesla"],
  ["status ok",          M.tessieStatus('{"data":{"attributes":{"aggregate_state":"operational"}},"included":[{"type":"status_page_resource","attributes":{"public_name":"Website","status":"operational"}}]}').label, "ok"],
  ["status degraded",    JSON.stringify(M.tessieStatus({data: {attributes: {aggregate_state: "degraded"}}, included: [{type: "status_page_section", attributes: {status: null}}, {type: "status_page_resource", attributes: {public_name: "Tesla Fleet API (Europe & Middle East)", status: "degraded"}}, {type: "status_page_resource", attributes: {public_name: "Website", status: "operational"}}]})), '{"state":"degraded","label":"degraded","affected":["Tesla Fleet API (Europe & Middle East)"]}'],
  ["status downtime",    M.tessieStatus({data: {attributes: {aggregate_state: "downtime"}}}).label, "down"],
  ["status unreadable",  M.tessieStatus("<html>").state, "unknown"],
  ["status empty",       M.tessieStatus("").label, "status unknown"],
  ["after lock",         M.afterCommand({vehicle_state: {locked: false}}, "lock").vehicle_state.locked, true],
  ["after climate",      M.afterCommand({}, "start_climate").climate_state.is_climate_on, true],
  ["after port close",   M.afterCommand({charge_state: {charge_port_door_open: true}}, "close_charge_port").charge_state.charge_port_door_open, false],
  ["after is a copy",    (s => (M.afterCommand(s, "unlock"), s.vehicle_state.locked))({vehicle_state: {locked: true}}), true],
  ["after honk no-op",   JSON.stringify(M.afterCommand({vehicle_state: {locked: true}}, "honk")), '{"vehicle_state":{"locked":true}}'],
  ["twelve controls",    M.controls({}).map(c => c.id).join(","),
     "lock,climate,sentry,port,flash,honk,charge,frunk,trunk,windows,defrost,wake"],
  ["every control has a glyph", M.controls({}).every(c => c.icon && c.icon.codePointAt(0) > 0xe000), true],
  ["every control has a command", M.controls({}).every(c => c.command && c.label), true],
  ["charge starts",      M.controls({}).find(c => c.id === "charge").command, "start_charging"],
  ["charging stops",     M.controls({charge_state: {charging_state: "Charging"}}).find(c => c.id === "charge").command, "stop_charging"],
  ["stopping a charge asks", M.controls({charge_state: {charging_state: "Charging"}}).find(c => c.id === "charge").confirm, true],
  ["windows vent",       M.controls({}).find(c => c.id === "windows").command, "vent_windows"],
  ["open windows close", M.controls({vehicle_state: {rd_window: 1}}).find(c => c.id === "windows").command, "close_windows"],
  ["open windows read open", M.controls({vehicle_state: {rd_window: 1}}).find(c => c.id === "windows").active, true],
  ["defrost starts",     M.controls({}).find(c => c.id === "defrost").command, "start_max_defrost"],
  ["defrost stops",      M.controls({climate_state: {defrost_mode: 2}}).find(c => c.id === "defrost").command, "stop_max_defrost"],
  ["frunk reads open",   M.controls({vehicle_state: {ft: 255}}).find(c => c.id === "frunk").active, true],
  ["trunk is one-shot",  M.controls({vehicle_state: {rt: 255}}).find(c => c.id === "trunk").command, "activate_rear_trunk"],
  ["after venting",      M.afterCommand({}, "vent_windows").vehicle_state.fd_window, 1],
  ["after closing up",   M.afterCommand({vehicle_state: {rp_window: 1}}, "close_windows").vehicle_state.rp_window, 0],
  ["after charging on",  M.afterCommand({}, "start_charging").charge_state.charging_state, "Charging"],
  ["after defrost",      M.afterCommand({}, "start_max_defrost").climate_state.defrost_mode, 2],
  ["trunk has no effect", JSON.stringify(M.afterCommand({vehicle_state: {rt: 0}}, "activate_rear_trunk")), '{"vehicle_state":{"rt":0}}'],
  ["six shown by default", M.enabledOnly(M.controls({}), M.readSetting({}, "controls")).map(c => c.id).join(","),
     "lock,climate,sentry,port,flash,honk"],
  ["the six are the default", M.isDefaultSetting(M.settingRow("controls"), M.CONTROL_DEFAULTS), true],
  ["all twelve is not the default", M.isDefaultSetting(M.settingRow("controls"),
     M.controls({}).map(c => c.id)), false],
  ["swapping one in",    M.toggleChoice(M.settingRow("controls"), null, "trunk").join(","),
     "lock,climate,sentry,port,flash,honk,trunk"],
  ["swapping one out",   M.toggleChoice(M.settingRow("controls"), null, "honk").join(","),
     "lock,climate,sentry,port,flash"],
  ["the default is not written", JSON.stringify(M.nextEntry({id: "t"}, "t", {controls: M.CONTROL_DEFAULTS})), '{"id":"t"}'],
  ["locked toggles off", M.controls({vehicle_state: {locked: true}})[0].command, "unlock"],
  ["unlock confirms",    M.controls({vehicle_state: {locked: true}})[0].confirm, true],
  ["unlocked locks",     M.controls({vehicle_state: {locked: false}})[0].command, "lock"],
  ["climate stops",      M.controls({climate_state: {is_climate_on: true}})[1].command, "stop_climate"],
  ["sentry starts",      M.controls({})[2].command, "enable_sentry"],
  ["tile url keyless",   M.tileUrl({x: 1, y: 2, z: 3}, true), "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/3/2/1"],
  ["tile url light",     M.tileUrl({x: 1, y: 2, z: 3}, false, ""), "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/3/2/1"],
  ["tile url carto key", M.tileUrl({x: 1, y: 2, z: 3}, true, "k y"), "https://d.basemaps.cartocdn.com/dark_all/3/1/2@2x.png?key=k%20y"],
  ["zoom cap keyless",   M.mapMaxZoom(""), 16],
  ["zoom cap carto",     M.mapMaxZoom("abc"), 19],
  ["credit keyless",     M.mapAttribution(""), "© Esri, HERE, Garmin, OpenStreetMap contributors"],
  ["credit carto",       M.mapAttribution("abc"), "© OpenStreetMap contributors © CARTO"],
  ["maps url",           M.mapsUrl(52.3, 4.8), "https://www.google.com/maps/search/?api=1&query=52.3,4.8"],
  ["maps template",      M.mapsUrl(52.3, 4.8, "geo:{lat},{lon}"), "geo:52.3,4.8"],
  ["unlock asks",        M.controls({vehicle_state: {locked: true}}, true)[0].confirm, true],
  ["unlock can not ask", M.controls({vehicle_state: {locked: true}}, false)[0].confirm, false],
  ["stat ids",           M.stats(snap, false).map(s => s.id).join(" "), "locked sentry odometer tyres inside outside chargeLimit lastCharge climate software"],
  ["stat value",         M.stats(snap, false).find(s => s.id === "odometer").value, "50,293 km"],
  ["stats need a car",   M.stats(null, false).length, 0],
  ["bar battery",        M.barLabel(snap, false, "battery"), "71%"],
  ["bar range",          M.barLabel(snap, false, "range"), "290 km"],
  ["bar nothing",        M.barLabel(snap, false, "none"), ""],
  ["bar with no car",    M.barLabel(null, false, "battery"), ""],
  ["default toggle",     M.readSetting({}, "showMap"), true],
  ["toggle word",        M.readSetting({demo: "on"}, "demo"), true],
  ["toggle boolean",     M.readSetting({demo: true}, "demo"), true],
  ["number clamps",      M.readSetting({mapZoom: 99}, "mapZoom"), 19],
  ["number nonsense",    M.readSetting({refreshMinutes: "later"}, "refreshMinutes"), 5],
  ["choice unknown",     M.readSetting({units: "furlongs"}, "units"), ""],
  ["choice kept",        M.readSetting({units: "imperial"}, "units"), "imperial"],
  ["multi unset is the default", M.readSetting({}, "controls").join(","), M.CONTROL_DEFAULTS.join(",")],
  ["multi empty is the default", M.readSetting({controls: ""}, "controls").join(","), M.CONTROL_DEFAULTS.join(",")],
  ["vitals unset is all ten", M.readSetting({}, "stats").length, 10],
  ["multi from string",  M.readSetting({controls: "lock, honk"}, "controls").join(","), "lock,honk"],
  ["multi from spaces",  M.readSetting({controls: "lock honk"}, "controls").join(","), "lock,honk"],
  ["multi from mixed",   M.readSetting({stats: "tyres,  inside outside"}, "stats").join(","), "tyres,inside,outside"],
  ["multi drops junk",   M.readSetting({controls: ["lock", "eject"]}, "controls").join(","), "lock"],
  ["multi can be none",  M.readSetting({controls: []}, "controls").length, 0],
  ["null shows them all", M.enabledOnly(M.controls({}), null).length, 12],
  ["some controls",      M.enabledOnly(M.controls({}), ["honk", "lock"]).map(c => c.id).join(","), "lock,honk"],
  ["no controls",        M.enabledOnly(M.controls({}), []).length, 0],
  ["vitals filtered",    M.enabledOnly(M.stats(snap, false), ["tyres"]).map(s => s.id).join(","), "tyres"],
  ["untick keeps order", M.toggleChoice(M.settingRow("controls"), null, "climate").join(","), "lock,sentry,port,flash,honk"],
  ["tick keeps order",   M.toggleChoice(M.settingRow("controls"), ["honk", "lock"], "sentry").join(","), "lock,sentry,honk"],
  ["a change is written", JSON.stringify(M.nextEntry({id: "t", name: "Sparky"}, "t", {showMap: false})), '{"id":"t","name":"Sparky","showMap":false}'],
  ["a default is dropped", JSON.stringify(M.nextEntry({id: "t", showMap: false}, "t", {showMap: true})), '{"id":"t"}'],
  ["text is trimmed",    M.nextEntry({id: "t"}, "t", {name: "  Sparky "}).name, "Sparky"],
  ["blank text dropped", JSON.stringify(M.nextEntry({id: "t", name: "Sparky"}, "t", {name: "   "})), '{"id":"t"}'],
  ["all of a multi is not the default", JSON.stringify(M.nextEntry({id: "t"}, "t", {controls: M.controls({}).map(c => c.id)})) !== '{"id":"t"}', true],
  ["reset keeps the id", JSON.stringify(M.nextEntry({id: "t", demo: true, mapZoom: 9}, "t", null)), '{"id":"t"}'],
  ["reset spares others", JSON.stringify(M.nextEntry({id: "t", demo: true, pinned: 1}, "t", null)), '{"id":"t","pinned":1}'],
  ["custom is noticed",  M.hasCustomSettings({id: "t", demo: true}), true],
  ["defaults are not",   M.hasCustomSettings({id: "t", showMap: true, units: ""}), false],
  ["empty is not",       M.hasCustomSettings({}), false],
  ["every option has a kind", M.SETTINGS.every(s => s.rows.every(r =>
     ["text", "choice", "number", "multi", "toggle"].indexOf(r.kind) !== -1 && r.key && r.label)), true],
  ["every key is unique", new Set(M.SETTINGS.flatMap(s => s.rows.map(r => r.key))).size,
     M.SETTINGS.reduce((n, s) => n + s.rows.length, 0)],
  ["one column holds it all", M.settingsColumns(1).length, 1],
  ["three columns keep order", M.settingsColumns(3).flat().map(s => s.title).join(" | "),
     M.SETTINGS.map(s => s.title).join(" | ")],
  ["three columns are level", M.settingsColumns(3).map(c =>
     c.reduce((n, s) => n + M.sectionWeight(s), 0)).join(","), "12,15,12"],
  ["columns lose nothing",  M.settingsColumns(2).flat().length, M.SETTINGS.length],
  ["no column is empty",    M.settingsColumns(3).every(c => c.length > 0), true],
  ["more columns than sections", M.settingsColumns(99).length, M.SETTINGS.length],
  ["entry from the layout", JSON.stringify(M.entryFor({layout: {right: [{id: "other"}, {id: "t", demo: true}]}}, "t")), '{"id":"t","demo":true}'],
  ["entry from any section", M.entryFor({layout: {center: [{id: "t", mapZoom: 12}]}}, "t").mapZoom, 12],
  ["a clone's entry counts", M.entryFor({layout: {left: [{id: "t#2", demo: true}]}}, "t").demo, true],
  ["missing entry is bare", JSON.stringify(M.entryFor({layout: {right: []}}, "t")), '{"id":"t"}'],
  ["no config is bare",     JSON.stringify(M.entryFor(null, "t")), '{"id":"t"}'],
  ["defaults read off a bare entry", M.readSetting(M.entryFor(null, "t"), "showMap"), true],
]
// The marker is the viewport centre, so the tile under it must contain the
// car's own tile coordinate at that spot.
const grid = M.tileGrid(52.0907, 5.1214, 16, 380, 240)
const n = 2 ** 16, fx = (5.1214 + 180) / 360 * n
const lr = 52.0907 * Math.PI / 180, fy = (1 - Math.log(Math.tan(lr) + 1 / Math.cos(lr)) / Math.PI) / 2 * n
const under = grid.find(t => t.left <= 190 && t.left + 256 > 190 && t.top <= 120 && t.top + 256 > 120)
cases.push(["tiles cover the viewport", grid.every(t => t.left > -256 && t.top > -256 && t.left < 380 && t.top < 240) && grid.length >= 4, true])
cases.push(["centre tile is the car's", under && under.x === Math.floor(fx) && under.y === Math.floor(fy), true])
cases.push(["tiles wrap the antimeridian", M.tileGrid(0, 179.99, 2, 512, 256).every(t => t.x >= 0 && t.x < 4), true])
let failed = 0
for (const [name, got, want] of cases) {
  if (got === want) console.log("  ✓ " + name)
  else { failed++; console.error(`  ✗ ${name}\n     want: ${JSON.stringify(want)}\n     got:  ${JSON.stringify(got)}`) }
}
process.stdout.write(`__node ${cases.length - failed} ${failed}\n`)
process.exit(failed ? 1 : 0)
JS

echo
echo "$PASS shell checks passed, $FAIL failed (node counts are above)"
(( FAIL == 0 ))
