import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + popup. This file owns presentation and the settings round-trip;
// Service.qml owns the hardware. Settings live inline on this widget's
// shell.json bar entry, which is why the widget pushes them into the singleton
// service rather than the other way around.
Panel {
  id: root
  moduleName: "floscom.kbd-backlight"
  ipcTarget: "floscom.kbd-backlight"
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("floscom.kbd-backlight") : null
  readonly property var config: Model.withDefaults(settings)

  readonly property bool available: service ? service.available : false
  readonly property bool hasSensor: service ? service.hasSensor : false
  readonly property int livePercent: service ? service.percent : 0
  readonly property int liveLux: service ? service.rawLux : -1
  readonly property bool autoOn: config.auto && hasSensor

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Keyboard cursor. Rows are derived from the same list the layout walks, so
  // j/k can never land on a row that is not on screen.
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property var rows: {
    var list = []
    if (hasSensor) list.push("auto")
    if (autoOn) {
      list.push("maxPercent")
      list.push("minPercent")
      list.push("luxDark")
      list.push("luxBright")
      list.push("response")
    } else {
      list.push("manualPercent")
    }
    return list
  }

  function rowIndex(key) { return rows.indexOf(key) }
  function hasCursorOn(key) { return cursorActive && rows[cursorIndex] === key }

  function moveCursor(delta) {
    cursorActive = true
    var next = cursorIndex + delta
    cursorIndex = Math.max(0, Math.min(rows.length - 1, next))
  }

  // h/l on a slider row nudges it; on the response row it walks the presets.
  function adjustCursorRow(delta) {
    if (!cursorActive) return
    var key = rows[cursorIndex]
    if (key === "response") {
      var order = ["slow", "normal", "fast"]
      var at = order.indexOf(activePreset)
      if (at < 0) at = 1
      applyPreset(order[Math.max(0, Math.min(order.length - 1, at + delta))])
      return
    }
    var spec = sliderSpec(key)
    if (!spec) return
    commitSetting(key, Number(config[key]) + spec.step * delta)
  }

  function activateCursorRow() {
    if (!cursorActive) return
    var key = rows[cursorIndex]
    if (key === "auto") toggleAuto()
    else if (key === "luxDark" || key === "luxBright") useCurrentReading(key)
  }

  // Bounds for every tunable slider, in one place so the keyboard path and the
  // mouse path cannot drift apart.
  function sliderSpec(key) {
    if (key === "manualPercent" || key === "maxPercent" || key === "minPercent")
      return { minimum: 0, maximum: 100, step: 5, integer: true }
    if (key === "luxDark") return { minimum: 0, maximum: 100, step: 1, integer: true }
    if (key === "luxBright") return { minimum: 1, maximum: 1000, step: 10, integer: true }
    return null
  }

  // Write one or more keys back to this widget's shell.json entry. Applied to
  // the local copy first so the panel redraws on the click itself; the host
  // echoes the same values back through the bar. With no writable entry (the
  // widget is not in a layout) it degrades to a session-only preference.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    pushSettings()
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function commitSetting(key, value) {
    var spec = sliderSpec(key)
    var next = value
    if (spec) next = Math.round(Math.max(spec.minimum, Math.min(spec.maximum, value)))
    if (Number(config[key]) === next) return
    var patch = {}
    patch[key] = next
    persistSettings(patch)
  }

  function toggleAuto() {
    // Leaving auto keeps the level the room had just settled on, so the
    // keyboard does not jump when the toggle is flipped.
    if (config.auto) persistSettings({ auto: false, manualPercent: root.livePercent })
    else persistSettings({ auto: true })
  }

  function useCurrentReading(key) {
    if (root.liveLux < 0) return
    commitSetting(key, root.liveLux)
  }

  // Scrolling the bar icon is a manual gesture, so it takes the keyboard out
  // of auto the way nudging a car's climate dial does.
  function nudge(delta) {
    var base = config.auto ? root.livePercent : config.manualPercent
    var next = Math.max(0, Math.min(100, base + delta))
    if (service) service.applyImmediate(next)
    persistSettings({ auto: false, manualPercent: next })
  }

  readonly property string activePreset: {
    if (config.pollIntervalMs >= 3000) return "slow"
    if (config.pollIntervalMs <= 1200) return "fast"
    return "normal"
  }

  function applyPreset(name) {
    if (name === "slow") persistSettings({ pollIntervalMs: 4000, smoothing: 0.8 })
    else if (name === "fast") persistSettings({ pollIntervalMs: 1000, smoothing: 0.35 })
    else persistSettings({ pollIntervalMs: 2000, smoothing: 0.65 })
  }

  // The service is a singleton and this widget exists once per monitor, so
  // every copy pushes the same object. Assignment is idempotent.
  function pushSettings() {
    if (root.service) root.service.settings = root.settings
  }

  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  onRowsChanged: if (cursorIndex >= rows.length) cursorIndex = Math.max(0, rows.length - 1)

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (service) service.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Nothing to control means nothing to show. A desktop with this plugin
  // installed gets an empty slot rather than a dead button.
  visible: available
  implicitWidth: available ? button.implicitWidth : 0
  implicitHeight: available ? button.implicitHeight : 0

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleAuto(): string { root.toggleAuto(); return root.config.auto ? "auto" : "manual" }
    function up(): string { root.nudge(10); return String(root.config.manualPercent) }
    function down(): string { root.nudge(-10); return String(root.config.manualPercent) }
    function status(): string {
      return Model.statusLine(root.livePercent, root.liveLux, root.hasSensor, root.autoOn)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.icon(root.livePercent, root.autoOn)
    // The glyph fades with the backlight itself, so the bar reads at a glance
    // without a percentage taking up room. Dimming the color rather than the
    // whole button keeps the hover fill at full strength.
    foreground: root.livePercent <= 0
      ? Qt.darker(root.barForeground, 1.9)
      : Qt.darker(root.barForeground, 1.0 + 0.6 * (1 - root.livePercent / 100))
    tooltipText: Model.statusLine(root.livePercent, root.liveLux, root.hasSensor, root.autoOn)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleAuto()
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.nudge(delta > 0 ? 10 : -10) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursorRow(dx)
      }
      onActivateRequested: root.activateCursorRow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "A") root.toggleAuto()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.hasCursorOn("auto")
            function focusHero() {
              root.cursorActive = true
              root.cursorIndex = Math.max(0, root.rowIndex("auto"))
            }

            PanelHero {
              id: hero
              width: parent.width
              title: "Keyboard backlight"
              meta: Model.statusLine(root.livePercent, root.liveLux, root.hasSensor, root.autoOn)
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: Model.icon(root.livePercent, root.autoOn)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: autoSwitch
                  visible: root.hasSensor
                  checked: root.config.auto
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: root.toggleAuto()

                  PanelToolTip {
                    visible: autoSwitch.containsMouse
                    text: root.config.auto ? "Stop following the light sensor" : "Follow the light sensor"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.hasSensor
            width: parent.width
            text: "No ambient light sensor found. Manual control only."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // ---- Manual ----------------------------------------------------
          Column {
            visible: !root.autoOn
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "BRIGHTNESS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SettingSlider {
              width: parent.width
              settingKey: "manualPercent"
              label: "Level"
              suffix: "%"
              // Track the pointer on the hardware while dragging; the value is
              // only written to shell.json once the drag ends.
              live: true
            }
          }

          // ---- Auto ------------------------------------------------------
          Column {
            visible: root.autoOn
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "RANGE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SettingSlider {
              width: parent.width
              settingKey: "maxPercent"
              label: "In the dark"
              suffix: "%"
              live: true
            }

            SettingSlider {
              width: parent.width
              settingKey: "minPercent"
              label: "In bright light"
              suffix: "%"
              live: true
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "THRESHOLDS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "The sensor reports raw units, not calibrated lux. Set these "
                + "from the light you actually have: the reading right now is "
                + (root.liveLux >= 0 ? root.liveLux : "—") + "."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SettingSlider {
              width: parent.width
              settingKey: "luxDark"
              label: "Dark below"
              suffix: ""
              showUseCurrent: true
            }

            SettingSlider {
              width: parent.width
              settingKey: "luxBright"
              label: "Bright above"
              suffix: ""
              showUseCurrent: true
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "RESPONSE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              PresetButton { preset: "slow";   label: "Slow" }
              PresetButton { preset: "normal"; label: "Normal" }
              PresetButton { preset: "fast";   label: "Fast" }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "j/k move · h/l adjust · a toggles auto · enter uses the current reading"
            color: Qt.darker(root.foreground, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // A labeled slider bound to one settings key, plus the optional "use the
  // current reading" button the two thresholds need. Declared inline so the
  // bounds, the cursor wiring, and the persist call stay next to the rows they
  // belong to.
  component SettingSlider: Column {
    id: rowRoot

    property string settingKey: ""
    property string label: ""
    property string suffix: ""
    property bool showUseCurrent: false
    // Preview the value on the hardware while the knob is being dragged.
    property bool live: false

    readonly property var spec: root.sliderSpec(settingKey)
    readonly property int currentValue: Number(root.config[settingKey])
    readonly property bool focused: root.hasCursorOn(settingKey)

    spacing: Style.spacing.labelGap

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Text {
        textFormat: Text.PlainText
        width: parent.width - valueText.implicitWidth - parent.spacing
          - (useCurrent.visible ? useCurrent.implicitWidth + parent.spacing : 0)
        text: rowRoot.label
        color: rowRoot.focused ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      Button {
        id: useCurrent
        visible: rowRoot.showUseCurrent && root.liveLux >= 0
        text: "use " + root.liveLux
        fontSize: Style.font.caption
        foreground: root.foreground
        bordered: true
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.useCurrentReading(rowRoot.settingKey)
        onHovered: function(on) {
          if (!on) return
          root.cursorActive = true
          root.cursorIndex = Math.max(0, root.rowIndex(rowRoot.settingKey))
        }
      }

      Text {
        id: valueText
        textFormat: Text.PlainText
        text: rowRoot.currentValue + rowRoot.suffix
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      width: parent.width
      bar: root.bar
      value: rowRoot.currentValue
      minimum: rowRoot.spec ? rowRoot.spec.minimum : 0
      maximum: rowRoot.spec ? rowRoot.spec.maximum : 100
      step: rowRoot.spec ? rowRoot.spec.step : 1
      integer: true
      fillColor: rowRoot.focused ? root.foreground : Qt.darker(root.foreground, 1.25)

      onMoved: function(value) {
        root.cursorActive = true
        root.cursorIndex = Math.max(0, root.rowIndex(rowRoot.settingKey))
        if (rowRoot.live && root.service) root.service.applyImmediate(value)
      }
      onReleased: function(value) { root.commitSetting(rowRoot.settingKey, value) }
    }
  }

  component PresetButton: Button {
    property string preset: ""
    property string label: ""

    text: label
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    bordered: true
    selected: root.activePreset === preset
    hasCursor: root.hasCursorOn("response") && root.activePreset === preset
    onClicked: root.applyPreset(preset)
    onHovered: function(on) {
      if (!on) return
      root.cursorActive = true
      root.cursorIndex = Math.max(0, root.rowIndex("response"))
    }
  }
}
