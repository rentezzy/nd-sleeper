# Hardware findings

Measured on a MacBook Air M4 (Mac16,12, fanless) running macOS 26.7, with any external display unplugged, using throwaway probe tools that are no longer in the repo.

## Kernel sleep flag

- Without an external display, only the kernel `SleepDisabled` flag keeps the Mac awake with the lid closed.
- The flag is global, root-only and survives reboot.
- While set it blocks all sleep, including idle sleep and Apple menu Sleep. The display still sleeps.
- `pmset -g` omits `SleepDisabled` when it is off. Read it and `AppleClamshellState` from the `IOPMrootDomain` registry entry instead.
- `IOPMSetSystemPowerSetting("SleepDisabled", …)` is exported by IOKit but has no header, so it is loaded with `dlsym`. It accepted `kCFBooleanTrue` and `kCFBooleanFalse` on the first try.
- The call returns in 0.4 to 3 ms and the registry reflects the new value 7 to 15 ms after the request.
- `pmset -a disablesleep` takes about 70 ms for the same change.

## Event order

- Lid close with the flag off: the clamshell message `0xE0034100` arrives first with the closed and causes-sleep bits set, then `kIOMessageSystemWillSleep` 20 to 45 ms later (23 ms and 40 ms in two runs).
- WillSleep from a clamshell close is not vetoable.
- The causes-sleep bit is set even when the flag is on, so it does not predict sleep.
- Unplug with the lid closed and the flag on: the Mac stays awake, a repeated clamshell message arrives, then the power-source notification 18 ms later.
- `kIOPSNotifyPowerSource` (`com.apple.system.powersources.source`) fires only on AC and battery changes.
- The general `IOPSNotificationCreateRunLoopSource` also reports capacity and time-remaining changes, including while charging, so it must not be armed on AC. Its AC wakeup rate was not measured.
- Constants spelled out because function-like macros are not imported into Swift: clamshell change `0xE0034100`, CanSystemSleep `0xE0000270`, WillSleep `0xE0000280`, WillNotSleep `0xE0000290`, HasPoweredOn `0xE0000300`, WillPowerOn `0xE0000320`.

## Sleep latency

- Forced sleep works by clearing the flag and then calling `IOPMSleepSystem` or `pmset sleepnow`, with no gap needed between the two.
- The Mac enters sleep 5 to 10 s after a sleep request.
- Lid close on battery with the flag off reached "Clamshell Sleep" in `pmset -g log` about 5 s after WillSleep.

## Dark wakes

- After a sleep request the Mac often dark-wakes for network maintenance and `SleepService` requests, typically for about 2 s.
- User processes run during a dark wake with the screen off.
- A process cannot tell a dark wake from a full wake by its own clocks. `pmset -g log` is authoritative.
- A `sudo` ticket expires across long sleeps.

## T3 Code database

- `~/.t3/userdata/statev2.sqlite` runs in WAL mode. Watching `statev2.sqlite-wal` plus the parent directory catches every write and WAL recreation.
- While agents stream, T3 writes about 40 times a second.
- A 1 s throttle turned 10,207 file events into 42 queries.
- The probe's three queries together (active runs, pending requests and the working check) took 0.8 to 4.5 ms using the existing partial indexes. The working check alone is a subset of that.
- A turn waiting on a user question stays `running` and adds a `pending | user_input` row in `orchestration_v2_projection_runtime_requests`, which the query excludes.
- A parent waiting on a delegated subagent completes its own run while the child runs, then starts a new run when the child finishes, so there is no idle gap.
- A permission approval prompt was not observed. It is expected to show as a pending request too.
- The database must be opened as the user. Opening it as root would create root-owned `-shm` files.

## External display detection

- With a monitor attached, macOS clamshell mode keeps the Mac awake on its own, so every lid test needs the monitor unplugged.
- Detection: count `Resolution:` lines in `system_profiler SPDisplaysDataType` and subtract `Connection Type: Internal` lines.

## Option B, setting the flag after the lid closes

- Setting the flag 0, 1 or 3 s after the lid event cancelled the clamshell sleep in all six trials, on AC and on battery, including two trials that held the WillSleep ack for 5 s.
- `pmset -g log` recorded no Sleep entry for those trials, only display off and on, plus a 5.4 s ack delay from the probe for the held trials.
- With no added delay the rescue flag landed 8.5 to 22 ms after the clamshell message across four trials.
- macOS had already broadcast WillSleep to every app and sent the matching wake only when the lid reopened, up to 61 s later. Apps such as T3 and network clients may pause in that window.
- Benefit: the T3 watch could stay off while the lid is open, with one query at lid close instead.
- Not adopted. The shipped design sets the flag before the lid closes and watches T3 on battery. Whether an agent keeps streaming through a late rescue is untested.
