# Tessie

A bar widget that shows where your Tesla is and lets you control it, through
[Tessie](https://tessie.com). Click the Tesla **T** in the bar for a map of the
car, its battery and vitals, and toggles for the locks, climate, sentry and
charge port.

![Tessie](preview.png)

- **Plugin ID:** `io.github.kimm-stensborg.tessie`
- **Kind:** `bar-widget`
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`, and a
  [Tessie](https://tessie.com) account with an API token

## Dependencies

All present on a stock Omarchy install:

| Package | Used for |
|---------|----------|
| `curl` | every request to Tessie, its status page and the map tiles |
| `jq` | reading and writing JSON in `bin/tessie` |
| `libsecret`, `gnome-keyring` | `secret-tool`, which keeps the token in your keyring |

Without a keyring the token goes to a private file instead (see
[What it writes](#what-it-writes)). The tests also need `python` and
`nodejs`; `nodejs` is not on a stock install (`omarchy pkg add nodejs`).

## Install

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-tessie.git
omarchy plugin enable io.github.kimm-stensborg.tessie
```

`omarchy plugin add` clones into
`~/.config/omarchy/plugins/io.github.kimm-stensborg.tessie/` and leaves the
plugin disabled so the code can be read before it runs. Plugins execute
unsandboxed inside `omarchy-shell`. Add `--enable --yes` to skip every prompt.

Enabling it puts the **T** in the right section of the bar. To move it:

```bash
omarchy bar move io.github.kimm-stensborg.tessie --after omarchy.tray
```

Then connect your Tessie account:

1. Create an API token at <https://dash.tessie.com/settings/api>.
2. Click the **T** and choose **Set up Tessie token**, or run:

   ```bash
   ~/.config/omarchy/plugins/io.github.kimm-stensborg.tessie/bin/tessie login
   ```

The token is checked against Tessie before it is stored. The first car on the
account is shown unless you set `vin` (see [Settings](#settings)).

To update:

```bash
omarchy plugin update io.github.kimm-stensborg.tessie
omarchy restart shell
```

## Remove

```bash
~/.config/omarchy/plugins/io.github.kimm-stensborg.tessie/bin/tessie logout
omarchy plugin remove io.github.kimm-stensborg.tessie
rm -rf ~/.cache/omarchy-tessie
```

`logout` first: it deletes the token from your keyring (or its file) and the
cached VIN, which `omarchy plugin remove` does not touch. Revoke the token at
<https://dash.tessie.com/settings/api> as well if you no longer use it.

## Usage

| On the **T** | Does |
|--------------|------|
| left click | open or close the panel |
| middle click | refresh |
| right click | open the car's position in a maps app |

Or open it from a script or a key:

```bash
omarchy-shell shell toggle io.github.kimm-stensborg.tessie '{}'
```

```lua
o.bind("SUPER + CTRL + T", "Tessie", "omarchy-shell shell toggle io.github.kimm-stensborg.tessie '{}'")
```

If you pick a key that is already taken, put `hl.unbind("<key>")` on the line
before it.

## Keys

| Key | Does |
|-----|------|
| `r` | refresh |
| `m` | open the car's position in a maps app |
| `Tab` / `Shift+Tab` | move to the next or previous bar panel |
| `Esc` | close |

## The panel

- the car's name, and a dot for what it is doing: driving, parked, charging
  or asleep. An unnamed car shows its model.
- a map centred on the car. Scroll to zoom, click to open it in a maps app.
- the address, plus the speed or the charging power and time to full
- battery level and range, with a tick at the charge limit
- locked, sentry, odometer, tyres, inside and outside temperature, charge
  limit, last charge, climate and software version
- toggles for **lock**, **climate**, **sentry** and **charge port**, plus
  **flash** and **honk**. Unlocking asks for a second click.
- a footer with Tessie's service status from
  [status.tessie.com](https://status.tessie.com), when Tessie last heard from
  the car, and links to tessie.com and the status page

Reading never wakes the car: the widget asks for Tessie's cached state, so
polling costs no battery. Only the control buttons wake it. It polls every
`refreshMinutes` while the panel is closed and every 30 seconds while it is
open.

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`:

| Key              | Default                  | Meaning                                     |
|------------------|--------------------------|---------------------------------------------|
| `name`           | the car's name, or model | Panel heading                               |
| `vin`            | first car on the account | Which car to show                           |
| `units`          | follows the car          | `metric` or `imperial`                      |
| `refreshMinutes` | `5`                      | Poll interval while the panel is closed     |
| `mapZoom`        | `16`                     | Starting map zoom, 3 to 16 (19 with a key)  |
| `cartoKey`       | none                     | Use CARTO's basemaps, see [Map](#map)       |
| `mapsUrl`        | Google Maps              | Maps link template with `{lat}` and `{lon}` |
| `demo`           | `false`                  | Show a made-up car and never call Tessie    |

For example:

```bash
omarchy bar set io.github.kimm-stensborg.tessie name "Sparky"
omarchy bar set io.github.kimm-stensborg.tessie demo true --json
omarchy bar set io.github.kimm-stensborg.tessie mapsUrl "https://www.openstreetmap.org/?mlat={lat}&mlon={lon}#map=17/{lat}/{lon}"
```

## Map

Out of the box the map uses Esri's gray Canvas basemap, which needs no
signup. For CARTO's darker, sharper basemap, and zoom up to 19, get a free
key at <https://carto.com/basemaps/apikey>. It is emailed to you straight
away and is meant for non-commercial use. Then:

```bash
omarchy bar set io.github.kimm-stensborg.tessie cartoKey "your-key"
```

## What it writes

- the token: in your keyring as `service tessie`, or, without a keyring, in
  `~/.config/omarchy-tessie/token` with mode 0600
- `~/.cache/omarchy-tessie/vin`: the VIN found on the account, so it is looked
  up once
- the settings above, in `~/.config/omarchy/shell.json`, when you set them

Nothing else on the system is touched. It contacts:

- `api.tessie.com`: the car's state, and the commands you send
- `status.tessie.com`: Tessie's service status, when the panel opens and at
  most every two minutes
- `server.arcgisonline.com`, or `basemaps.cartocdn.com` with a CARTO key: map
  tiles

With `demo` on, no request goes to `api.tessie.com`.

## Command line

Everything the widget does goes through `bin/tessie`, so you can run it by
hand. `state` and `command` always print one JSON object.

```
bin/tessie login              store a Tessie API token
bin/tessie logout             forget it
bin/tessie vin                print the VIN in use
bin/tessie state              one JSON snapshot of the car
bin/tessie command lock       lock, unlock, start_climate, stop_climate, flash,
                              honk, enable_sentry, disable_sentry,
                              open_charge_port, close_charge_port
```

`TESSIE_VIN` picks another car, and `TESSIE_DEMO=1` answers with the made-up
car.

## Files

| Path | What |
|------|------|
| `BarWidget.qml` | the bar button, with the Tesla **T** drawn on a canvas |
| `Panel.qml` | the panel: map, vitals, controls, footer |
| `Model.js` | units, formatting, status, controls and map tile math |
| `bin/tessie` | `login`, `state` and `command`: the only code that talks to Tessie or touches the token |
| `test.sh` | the tests |

## Developing

Work in a clone of the repository and bring commits into the installed copy
without going through GitHub:

```bash
git -C ~/.config/omarchy/plugins/io.github.kimm-stensborg.tessie pull ~/Projects/omarchy-tessie main
omarchy restart shell
```

Do not edit the installed copy itself: `omarchy plugin update` refuses to
fast-forward over local changes.

A rescan does not pick up changed QML or `Model.js`: the shell keeps compiled
components cached, so run `omarchy restart shell` after changing them.
`bin/tessie` runs fresh every time. Turn on `demo` to work on the panel
without a car.

## Tests

```bash
./test.sh
```

The tests run `bin/tessie` against a local mock of the Tessie API, and the
helpers in `Model.js` under node. They use a throwaway config and cache and
skip the keyring, so no test touches the real API, your keyring or your
stored token.

Map tiles © Esri, HERE, Garmin and
[OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, or with
a key © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors
© [CARTO](https://carto.com/attributions).
