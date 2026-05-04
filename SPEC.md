# claude-memory — Architecture & Decision Log

## 1. Problem Statement

Claude Code (the CLI) ships an auto-memory feature: if `autoMemoryEnabled: true` is set in `~/.claude/settings.json`, Claude is expected to write durable memory entries into `~/.claude/projects/<encoded-cwd>/memory/` over the course of conversations. The mechanism is prompt-driven — the model decides mid-conversation when content is "memorable enough" to save. Two failure modes follow from that design:

### 1.1 Per-cwd silos

Memory is namespaced by cwd. Each working directory becomes its own folder under `~/.claude/projects/` (with the cwd path encoded into the folder name — e.g. `/path/to/project` becomes `-path-to-project`). A memory entry written while working in one cwd lives only in that cwd's memory folder and is **not visible** to a Claude Code session started in a sibling or parent cwd, even when the same person and the same broader project family are involved.

This becomes most painful when substantial work performed in a sub-project cwd is later referenced from the parent or a sibling cwd, because Claude only loads the current cwd's `MEMORY.md` at startup — even though the relevant entry exists, just one folder over.

### 1.2 Write-rate variance

The auto-memory rules in the global `~/.claude/CLAUDE.md` instruct Claude to save memory entries when certain triggers occur (user corrections, validated approaches, project state changes, external references cited). But because the trigger is interpretive ("did anything memorable happen?"), the model sometimes does not notice. Some sessions yield no memory entries despite producing content that would have been worth saving.

Both failures are **at session boundaries**:

- The cross-cwd silo is a **read-time** problem — at session start, only the current cwd's memory is loaded.
- The write-rate variance is a **write-time** problem — by the end of a session, content that should have been saved has not been.

Claude Code exposes a hook system (`SessionStart`, `PreCompact`, `Stop`, `SessionEnd`, etc.) that fires at exactly those boundaries. This repo uses those hooks to close both gaps.

## 2. Alternatives Considered

Before settling on hooks, the author surveyed several memory-system architectures. The matrix below is the relevant excerpt; full notes from the survey are kept in the user's session transcripts.

