import QtQuick
import Quickshell
import Quickshell.Io

// Thin NDJSON client. The Node daemon owns threads, Pi RPC processes, and all
// filesystem access so this UI never sees credentials or writes chat logs.
Item {
  id: root
  property string pluginDir: ""
  property string socketPath: ""
  property bool autostartDaemon: true
  property bool online: false
  property bool statusLoaded: false
  property bool localStateLoaded: false
  property bool configured: false
  property bool providerReady: false
  property string providerReason: ""
  property string provider: ""
  property string model: ""
  property string thinking: "medium"
  property var threads: []
  property string activeThreadId: ""
  property var messages: []
  property string partial: ""
  property string errorText: ""
  property bool working: false
  property string activityText: ""
  property var pending: ({})
  property var socketRef: null
  property int pendingCount: 0
  readonly property string activityState: {
    if (!root.online) return "offline"
    if (root.partial.length > 0) return "receiving"
    if (root.working) return "working"
    if (root.pendingCount > 0) return "sending"
    return "ready"
  }
  readonly property string activityGlyph: {
    if (root.activityState === "sending") return "↕"
    if (root.activityState === "receiving") return "◌"
    if (root.activityState === "working") return "◌"
    if (root.activityState === "ready") return "●"
    return "○"
  }

  readonly property string effectiveSocketPath: socketPath.length > 0 ? socketPath : ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-agent.sock")
  readonly property string providerLabel: {
    if (root.provider === "codex") return "Codex"
    if (root.provider === "ollama") return "Ollama"
    if (root.provider === "anthropic") return "Claude"
    if (root.provider === "openrouter") return "OpenRouter"
    return root.provider
  }
  readonly property string modelLabel: root.model.length > 0 ? root.model : "default"

  // Hydrate the last selection immediately from the daemon's state file. The
  // socket status call still refreshes readiness, but the panel never has to
  // show an empty surface while that first request is in flight.
  FileView {
    id: localStateFile
    path: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/omarchy-agent/state.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyLocalState(text())
    onLoadFailed: {
      root.localStateLoaded = true
      root.statusLoaded = true
    }
    onFileChanged: reload()
  }

  function applyLocalState(raw) {
    try {
      var data = JSON.parse(raw || "{}")
      root.configured = data.configured === true
      root.provider = data.provider || ""
      root.model = data.model || ""
      root.thinking = data.thinking || "medium"
      // Codex uses the existing CLI OAuth session, and Ollama has no login
      // step. The live status reply below remains authoritative.
      root.providerReady = root.provider === "codex" || root.provider === "ollama"
    } catch (e) {
      root.configured = false
      root.provider = ""
      root.providerReady = false
    }
    root.localStateLoaded = true
    root.statusLoaded = true
  }

  function request(method, params, callback) {
    var socket = root.socketRef || socketLoader.item
    if (!socket || !root.online) return false
    var id = String(Date.now()) + "-" + Math.random()
    root.pending[id] = callback
    root.pendingCount += 1
    socket.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n")
    socket.flush()
    return true
  }
  function refresh() {
    request("status", {}, function(data) {
      root.configured = data.state.configured === true
      root.provider = data.state.provider || ""
      root.model = data.state.model || ""
      root.thinking = data.state.thinking || "medium"
      root.providerReady = data.providerStatus && data.providerStatus.ready === true
      root.providerReason = data.providerStatus ? (data.providerStatus.reason || "") : ""
      root.statusLoaded = true
      root.threads = data.threads || []
    })
  }
  function setThinking(level) {
    request("setThinking", { thinking: level }, function(data) { root.thinking = data.thinking || level })
  }
  function renameThread(id, title) {
    request("renameThread", { threadId: id, title: title }, function(thread) {
      var list = root.threads.slice()
      for (var i = 0; i < list.length; i++) if (list[i].id === thread.id) list[i] = thread
      root.threads = list
    })
  }
  function deleteThread(id) {
    request("deleteThread", { threadId: id }, function(result) {
      root.threads = root.threads.filter(function(thread) { return thread.id !== result.id })
      if (root.activeThreadId === result.id) root.newThread()
    })
  }
  function chooseProvider(name) {
    request("configure", { provider: name }, function(data) { root.configured = true; root.provider = data.provider || name; root.providerReady = name === "ollama"; root.refresh() })
  }
  function openProviderSetup() {
    if (!root.provider || root.provider === "ollama" || root.provider === "codex") return
    loginRunner.command = ["omarchy-launch-tui", "--app-id=org.omarchy.agent.setup", "pi", "--provider", root.provider]
    loginRunner.running = true
  }
  function newThread() { root.activeThreadId = ""; root.messages = []; root.partial = ""; root.working = false; root.activityText = "" }
  function openThread(id) {
    root.activeThreadId = id; root.partial = ""; root.working = false; root.activityText = ""
    request("messages", { threadId: id }, function(data) { root.messages = data.messages || [] })
  }
  function send(text) {
    if (!text || !text.trim().length) return
    var message = text.trim()
    root.errorText = ""
    root.working = true
    root.activityText = "Thinking…"
    if (!root.activeThreadId) {
      request("createThread", { message: message }, function(thread) {
        root.activeThreadId = thread.id; root.threads.unshift(thread)
        root.messages = [{ role: "user", text: message }]; root.partial = ""
        root.request("send", { threadId: thread.id, message: message }, function() {})
      })
    } else {
      root.messages = root.messages.concat([{ role: "user", text: message }]); root.partial = ""
      request("send", { threadId: root.activeThreadId, message: message }, function() {})
    }
  }
  function startDaemon() { if (root.pluginDir.length > 0) daemonStarter.running = true }
  function updateSocketState() {
    var socket = root.socketRef || socketLoader.item
    if (!socket) {
      root.online = false
      reconnectTimer.restart()
      return
    }
    var isConnected = socket.connected === true
    root.online = isConnected
    if (isConnected) {
      root.reconnectAttempt = 0
      root.refresh()
    } else {
      reconnectTimer.start()
    }
  }
  function handleLine(line) {
    if (!line || !line.length) return
    try {
      var frame = JSON.parse(line)
      if (frame.id !== undefined) {
        var callback = root.pending[frame.id]; delete root.pending[frame.id]
        root.pendingCount = Math.max(0, root.pendingCount - 1)
        if (frame.ok && callback) callback(frame.data)
        else if (!frame.ok) { root.errorText = frame.error || "Agent request failed"; root.working = false; root.activityText = "" }
        return
      }
      if (frame.event === "assistantDelta" && frame.data.threadId === root.activeThreadId) { root.partial += frame.data.delta }
      if (frame.event === "activity" && frame.data.threadId === root.activeThreadId) {
        root.working = frame.data.active !== false
        root.activityText = frame.data.text || (root.working ? "Working…" : "")
      }
      if (frame.event === "turnEnd" && frame.data.threadId === root.activeThreadId) {
        if (root.partial.length > 0) root.messages = root.messages.concat([{ role: "assistant", text: root.partial }])
        root.partial = ""; root.working = false; root.activityText = ""; root.refresh()
      }
    } catch (e) { root.errorText = "Could not read response from agent service" }
  }
  Component {
    id: socketComponent
    Socket {
      id: agentSocket
      path: root.effectiveSocketPath
      connected: true
      parser: SplitParser { splitMarker: "\n"; onRead: function(line) { root.handleLine(line) } }
      onConnectionStateChanged: {
        root.socketRef = agentSocket
        var isConnected = agentSocket.connected === true
        root.online = isConnected
        if (isConnected) {
          root.reconnectAttempt = 0
          root.refresh()
        } else {
          reconnectTimer.restart()
        }
      }
      onError: function(error) { root.online = false; root.startDaemon(); reconnectTimer.restart() }
      Component.onCompleted: {
        root.socketRef = agentSocket
        Qt.callLater(root.updateSocketState)
      }
      Component.onDestruction: {
        if (root.socketRef === agentSocket) root.socketRef = null
      }
    }
  }
  // Create the client socket with the widget.  The daemon is a user service,
  // so there is no benefit to delaying this until the panel is opened; doing
  // so could leave the panel with every content view hidden while status was
  // still waiting for the first connection.
  Loader {
    id: socketLoader
    active: true
    sourceComponent: socketComponent
  }
  Process { id: daemonStarter; command: [root.pluginDir + "/bin/omarchy-agent-ensure"]; onExited: reconnectTimer.restart() }
  Process { id: loginRunner }
  property int reconnectAttempt: 0
  Timer {
    id: reconnectTimer
    interval: Math.min(3000, 500 + root.reconnectAttempt * 250)
    repeat: false
    onTriggered: {
      if (root.online) return
      root.reconnectAttempt += 1
      socketLoader.active = false
      Qt.callLater(function() { socketLoader.active = true })
    }
  }
  Timer { interval: 2000; running: root.statusLoaded && root.provider.length > 0 && !root.providerReady; repeat: true; onTriggered: root.refresh() }
  Component.onCompleted: {
    if (root.autostartDaemon) root.startDaemon()
    Qt.callLater(root.updateSocketState)
  }
}
