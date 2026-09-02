#!/usr/bin/env node
// The daemon deliberately owns provider execution and all durable state.  QML
// only sees the unix socket; credentials stay in Pi's 0600 auth store.
import { createServer } from "node:net";
import { mkdir, chmod, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { spawn, execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const home = homedir();
const runtime = process.env.XDG_RUNTIME_DIR || "/tmp";
const stateDir = process.env.OMARCHY_AGENT_STATE_DIR || join(home, ".local/state/omarchy-agent");
const sessionDir = join(stateDir, "sessions");
const socketPath = process.env.OMARCHY_AGENT_SOCKET || join(runtime, "omarchy-agent.sock");
const statePath = join(stateDir, "state.json");
const threadsPath = join(stateDir, "threads.json");
const idleReviewMs = 30 * 60 * 1000;
const runnerIdleMs = 15 * 60 * 1000;
const clients = new Set();
const runners = new Map();

const defaults = { provider: "", model: "", thinking: "medium", configured: false, version: 1 };
let state = { ...defaults };
let threads = [];

async function readJson(path, fallback) {
  try { return JSON.parse(await readFile(path, "utf8")); } catch { return fallback; }
}
async function writeJson(path, value) {
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, path);
  await chmod(path, 0o600);
}
function broadcast(event, data) {
  const line = `${JSON.stringify({ event, data })}\n`;
  for (const socket of clients) socket.write(line);
}
function threadSummary(thread) {
  return {
    id: thread.id, title: thread.title, project: thread.project,
    pinned: thread.pinned, archived: thread.archived, createdAt: thread.createdAt,
    lastActivity: thread.lastActivity, preview: thread.preview || ""
  };
}
function titleFor(message) {
  const words = message.replace(/\s+/g, " ").trim().split(" ").slice(0, 7).join(" ");
  return words.length > 56 ? `${words.slice(0, 53)}…` : words || "New conversation";
}
function isProject(message) { return /\b(plugin|develop|build|implement|project|repository|repo)\b/i.test(message); }
function uiMessages(messages) {
  return messages.filter(message => message && (message.role === "user" || message.role === "assistant")).map(message => {
    let text = "";
    if (typeof message.content === "string") text = message.content;
    else if (Array.isArray(message.content)) text = message.content.filter(part => part && part.type === "text").map(part => part.text || "").join("");
    return { role: message.role, text, timestamp: message.timestamp || Date.now() };
  }).filter(message => message.text.length > 0);
}
async function writeState() { await writeJson(statePath, state); }
async function writeThreads() { await writeJson(threadsPath, threads); }

function configuredModel() {
  if (state.model) return state.model;
  if (state.provider !== "codex") return "default";
  if (process.env.CODEX_MODEL) return process.env.CODEX_MODEL;
  try {
    const config = readFileSync(join(home, ".codex/config.toml"), "utf8");
    return config.match(/^model\s*=\s*["']([^"']+)["']/m)?.[1] || "default";
  } catch { return "default"; }
}

function activityForItem(item, phase = "started") {
  const type = item?.type || "";
  if (type === "reasoning") return "Thinking…";
  if (type === "agent_message") return phase === "completed" ? "Finishing…" : "Writing…";
  if (type === "command_execution") return phase === "completed" ? "Finished running a command" : "Running a command…";
  if (type === "mcp_tool_call" || type === "function_call" || type === "custom_tool_call") return "Using a tool…";
  if (type === "web_search_call") return "Searching the web…";
  if (type === "file_change" || type === "file_edit") return "Editing files…";
  if (type === "computer_call") return "Working with the desktop…";
  return phase === "completed" ? "Working…" : "Thinking…";
}

function activityForPiEvent(event) {
  if (event.type === "tool_execution_start") {
    const name = event.toolName || event.toolCall?.name || event.tool?.name;
    return name ? `Using ${name}…` : "Using a tool…";
  }
  if (event.type === "tool_execution_update") return "Using a tool…";
  if (event.type === "tool_execution_end") return "Thinking…";
  if (event.type === "message_update" && event.assistantMessageEvent?.type === "text_delta") return "Writing…";
  if (event.type === "turn_start" || event.type === "message_start") return "Thinking…";
  return "";
}

async function runtimeContext() {
  const commands = [
    ["omarchy", ["menu", "keybindings", "--print"]],
    ["omarchy", ["plugin", "list", "--json"]]
  ];
  const results = await Promise.all(commands.map(async ([cmd, args]) => {
    try { return (await execFileAsync(cmd, args, { timeout: 3000, maxBuffer: 256 * 1024 })).stdout.trim(); }
    catch { return "Unavailable"; }
  }));
  return [
    "You are the user's Omarchy Agent: a practical, careful steward of their Linux desktop.",
    "You may inspect and change the user's Omarchy configuration when asked. Explain consequential changes before making them.",
    "The Omarchy skill is authoritative for safe desktop configuration. Read the relevant skill instructions before changing ~/.config/.",
    "This is a persistent conversation. Pi handles token-driven compaction; durable session logs must be treated as source history.",
    "", "## Live desktop snapshot", "### Current keybindings", results[0], "", "### Installed plugins", results[1]
  ].join("\n");
}
async function providerStatus() {
  if (!state.provider) return { ready: false, reason: "Choose a provider" };
  if (state.provider === "codex") {
    try {
      const { stdout, stderr } = await execFileAsync("codex", ["login", "status"], { timeout: 10000 });
      const status = `${stdout}\n${stderr}`;
      return { ready: /Logged in/i.test(status), reason: /Logged in/i.test(status) ? "" : "Log in to Codex" };
    } catch { return { ready: false, reason: "Codex CLI is not available" }; }
  }
  if (state.provider === "ollama") {
    try { await execFileAsync("ollama", ["list"], { timeout: 3000 }); return { ready: true, reason: "" }; }
    catch { return { ready: false, reason: "Ollama is not running" }; }
  }
  try {
    const { stdout } = await execFileAsync(process.env.OMARCHY_AGENT_PI || "pi", ["auth", "check", "--provider", state.provider, "--json"], { timeout: 10000 });
    const result = JSON.parse(stdout);
    return { ready: result.status === "ready", reason: result.reason || (result.status === "ready" ? "" : "Sign-in is required") };
  } catch { return { ready: false, reason: "Could not verify provider sign-in" }; }
}

class Runner {
  constructor(thread) { this.thread = thread; this.pending = new Map(); this.buffer = ""; this.lastUsed = Date.now(); }
  async start() {
    if (this.process) return;
    const access = await providerStatus();
    if (!access.ready) throw new Error(`${state.provider || "Selected provider"} is not ready: ${access.reason}`);
    if (state.provider === "codex") { this.backend = "codex"; return; }
    this.backend = "pi";
    const context = await runtimeContext();
    const args = ["--mode", "rpc", "--session-dir", sessionDir, "--session-id", this.thread.id,
      "--name", this.thread.title, "--skill", "/usr/share/omarchy/default/agents/skills/omarchy",
      "--append-system-prompt", context];
    if (state.provider) args.push("--provider", state.provider);
    if (state.model) args.push("--model", state.model);
    if (state.thinking) args.push("--thinking", state.thinking);
    this.process = spawn(process.env.OMARCHY_AGENT_PI || "pi", args, { cwd: home, stdio: ["pipe", "pipe", "pipe"] });
    this.process.stdout.on("data", data => this.onData(data));
    this.process.stderr.on("data", data => broadcast("diagnostic", { threadId: this.thread.id, text: String(data) }));
    this.process.on("exit", () => { this.process = null; runners.delete(this.thread.id); broadcast("runner", { threadId: this.thread.id, online: false }); });
    broadcast("runner", { threadId: this.thread.id, online: true });
  }
  onData(chunk) {
    this.buffer += String(chunk);
    let at;
    while ((at = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, at).replace(/\r$/, ""); this.buffer = this.buffer.slice(at + 1);
      if (!line) continue;
      try { this.onEvent(JSON.parse(line)); } catch { broadcast("diagnostic", { threadId: this.thread.id, text: "Pi emitted invalid RPC JSON" }); }
    }
  }
  onEvent(event) {
    if (event.type === "response" && event.id && this.pending.has(event.id)) {
      const { resolve, reject } = this.pending.get(event.id); this.pending.delete(event.id);
      event.success ? resolve(event.data) : reject(new Error(event.error?.message || "Pi rejected request")); return;
    }
    const activity = activityForPiEvent(event);
    if (activity) broadcast("activity", { threadId: this.thread.id, text: activity, active: true });
    if (event.type === "message_update" && event.assistantMessageEvent?.type === "text_delta")
      broadcast("assistantDelta", { threadId: this.thread.id, delta: event.assistantMessageEvent.delta });
    else if (event.type === "turn_end") {
      broadcast("activity", { threadId: this.thread.id, text: "", active: false });
      broadcast("turnEnd", { threadId: this.thread.id });
    } else if (event.type === "agent_end") {
      broadcast("activity", { threadId: this.thread.id, text: "", active: false });
      broadcast("agentEnd", { threadId: this.thread.id });
    }
  }
  rpc(command) {
    this.lastUsed = Date.now();
    const id = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject }); this.process.stdin.write(`${JSON.stringify({ ...command, id })}\n`);
    });
  }
  async messages() {
    await this.start();
    return this.backend === "codex" ? (this.thread.messages || []) : ((await this.rpc({ type: "get_messages" })).messages || []);
  }
  async codexPrompt(message) {
    const context = await runtimeContext();
    const prompt = this.thread.codexSessionId
      ? `${message}\n\n## Current Omarchy desktop snapshot\n${context}`
      : `${context}\n\n## User request\n${message}`;
    // `exec resume` has a smaller option set than a new `exec` invocation:
    // workspace/sandbox flags belong only on the initial session command.
    const resumeOptions = ["--json", "--skip-git-repo-check"];
    const newSessionOptions = ["--json", "--skip-git-repo-check", "--cd", home];
    const args = this.thread.codexSessionId
      ? ["exec", "resume", ...resumeOptions, this.thread.codexSessionId, prompt]
      : ["exec", ...newSessionOptions, "--sandbox", "workspace-write", "--add-dir", home, prompt];
    this.lastUsed = Date.now();
    broadcast("activity", { threadId: this.thread.id, text: "Thinking…", active: true });
    return new Promise((resolve, reject) => {
      let buffer = "";
      const child = this.commandProcess = spawn("codex", args, { cwd: home, stdio: ["ignore", "pipe", "pipe"] });
      const consume = line => {
        if (!line) return;
        try {
          const event = JSON.parse(line);
          if (event.type === "thread.started" && event.thread_id) { this.thread.codexSessionId = event.thread_id; writeThreads(); }
          if (event.type === "item.started" || event.type === "item.updated") {
            broadcast("activity", { threadId: this.thread.id, text: activityForItem(event.item), active: true });
          }
          if (event.type === "item.completed" && event.item?.type === "agent_message" && event.item.text) {
            const item = { role: "assistant", text: event.item.text, timestamp: Date.now() };
            this.thread.messages = [...(this.thread.messages || []), item]; writeThreads();
            broadcast("assistantDelta", { threadId: this.thread.id, delta: event.item.text });
          }
          if (event.type === "item.completed") {
            broadcast("activity", { threadId: this.thread.id, text: activityForItem(event.item, "completed"), active: true });
          }
          if (event.type === "turn.completed") {
            broadcast("activity", { threadId: this.thread.id, text: "", active: false });
            broadcast("turnEnd", { threadId: this.thread.id });
          }
        } catch { broadcast("diagnostic", { threadId: this.thread.id, text: "Codex emitted invalid JSON" }); }
      };
      child.stdout.on("data", data => { buffer += String(data); let at; while ((at = buffer.indexOf("\n")) >= 0) { consume(buffer.slice(0, at)); buffer = buffer.slice(at + 1); } });
      child.stderr.on("data", data => broadcast("diagnostic", { threadId: this.thread.id, text: String(data) }));
      child.on("error", reject);
      child.on("exit", code => { this.commandProcess = null; if (code === 0) { broadcast("activity", { threadId: this.thread.id, text: "", active: false }); broadcast("turnEnd", { threadId: this.thread.id }); resolve({ accepted: true }); } else reject(new Error(`Codex exited with status ${code}`)); });
    });
  }
  async prompt(message) {
    await this.start();
    broadcast("activity", { threadId: this.thread.id, text: "Thinking…", active: true });
    return this.backend === "codex" ? this.codexPrompt(message) : this.rpc({ type: "prompt", message });
  }
  stop() { this.process?.kill("SIGTERM"); this.commandProcess?.kill("SIGTERM"); }
}
async function runnerFor(thread) { let runner = runners.get(thread.id); if (!runner) { runner = new Runner(thread); runners.set(thread.id, runner); } await runner.start(); return runner; }

