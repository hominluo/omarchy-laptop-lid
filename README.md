# Laptop Lid

An Omarchy shell plugin that decides what closing the laptop lid does, from the
bar: keep running, keep running only on AC, keep running only on battery, or
suspend normally.

![panel](docs/panel.png)

## Why this exists

The obvious way to keep a laptop awake with the lid shut is a `logind` drop-in:

```ini
# /etc/systemd/logind.conf.d/something.conf
[Login]
HandleLidSwitch=ignore
```

That is a system file, so every change needs root, and on a machine without a
polkit agent it means a password prompt in a terminal. It is also one-way: with
`ignore` set there is no way back to suspend without editing root files again.

`logind` asks inhibitors before it acts, so this plugin holds a
`handle-lid-switch` inhibitor instead:

```bash
systemd-inhibit --what=handle-lid-switch --mode=block \
  --who="Omarchy lid policy" --why="..." sleep infinity
```

No privileges, instant toggling, and the inhibitor lives exactly as long as the
process holding it. If the shell crashes or you log out, the lid goes back to
the stock behaviour instead of leaving a laptop cooking in a bag.

## Modes

| Mode | On AC | On battery |
| --- | --- | --- |
| Keep running | awake | awake |
| Keep running on AC | awake | suspend |
| Keep running on battery | suspend | awake |
| Suspend | suspend | suspend |

The first three are opt-in. Out of the box the plugin is in **Suspend**, exactly
logind's default (`HandleLidSwitch=suspend`), so merely installing it changes
nothing until a mode is picked. "Suspend" here means the normal sleep-to-RAM
(`s2idle` on modern laptops) — the same thing as `systemctl sleep` unless a
`SleepOperation=` is configured.

"Plugged in" is not UPower's `OnBattery`. That flag aggregates every
line-power device, USB-C/UCSI ports included, and a port whose `online`
attribute goes stale after the cable is pulled keeps it `false` forever — which
is how an "AC only" policy ends up holding the lid open on battery. The plugin
asks logind instead (`OnExternalPower`, the flag logind itself branches on),
and a battery that is reporting *discharging* overrides it, because a draining
pack means the machine is running on it whatever a port claims.

When logind is docked or sees an external display it uses
`HandleLidSwitchDocked` (default `ignore`) rather than the action above, so a
lid close keeps running in every mode. The panel says so instead of pretending
the machine will sleep.

The bar glyph is the chosen mode's glyph, the same one its row uses in the
panel: a laptop for **Keep running**, a plug for **Keep running on AC**, a
battery for **Keep running on battery**, and a "zzz" symbol for **Suspend**.
Colour carries no meaning — the bar's active colour is the urgent red, which
made a healthy "keep running" look like a fault and still left three of the four
modes looking identical. The tooltip names the mode and what it does on the
current power source, so "Keep running on AC" on battery reads as suspending.

## Lock on lid close

An inhibitor blocks `logind`'s whole lid action, including the lock-before-suspend
that Omarchy normally gets. Left alone, an awake closed lid would unlock on
open, so the plugin watches the ACPI lid switch itself and runs
`omarchy system lock` — except while an external display is connected (anything
that is not an internal eDP, LVDS or DSI output), because then closing the lid
is docking, not walking away. The toggle is in the panel.

Omarchy 4.5 already binds `switch:on:Lid Switch` to `omarchy-system-lid-close`,
which locks the same way and independently of any inhibitor. When that binding
is present the plugin recognises it, leaves the locking to it, and the toggle
reports what Omarchy is doing instead of offering a switch that could not turn
it off. The plugin's own lock remains the fallback for older installs.

The lid switch is read from `/proc/acpi/button/lid/*/state`, with a 3 second
poll whenever an inhibitor is held. procfs inotify is not dependable across
firmwares, so the timer is the safety net. The first sample after a shell
restart is treated as a baseline, so restarting the shell with the lid already
shut does not lock the screen.

## Requirements

- A laptop with an ACPI lid switch (`/proc/acpi/button/lid/*/state`).
- `systemd-inhibit` (systemd), `busctl` (systemd, for logind's live policy),
  `hyprctl` (Hyprland) and the `omarchy` CLI (used for `omarchy system lock`)
  — all already on Omarchy.
- **A lid action that actually sleeps.** The panel warns when logind's live
  policy makes a lid close do something else — `ignore`, `lock`, `poweroff`,
  `reboot`, `halt`, `kexec` — because that outranks the plugin and breaks the
  modes that rely on suspending. Remove the drop-in and
  `sudo systemctl reload systemd-logind` if this plugin replaced a manual fix.

## Install

```bash
omarchy plugin add https://github.com/hominluo/omarchy-laptop-lid --enable
```

or, for local development, point a checkout at the plugins directory (remove
the installed copy first, or the link path is taken):

```bash
rm -rf ~/.config/omarchy/plugins/io.github.hominluo.lid
ln -s ~/Github/Omarchy/omarchy-laptop-lid ~/.config/omarchy/plugins/io.github.hominluo.lid
omarchy restart shell
```

The plugin stores its choice in
`~/.local/state/omarchy/lid-policy/state.json` and re-applies it at shell start.

## Scripting

```bash
omarchy-shell io.github.hominluo.lid.ctl status
omarchy-shell io.github.hominluo.lid.ctl mode battery
```

`mode` accepts `awake`, `ac`, `battery` and `suspend` (case-insensitive) and
prints the resulting mode. An unknown value prints an `invalid mode:` line and
leaves the saved choice untouched.

`status` returns JSON, including `requested` (what the policy wants),
`inhibiting` (whether the inhibitor process is actually alive), `conflict`
(whether the live system policy keeps the lid from sleeping), `onBattery`,
`onExternalPower` and `batteryDischarging` (the inputs behind the per-source
modes), `lidAction` (what logind would do with a close right now), `docked`,
`nativeLidLock` and `policy` (the raw `HandleLidSwitch*` values logind reports).

## Files

| File | Purpose |
| --- | --- |
| `manifest.json` | Plugin manifest: one `bar-widget` entry point |
| `Panel.qml` | Bar item, panel, inhibitor process, state, lid watcher |

## Uninstall

`omarchy plugin remove io.github.hominluo.lid`. Stock lid behaviour returns by
itself — nothing outside your config was ever touched.

## License

MIT
