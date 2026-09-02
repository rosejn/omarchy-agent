import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// A small OS mark with two eyes: it stays recognisable at bar size and inherits
// every Omarchy theme instead of relying on a fixed-color bitmap asset.
BarWidget {
  id: root
  moduleName: "org.omarchy.agent"
  readonly property string pluginDir: {
    var path = Qt.resolvedUrl(".").toString(); if (path.indexOf("file://") === 0) path = path.substring(7)
    return decodeURIComponent(path.endsWith("/") ? path.slice(0, -1) : path)
  }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function inject() { if (panelLoader.item) { panelLoader.item.bar = root.bar; panelLoader.item.anchorItem = button; panelLoader.item.client = client } }
  onBarChanged: inject()
  onSettingsChanged: inject()

  AgentClient {
    id: client
    pluginDir: root.pluginDir
    socketPath: root.setting("socketPath", "")
    autostartDaemon: root.setting("autostartDaemon", true) === true
  }
  Loader { id: panelLoader; active: true; source: Qt.resolvedUrl("Panel.qml"); visible: false; onLoaded: root.inject() }
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Rounded-face mark, deliberately drawn from text so it follows themes.
    text: "☻"
    active: panelLoader.item && panelLoader.item.opened
    dimmed: !client.online
    tooltipText: client.configured ? "Omarchy Agent" : "Set up Omarchy Agent"
    onPressed: function(buttonCode) { if (buttonCode === Qt.LeftButton) root.toggle() }
  }

  // Quiet health/activity signal: arrows while a request is being handed off,
  // a turning ring while the model is answering, and a steady dot when idle.
  Text {
    id: activityMark
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    z: 2
    text: client.activityGlyph
    color: client.activityState === "offline" ? Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35) : (root.bar ? root.bar.foreground : Color.foreground)
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    opacity: client.activityState === "ready" ? 0.72 : 0.9
    RotationAnimation on rotation {
      running: client.activityState === "receiving"
      from: 0; to: 360; duration: 1100; loops: Animation.Infinite
    }
    SequentialAnimation on opacity {
      running: client.activityState === "sending"
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 500 }
      NumberAnimation { to: 0.9; duration: 500 }
    }
  }
}