async function dispatch(method, params = {}) {
  if (method === "status") return { state: { ...state, model: configuredModel() }, providerStatus: await providerStatus(), threads: threads.filter(t => !t.archived).map(threadSummary) };
  if (method === "configure") {
    state = { ...state, provider: String(params.provider || ""), model: String(params.model || ""), configured: true };
    for (const runner of runners.values()) runner.stop();
    runners.clear();
    await writeState(); return state;
  }
  if (method === "setThinking") {
    const levels = ["off", "low", "medium", "high", "xhigh"];
    if (!levels.includes(params.thinking)) throw new Error("Unsupported thinking level");
    state = { ...state, thinking: params.thinking }; await writeState();
    await Promise.all([...runners.values()].map(runner => runner.rpc({ type: "set_thinking_level", level: state.thinking }).catch(() => null)));
    return state;
  }
  if (method === "threads") {
    const cutoff = Date.now() - (Number(params.hideDormantAfterDays || 30) * 86400000);
    return threads.filter(t => params.includeArchived || (!t.archived && t.lastActivity >= cutoff)).map(threadSummary);
  }
  if (method === "createThread") {
    const now = Date.now(), initial = String(params.message || "");
    const thread = { id: crypto.randomUUID(), title: titleFor(initial), preview: initial, project: isProject(initial), pinned: isProject(initial), archived: false, createdAt: now, lastActivity: now };
    threads.unshift(thread); await writeThreads(); return threadSummary(thread);
  }
  const thread = threads.find(t => t.id === params.threadId);
  if (!thread) throw new Error("Thread not found");
  if (method === "messages") {
    const messages = await (await runnerFor(thread)).messages();
    return { messages: state.provider === "codex" ? messages : uiMessages(messages) };
  }
  if (method === "send") {
    const message = String(params.message || "").trim(); if (!message) throw new Error("Message cannot be empty");
    thread.lastActivity = Date.now(); thread.preview = message; thread.archived = false;
    if (state.provider === "codex") thread.messages = [...(thread.messages || []), { role: "user", text: message, timestamp: Date.now() }];
    await writeThreads();
    await (await runnerFor(thread)).prompt(message); return { accepted: true };
  }
  if (method === "setPinned") { thread.pinned = Boolean(params.pinned); await writeThreads(); return threadSummary(thread); }
  if (method === "archive") { thread.archived = true; await writeThreads(); return threadSummary(thread); }
  throw new Error(`Unknown method: ${method}`);
}

