import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "oma.quake"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    else if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function sendStatusNotification() {
    if (panelLoader.item && panelLoader.item.sendStatusNotification)
      panelLoader.item.sendStatusNotification()
  }

  readonly property string displayText: panelLoader.item
    ? panelLoader.item.pillText(root.vertical)
    : Model.barLabel(null, root.vertical)
  readonly property bool alerting: panelLoader.item ? panelLoader.item.alerting === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: true
    active: root.alerting
    tooltipText: panelLoader.item ? panelLoader.item.tooltipText : ""
    keepSpace: true
    opacity: pulse.running ? pulse.opacity : 1

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.sendStatusNotification()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    OpticalGlyph {
      visible: root.vertical
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      text: Model.QUAKE_GLYPH
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.active ? button.activeColor : button.foreground
    }
  }

  SequentialAnimation {
    id: pulse
    running: root.alerting
    loops: Animation.Infinite
    property real opacity: 1
    NumberAnimation { target: pulse; property: "opacity"; to: 0.55; duration: 700; easing.type: Easing.InOutSine }
    NumberAnimation { target: pulse; property: "opacity"; to: 1; duration: 700; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) pulse.opacity = 1
  }
}
