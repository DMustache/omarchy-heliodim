# heliodim

Laptop screen brightness that follows the sun. One static Zig binary (~230 KB,
~0.8 MB RSS, one thread) and no dependencies beyond `brightnessctl`.
It works alongside Omarchy's night light (hyprsunset changes colour, heliodim
changes brightness).

## How it works

- **Sun**: the same subsolar-point formula Omarchy's Elsewhen clock draws its
  daylight strip with, so the two agree on sunrise. Clear-sky irradiance is
  Haurwitz; the curve is `min + (max-min) * sqrt(GHI/1000)`.
- **Schedule, not polling**: at start it reads `max_brightness`. One step
  (`step`%, default 1%) becomes a raw delta, e.g. 655 of 65535 on amdgpu.
  After each change it finds the next minute when the target is one step away
  and arms a wall-clock `timerfd` for that moment. Nights are a single sleep
  until dawn. Suspend and clock changes are handled by the timer itself.
- **Hand changes win**: the kernel raises `POLLPRI` on `actual_brightness`
  after every set, so brightness keys are seen immediately. Once they stop for
  2 s, heliodim keeps `pct - curve` as an offset (the curve keeps moving, your
  correction rides on it). It also appends one line to
  `~/.local/state/heliodim/events.jsonl`:

  ```json
  {"t":1794414004,"pct":88.00,"curve":95.00,"offset":-7.00,"elev":-23.75,"az":273.5,"clear":0}
  ```

  `elev`/`az`/`clear` are the sun's state at that moment, kept as data for
  learning cloudy-day corrections later. The last offset survives restarts.
- **Writes** go through `brightnessctl` → logind, so no root or udev rules.
  Big gaps (start, resume) ramp in at most 10 steps. A screen at 0 is left alone.

## Location

First match wins; nothing goes to the network:

1. `lat` / `lon` in `~/.config/heliodim/config`
2. the "here" city of the Elsewhen clock (`~/.config/omarchy/shell.json`),
   while the system time zone is still that city's zone
3. `omarchy-weather-location --set NAME LAT,LON`
4. the time zone's reference city (`/etc/localtime` → `zone1970.tab`)

## Config

`~/.config/heliodim/config`, all optional:

```ini
lat = 55.75
lon = 37.62
min = 10      # % at night
max = 100     # % at the top of the curve
step = 1      # % per change
device = amdgpu_bl1
```

## Install

On Omarchy, add and enable the plugin:

If you installed an earlier systemd service, first run
`systemctl --user disable --now heliodim`.

```sh
omarchy plugin add https://github.com/DMustache/omarchy-heliodim --enable
```

The plugin includes static Linux binaries for x86_64 and aarch64 and starts the
right one automatically. You need no Zig or separate installer; Omarchy already
provides `brightnessctl`. To check the daemon:

```sh
~/.config/omarchy/plugins/dmustache.heliodim/bin/heliodim status
```

## Uninstall

```sh
omarchy plugin remove dmustache.heliodim
```

Omarchy disables the plugin and removes its bundled daemon. Your config and
hand-change log remain in `~/.config/heliodim` and
`~/.local/state/heliodim`; remove those directories too if you want to erase
your settings and history.

## Build from source with Mise

The project pins Zig 0.17.0 in `mise.toml`:

```sh
mise install
mise exec -- zig build test
mise exec -- zig build -Drelease
```

Pushing a `v*` tag creates a GitHub release with both Linux binaries and their
SHA-256 checksums. CI checks that the binaries bundled in the plugin match the
source builds.

## Bar widget

`widget/BarWidget.qml` shows where the sun stands as a 12×12 pixel icon in
the bar's text color: stars at night, a sliver at twilight, a half disc at
sunrise, a disc that climbs, rays near 90°. Mornings put the sun on the left,
evenings on the right.

- **Left click** opens the panel: today's sky with sunrise, noon and sunset,
  the brightness on screen against the plain sun curve, your offset, the next
  step and the location.
- **Middle click**, or **Pause** in the panel, leaves brightness to you until
  the next sunrise or sunset; again to resume.
- **Forget offset** returns to the plain curve.

The daemon writes its state to `$XDG_RUNTIME_DIR/heliodim.json` on every
change; the widget reads it and computes the sun itself with the same
formula. The same controls work from a terminal:

```sh
~/.config/omarchy/plugins/dmustache.heliodim/bin/heliodim pause  # until the next sunrise or sunset; again to resume
~/.config/omarchy/plugins/dmustache.heliodim/bin/heliodim reset  # forget your offset
```

## Art and site

`assets/gen.py` holds the pixel art as text maps: the logo (on the Omarchy
wordmark's block grid) and the bar icon's sun states, morning and evening.
It writes `assets/logo.svg`, `assets/sun/*.svg`, `widget/Art.js` and the site page.
`site/publish.sh` builds the page and pushes it to the `gh-pages` branch;
the `pages` workflow runs it on every push to `main` that touches `assets/` or `site/`.
The `ci` workflow builds and tests the binary on every push and pull request.