async function main() {
  await mkdir(sessionDir, { recursive: true, mode: 0o700 });
  state = { ...defaults, ...await readJson(statePath, {}) };
  if (state.provider === "openai-codex") { state.provider = "codex"; await writeState(); }
  threads = await readJson(threadsPath, []);
  if (existsSync(socketPath)) await unlink(socketPath);
  const server = createServer(socket => {
    clients.add(socket); let buffer = "";
    socket.on("data", async data => {
      buffer += String(data); let at;
      while ((at = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, at); buffer = buffer.slice(at + 1); if (!line) continue;
        let request; try { request = JSON.parse(line); } catch { socket.write('{"ok":false,"error":"Invalid JSON"}\n'); continue; }
        try { socket.write(`${JSON.stringify({ id: request.id, ok: true, data: await dispatch(request.method, request.params) })}\n`); }
        catch (error) { socket.write(`${JSON.stringify({ id: request.id, ok: false, error: error.message })}\n`); }
      }
    });
    socket.on("close", () => clients.delete(socket));
    socket.on("error", () => clients.delete(socket));
  });
  server.listen(socketPath, async () => { await chmod(socketPath, 0o600); console.log(`Omarchy Agent listening at ${socketPath}`); });
  setInterval(async () => {
    const now = Date.now();
    for (const [id, runner] of runners) if (now - runner.lastUsed > runnerIdleMs) runner.stop();
    for (const thread of threads) if (!thread.archived && now - thread.lastActivity > idleReviewMs && !thread.idleReviewDueAt) thread.idleReviewDueAt = now;
    await writeThreads();
  }, 60000).unref();
}
main().catch(error => { console.error(error); process.exit(1); });
