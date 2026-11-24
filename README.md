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
- Lid closed on battery: stays awake up to 30 minutes while an agent works, then sleeps. Sleeps sooner when agents finish, at 20% battery or under serious thermal pressure. Sleeps right away if nothing is working.
- Unplugging with the lid closed follows the battery rules.
- An agent waiting for your answer or approval counts as not working.
- If nd-sleeper stops or crashes on battery, normal macOS sleep comes back on its own.

## Commands

Durations look like `45m`, `2h` or `1h30m`, up to `30d`. Every command accepts `--help`.

### `status [--json] [--metrics]`

Shows the current mode, power, lid, battery, thermal state, agents and whether sleep is blocked. `--json` gives machine-readable output. `--metrics` adds event, query, CPU and wakeup counters since start.

### `hold [duration] [--force]`

Stays awake with the lid closed regardless of agents, until the duration ends or you run `auto`. On battery an untimed hold ends after 4 hours, and any hold ends at 20% battery or under serious thermal pressure unless you add `--force`.

### `normal [duration]`

Restores normal macOS sleep, on AC too, until the duration ends or you run `auto`.

### `auto`

Ends `hold` or `normal` and returns to automatic mode.

### `sleep`

Sleeps the Mac now and returns to automatic mode on wake. Use it instead of the Apple menu Sleep item, which does nothing while nd-sleeper blocks sleep.

### `logs [--since duration] [--json]`

Shows past state changes with their reasons, readings and resource usage, read from `~/Library/Logs/nd-sleeper/`. Works while nd-sleeper is stopped. `--since 2h` shows only the last two hours. `--json` prints raw JSON lines.

### `install` and `uninstall`

`install` sets up or upgrades nd-sleeper and starts it. `uninstall` stops it, restores normal sleep and removes everything except `~/Library/Logs/nd-sleeper/`.
