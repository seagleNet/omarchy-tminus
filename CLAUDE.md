# CLAUDE.md

An Omarchy shell bar-widget plugin for tminus (`t-`, repo
https://github.com/seagleNet/tminus); see README.md for what it does, its
settings and the commands CI runs. Load the `omarchy` skill when working here;
its `plugins.md` has the shell's plugin conventions. Where it disagrees with
this file about reloading, this file was tested. Things that are easy to get
wrong:

- **Reloading:** saving a file restarts the widget with the QML the shell
  already loaded, even after `omarchy-shell shell reloadPlugins`. Copy the
  files over `~/.config/omarchy/plugins/seaglenet.tminus/` (symlinks are
  refused) and run `omarchy restart shell`. Check a change with something that
  differs while a timer runs: the idle hourglass looks the same in every
  version.
- **What it depends on in tminus:** `t- ctl status --follow` (JSON: `text`,
  `tooltip`, `class`, `name`), `t- ctl list --json`, `t- ctl -n NAME <cmd>`,
  `t- ctl attach`, `t- --check`, and `COMPLETE=fish t- -- t- <args>`
  (`candidate<TAB>description` lines). Changing any of them in tminus breaks
  the widget; `tests/logic.test.mjs` holds copies of the output.
- **Never a shell:** typed words and anything from `t-` (names, pids) reach
  processes only as arguments: `bash -lc 'exec "$@"'` (`Util.execArgv`), or a
  fixed script with positional `$1`/`$2`. Text from `t-` is shown with
  `Text.PlainText`. The only shell strings are the user's own `shell.json`
  settings.
- **Logic.js** is a `.pragma library` file with pure functions; the tests load
  it under node. Keep processes, models and Omarchy imports in `BarWidget.qml`.
- **Bar API:** third-party widgets get a stand-in `bar` (`PluginBarApi`), not
  the real bar: use its colors and `showTooltip`, not `bar.run`
  (`Util.execArgv` / `Util.execDetached` instead).
- **Colors on `WidgetButton`** animate (160 ms `Behavior on color`): change
  them in steps and let that transition fade, never per frame.
- **The popup** is a `KeyboardPanel`, not a `PopupCard`: the start field needs
  the keyboard as soon as it opens. Timer rows are a `ListModel` updated in
  place; replacing the model every second would rebuild the rows under the
  mouse.
- **Glyphs:** Material Design icons from the Nerd Font, written with
  `String.fromCodePoint` (no literal glyphs or other non-ASCII in the source).
- QML uses `var`, like Omarchy's own shell; `.qmllint.ini` turns that warning
  and `MissingProperty` (Omarchy types the bar and `Style.font`/`spacing` as
  plain `QtObject`) off, and fails on any other. Format QML and JS with
  `qmlformat` (settings in `.qmlformat.ini`). Run `node --test tests` for every
  change to `Logic.js`.

## Testing in the live session

Start timers with `setsid t- ... --headless </dev/null >/dev/null 2>&1 &` (a
plain background job dies with the command). Screenshot the bar with
`grim -g "X,Y WxH"`; the popup can't be opened without a real right click, so
ask the user to open it, and screenshot after a delay. `console.log` from the
widget lands in `journalctl --user -t omarchy-shell`.

## Releasing

`omarchy plugin add` and `update` install `master`'s newest commit, and the
marketplace listing is verified for one exact commit. So `master` only moves on
a release, and stays on the verified commit in between:

- Work on `dev`; merge into `master` only to release.
- A release bumps `version` in `manifest.json`, then gets a `vX.Y.Z` tag and a
  GitHub release. If it needs a newer tminus, release tminus first and update
  the README's requirements.
- Right after pushing `master`, submit the new commit through the
  [Plugin verification form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml),
  choosing "Verify and publish a newer upstream commit". Until it is approved,
  the listing shows "Update unverified".
- Plugin IDs are permanent and must be lowercase.
