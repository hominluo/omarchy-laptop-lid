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
// is docking, not walking away).
//
// Modes:
//   awake   - keep running on battery and AC
//   ac      - keep running only while plugged in, stock suspend on battery
//   battery - keep running only on battery, stock suspend on AC
//   suspend - never inhibit, stock logind behaviour
Panel {
  id: root
  moduleName: "io.github.hominluo.lid"
  ipcTarget: "io.github.hominluo.lid"

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/lid-policy"
  readonly property string statePath: stateDir + "/state.json"

  readonly property var modeOrder: ["awake", "ac", "battery", "suspend"]

  // Default: suspend, i.e. stock logind behaviour. Installing a plugin should
  // not silently change how the lid behaves - "Keep running" is opted into from
  // the panel, and the choice is saved to state.json on every change.
  property string mode: "suspend"
  property bool lockOnLid: true

  property string lidPath: ""
  property bool lidClosed: false
  // Last value of each HandleLidSwitch* key in the merged system config.
  // Populated from systemd-analyze so drop-in order, whitespace around "="
  // and the ExternalPower/Docked variants are all resolved the way logind
  // resolves them. Only read to warn when the config outranks this plugin.
  property var systemPolicy: ({})

  // Set as soon as the user picks anything, so a slow state-file load cannot
  // overwrite a fresh choice.
  property bool stateTouched: false

  readonly property bool onBattery: UPower.onBattery
  readonly property var battery: UPower.displayDevice
  readonly property bool batteryPresent: !!battery && battery.isPresent
  readonly property int batteryPercent: {
    var device = root.battery
    if (!device || !device.isPresent) return -1
    var fraction = Number(device.percentage)
    if (!isFinite(fraction)) return -1
    return Math.round(Math.max(0, Math.min(1, fraction)) * 100)
  }

  // The one decision the whole plugin exists to make.
  readonly property bool shouldInhibit:
    mode === "awake" ||
    (mode === "ac" && !onBattery) ||
    (mode === "battery" && onBattery)

  // Any of the three keys can force the lid action to "nothing". The AC and
  // battery modes also rely on logind suspending when the plugin is not
  // inhibiting, so an ignore entry breaks those too, not just Suspend.
  readonly property bool overrideActive:
    systemPolicy.HandleLidSwitch === "ignore"
      || systemPolicy.HandleLidSwitchExternalPower === "ignore"
      || systemPolicy.HandleLidSwitchDocked === "ignore"
  readonly property bool policyConflicts: overrideActive && mode !== "awake"

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

  function heroTitle() {
    if (root.shouldInhibit) return "Closing the lid keeps it running"
    if (root.policyConflicts) return "The system config ignores the lid"
    return "Closing the lid suspends"
  }

  function heroMeta() {
    if (!root.batteryPresent) return root.onBattery ? "No battery detected" : "Plugged in"
    var bits = []
    bits.push(root.onBattery ? "On battery" : "On AC")
    if (root.batteryPercent >= 0) bits.push(root.batteryPercent + "%")
    bits.push(root.lidClosed ? "lid shut" : "lid open")
    return bits.join("  ·  ")
  }

  function barTooltip() {
    if (root.shouldInhibit)
      return root.onBattery ? "Lid close keeps it running on battery" : "Lid close keeps it running on AC"
    if (root.policyConflicts) return "System config ignores the lid close"
    return "Lid close suspends"
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

  // systemd-inhibit holds the inhibitor for as long as its child lives, so the
  // child is `sleep infinity` and the Process binding is the switch. Stopping it
  // sends SIGTERM, which drops the inhibitor and hands the lid back to logind.
  Process {
    id: inhibitor
    running: root.shouldInhibit && root.cleanupDone
    command: [
      "systemd-inhibit",
      "--what=handle-lid-switch",
      "--who=Omarchy lid policy",
      "--why=Lid-close behavior chosen from the bar",
      "--mode=block",
      "sleep", "infinity"
    ]
  }

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
    var wasOpen = !root.lidClosed
    root.lidClosed = closed
    if (closed && wasOpen) root.lidClosedNow()
  }

  function lidClosedNow() {
    if (!root.shouldInhibit || !root.lockOnLid) return
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

  // ---------- system policy ----------

  Process {
    id: policyProbe
    command: [
      "bash", "-c",
      'systemd-analyze cat-config systemd/logind.conf 2>/dev/null '
        + '| grep -E "^[[:space:]]*HandleLidSwitch[A-Za-z]*[[:space:]]*=" || true'
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPolicy(text)
    }
  }

  function applyPolicy(t) {
    var map = ({})
    var lines = String(t).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^\s*(HandleLidSwitch[A-Za-z]*)\s*=\s*(\S+)/.exec(lines[i])
      if (m) map[m[1]] = m[2].toLowerCase()
    }
    root.systemPolicy = map
  }

  function refreshPolicy() {
    policyProbe.running = true
  }

  Component.onCompleted: {
    lidProbe.running = true
    staleCleanup.running = true
    root.refreshPolicy()
  }

  onOpenedChanged: if (opened) root.refreshPolicy()

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
        policy: root.systemPolicy
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
    // 󰌢 md-laptop while it keeps running, 󰒲 md-power-sleep when the lid will
    // suspend it. The glyph says what will happen, so the bar is readable
    // without opening the panel.
    text: root.shouldInhibit ? "󰌢" : "󰒲"
    active: root.shouldInhibit
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
            text: root.shouldInhibit ? "󰌢" : "󰒲"
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
              text: root.lockOnLid ? "󰌾" : "󰌿"
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
                text: root.shouldInhibit
                  ? "Skipped with an external display"
                  : "Only applies while the lid keeps it running"
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
              checked: root.lockOnLid
              interactive: root.shouldInhibit
              foreground: root.foreground
              onToggled: root.setLockOnLid(!root.lockOnLid)
            }
          }
        }

        // ---------- Diagnostics ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          // The one thing an inhibitor cannot do is outrank the system config.
          // If a drop-in says ignore, every mode that expects logind to suspend
          // is a lie - not only Suspend, but also the unplugged half of "AC"
          // and the plugged half of "Battery".
          PanelSeparator {
            foreground: root.foreground
            visible: root.policyConflicts
          }

          Text {
            textFormat: Text.PlainText
            visible: root.policyConflicts
            width: parent.width
            wrapMode: Text.WordWrap
            text: "A HandleLidSwitch=ignore entry in the system config outranks this plugin, "
              + "so the modes that rely on suspending may not work (the docked and "
              + "external-power variants count too). Remove that drop-in "
              + "(for example /etc/systemd/logind.conf.d/30-lid-ignore.conf) and reload systemd-logind."
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
              + (root.shouldInhibit && root.lockOnLid ? "  ·  locks on close" : "")
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
