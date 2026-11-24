# nd-sleeper

Keeps a MacBook awake with the lid closed on AC, and on battery only while a T3 Code agent is working.

## Install

Requires an Apple Silicon Mac running macOS 15 or newer.

```sh
mise use -g github:rentezzy/nd-sleeper
nd-sleeper install
```

`install` asks for your password once. Run it again after upgrading.

## Automatic mode

- Lid closed on AC: stays awake, no external display needed.
- Lid closed on battery: stays awake while an agent works, for up to `battery_window` (30 minutes by default), then sleeps. Sleeps sooner when agents finish, at `battery_floor` (20% by default) or under serious thermal pressure. Sleeps right away if nothing is working.
- Unplugging with the lid closed follows the battery rules.
- An agent waiting for your answer or approval counts as not working.
- If nd-sleeper stops or crashes on battery, normal macOS sleep comes back on its own.

## Settings

Settings live in `~/.config/nd-sleeper/config.toml`. A missing file or key uses the default.

| Setting | Unit | Default | Allowed | Meaning |
| --- | --- | --- | --- | --- |
| `battery_window` | seconds | `1800` | 60 to 14400 | Longest the Mac stays awake with the lid closed on battery |
| `battery_floor` | percent | `20` | 1 to 99 | Battery level at which it sleeps anyway |

```toml
battery_window = 3600
battery_floor = 15
```

Run `nd-sleeper reload` after editing. If the file has an error, `reload` prints it and keeps the current settings.

## Commands

Durations look like `45m`, `2h` or `1h30m`, up to `30d`. Every command accepts `--help`.

### `status [--json] [--metrics]`

Shows the mode, uptime, power, lid, battery, thermal state, agents, whether sleep is blocked, the active settings and the helper connection. `--json` gives machine-readable output. `--metrics` adds event, query, CPU and wakeup counters since start.

### `hold [duration] [--force]`

Stays awake with the lid closed regardless of agents, until the duration ends or you run `auto`. On battery an untimed hold ends after 4 hours, and any hold ends at `battery_floor` or under serious thermal pressure unless you add `--force`.

### `normal [duration]`

Restores normal macOS sleep, on AC too, until the duration ends or you run `auto`.

### `auto`

Ends `hold` or `normal` and returns to automatic mode.

### `sleep`

Sleeps the Mac now and returns to automatic mode on wake. Use it instead of the Apple menu Sleep item, which does nothing while nd-sleeper blocks sleep.

### `reload`

Re-reads `~/.config/nd-sleeper/config.toml` and applies it right away. A running lid-closed window adopts the new length.

### `logs [--since duration] [--json]`

Shows past state changes with their reasons, wakes, settings reloads and the helper's safety actions, read from `~/Library/Logs/nd-sleeper/` (at most about 4 MB). Works while nd-sleeper is stopped. `--since 2h` shows only the last two hours. `--json` prints raw JSON lines.

### `install` and `uninstall`

`install` sets up or upgrades nd-sleeper and starts it. `uninstall` stops it, restores normal sleep and removes it, keeping your settings in `~/.config/nd-sleeper/` and your logs in `~/Library/Logs/nd-sleeper/`.
