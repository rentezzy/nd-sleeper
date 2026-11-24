# nd-sleeper

Keeps a MacBook awake with the lid closed on AC, and on battery only while AI agents are working.

> Early sketch. Nothing is implemented yet.

## Behavior

- Lid closed on AC: never sleeps, no external display needed.
- Lid closed on battery: stays awake up to 30 minutes while an agent is working, then sleeps. Sleeps earlier when agents finish, at 20% battery or under thermal pressure. Sleeps right away when nothing is working.
- No polling. On AC it does nothing until the power source changes. Agent sources are watched only on battery.

## CLI sketch

```
nd-sleeper status [--json] [--metrics]   current mode, power, lid, battery, agents, grace time left
nd-sleeper on [--for 2h]                 force awake with the lid closed
nd-sleeper off                           normal macOS sleep until `auto`
nd-sleeper auto                          back to automatic behavior
nd-sleeper sleep                         sleep now (Apple menu Sleep is disabled while active)
nd-sleeper logs [--last 1h]              state transitions and resource counters
nd-sleeper install | uninstall           set up or remove the root daemon (asks for sudo)
```

## How it works

A root LaunchDaemon owns the kernel `SleepDisabled` flag and listens to power, lid, wake and thermal events. Agent activity comes from pluggable sources, starting with T3 Code. Every state change is logged with resource counters to `/var/log/nd-sleeper/events.jsonl`.
