# Omarchy Agent

The Omarchy Agent is a persistent desktop agent in the center of the Omarchy
bar. It uses [Pi](https://pi.dev) as its provider-agnostic coding-agent engine,
so the same UI can use ChatGPT/Codex, Claude, OpenRouter, Ollama, or any other
provider Pi supports.

## Current vertical slice

- Center-bar OS-face mark; click to open a two-pane thread/chat dropdown.
- First-run provider selection without copying API keys into the plugin.
- Pi RPC sessions stored under `~/.local/state/omarchy-agent/sessions/`.
- Full logs remain on disk; `threads.json` is only an index used to name, pin,
  and hide dormant threads.
- Heuristic project detection (`plugin`, `develop`, `build`, etc.) pins a new
  work thread immediately. The next phase replaces that heuristic with a cheap
  post-turn classifier that can improve the title and pin decision.
- Every Pi runner receives the Omarchy skill and a live snapshot of current
  keybindings and installed plugins when it starts.
- Pi's native token-aware compaction preserves a structured working summary as
  a conversation grows.

Install from this checkout:

```bash
./install.sh
```

Then click the center-bar face icon, choose a provider, and complete Pi's login
flow if needed. Pi stores OAuth/API credentials in `~/.pi/agent/auth.json`
with restrictive permissions; this plugin never reads or writes secrets.

## Design commitments

The background service owns all LLM execution. The QML interface talks only to
`$XDG_RUNTIME_DIR/omarchy-agent.sock` (mode `0600`), so a bar plugin cannot
accidentally leak credentials into QML settings or logs.

Thread cleanup is non-destructive: after 30 inactive days a thread leaves the
default list, but its Pi JSONL session remains searchable/reopenable. A future
thread browser will expose this archive directly. The service already marks
idle threads for review after 30 minutes; the next implementation step is to
ask Pi for a structured `continue | summarize | archive` decision at that
point, only while the thread is not running.

See [DESIGN.md](DESIGN.md) for the intended production architecture and phases.
