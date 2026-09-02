# Omarchy Agent design

## Product model

One agent represents the operating system, rather than another terminal
launcher. A person should be able to ask for help, inspect their desktop,
develop a plugin, or make a deliberate system change from one durable thread.

```
Bar dropdown (QML)
  ├─ thread list: active projects first, dormant archive on demand
  └─ chat panel: streamed Pi RPC events
          │ 0600 Unix socket
          ▼
Node daemon
  ├─ thread index + policy metadata        ~/.local/state/omarchy-agent/
  ├─ Pi JSONL session logs                 ~/.local/state/omarchy-agent/sessions/
  ├─ dynamic desktop snapshot              keybindings, plugin list, safe paths
  └─ Pi runner                             provider auth lives in ~/.pi/agent/
          │
          └─ Omarchy skill + Pi tools
```

## Context and memory policy

Pi provides the first, essential layer: token-bound auto-compaction retains a
structured work summary plus recent messages, while original JSONL entries are
never discarded. The agent daemon adds a second layer:

1. On each runner start, generate a compact live desktop snapshot.
2. After 30 quiet minutes, evaluate the final activity with a low-cost,
   tool-free classifier: `continue`, `summarize`, or `archive`.
3. Summarize only a concluded thread; leave an active project intact.
4. Persist title, project status, pinning, and summary in the thread index.
5. Hide inactive threads from the default list after 30 days, never delete
   their logs. Full-text archive search can rehydrate any thread.

The classifier is deliberately separate from the main agent: it cannot run
tools or mutate the system, and it receives only the recent activity plus the
existing Pi summary. This prevents background "helpfulness" from making changes
or silently spending a large context budget.

## Provider onboarding

Provider cards set Pi's provider selection only. They never accept credentials
in QML. On first selection, launch Pi's official `/login` flow for OAuth or API
key storage. Existing Pi auth is reused automatically. Local Ollama requires a
running local service and a model selected in Pi.

## Delivery phases

1. **Vertical slice (this repository):** plugin shell, Pi RPC daemon, durable
   threads, provider selection, live Omarchy context, streaming chat.
2. **Safe action UX:** display Pi tool calls and require an explicit approval
   policy for command classes that alter the desktop.
3. **Memory intelligence:** LLM title/project classifier, idle decision,
   searchable archived thread browser, manual pin and rename.
4. **Omarchy-native expertise:** curated read-only context collectors, plugin
   creation templates, diagnostics, and per-action diffs/rollback guidance.
5. **Polish:** rich markdown, command output cards, attachments, notifications,
   accessibility, tests, and package/update integration.