| System | Core idea | Why not adopted |
|---|---|---|
| [mem-palace](https://github.com/mempalace/mempalace) | Local-first verbatim transcript storage with hybrid semantic/lexical search; `wings/rooms/drawers` structure | Adds a vector DB stack; English-only default embedder needs replacement for the user's CJK conversations; overkill at the current memory volume (~64 entries) |
| [Obsidian + Basic Memory](https://docs.basicmemory.com/integrations/obsidian) | Markdown vault with `[[wiki-links]]`; Claude reads/writes via MCP | User's `Applied Learning` rule prefers CLI over MCP; introduces a vault-management workflow the user does not need yet; Obsidian's value (graph view, manual curation) does not address the write-rate variance |
| [Karpathy LLM Wiki / claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian) | `/wiki`, `/save`, `/autoresearch` slash commands compile sessions into a maintained wiki of 10–15 pages | Requires conscious workflow discipline; useful long-term but does not solve the immediate write-rate problem |
| [OpenClaw](https://github.com/openclaw/openclaw) | Multi-layer plugin pipeline; daily logs → recall signals → background "dreaming sweep" → promoted into `MEMORY.md`; pluggable QMD / LanceDB / Honcho backends; CJK FTS5 trigram | OpenClaw is a separate AI-assistant gateway, not a Claude Code add-on; concepts directly informed Layer 2 (boundary-event audit) and the longer-term promotion roadmap |
| [muse-crystal-seed](https://github.com/frank890417/muse-crystal-seed) | Seven-file agent decomposition (SOUL/IDENTITY/USER/MEMORY/AGENTS/HEARTBEAT/TOOLS); `after-action` skill enforces a six-step closing checklist; `Lesson Graduation` system for chronic feedback | Inspiration for Layer 2's mandatory four-question audit prompt; the `Lesson Graduation` mechanism is held back as a future "Layer 3" once the existing `Applied Learning` log accumulates enough entries to justify it |
| [Letta / MemGPT](https://github.com/letta-ai/letta) | OS virtual-memory metaphor (Core / Recall / Archival); agent runs inside Letta runtime | Wrong scope — would require migrating off Claude Code, not augmenting it |
| [Mem0](https://github.com/mem0ai/mem0) | Three-tier scope (user/session/agent), hybrid vector + graph + KV; drop-in API | API service; would introduce a vector DB and a service dependency for a problem that filesystem hooks solve |
| [Zep / Graphiti](https://github.com/getzep/zep) | Temporal knowledge graph with fact-validity windows; ~63.8% on LongMemEval (vs Mem0 49.0%) | Architecturally interesting for "what was true on date X" queries, but daily-log dates already suffice for the user's current need |
| [Anthropic Memory Tool (`memory_20250818`)](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) | API-layer client-side tool with `view/create/str_replace/insert/delete/rename` over a `/memories` virtual directory; pairs with context editing | The official direction. As of writing, Claude Code's CLI auto-memory has not integrated it; this repo's hooks are a parallel implementation at the lifecycle-event layer rather than the tool-call layer. See § 9 for coexistence notes |

## 3. Why Hooks

Two design pressures favored hooks over every other option in § 2:

### 3.1 Reliability vs flexibility

The native auto-memory mechanism asks the model to decide *during* a turn whether content is worth saving. This is flexible (the model can save anything, anytime) but unreliable (the model can also save nothing, even when content was clearly worth saving). Hooks give up the fine-grained "during a turn" trigger but gain a guaranteed trigger at lifecycle boundaries — and most write-rate failures happen because the model finished the conversation without noticing, not because it noticed and got the trigger wrong.

So the right complement to a flexible-but-unreliable mechanism is a coarse-but-reliable one. Hooks fit that role exactly.

### 3.2 Scope alignment

Claude Code already keeps memory as plain markdown files at known paths. Any other system in § 2 introduces either a database, a service, an MCP server, or an external app. Hooks are the lowest-overhead extension point that operates on the existing filesystem with zero new dependencies and stays compatible with the user's `Applied Learning` rule of "prefer CLI over MCP."

### 3.3 Forward compatibility

When Anthropic's Memory Tool eventually lands in Claude Code, hooks at the lifecycle layer remain orthogonal to a tool firing per tool call. The two can coexist; § 9 discusses migration paths.

## 4. Architecture

### 4.1 Layer 1 — Cross-cwd index

**Hook:** `SessionStart`
**Script:** `hooks/memory-aggregate.sh`
**Trigger:** every session start, every source (`startup`, `resume`, `clear`, `compact`)

On fire, the script:

1. Reads the hook event JSON from stdin and extracts the current cwd
2. Iterates every `~/.claude/projects/*/memory/MEMORY.md`
3. For each, resolves the actual cwd by reading the first line of the most recent `*.jsonl` transcript in that project directory (each transcript record carries a `cwd` field — this avoids the lossy filename-encoding decode)
4. Skips the current cwd (its `MEMORY.md` is already auto-loaded)
5. Skips empty `MEMORY.md` files
6. Emits a `<system-reminder>` block listing per-cwd:
   - The decoded cwd path
   - The number of `^- ` index entries
   - The full set of index lines (one-line pointers, already short by `MEMORY.md` discipline)

The output also includes prescriptive guidance for Claude on when to consult the index (cross-project topic match, explicit user reference) and when to ignore it (task fully scoped to current cwd).

**Why this design:**

- **Index, not content** — emitting only the one-line pointers (titled summaries) keeps the SessionStart token cost low; Claude reads source files via the standard `Read` tool when an entry looks relevant. Average emitted block is on the order of 10 KB at 60–70 entries.
- **Decode via transcript, not filename** — the `~/.claude/projects/<encoded-cwd>` filename encoding is lossy (`/`, `_`, `.` all map to `-`), so reverse-decoding the cwd from the folder name is unreliable. The transcript's `cwd` field is authoritative.
- **`<system-reminder>` wrapper** — signals to Claude that this is system-injected context, not user input, and aligns with the format Claude Code uses internally.

### 4.2 Layer 2 — Audit checkpoint

**Hooks:** `PreCompact` and `SessionEnd`
**Script:** `hooks/memory-checkpoint.sh`
**Prompt:** `hooks/memory-checkpoint-prompt.txt`
**Trigger:** before context compaction, and at session end

On fire, the script consumes stdin (hook event JSON, currently unused) and prints the prompt file. The prompt is a `<system-reminder>` block instructing Claude to audit the session against four memory categories (`user`, `feedback`, `project`, `reference`) and answer YES/NO explicitly per category — silently skipping is forbidden by the prompt.

**Why this design:**

- **Two events, one script** — `PreCompact` covers the long-session case (compaction implies enough activity to be worth auditing). `SessionEnd` is a second-line safety net for the case where a session ends without ever compacting. Both invoke the same script.
- **Prompt as data** — the audit prompt is in a separate `.txt` file. This makes the prompt easy to revise without touching shell logic, and the script becomes a thin wrapper that exits cleanly on any error.
- **No deduplication** — if both `PreCompact` and `SessionEnd` fire in the same session (compaction during a long session that then ends), the audit runs twice. The redundant pass is preferable to a missed pass; if Claude already saved entries earlier, the prompt instructs the model to acknowledge that explicitly so the second pass becomes a no-op.
- **No length conditioning** — short sessions still get the prompt. The cost is one round of reasoning, and short sessions tend to honestly answer "no" across all four categories anyway, which is a meaningful confirmation in itself.

### 4.3 Trade-offs not made

The following adjacent ideas were considered and deferred:

- **Stop hook for per-turn audit** — fires every reply; would saturate token cost and noise. Discarded.
- **UserPromptSubmit hook for active prefetch** (à la OpenClaw `active-memory`) — a more ambitious version of Layer 1 that injects relevant memory before each turn, not just at session start. Held as a possible future Layer 4 once Layer 1's effect is observed in practice.
- **Lesson Graduation** — porting muse-crystal-seed's `active`/`graduated`/`chronic` state machine to the global `Applied Learning` log. Held as a possible future Layer 3 when that log accumulates ≥ 5 entries (currently 1).

## 5. File Layout

```
claude-memory/
├── .gitignore
├── .gitattributes
├── LICENSE                              MIT
├── README.md                            human-facing intro & install
├── CLAUDE.md                            agent index for working in this repo
├── SPEC.md                              this document
├── setup.sh                             idempotent installer + verifier
└── hooks/
    ├── memory-aggregate.sh              Layer 1 (SessionStart)
    ├── memory-checkpoint.sh             Layer 2 (PreCompact + SessionEnd)
    └── memory-checkpoint-prompt.txt     Layer 2 prompt content
```

After install, the deployed surface is:

```
~/.claude/hooks/
  memory-aggregate.sh           -> /opt/projects/claude-memory/hooks/memory-aggregate.sh
  memory-checkpoint.sh          -> /opt/projects/claude-memory/hooks/memory-checkpoint.sh
  memory-checkpoint-prompt.txt  -> /opt/projects/claude-memory/hooks/memory-checkpoint-prompt.txt

~/.claude/system/memory         -> /opt/projects/claude-memory   (operational pointer)

~/.claude/settings.json
  hooks.SessionStart   includes  bash ~/.claude/hooks/memory-aggregate.sh
  hooks.PreCompact     includes  bash ~/.claude/hooks/memory-checkpoint.sh
  hooks.SessionEnd     includes  bash ~/.claude/hooks/memory-checkpoint.sh
```

The repo is the single source of truth. Hooks at `~/.claude/hooks/` are symlinks back into the repo, so editing through either path stages the same file. The repo's location is portable (`SCRIPT_DIR=$(cd $(dirname $0) && pwd)` resolves at runtime).

## 6. Install Flow (`setup.sh`)

The installer runs four phases plus a tool dependency check, in order:

### 6.1 Tool dependency check

Verifies `jq` and `bash` are on `PATH`. Aborts with remediation hint if either is missing.

### 6.2 Phase 1 — install hook files

For each of the three artifacts (`memory-aggregate.sh`, `memory-checkpoint.sh`, `memory-checkpoint-prompt.txt`):

| State at `~/.claude/hooks/<file>` | Action |
|---|---|
| Symlink already pointing at repo | Skip, mark ok |
| Symlink pointing elsewhere | Halt unless `--force`; with `--force`, relink |
| Real file with content matching repo | Move real file to `~/.claude/hooks/.bak/<timestamp>/`, then symlink |
| Real file with content differing from repo | Halt with diff unless `--force`; with `--force`, back up and replace |
| Absent | Symlink |

### 6.3 Phase 2 — wire `settings.json`

For each of the three required hook entries:

```
SessionStart  matcher='.*'  command='bash ~/.claude/hooks/memory-aggregate.sh'
PreCompact    matcher='.*'  command='bash ~/.claude/hooks/memory-checkpoint.sh'
SessionEnd    matcher='.*'  command='bash ~/.claude/hooks/memory-checkpoint.sh'
```

| State in `settings.json` for this event | Action |
|---|---|
| Entry with exact-matching command exists | Skip, mark ok |
| `memory-*` entry exists with a different command | Halt with diff and remediation hint (no `--force` override) |
| Entry absent | Add via `jq` |

The patch always:

1. Backs up `settings.json` to `settings.json.bak.<timestamp>` first
2. Computes the new content into a temp file
3. `mv` to the destination atomically
4. Re-validates JSON; on failure restores from backup

The `jq` insertion logic is:

```jq
.hooks //= {} |
.hooks[$ev] //= [] |
if (.hooks[$ev] | map(.matcher == $matcher) | any) then
  # add to existing matcher block
  .hooks[$ev] |= map(
    if .matcher == $matcher then
      .hooks += [{type: "command", command: $cmd}]
    else . end
  )
else
  # create new matcher block
  .hooks[$ev] += [{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}]
end
```

### 6.4 Phase 3 — system link

Creates `~/.claude/system/memory` → repo path. Idempotent: skip if symlink already correct, halt on real-path occupation, relink with `--force` on wrong-target.

### 6.5 Phase 4 — verify

Runs *after* any patch attempt, regardless of whether the patch wrote anything:

- Each of the three deployed paths must be a symlink whose target matches the repo file
- Layer 1 smoke: pipe a fake `cwd` JSON to `memory-aggregate.sh`; expect either empty output (fresh machine) or the `Cross-cwd memory index` header
- Layer 2 smoke: pipe `{}` to `memory-checkpoint.sh`; expect the `Memory checkpoint` sentinel string
- Each `settings.json` event must contain the exact-match command

If any check fails, the summary line is `Verification failed`. This is the answer to "if setup skipped, will the user know when something is wrong?" — the verify phase tests the deployed state directly, not the patch outcome.

### 6.6 Flags

- `--dry-run` — print every action that would be taken; do nothing
- `--force` — replace existing `~/.claude/hooks/memory-*` files even if content differs (settings.json conflicts still halt)
- `-h` / `--help` — print top-of-file documentation

## 7. Hook Contract

Every hook script in this repo follows the same contract:

### Inputs

- `stdin` — JSON object emitted by Claude Code, containing `session_id`, `cwd`, `transcript_path`, and event-specific fields. Read but tolerated as empty if missing
- Environment variables — none required; `$HOME` used implicitly via the script's path resolution

### Outputs

- `stdout` — text content. For `SessionStart`, `PreCompact`, and `SessionEnd`, this becomes additional context injected into Claude's session
- Exit code — always `0`. The trap `trap 'exit 0' ERR` ensures any internal error degrades to a no-op rather than blocking Claude Code's lifecycle event

### Format conventions

- Output is wrapped in `<system-reminder>...</system-reminder>` to mark it as system-injected context
- The wrapped content uses Markdown where useful but stays terse — Claude is the consumer, not a human reader

## 8. settings.json Patch Discipline

This is the highest-risk surface in the project: a malformed write would break Claude Code's startup. Discipline:

1. **Never write the whole file.** Only `jq`-mediated edits.
2. **Always back up.** `settings.json.bak.<timestamp>` is written before any mutation.
3. **Atomic write.** New content goes to a temp path, then `mv` replaces the original.
4. **Validate before and after.** `jq . settings.json >/dev/null` is run before reading and after writing.
5. **Restore on corruption.** If the post-write validation fails, the backup is restored automatically.
6. **Never silently overwrite a conflict.** A `memory-*` entry with a different command stops the install; user resolves manually.

The author considered exposing a `--force` for settings.json conflicts and rejected it: a wrong settings.json is worse than a no-op install, and the cost of human review on conflict is bounded.

## 9. Relationship to Anthropic Memory Tool

Anthropic announced the Memory Tool (`memory_20250818`) and context editing on **2025-09-29**, alongside Claude Sonnet 4.5. Confirmed at <https://claude.com/blog/context-management>. The tool is API/SDK-layer:

- Operates client-side via tool calls — the application implements file ops
- Provides `view/create/str_replace/insert/delete/rename` commands over a `/memories` virtual directory
- Pairs with context editing: when context approaches the limit, old tool results are auto-cleared and Claude is warned to save important content into memory first

This repo's hooks are a **parallel implementation at a different layer**:

| Layer | Native Claude Code | Anthropic Memory Tool | This repo |
|---|---|---|---|
| Where memory lives | `~/.claude/projects/<cwd>/memory/` | `/memories/` (client-defined) | Same as native |
| Read trigger | Auto-load `MEMORY.md` at session start | Tool call when needed | Layer 1 hook augments with cross-cwd index |
| Write trigger | Model self-judgment in conversation | Tool call when needed | Layer 2 hook prompts at boundaries |
| Granularity | Per-turn (model decision) | Per-tool-call | Per-lifecycle-event |
| Status in Claude Code CLI | Active | Not yet integrated (as of this writing) | Active |

When Claude Code integrates the Memory Tool natively, the layers should coexist:

- **Layer 1** still adds value — the Memory Tool does not natively know about other cwds
- **Layer 2** may become redundant if the Memory Tool's write triggers prove reliable; in that case, Layer 2 can be removed without affecting the rest of the system

The portable `~/.claude/hooks/memory-*.sh` paths in `settings.json` (rather than repo-absolute paths) ensure that adapting to such changes is a one-line edit.

## 10. Future Extensions (Not Implemented)

### 10.1 Layer 3 — Lesson Graduation

Port muse-crystal-seed's lesson state machine into the user's global `Applied Learning` log:

- `active` — entry currently in effect, monitored for violations per session
- `graduated` — 7 consecutive sessions without violation; entry archived (still searchable, no longer reminded)
- `chronic` — entry has been re-added 3+ times after promotion; flagged for structural fix (hook, gate, automation) rather than another reminder

Defer until `Applied Learning` accumulates ≥ 5 entries (currently 1). Premature implementation would impose state machine overhead on a single rule.

### 10.2 Layer 4 — Active prefetch

A `UserPromptSubmit` hook that searches all `~/.claude/projects/*/memory/` for keyword matches with each user message, injecting relevant entries proactively (à la OpenClaw `active-memory`).

Defer until Layer 1's effect is observed for ≥ 2 weeks. If users still ask "did we work on X before?" after Layer 1 ships the index proactively, Layer 4 closes the gap. If Layer 1 is sufficient, Layer 4 is wasted token spend.

### 10.3 Promotion sweep

A periodic background job (cron or on-demand) that reviews recent daily logs and promotes content into `MEMORY.md` based on access frequency, à la OpenClaw `dreaming sweep` and `memory promote`.

Defer until daily logs exist; the user does not currently maintain `memory/YYYY-MM-DD.md` files. If short-term memory becomes a need, the daily-log + promote pipeline is the first step before any sweep.

## 11. References

### Anthropic primary sources
- [Memory tool documentation](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
- [Context management announcement (2025-09-29)](https://claude.com/blog/context-management)
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)

### Memory system surveys (informed § 2)
- [mem-palace](https://github.com/mempalace/mempalace)
- [Basic Memory + Obsidian](https://docs.basicmemory.com/integrations/obsidian)
- [obsidian-claude-code-mcp](https://github.com/iansinnott/obsidian-claude-code-mcp)
- [claude-obsidian (Karpathy LLM Wiki pattern)](https://github.com/AgriciDaniel/claude-obsidian)
- [OpenClaw memory architecture](https://github.com/openclaw/openclaw/tree/main/docs/concepts)
- [muse-crystal-seed](https://github.com/frank890417/muse-crystal-seed)
- [Letta (formerly MemGPT)](https://github.com/letta-ai/letta)
- [Mem0](https://github.com/mem0ai/mem0)
- [Zep / Graphiti](https://github.com/getzep/zep)

### Sibling repos in this user's Claude Code config
- [`claude-backup`](https://github.com/howar31/claude-backup) — three-layer config tree backup, sets the convention for `~/.claude/system/<topic>/` symlinks and `setup.sh` patterns this repo follows
- [`claude-statusline`](https://github.com/howar31/claude-statusline) — drift-aware statusline; reads `claude-backup`'s drift flag to surface backup health
