# Changelog

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
