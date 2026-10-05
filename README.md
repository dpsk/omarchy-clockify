# omarchy-clockify

A minimal [Clockify](https://clockify.me) time tracker for the
[Omarchy](https://omarchy.org) bar. It shows the running timer in the bar and
opens a small popup with three things:

- **Current**: what's running, for how long, and a Stop button.
- **New**: a description and an optional project. Press Enter to start.
- **Recent**: your last few distinct entries. Click one to restart it.

That's the whole app. It's a native Omarchy shell plugin, so it follows your
theme and fonts. It keeps no daemon running and has no dependencies beyond
Python's standard library.

<img src="screenshot.png" alt="Clockify panel open under the Omarchy bar, showing a running timer and recent entries" width="420">

## Install

```bash
omarchy plugin add https://github.com/dpsk/omarchy-clockify.git --enable
```

Then click the timer icon in the bar and choose **Set up API key**. Or run the
setup directly:

```bash
python3 ~/.config/omarchy/plugins/dpsk.clockify/clockify.py setup
```

Setup asks for an API key (create one under Clockify → **Profile settings →
API**), checks it against Clockify, lets you pick a workspace if you have more
than one, and saves it to `~/.config/omarchy/clockify.json` with mode `600`.

### Hotkey

Plugins can't register keybindings themselves. To open the panel with
<kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd>, add this to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "Clockify", "omarchy-shell dpsk.clockify toggle")
```

## Usage

| Where | Input | Action |
|---|---|---|
| Bar icon | Left click | Open or close the panel |
| Bar icon | Middle click | Stop the running timer |
| Description field | <kbd>Enter</kbd> | Start the timer (or restart the highlighted recent entry) |
| Description field | <kbd>↑</kbd> / <kbd>↓</kbd> | Highlight a recent entry |
| Description field | <kbd>Tab</kbd> | Open the project picker |
| Project picker | Type, <kbd>↑</kbd>/<kbd>↓</kbd>, <kbd>Enter</kbd> | Filter and choose a project |
| Project button | Right click | Clear the selected project |
| Anywhere | <kbd>Esc</kbd> | Close the panel |

IPC:

```bash
omarchy-shell dpsk.clockify toggle    # also: open, close
omarchy-shell dpsk.clockify stop
omarchy-shell dpsk.clockify refresh
omarchy-shell dpsk.clockify status    # "1:23 Writing docs · Project" or "idle"
```

The helper also works as a standalone CLI. It prints JSON:

```bash
clockify.py status [--light]
clockify.py cached            # last snapshot from disk, no network
clockify.py start "Writing docs" [projectId]
clockify.py stop
```

If your workspace requires a project or a description, the panel follows
those rules: Start stays disabled until the required field is filled in.
Clockify would accept such an entry at start, but it would then refuse to stop
it.

## Settings

| Setting | Where | Default |
|---|---|---|
| `refreshIntervalSec` | the widget's entry in `~/.config/omarchy/shell.json` | `30` |
| `workspaceId` | `~/.config/omarchy/clockify.json` | your active workspace |
| `region` | `~/.config/omarchy/clockify.json` | `global` (`eu`, `us`, `uk`, `au` for regional data residency) |

```bash
omarchy bar set dpsk.clockify refreshIntervalSec 60 --json
```

## Resource use

- **Opening is instant.** The popup draws whatever is already in memory and
  never waits on the network. At startup, the last snapshot is read from disk
  (~40 ms), so Recent and projects are ready even right after login.
- **Refreshing happens in the background.** While the popup is closed, the bar
  makes one small request every `refreshIntervalSec` through a short-lived
  Python process that exits right away. A full refresh (recent entries,
  projects, workspace rules) runs only when something changed: a timer was
  started or stopped here or on another device, or the data is more than a
  minute old when you open the popup. Its requests go out in parallel, so it
  costs about one round trip to Clockify.
- After errors, polling backs off up to 5 minutes.
- The bar label updates once a minute, and only while a timer is running.
- The popup's contents are created when it opens and destroyed when it closes.

## What this plugin can access

- **Network**: only Clockify's API hosts (`api.clockify.me` or the regional host you choose).
- **Files**: reads `~/.config/omarchy/clockify.json`, and reads and writes `~/.cache/omarchy-clockify/` (your recent entries and projects, so the popup opens instantly).
- **Your Clockify account**: whatever your API key allows. The plugin only
  reads your user, workspaces, projects, and your own time entries, and only
  creates or stops your own time entries.

The API key never enters the shared QML scene, never shows up on a command
line, and is never printed. See [SECURITY.md](SECURITY.md) for the full
threat model.

## Development

```bash
git clone https://github.com/dpsk/omarchy-clockify.git
ln -s "$PWD/omarchy-clockify" ~/.config/omarchy/plugins/dpsk.clockify
omarchy plugin enable dpsk.clockify --section right
python3 -m unittest discover tests
```

Saved changes hot-reload in the running shell.

## License

MIT
