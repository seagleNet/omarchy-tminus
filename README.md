# omarchy-tminus

An [Omarchy](https://omarchy.org/) bar widget for [tminus](https://github.com/seagleNet/tminus)
(`t-`): the running countdown in your bar, which you can pause, skip, stop and
stretch without opening its window.

It follows `t- ctl status --follow`, so it shows the newest timer, with or
without a window, including `--headless` ones that live only in the bar.
It hides itself while no timer runs.

## Install

Needs tminus 0.3 or later (`cargo install tminus`).

```sh
omarchy plugin add https://github.com/seagleNet/omarchy-tminus.git --enable
```

Move it with `omarchy bar move io.github.seaglenet.tminus --section right`,
update it with `omarchy plugin update io.github.seaglenet.tminus`.

## Using it

| Action | Effect |
|---|---|
| Left click | pause / resume; starts the next segment while one waits (`--confirm`); dismisses a finished timer |
| Middle click | next segment |
| Right click | stop |
| Scroll up / down | add / take time (`step`, 1 minute by default) |
| Hover | title, segment, what comes next, the timer's name |

Paused timers are dimmed; the final seconds and a finished timer use the
theme's urgent color. On a vertical bar it shows only the icon.

## Settings

Set them on the widget's entry in `~/.config/omarchy/shell.json` (it reloads on save):

```json
{ "id": "io.github.seaglenet.tminus", "step": "5m", "start": "25m:work 5m:break x4 --notify" }
```

| Key | Default | Meaning |
|---|---|---|
| `command` | `t-` | The tminus binary, if the login shell's `PATH` doesn't have it (e.g. `~/.cargo/bin/t-`) |
| `name` | | Follow only the timer with this name (`t- -n NAME`); empty follows the newest |
| `step` | `1m` | Time added or taken per scroll notch |
| `start` | | If set, an icon stays in the bar while no timer runs; clicking it runs `t- <start> --headless` |

The widget may be added more than once, e.g. one per named timer.

## License

MIT
