import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Singleton engine: owns the sensor poll, the curve, and every write to the
// LED. It is a `service` kind precisely so this runs once — a bar widget is
// instantiated per monitor, and three copies racing to set the same LED would
// fight each other on every ramp step.
//
// The widget is the settings owner (settings live inline on its shell.json bar
// entry, which only the widget can see and write). It pushes them in here via
// `settings`; every monitor's copy pushes the same values, so the assignment is
// idempotent.
Item {
  id: root

  // Injected by the shell for third-party services.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // Raw shell.json entry, pushed in by the bar widget.
  property var settings: ({})
  readonly property var config: Model.withDefaults(settings)

  // Discovered hardware. Empty ledPath means there is nothing to control and
  // the whole plugin stands down.
  property string ledPath: ""
  property string sensorPath: ""
  property bool probed: false
  readonly property bool available: ledPath !== ""
  readonly property bool hasSensor: sensorPath !== ""
  readonly property string ledName: Model.ledName(ledPath)

  // Live device state, refreshed by the poll.
  property int deviceRaw: 0
  property int deviceMax: 255
  property int rawLux: -1

  // Smoothed sensor value the curve actually reads. Null until the first
  // sample so the EMA seeds from the real reading instead of ramping up from 0.
  property var averageLux: null

  // What we have asked the hardware for, in percent and in device units.
  property int requestedPercent: -1
  property int targetRaw: 0
  property int rampRaw: 0

  readonly property int percent: Model.rawToPercent(deviceRaw, deviceMax)
  readonly property int desiredPercent: {
    if (!config.auto) return config.manualPercent
    if (!hasSensor || averageLux === null) return config.manualPercent
    return Model.autoPercent(averageLux, config)
  }

  // Number of hops a full-scale change is split into, and the gap between
  // them. ~8 * 35ms keeps a sunrise from landing as a visible snap while
  // costing at most eight brightnessctl spawns per adjustment.
  readonly property int rampSteps: 8
  property bool ramping: false

  property int _pendingWrite: -1

  signal applied(int percent)

  function refresh() {
    if (!probed) { probeProc.running = true; return }
    if (!available) return
    if (!pollProc.running) pollProc.running = true
  }

  // Target the hardware at `percent`. `force` re-asserts even when the value
  // has not changed, which is what a resume from sleep needs — Omarchy's
  // system-sleep hook zeroes the LED behind our back.
  function apply(percent, force) {
    if (!available) return
    var next = Model.clampPercent(percent)
    if (!force && next === requestedPercent) return
    requestedPercent = next
    targetRaw = Model.percentToRaw(next, deviceMax)
    rampRaw = deviceRaw
    if (targetRaw === rampRaw) { ramping = false; return }
    ramping = true
    rampTimer.restart()
    stepRamp()
  }

  // Straight to the value, no ramp. Dragging the slider in the popup should
  // track the pointer, not chase it.
  function applyImmediate(percent) {
    if (!available) return
    ramping = false
    rampTimer.stop()
    requestedPercent = Model.clampPercent(percent)
    targetRaw = Model.percentToRaw(requestedPercent, deviceMax)
    rampRaw = targetRaw
    write(targetRaw)
  }

  function stepRamp() {
    if (!ramping) return
    rampRaw = Model.rampStep(rampRaw, targetRaw, rampSteps)
    write(rampRaw)
    if (rampRaw === targetRaw) {
      ramping = false
      rampTimer.stop()
      root.applied(requestedPercent)
    }
  }

  // brightnessctl rather than a direct sysfs write: /sys/class/leds is
  // root-owned, and brightnessctl falls back to logind's SetBrightness over
  // D-Bus, which polkit grants to the active session. One write at a time —
  // restarting a live Process drops the spawn on the floor, so the newest
  // value waits and supersedes anything queued behind it.
  function write(raw) {
    if (!available) return
    deviceRaw = raw
    if (writeProc.running) { _pendingWrite = raw; return }
    writeProc.command = ["brightnessctl", "-d", root.ledName, "-q", "set", String(raw)]
    writeProc.running = true
  }

  onConfigChanged: {
    pollTimer.interval = config.pollIntervalMs
    // A settings change should land now, not at the next poll tick.
    if (available) Qt.callLater(function() { root.apply(root.desiredPercent, false) })
  }

  Component.onCompleted: probeProc.running = true

  // Hardware discovery. Both globs are matched in the shell rather than in QML
  // so a machine with a differently-named LED (thinkpad::kbd_backlight,
  // asus::kbd_backlight) or a second IIO device still works untouched.
  Process {
    id: probeProc
    command: ["sh", "-c",
      "led=''; for d in /sys/class/leds/*kbd_backlight*; do " +
      "if [ -r \"$d/brightness\" ]; then led=\"$d\"; break; fi; done; " +
      "als=''; for d in /sys/bus/iio/devices/iio:device*; do " +
      "if [ -r \"$d/in_illuminance_raw\" ]; then als=\"$d/in_illuminance_raw\"; break; fi; done; " +
      "printf '%s\\n%s\\n' \"$led\" \"$als\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = Model.parseDevices(text)
        root.ledPath = found.ledPath
        root.sensorPath = found.sensorPath
        root.probed = true
        if (!root.available) {
          console.warn("floscom.kbd-backlight: no *kbd_backlight* LED found; plugin idle")
          return
        }
        pollProc.running = true
      }
    }
  }

  // One spawn per poll for the whole sample: current level, the device's own
  // scale, and the sensor. `-1` stands in for a missing sensor so the parser
  // has a fixed three-field line either way.
  Process {
    id: pollProc
    command: ["sh", "-c",
      "printf '%s %s %s\\n' " +
      "\"$(cat \"$LED/brightness\" 2>/dev/null || echo 0)\" " +
      "\"$(cat \"$LED/max_brightness\" 2>/dev/null || echo 255)\" " +
      "\"$(cat \"$ALS\" 2>/dev/null || echo -1)\""]
    environment: ({ "LED": root.ledPath, "ALS": root.sensorPath })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var sample = Model.parseSample(text)
        if (!sample) return
        root.deviceMax = sample.max
        root.rawLux = sample.lux
        if (sample.lux >= 0)
          root.averageLux = Model.smoothLux(root.averageLux, sample.lux, root.config.smoothing)

        // Mid-ramp our own writes are in flight, so the device reading is
        // stale by construction — leave rampRaw authoritative.
        if (root.ramping) return
        root.deviceRaw = sample.raw

        var want = root.desiredPercent
        if (root.config.auto) {
          // Auto owns the LED: re-assert whenever the hardware has drifted
          // (resume from sleep, an Fn key) or the curve has moved enough to
          // be worth a write. The dead zone keeps a flickering sensor from
          // spawning brightnessctl every two seconds.
          var drifted = Model.rawToPercent(sample.raw, sample.max) !== root.requestedPercent
          var moved = root.requestedPercent < 0
            || Math.abs(want - root.requestedPercent) >= 2
            || want === 0 || want === 100
          if (moved) root.apply(want, false)
          else if (drifted && root.requestedPercent >= 0) root.apply(root.requestedPercent, true)
        } else if (root.requestedPercent !== want) {
          root.apply(want, false)
        }
      }
    }
  }

  Process {
    id: writeProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root._pendingWrite < 0) return
      var queued = root._pendingWrite
      root._pendingWrite = -1
      root.write(queued)
    }
  }

  Timer {
    id: pollTimer
    interval: root.config.pollIntervalMs
    running: root.available
    repeat: true
    triggeredOnStart: false
    onTriggered: if (!pollProc.running) pollProc.running = true
  }

  Timer {
    id: rampTimer
    interval: 35
    repeat: true
    onTriggered: root.stepRamp()
  }
}
