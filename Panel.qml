import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Ui
import qs.Commons

// Lid-close policy for laptops.
//
// Why an inhibitor and not the logind config: /etc/systemd/logind.conf.d is
// root-owned and this machine has no polkit authentication agent, so a bar
// switch could never rewrite it without a password prompt. logind consults
// handle-lid-switch inhibitors before it acts, so holding one keeps the machine
// awake with no privileges at all, applies instantly, and is released the
// moment the shell exits - the worst case is the stock suspend, never a laptop
// cooking in a bag.
//
// The flip side is that an inhibitor blocks logind's whole lid action, including
// Omarchy's lock-before-suspend, so nothing would lock the screen on close. That
// is why the lock toggle below exists: it watches the ACPI lid switch and locks
// itself, except while an external display is connected (where closing the lid
// is docking, not walking away). Newer Omarchy has its own switch:on:Lid Switch
// binding for exactly that; when it is present the plugin leaves the locking to
// it instead of firing a second lock.
//
// Modes:
//   awake   - keep running on battery and AC
//   ac      - keep running only while plugged in, stock suspend on battery
//   battery - keep running only on battery, stock suspend on AC
//   suspend - never inhibit, stock logind behaviour
//
// "Plugged in" is deliberately not UPower's OnBattery. That flag aggregates
// every line-power device, USB-C/UCSI ports included, and a port whose "online"
// attribute goes stale after the cable is pulled keeps it false forever - so an
// "AC only" policy would never let go. The decision instead mirrors logind,
// which picks the lid action from its own OnExternalPower, and a battery that
// is actually discharging vetoes both: if the pack is draining, the machine is
// running on it no matter what a port claims.
Panel {
  id: root
  moduleName: "io.github.hominluo.lid"
  ipcTarget: "io.github.hominluo.lid"

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/lid-policy"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string inhibitScript: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.hominluo.lid/bin/lid-inhibit"

  readonly property var modeOrder: ["awake", "ac", "battery", "suspend"]

  // Default: suspend, i.e. stock logind behaviour. Installing a plugin should
  // not silently change how the lid behaves - "Keep running" is opted into from
  // the panel, and the choice is saved to state.json on every change.
  property string mode: "suspend"
  property bool lockOnLid: true

  property string lidPath: ""
  property bool lidClosed: false
  // The first read is a baseline, not a lid close: a shell restart with the lid
  // already shut must not lock the screen.
  property bool lidSeen: false

  // Effective logind policy, read from the running daemon. The config files in
  // /etc/systemd/logind.conf.d are not the truth - a drop-in can be removed
  // without reloading logind - and "ignore" is only one of several actions that
  // fail to suspend.
  property var logind: ({})
  property bool logindReady: false
  property bool logindExternalPower: true

  // Omarchy ships its own lid-close hook (a Hyprland switch binding) that locks
  // the session. When it is active the toggle below cannot switch that off, so
  // the plugin stops locking itself and the row says who is doing it.
  property bool nativeLidLock: false

  // Set as soon as the user picks anything, so a slow state-file load cannot
  // overwrite a fresh choice.
  property bool stateTouched: false
  // A second click while a save is in flight must not be dropped.
  property bool savePending: false

  readonly property var battery: UPower.displayDevice
  readonly property bool batteryPresent: !!battery && battery.isPresent
  readonly property bool batteryDischarging: root.batteryPresent && battery.state === UPowerDeviceState.Discharging
  readonly property int batteryPercent: {
    var device = root.battery
    if (!device || !device.isPresent) return -1
    var fraction = Number(device.percentage)
    if (!isFinite(fraction)) return -1
    return Math.round(Math.max(0, Math.min(1, fraction)) * 100)
  }

  // logind is the authority here: it is the process that decides what a lid
  // close does, and OnExternalPower is the flag it branches on. UPower is only
  // the fallback for systems where busctl cannot be reached.
  readonly property bool onExternalPower:
    root.logindReady ? root.logindExternalPower : !UPower.onBattery
  readonly property bool onBattery: root.batteryDischarging || !root.onExternalPower

  // The one decision the whole plugin exists to make.
  readonly property bool shouldInhibit:
    mode === "awake" ||
    (mode === "ac" && !onBattery) ||
    (mode === "battery" && onBattery)

  // The action logind would take with no inhibitor in the way, resolved the
  // same way logind resolves it: docked/external display first, then external
  // power, then the plain lid action.
  readonly property string lidAction: {
    var cfg = root.logind
    var main = typeof cfg.HandleLidSwitch === "string" && cfg.HandleLidSwitch !== ""
      ? cfg.HandleLidSwitch
      : "suspend"
    if (cfg.Docked === true)
      return typeof cfg.HandleLidSwitchDocked === "string" && cfg.HandleLidSwitchDocked !== ""
        ? cfg.HandleLidSwitchDocked
        : "ignore"
    var external = cfg.HandleLidSwitchExternalPower
    if (typeof external === "string" && external !== "" && root.logindExternalPower)
      return external
    return main
  }

  // Which setting produced lidAction, so the warning can name the drop-in
  // key the user has to go and fix.
  readonly property string lidActionSource: {
    var cfg = root.logind
    if (cfg.Docked === true) return "HandleLidSwitchDocked"
    if (typeof cfg.HandleLidSwitchExternalPower === "string"
        && cfg.HandleLidSwitchExternalPower !== ""
        && root.logindExternalPower) return "HandleLidSwitchExternalPower"
    return "HandleLidSwitch"
  }

  // Only these put the machine to sleep. "ignore" leaves it awake, "lock" only
  // locks the screen, and poweroff/reboot/halt take it down.
  readonly property bool lidActionSleeps:
    ["suspend", "hibernate", "hybrid-sleep", "suspend-then-hibernate"].indexOf(root.lidAction) !== -1

  // An awake policy outranks the system config; everything else depends on
  // logind still being willing to sleep.
  readonly property bool policyConflicts: root.logindReady && !root.lidActionSleeps && root.mode !== "awake"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : Style.hoverFillFor(Color.foreground, Color.accent)
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : Style.selectedFillFor(Color.foreground, Color.accent)
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.5)

  // ---------- presentation helpers ----------

  function modeTitle(m) {
    if (m === "awake") return "Keep running"
    if (m === "ac") return "Keep running on AC"
    if (m === "battery") return "Keep running on battery"
    return "Suspend"
  }

  function modeSubtitle(m) {
    if (m === "awake") return "Awake with the lid shut, battery or AC"
    if (m === "ac") return "Suspends on battery - safe in a bag"
    if (m === "battery") return "Suspends whenever it is plugged in"
    return "Stock behaviour: closing the lid suspends"
  }

  // Outline glyphs on purpose: the filled battery (󰁹) and laptop-off (󰌣)
  // codepoints collapse into unreadable blobs at the row's 14 px, so the rows
  // use the outline battery and the "zzz" sleep symbol instead.
  function modeGlyph(m) {
    if (m === "awake") return "󰌢"
    if (m === "ac") return "󰚥"
    if (m === "battery") return "󰂎"
    return "󰒲"
  }

  // The bar and the panel header wear the same glyph as the mode's row, so a
  // mode is one shape everywhere. Colour carries no meaning: the bar's active
  // colour is the urgent red, which made a perfectly healthy "keep running"
  // look like an error, and three of the four modes looked identical anyway.
  function barGlyph() {
    return root.modeGlyph(root.mode)
  }

  // What a lid close actually does right now, in the words logind would use.
  // Bare infinitives, so every sentence below can be built from one table.
  function lidActionVerb(a) {
    if (a === "suspend") return "suspend"
    if (a === "hibernate") return "hibernate"
    if (a === "hybrid-sleep") return "hybrid sleep"
    if (a === "suspend-then-hibernate") return "suspend, then hibernate"
    if (a === "lock") return "only lock the screen"
    if (a === "poweroff") return "power the machine off"
    if (a === "reboot" || a === "soft-reboot") return "reboot"
    if (a === "kexec") return "reboot via kexec"
    if (a === "halt") return "halt"
    if (a === "sleep") return "sleep"
    if (a === "ignore") return "do nothing"
    return "do " + a
  }

  function heroTitle() {
    if (root.shouldInhibit) return "Closing the lid will keep it running"
    return "Closing the lid will " + root.lidActionVerb(root.lidAction)
  }

  function heroMeta() {
    if (!root.batteryPresent) return root.onBattery ? "No battery detected" : "Plugged in"
    var bits = []
    bits.push(root.onBattery ? "On battery" : "On AC")
    if (root.batteryPercent >= 0) bits.push(root.batteryPercent + "%")
    bits.push(root.lidClosed ? "lid shut" : "lid open")
    return bits.join("  ·  ")
  }

  // The glyph names the chosen mode, so the tooltip has to say what that mode
  // does right now - on the other power source an "AC" policy still suspends.
  function outcomeText() {
    if (root.shouldInhibit) return "lid close will keep it running"
    var outcome = "lid close will " + root.lidActionVerb(root.lidAction)
    if (root.mode === "ac") return outcome + " (on battery)"
    if (root.mode === "battery") return outcome + " (plugged in)"
    return outcome
  }

  function barTooltip() {
    var policy = root.modeTitle(root.mode)
    if (root.policyConflicts) return policy + " · system config: lid close will " + root.lidActionVerb(root.lidAction)
    return policy + " · " + root.outcomeText()
  }

  // Docked is the common case and has a different remedy from a drop-in, so
  // name the setting that is actually in force.
  function conflictMessage() {
    var verb = root.lidActionVerb(root.lidAction)
    if (root.lidActionSource === "HandleLidSwitchDocked")
      return "A dock or external display is connected, so logind uses its docked action and "
        + "a lid close will " + verb + " (HandleLidSwitchDocked, ignore by default). "
        + "This is stock logind behaviour, not a fault: unplug the display, or set "
        + "HandleLidSwitchDocked, if the suspend modes should apply while docked."
    return "logind's " + root.lidActionSource + " setting makes a lid close " + verb
      + ", so the modes that step aside will not sleep. A drop-in in "
      + "/etc/systemd/logind.conf.d outranks this plugin - a leftover 30-lid-ignore.conf "
      + "is the usual one. Remove it and reload systemd-logind."
  }

  function lockRowSubtitle() {
    if (root.nativeLidLock) return "Omarchy locks on lid close"
    if (root.shouldInhibit) return "Skipped with an external display"
    return "Only applies while the lid keeps it running"
  }

  // ---------- persistence ----------

  function loadState(t) {
    if (root.stateTouched) return
    var parsed
    try {
      parsed = JSON.parse(String(t))
    } catch (e) {
      return
    }
    if (parsed && typeof parsed.mode === "string" && root.modeOrder.indexOf(parsed.mode) !== -1)
      root.mode = parsed.mode
    if (parsed && typeof parsed.lockOnLid === "boolean")
      root.lockOnLid = parsed.lockOnLid
  }

  function saveState() {
    // Write to a private temp file and rename it into place: a shell crash or a
    // second rapid click can otherwise leave a truncated state.json behind.
    // Clicking faster than the write finishes queues one more save instead of
    // silently losing the last choice.
    if (saveProc.running) {
      root.savePending = true
      return
    }
    saveProc.command = [
      "bash", "-c",
      'dir="$0"; '
        + 'mkdir -p "$dir" || exit 1; '
        + 'tmp="$dir/.state.$$.tmp"; '
        + 'printf \'{"mode":"%s","lockOnLid":%s}\\n\' "$1" "$2" > "$tmp" || exit 1; '
        + 'mv -f "$tmp" "$dir/state.json"',
      root.stateDir, root.mode, root.lockOnLid ? "true" : "false"
    ]
    saveProc.running = true
  }

  function setMode(m) {
    if (root.modeOrder.indexOf(m) === -1 || root.mode === m) return
    root.stateTouched = true
    root.mode = m
    root.saveState()
  }

  function setLockOnLid(v) {
    if (root.lockOnLid === v) return
    root.stateTouched = true
    root.lockOnLid = v
    root.saveState()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    printErrors: false
    onLoaded: root.loadState(text())
  }

  Process {
    id: saveProc
    onExited: {
      if (!root.savePending) return
      root.savePending = false
      root.saveState()
    }
  }

  // ---------- the inhibitor ----------

  // A crashed shell does not take its children with it: systemd-inhibit survives
  // reparented to the omarchy-shell wrapper, so the machine would keep believing
  // the lid may be ignored with nothing on screen to show why. Sweep those
  // orphans away before starting our own, and only arm the inhibitor after the
  // sweep so it cannot shoot itself in the foot.
  property bool cleanupDone: false

  Process {
    id: staleCleanup
    // Bracket the first letter so this pattern cannot match the bash -c
    // command line that contains it (pgrep -f matches the whole argv).
    command: [
      "bash", "-c",
      'for pid in $(pgrep -u "$UID" -f -- "[s]ystemd-inhibit --what=handle-lid-switch --who=Omarchy lid policy"); do '
        + 'for child in $(pgrep -P "$pid"); do kill -TERM "$child" 2>/dev/null; done; '
        + 'kill -TERM "$pid" 2>/dev/null; '
        + 'done; true'
    ]
    onExited: root.cleanupDone = true
  }

  // If the sweep somehow never reports back, stop waiting rather than leave the
  // machine unable to keep itself awake.
  Timer {
    interval: 3000
    repeat: false
    running: !root.cleanupDone
    onTriggered: root.cleanupDone = true
  }

  // systemd-inhibit holds the inhibitor for as long as its child lives. The
  // child is not `sleep infinity` any more: bin/lid-inhibit watches the shell
  // and systemd-inhibit's own child watches the supervisor, so a crash, a
  // SIGKILL or a normal stop all drop the inhibitor within a second instead
  // of leaving an orphan until the next shell start.
  //
  // Driven by syncInhibitor() instead of a `running:` binding: the binding form
  // breaks the moment JS writes the property, and the retry below has to write
  // it. A logind restart or an OOM kill takes the child down without touching
  // shouldInhibit, and an inhibitor that is silently gone is exactly the failure
  // this plugin exists to avoid.
  Process {
    id: inhibitor
    command: ["bash", root.inhibitScript]
    onExited: {
      if (root.shouldInhibit && root.cleanupDone) rearmTimer.restart()
    }
  }

  Timer {
    id: rearmTimer
    interval: 3000
    repeat: false
    onTriggered: root.syncInhibitor()
  }

  function syncInhibitor() {
    var want = root.shouldInhibit && root.cleanupDone
    if (want === inhibitor.running) return
    inhibitor.running = want
  }

  onShouldInhibitChanged: root.syncInhibitor()
  onCleanupDoneChanged: root.syncInhibitor()

  // ---------- lid switch ----------

  Process {
    id: lidProbe
    command: ["bash", "-c", "ls -d /proc/acpi/button/lid/*/state 2>/dev/null | head -n 1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lidPath = text.trim()
    }
  }

  FileView {
    id: lidFile
    path: root.lidPath
    watchChanges: root.lidPath !== ""
    printErrors: false
    onLoaded: root.applyLidState(text())
    onFileChanged: reload()
  }

  // procfs inotify is not dependable across firmwares, so poll while it
  // matters. The read is a single small procfs file, so it can run in every
  // mode; that keeps the panel's "lid open/shut" line truthful even when the
  // plugin is not holding an inhibitor.
  Timer {
    interval: 3000
    repeat: true
    running: root.lidPath !== ""
    onTriggered: lidFile.reload()
  }

  function applyLidState(t) {
    var closed = /closed/i.test(String(t))
    var firstSample = !root.lidSeen
    root.lidSeen = true
    var wasOpen = !root.lidClosed
    root.lidClosed = closed
    if (!firstSample && closed && wasOpen) root.lidClosedNow()
  }

  function lidClosedNow() {
    if (!root.shouldInhibit || !root.lockOnLid) return
    // Omarchy's own switch:on:Lid Switch binding already ran
    // omarchy-system-lid-close; a second lock here only races it.
    if (root.nativeLidLock) return
    monitorProbe.running = true
  }

  // Docked is not the same as walking away: with an external display attached
  // the machine is at a desk and locking on every lid close would be hostile.
  Process {
    id: monitorProbe
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lockIfUndocked(text)
    }
  }

  function lockIfUndocked(json) {
    var external = false
    try {
      var list = JSON.parse(String(json))
      for (var i = 0; i < list.length; i++) {
        var name = String(list[i].name || "")
        if (name !== "" && !root.isInternalOutput(name)) external = true
      }
    } catch (e) {
      // A failed probe must not cost the lock: keep it unless we know better.
      external = false
    }
    if (!external) lockProc.running = true
  }

  // Internal panels are not always eDP: older Intel machines expose LVDS and
  // ARM laptops DSI, and a name is case-insensitive. Treating any of those as
  // "external" would silently skip the lock on every close.
  function isInternalOutput(name) {
    var n = String(name).toLowerCase()
    return n.indexOf("edp") === 0 || n.indexOf("lvds") === 0 || n.indexOf("dsi") === 0
  }

  Process {
    id: lockProc
    command: ["omarchy", "system", "lock"]
  }

  // Does Omarchy itself lock on a lid close? Its binding runs
  // omarchy-system-lid-close from the switch event, independently of any
  // inhibitor, so when it is present the toggle below cannot turn that off and
  // the plugin must not add a second lock.
  Process {
    id: nativeLidProbe
    command: [
      "bash", "-c",
      'command -v omarchy-system-lid-close >/dev/null 2>&1 || exit 1; '
        + 'hyprctl -j binds 2>/dev/null | grep -q "switch:on:Lid Switch"'
    ]
    onExited: (exitCode) => root.nativeLidLock = exitCode === 0
  }

  // ---------- system policy + power source (live, from logind) ----------

  // The whole vtable in one process: five busctl spawns, only when something
  // changed or the panel is open. HandleLidSwitch* are const properties, so
  // they only move when logind itself reloads.
  Process {
    id: logindProbe
    command: [
      "bash", "-c",
      'm=org.freedesktop.login1.Manager; '
        + 'for p in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked Docked OnExternalPower; do '
        + 'v=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 "$m" "$p" 2>/dev/null) || continue; '
        + 'printf "%s=%s\n" "$p" "$v"; '
        + 'done'
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLogind(text)
    }
  }

  // OnExternalPower has no PropertiesChanged signal, and it is the one value
  // that has to track a pulled cable. One busctl call, and only while a mode
  // actually depends on the power source.
  Process {
    id: powerProbe
    command: [
      "busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
      "org.freedesktop.login1.Manager", "OnExternalPower"
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPower(text)
    }
  }

  function parseBool(raw) {
    var m = /^b\s+(true|false)$/.exec(String(raw).trim())
    return m ? m[1] === "true" : undefined
  }

  function parseString(raw) {
    var m = /^s\s+"(.*)"$/.exec(String(raw).trim())
    return m ? m[1] : undefined
  }

  function applyLogind(t) {
    var next = ({})
    var parsedAny = false
    var lines = String(t).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i].indexOf("=")
      if (at <= 0) continue
      var key = lines[i].substring(0, at)
      var raw = lines[i].substring(at + 1)
      var str = root.parseString(raw)
      if (str !== undefined) {
        next[key] = str
        parsedAny = true
        continue
      }
      var bool = root.parseBool(raw)
      if (bool !== undefined) {
        next[key] = bool
        parsedAny = true
      }
    }
    if (!parsedAny) {
      // logind gone or busctl missing: fall back to UPower rather than keep a
      // stale policy around that would make every label a guess.
      root.logindReady = false
      return
    }
    root.logind = next
    if (typeof next.OnExternalPower === "boolean")
      root.logindExternalPower = next.OnExternalPower
    root.logindReady = true
  }

  function applyPower(t) {
    var v = root.parseBool(t)
    if (v === undefined) {
      root.logindReady = false
      return
    }
    root.logindExternalPower = v
    root.logindReady = true
  }

  function refreshPower() {
    if (!powerProbe.running) powerProbe.running = true
  }

  function refreshLogind() {
    if (!logindProbe.running) logindProbe.running = true
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.mode === "ac" || root.mode === "battery" || root.opened
    onTriggered: root.refreshPower()
  }

  // UPower still watches the pack and reports charging state changes, which is
  // the fastest signal that the cable moved - read logind's answer right then.
  Connections {
    target: root.battery
    function onStateChanged() { root.refreshPower() }
  }

  onModeChanged: {
    root.refreshPower()
    // The policy block is cheap but pointless on every tick; the timer above
    // covers the power half, and this keeps the docked/external-power branch
    // honest when the user switches modes.
    root.refreshLogind()
  }

  Component.onCompleted: {
    lidProbe.running = true
    staleCleanup.running = true
    nativeLidProbe.running = true
    root.refreshPower()
    root.refreshLogind()
  }

  onOpenedChanged: if (opened) {
    root.refreshPower()
    root.refreshLogind()
  }

  // Scriptable control, so a keybinding or a hook can flip the policy without
  // opening the panel:
  //   omarchy-shell io.github.hominluo.lid.ctl mode ac
  //   omarchy-shell io.github.hominluo.lid.ctl status
  IpcHandler {
    target: "io.github.hominluo.lid.ctl"

    function mode(m: string): string {
      var v = String(m).trim().toLowerCase()
      if (root.modeOrder.indexOf(v) === -1)
        return "invalid mode: " + v + " (expected " + root.modeOrder.join(", ") + ")"
      root.setMode(v)
      return root.mode
    }

    function status(): string {
      return JSON.stringify({
        mode: root.mode,
        lockOnLid: root.lockOnLid,
        requested: root.shouldInhibit,
        inhibiting: inhibitor.running,
        conflict: root.policyConflicts,
        onBattery: root.onBattery,
        onExternalPower: root.onExternalPower,
        batteryDischarging: root.batteryDischarging,
        lidAction: root.lidAction,
        docked: root.logindReady && root.logind.Docked === true,
        nativeLidLock: root.nativeLidLock,
        logind: root.logindReady,
        policy: root.logind
      })
    }
  }

  // ---------- bar item ----------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // One glyph per mode, the same shapes the panel rows use: laptop for keep
    // running, plug for AC only, battery for battery only, "zzz" for suspend.
    // The icon names the policy; the tooltip can still correct it when the
    // current power source makes the outcome different.
    text: root.barGlyph()
    active: false
    tooltipText: root.barTooltip()
    onPressed: root.toggle()
  }

  // ---------- panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        // ---------- Hero ----------
        Row {
          width: parent.width
          spacing: Style.space(14)

          Text {
            textFormat: Text.PlainText
            text: root.barGlyph()
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - Style.space(14) - Style.font.display
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.heroTitle()
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.heroMeta()
              color: root.dim
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Mechanism ----------
        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "WHEN THE LID CLOSES"
            foreground: root.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Repeater {
            model: root.modeOrder

            ChoiceRow {
              required property string modelData
              width: parent.width
              glyph: root.modeGlyph(modelData)
              title: root.modeTitle(modelData)
              subtitle: root.modeSubtitle(modelData)
              active: root.mode === modelData
              onPicked: root.setMode(modelData)
            }
          }
        }

        // ---------- Screen ----------
        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "SCREEN"
            foreground: root.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(lockLabels.implicitHeight, lockSwitch.implicitHeight) + Style.space(6)
            opacity: root.shouldInhibit ? 1.0 : 0.4

            // Same glyph column as the mode rows, so the lock row lines up with
            // them instead of starting flush against the panel edge.
            Text {
              id: lockGlyph
              textFormat: Text.PlainText
              text: root.lockOnLid || root.nativeLidLock ? "󰌾" : "󰌿"
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              width: Style.space(22)
              horizontalAlignment: Text.AlignHCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: lockLabels
              anchors.left: lockGlyph.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: lockSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                text: "Lock screen on lid close"
                color: root.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.lockRowSubtitle()
                color: root.dim
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }

            ToggleSwitch {
              id: lockSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // With Omarchy's own hook in place the toggle has nothing left to
              // control, so it reports what actually happens and stops
              // pretending to be a switch.
              checked: root.nativeLidLock ? true : root.lockOnLid
              interactive: root.shouldInhibit && !root.nativeLidLock
              foreground: root.foreground
              onToggled: root.setLockOnLid(!root.lockOnLid)
            }
          }
        }

        // ---------- Diagnostics ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          // The one thing an inhibitor cannot do is outrank the system policy.
          // If logind would ignore the lid - or only lock, or power off - every
          // mode that expects logind to suspend is a lie, not only Suspend, but
          // also the unplugged half of "AC" and the plugged half of "Battery".
          PanelSeparator {
            foreground: root.foreground
            visible: root.policyConflicts
          }

          Text {
            textFormat: Text.PlainText
            visible: root.policyConflicts
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.conflictMessage()
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          // Heat and drain are the real cost of an awake closed lid; say so in
          // the state where it applies instead of a permanent nag.
          Text {
            textFormat: Text.PlainText
            visible: root.shouldInhibit && root.onBattery
            width: parent.width
            wrapMode: Text.WordWrap
            text: "On battery with the lid shut it keeps drawing power and warming up. "
              + "Keep running on AC is the safe mode for a bag."
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "inhibitor " + (inhibitor.running ? "held" : "released")
              + (root.shouldInhibit && root.lockOnLid && !root.nativeLidLock ? "  ·  locks on close" : "")
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // A selectable row, styled like the audio panel's device rows.
  component ChoiceRow: CursorSurface {
    id: choice
    required property string glyph
    required property string title
    required property string subtitle
    required property bool active
    signal picked()

    current: active
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: choiceInner.implicitHeight + Style.spacing.xl

    Row {
      id: choiceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: choice.glyph
        color: root.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: choice.title
          color: root.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: choice.active
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          visible: choice.subtitle !== ""
          text: choice.subtitle
          color: root.dim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: choice.hasCursor = true
      onExited: choice.hasCursor = false
      onClicked: choice.picked()
    }
  }
}
