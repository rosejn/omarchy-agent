import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Intentionally only two panes: durable thread navigation and the conversation.
Panel {
  id: root
  moduleName: "org.omarchy.agent"
  manageIpc: false
  property var anchorItem: null
  property var bar: null
  property var client: null
  property bool threadsCollapsed: false
  property bool settingsOpen: false
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(foreground, 1.55)
  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function choose(provider) { if (client) client.chooseProvider(provider) }
  Process { id: dictation; command: ["voxtype", "record", "toggle"] }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: composer
    contentWidth: Style.space(760)
    contentHeight: Style.space(540)

    PanelKeyCatcher {
      anchors.fill: parent
      blocked: composer.activeFocus
      onCloseRequested: root.close()

      Rectangle {
        anchors.fill: parent
        color: Color.background

        // First start: pick the Pi provider. Authentication continues in Pi's
        // own protected flow, never through this plugin's socket or state files.
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(48)
          spacing: Style.space(14)
          visible: root.client && root.client.statusLoaded && root.client.provider.length === 0

          Text { width: parent.width; text: "Meet your Omarchy Agent"; color: root.foreground; horizontalAlignment: Text.AlignHCenter; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
          Text { width: parent.width; text: "Choose a provider. Your sign-in and API keys stay in Pi’s own secure auth store."; color: root.muted; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.family: Style.font.family; font.pixelSize: Style.font.body }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)
            Repeater {
              model: [
                { label: "Codex", provider: "codex", detail: "Uses your Codex login" },
                { label: "Claude", provider: "anthropic", detail: "Claude login or key" },
                { label: "OpenRouter", provider: "openrouter", detail: "Many hosted models" },
                { label: "Ollama", provider: "ollama", detail: "Local models" }
              ]
              delegate: Rectangle {
                required property var modelData
                width: Style.space(145); height: Style.space(92)
                color: setupHover.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : Style.normalFillFor(root.foreground, Color.accent)
                border.color: root.foreground; border.width: 1
                Column {
                  anchors.centerIn: parent
                  spacing: Style.space(4)
                  Text { text: parent.parent.modelData.label; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter }
                  Text { text: parent.parent.modelData.detail; color: root.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter }
                }
                MouseArea { id: setupHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.choose(parent.modelData.provider); if (parent.modelData.provider !== "ollama") root.client.openProviderSetup() } }
              }
            }
          }
          Text { width: parent.width; text: "After choosing, run /login in Pi once if the provider needs authentication."; color: root.muted; horizontalAlignment: Text.AlignHCenter; font.family: Style.font.family; font.pixelSize: Style.font.caption }
        }

        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(96)
          spacing: Style.space(12)
          visible: root.client && root.client.statusLoaded && root.client.provider.length > 0 && !root.client.providerReady
          Text { width: parent.width; text: "Finish connecting " + root.client.provider; color: root.foreground; horizontalAlignment: Text.AlignHCenter; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
          Text { width: parent.width; text: root.client.providerReason || "Sign-in is required before this provider can answer."; color: root.muted; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.family: Style.font.family; font.pixelSize: Style.font.body }
            Text { anchors.horizontalCenter: parent.horizontalCenter; visible: root.client.provider !== "codex"; text: "Open sign-in"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.client.openProviderSetup() } }
        }

        Row {
          anchors.fill: parent
          anchors.margins: Style.space(12)
          spacing: 0
          visible: root.client && root.client.statusLoaded && root.client.providerReady

          Item {
            width: root.threadsCollapsed ? Style.space(28) : Style.space(210)
            height: parent.height
            Column {
              anchors.fill: parent
              spacing: Style.space(7)
              Row {
                width: parent.width
                Text { text: root.threadsCollapsed ? "›" : "Conversations"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.bold: true; width: root.threadsCollapsed ? parent.width : parent.width - newThread.width - Style.space(4); horizontalAlignment: root.threadsCollapsed ? Text.AlignHCenter : Text.AlignLeft; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.threadsCollapsed = !root.threadsCollapsed } }
                Text { id: newThread; visible: !root.threadsCollapsed; text: "+"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; width: Style.space(24); horizontalAlignment: Text.AlignRight; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.client.newThread() } }
              }
              ListView {
                visible: !root.threadsCollapsed
                width: parent.width; height: parent.height - y - Style.space(26); clip: true; model: root.client.threads; spacing: Style.space(3)
                delegate: Item {
                  required property var modelData
                  width: ListView.view.width; height: Style.space(48)
                  Rectangle { anchors.fill: parent; color: root.client.activeThreadId === modelData.id ? Qt.rgba(0.5, 0.5, 0.5, 0.16) : "transparent"; radius: Style.space(5) }
                  Column {
                    anchors.fill: parent; anchors.margins: Style.space(5)
                    Text { width: parent.width; text: (parent.parent.modelData.pinned ? "★ " : "") + parent.parent.modelData.title; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: parent.parent.modelData.pinned; elide: Text.ElideRight }
                    Text { width: parent.width; text: parent.parent.modelData.preview || ""; color: root.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                  }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.client.openThread(parent.modelData.id) }
                }
              }
              Text {
                visible: !root.threadsCollapsed
                width: parent.width
                text: "⚙"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsOpen = !root.settingsOpen }
              }
            }
          }

          Rectangle { width: 1; height: parent.height; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35) }

          Item {
            width: parent.width - (root.threadsCollapsed ? Style.space(29) : Style.space(211)); height: parent.height
            Column {
            anchors.fill: parent
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(7)
            Row {
              width: parent.width
              Text { text: root.client.activeThreadId.length > 0 ? "Omarchy Agent" : "New conversation"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.bold: true; width: parent.width - thinkingControl.width - statusMark.width - Style.space(12); elide: Text.ElideRight }
              Text {
                id: statusMark
                text: root.client.activityGlyph
                color: root.client.activityState === "offline" ? root.muted : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                width: Style.space(14)
                horizontalAlignment: Text.AlignHCenter
                RotationAnimation on rotation {
                  running: root.client.activityState === "receiving" || root.client.activityState === "working"
                  from: 0; to: 360; duration: 1100; loops: Animation.Infinite
                }
                SequentialAnimation on opacity {
                  running: root.client.activityState === "sending"
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.35; duration: 500 }
                  NumberAnimation { to: 0.9; duration: 500 }
                }
              }
              Text { id: thinkingControl; text: root.client.providerLabel + " " + root.client.modelLabel + " - Thinking: " + root.client.thinking; color: root.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideLeft; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: thinkingMenu.open() } }
              Popup {
                id: thinkingMenu
                parent: panel
                x: thinkingControl.mapToItem(panel, thinkingControl.width - width, 0).x
                y: thinkingControl.mapToItem(panel, 0, thinkingControl.height).y + Style.space(6)
                width: Style.space(132)
                padding: Style.space(4)
                background: Rectangle {
                  color: Color.background
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
                  border.width: 1
                  radius: Style.space(8)
                }
                contentItem: Column {
                  spacing: Style.space(2)
                  Repeater {
                    model: ["off", "low", "medium", "high", "xhigh"]
                    delegate: Rectangle {
                      required property string modelData
                      width: thinkingMenu.width - thinkingMenu.padding * 2
                      height: Style.space(26)
                      radius: Style.space(5)
                      color: optionMouse.containsMouse || root.client.thinking === modelData
                        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                        : "transparent"
                      Text {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8)
                        verticalAlignment: Text.AlignVCenter
                        text: modelData
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                      MouseArea {
                        id: optionMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.client.setThinking(modelData); thinkingMenu.close() }
                      }
                    }
                  }
                }
              }
            }
            Text { width: parent.width; visible: root.client.errorText.length > 0; text: root.client.errorText; color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            ListView {
              id: messageList
              width: parent.width; height: parent.height - composerBox.height - activityLine.height - Style.space(38); clip: true; model: root.client.messages; spacing: Style.space(7)
              onCountChanged: Qt.callLater(function() { messageList.positionViewAtEnd() })
              delegate: Item {
                required property var modelData
                width: ListView.view.width; height: bubble.height + Style.space(12)
                Rectangle {
                  id: bubble
                  width: Math.max(Style.space(260), parent.width * 0.78)
                  height: bubbleText.contentHeight + Style.space(12)
                  anchors.right: parent.modelData.role === "user" ? parent.right : undefined
                  anchors.left: parent.modelData.role === "user" ? undefined : parent.left
                  color: parent.modelData.role === "user" ? Qt.rgba(0.5, 0.5, 0.5, 0.22) : "transparent"
                  radius: parent.modelData.role === "user" ? Style.space(10) : 0
                  TextEdit { id: bubbleText; width: parent.width - Style.space(16); anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; anchors.topMargin: Style.space(6); height: contentHeight; text: parent.parent.modelData.text; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; wrapMode: TextEdit.WordWrap; readOnly: true; selectByMouse: true }
                }
              }
              footer: TextEdit { width: messageList.width * 0.78; visible: root.client.partial.length > 0; text: root.client.partial; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; wrapMode: TextEdit.Wrap; readOnly: true; selectByMouse: true }
            }
            Text {
              id: activityLine
              width: parent.width
              height: visible ? implicitHeight : 0
              visible: root.client.working
              text: "◌  " + (root.client.activityText || "Working…")
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              SequentialAnimation on opacity {
                running: activityLine.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.45; duration: 700 }
                NumberAnimation { to: 1.0; duration: 700 }
              }
            }
            Rectangle {
              id: composerBox
              width: parent.width; height: Math.min(Style.space(150), Math.max(Style.space(54), composer.contentHeight + Style.space(20))); color: Qt.rgba(0.5, 0.5, 0.5, 0.13); radius: Style.space(12); clip: true
              Flickable {
                id: composerScroll
                anchors.left: parent.left; anchors.right: dictationButton.left; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.margins: Style.space(10)
                contentWidth: width; contentHeight: composer.contentHeight; clip: true
                interactive: contentHeight > height
                TextEdit {
                  id: composer
                  width: composerScroll.width; height: contentHeight
                  color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; wrapMode: TextEdit.WordWrap; selectByMouse: true
                  onCursorRectangleChanged: {
                    if (cursorRectangle.y < composerScroll.contentY) composerScroll.contentY = cursorRectangle.y
                    else if (cursorRectangle.y + cursorRectangle.height > composerScroll.contentY + composerScroll.height) composerScroll.contentY = cursorRectangle.y + cursorRectangle.height - composerScroll.height
                  }
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Space && (event.modifiers & Qt.ShiftModifier)) {
                      composer.insert(composer.cursorPosition, "\n")
                      event.accepted = true
                    }
                  }
                  Keys.onReturnPressed: function(event) { if (!(event.modifiers & Qt.ShiftModifier)) { root.client.send(composer.text); composer.text = ""; event.accepted = true } }
                }
              }
              Text { id: dictationButton; text: "◉"; anchors.right: sendButton.left; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; color: root.muted; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { composer.forceActiveFocus(); dictation.running = true } } }
              Text { id: sendButton; text: "↑"; anchors.right: parent.right; anchors.rightMargin: Style.space(12); anchors.verticalCenter: parent.verticalCenter; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.title; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.client.send(composer.text); composer.text = "" } } }
            }
            }
          }
        }

        Popup {
          id: settingsPopup
          visible: root.settingsOpen
          x: Style.space(12)
          y: parent.height - height - Style.space(12)
          padding: Style.space(10)
          background: Rectangle { color: Color.background; radius: Style.space(8) }
          contentItem: Column {
            spacing: Style.space(8)
            Text { text: "Agent settings"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
            Repeater {
              model: [
                { label: "Codex", provider: "codex" },
                { label: "Claude", provider: "anthropic" },
                { label: "OpenRouter", provider: "openrouter" },
                { label: "Ollama", provider: "ollama" }
              ]
              delegate: Text {
                required property var modelData
                text: root.client.provider === modelData.provider ? "✓ " + modelData.label : modelData.label
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.client.chooseProvider(parent.modelData.provider); root.settingsOpen = false; if (parent.modelData.provider !== "ollama") root.client.openProviderSetup() } }
              }
            }
          }
        }
      }
    }
  }
}
