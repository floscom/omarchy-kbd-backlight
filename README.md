# omarchy-kbd-backlight

An Omarchy shell plugin that drives the keyboard backlight from the laptop's
ambient light sensor, with a bar widget for tuning it.

Built for a MacBook running Omarchy (`applesmc` LED + `acpi-als` sensor), but
the hardware is discovered by glob, so any machine exposing a
`*kbd_backlight*` LED and an IIO `in_illuminance_raw` sensor works unchanged.

## What it does

- Polls the ambient light sensor and maps the reading onto a backlight level:
  bright room, dim keyboard; dark room, bright keyboard.
- Smooths the sensor with an exponential moving average so a hand passing over
  it, or a flickering bulb, doesn't pump the LED.
- Ramps changes over ~8 steps instead of snapping.
- Re-asserts the level after a resume from sleep, which Omarchy's
  `system-sleep` hook zeroes.
- Falls back to a plain manual level when no sensor is present.

## Requirements

| Dependency | Why | Notes |
|---|---|---|
| `brightnessctl` | the only way this writes to the LED | ships in Omarchy's base package set |
| a `*kbd_backlight*` LED | the thing being controlled | `ls /sys/class/leds/` |
| an IIO ambient light sensor | optional | without one the plugin falls back to a manual level |

Nothing else. No daemon, no suid binary, no udev rule, no Python.

## Install

```bash
omarchy plugin add https://github.com/floscom/omarchy-kbd-backlight.git --enable --yes
omarchy bar move floscom.kbd-backlight --section right
```

Or, for local development, symlink the checkout and rescan:

```bash
ln -s ~/Dev/omarchy-kbd-backlight ~/.config/omarchy/plugins/floscom.kbd-backlight
omarchy-shell shell rescanPlugins
omarchy plugin enable floscom.kbd-backlight
```

`inotifywait` does not follow the symlink, so edits under `~/Dev` need an
explicit `omarchy-shell shell rescanPlugins` to take effect. A real checkout in
`~/.config/omarchy/plugins/` hot-reloads on save.

## Removal

```bash
omarchy plugin remove floscom.kbd-backlight --yes
```

That takes the widget out of the bar and deletes the checkout. The plugin
stores nothing outside its own entry in `~/.config/omarchy/shell.json`, which
`omarchy plugin remove` clears, so there is nothing else to clean up.

The keyboard backlight keeps whatever level it was last set to. To reset it:

```bash
brightnessctl -d smc::kbd_backlight set 0
```

For a symlinked development checkout, remove the link and rescan instead:

```bash
omarchy plugin disable floscom.kbd-backlight
rm ~/.config/omarchy/plugins/floscom.kbd-backlight
omarchy-shell shell rescanPlugins
```

## Using it

| Where | Action | Effect |
|---|---|---|
| Bar icon | left click | open the panel |
| Bar icon | right click | toggle auto on/off |
| Bar icon | scroll | adjust the level (drops out of auto) |
| Panel | `j` / `k` | move between rows |
| Panel | `h` / `l` | adjust the focused row |
| Panel | `a` | toggle auto |
| Panel | `enter` | on a threshold row, adopt the current sensor reading |

The icon dims in step with the actual backlight, so the bar shows the state
without spending room on a percentage.

### Calibrating the thresholds

`acpi-als` reports raw units, not calibrated lux — the numbers mean whatever
your sensor says they mean. The panel prints the live reading and puts a
**use `<n>`** button next to each threshold, so the way to set them is to sit
in the light you care about and click the button:

- **Dark below** — at or under this, the backlight sits at the *In the dark* level.
- **Bright above** — at or over this, it sits at the *In bright light* level.

Between the two the level follows a `t^0.55` ramp, which spends most of its
travel near the dark end where the eye actually notices the difference.

## Settings

All of them live inline on the widget's entry in
`~/.config/omarchy/shell.json` and are editable from the panel.

| Key | Default | Meaning |
|---|---|---|
| `auto` | `true` | follow the sensor |
| `manualPercent` | `40` | level used when `auto` is off |
| `maxPercent` | `100` | level at or below `luxDark` |
| `minPercent` | `0` | level at or above `luxBright` |
| `luxDark` | `5` | raw sensor units treated as darkness |
| `luxBright` | `150` | raw sensor units treated as bright |
| `pollIntervalMs` | `2000` | sensor poll interval |
| `smoothing` | `0.65` | EMA weight kept from the previous reading |

The **Response** row sets `pollIntervalMs` and `smoothing` together:
Slow `4000 / 0.8`, Normal `2000 / 0.65`, Fast `1000 / 0.35`.

## IPC

```bash
omarchy-shell floscom.kbd-backlight status       # "40% · 16 lx · auto"
omarchy-shell floscom.kbd-backlight toggleAuto
omarchy-shell floscom.kbd-backlight up           # +10%, drops out of auto
omarchy-shell floscom.kbd-backlight down
omarchy-shell floscom.kbd-backlight toggle       # the panel
```

`up` / `down` are the things to bind to `XF86KbdBrightnessUp` / `Down` in
`~/.config/hypr/bindings.lua` if you want the function keys to work too.

## Layout

| File | Role |
|---|---|
| `manifest.json` | plugin declaration; `service` + `bar-widget` |
| `Model.js` | the curve, the EMA, the ramp, parsing — no QML, no I/O |
| `Service.qml` | singleton: polls the sensor, owns every write to the LED |
| `Panel.qml` | bar icon, popup, settings round-trip |

### Why a service *and* a widget

A bar widget is instantiated once per monitor. Three copies racing to set one
LED would fight on every ramp step, so the hardware work lives in a `service`,
which the shell mounts exactly once. Settings go the other way: they live
inline on the widget's `shell.json` bar entry, which only the widget can read
and write, so the widget pushes them into the service.

### Why `brightnessctl`

`/sys/class/leds/*/brightness` is root-owned. `brightnessctl` falls back to
logind's `SetBrightness` over D-Bus, which polkit grants to the active session,
so the plugin needs no suid binary and no udev rule.

## License

MIT
