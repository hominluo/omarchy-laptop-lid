# Changelog

## 1.0.2

- `ctl status` now reports the live inhibitor process (`inhibiting`) separately
  from what the policy wants (`requested`), and includes `conflict` plus the
  parsed `policy`.
- `ctl mode` validates its argument, accepts any case, and prints an
  `invalid mode:` line instead of silently returning the current mode.
- State writes go through a private temp file and a rename, so a crash or rapid
  clicking cannot leave a truncated `state.json`. A slow state load can no
  longer overwrite a choice made right after the shell starts.
- The system-policy probe uses `systemd-analyze cat-config` and understands
  whitespace plus the `HandleLidSwitchExternalPower`/`Docked` variants. The
  warning now covers the AC and battery modes too, since they also depend on
  logind suspending when the plugin is not inhibiting.
- External-display detection recognizes LVDS and DSI internal panels, so
  lock-on-close is not skipped on non-eDP laptops.
- 0% battery is shown instead of being treated as "no reading".
- The lid poll runs whenever an inhibitor is held, keeping the panel's lid state
  truthful with the lock toggle off.

## 1.0.1

- Mode rows use outline glyphs (power plug, outline battery, "zzz" sleep) and
  the bar shows the sleep glyph when the lid will suspend, so the icon reads at
  14 px instead of collapsing into a filled blob.
- The lock-on-close row gets the same glyph column as the mode rows and a
  lock/unlock icon that follows the toggle.
- On plugin load, sweep away `systemd-inhibit` processes left behind by a
  crashed shell before starting a new one, so a stale inhibitor cannot silently
  keep a closed lid awake.

## 1.0.0

- Bar widget and panel to choose what closing the lid does: keep running on
  battery and AC, on AC only, on battery only, or stock suspend.
- Implemented with a `handle-lid-switch` logind inhibitor, so no root, no polkit
  prompt, no system config to maintain, and a crash falls back to suspend.
- Per-power-source switching: an "AC only" policy stops inhibiting the moment
  the charger is pulled, without a second action.
- Lock the screen when the lid closes, skipped while an external display is
  connected.
- Warns when a `HandleLidSwitch=ignore` drop-in outranks the plugin.
- `io.github.hominluo.lid.ctl` IPC: `mode <awake|ac|battery|suspend>` and
  `status`, for keybindings and hooks.
- Choice persisted in `~/.local/state/omarchy/lid-policy/state.json`.
