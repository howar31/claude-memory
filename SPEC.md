# claude-memory — Architecture & Decision Log

## 1. Problem Statement

Claude Code (the CLI) ships an auto-memory feature: if `autoMemoryEnabled: true` is set in `~/.claude/settings.json`, Claude is expected to write durable memory entries into `~/.claude/projects/<encoded-cwd>/memory/` over the course of conversations. The mechanism is prompt-driven — the model decides mid-conversation when content is "memorable enough" to save.

This repo addresses two failure modes of that design:

### 1.1 Per-cwd silos (read-time)

Memory is namespaced by cwd. Each working directory becomes its own folder under `~/.claude/projects/` (with the cwd path encoded into the folder name — e.g. `/path/to/project` becomes `-path-to-project`). A memory entry written while working in one cwd lives only in that cwd's memory folder and is **not visible** to a Claude Code session started in a sibling or parent cwd, even when the same person and the same broader project family are involved.

This becomes most painful when substantial work performed in a sub-project cwd is later referenced from the parent or a sibling cwd, because Claude only loads the current cwd's `MEMORY.md` at startup — even though the relevant entry exists, just one folder over.

A `SessionStart` hook closes this gap by injecting a cross-cwd index at the start of every session.

### 1.2 Write-rate variance (write-time)

The auto-memory rules in the global `~/.claude/CLAUDE.md` instruct Claude to save memory entries when certain triggers occur (user corrections, validated approaches, project state changes, external references cited). Because the trigger is interpretive ("did anything memorable happen?"), the model sometimes does not notice. Some sessions yield no memory entries despite producing content that would have been worth saving.

The `/memorize` skill closes this gap. It is a slash command (and model-invocable) that audits the current session against the four memory categories explicitly and persists matching entries.

## 2. Alternatives Considered

Before settling on hooks, the author surveyed several memory-system architectures. The matrix below is the relevant excerpt; full notes from the survey are kept in the user's session transcripts.

| System | Core idea | Why not adopted |
|---|---|---|
| [mem-palace](https://github.com/mempalace/mempalace) | Local-first verbatim transcript storage with hybrid semantic/lexical search; `wings/rooms/drawers` structure | Adds a vector DB stack; English-only default embedder needs replacement for the user's CJK conversations; overkill at the current memory volume (~64 entries) |
| [Obsidian + Basic Memory](https://docs.basicmemory.com/integrations/obsidian) | Markdown vault with `[[wiki-links]]`; Claude reads/writes via MCP | User's `Applied Learning` rule prefers CLI over MCP; introduces a vault-management workflow the user does not need yet; Obsidian's value (graph view, manual curation) is orthogonal to the cross-cwd silo problem |
| [Karpathy LLM Wiki / claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian) | `/wiki`, `/save`, `/autoresearch` slash commands compile sessions into a maintained wiki of 10–15 pages | Requires conscious workflow discipline; useful long-term but does not address per-cwd memory invisibility |
| [OpenClaw](https://github.com/openclaw/openclaw) | Multi-layer plugin pipeline; daily logs → recall signals → background "dreaming sweep" → promoted into `MEMORY.md`; pluggable QMD / LanceDB / Honcho backends; CJK FTS5 trigram | OpenClaw is a separate AI-assistant gateway, not a Claude Code add-on; concepts inform a possible future promotion roadmap |
| [muse-crystal-seed](https://github.com/frank890417/muse-crystal-seed) | Seven-file agent decomposition (SOUL/IDENTITY/USER/MEMORY/AGENTS/HEARTBEAT/TOOLS); `after-action` skill enforces a six-step closing checklist; `Lesson Graduation` system for chronic feedback | The `Lesson Graduation` mechanism is held back as a future extension once the existing `Applied Learning` log accumulates enough entries to justify it |
| [Letta / MemGPT](https://github.com/letta-ai/letta) | OS virtual-memory metaphor (Core / Recall / Archival); agent runs inside Letta runtime | Wrong scope — would require migrating off Claude Code, not augmenting it |
| [Mem0](https://github.com/mem0ai/mem0) | Three-tier scope (user/session/agent), hybrid vector + graph + KV; drop-in API | API service; would introduce a vector DB and a service dependency for a problem that filesystem hooks solve |
| [Zep / Graphiti](https://github.com/getzep/zep) | Temporal knowledge graph with fact-validity windows; ~63.8% on LongMemEval (vs Mem0 49.0%) | Architecturally interesting for "what was true on date X" queries, but daily-log dates already suffice for the user's current need |
| [Anthropic Memory Tool (`memory_20250818`)](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) | API-layer client-side tool with `view/create/str_replace/insert/delete/rename` over a `/memories` virtual directory; pairs with context editing | The official direction. As of writing, Claude Code's CLI auto-memory has not integrated it; this repo's hooks are a parallel implementation at the lifecycle-event layer rather than the tool-call layer. See § 9 for coexistence notes |

## 3. Why Hooks

Two design pressures favored hooks over every other option in § 2:

### 3.1 Scope alignment

Claude Code already keeps memory as plain markdown files at known paths. Any other system in § 2 introduces either a database, a service, an MCP server, or an external app. Hooks are the lowest-overhead extension point that operates on the existing filesystem with zero new dependencies and stays compatible with the user's `Applied Learning` rule of "prefer CLI over MCP."

### 3.2 Forward compatibility

When Anthropic's Memory Tool eventually lands in Claude Code, hooks at the lifecycle layer remain orthogonal to a tool firing per tool call. The two can coexist; § 9 discusses migration paths.

## 4. Architecture

### 4.1 Read — Cross-cwd index (SessionStart hook)

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

### 4.2 Write — `/memorize` skill

**Skill:** `skills/memorize/SKILL.md`
**Type:** standalone slash command (not plugin)
**Trigger:** user invocation OR model self-invocation

The skill instruction file walks Claude through a six-step audit:

1. **Locate the memory directory** — derive `~/.claude/projects/<encoded-cwd>/memory/` from the auto-loaded `MEMORY.md`, or fall back to scanning project transcripts for a matching cwd. Create the directory and an empty `MEMORY.md` if absent.
2. **Audit four categories** — `user`, `feedback`, `project`, `reference`. Decide YES / NO explicitly per category. Read existing entries to avoid duplicates and prefer updates over duplicates.
3. **Preview (only in `dry` mode)** — print proposed entries and wait for the user's response in the same skill execution; loop on edits, abort on decline.
4. **Write entries** — one `.md` file per memory under the memory dir, with `name` / `description` / `type` frontmatter. `feedback` and `project` types must include `Why:` and `How to apply:` body lines.
5. **Update `MEMORY.md` index** — append one pointer line per new entry, ≤ 150 chars.
6. **Report** — list filenames written / updated; an empty audit is a valid result.

**`$ARGUMENTS` parsing:**
- Leading token `dry` (alone, or followed by whitespace + more text) enables preview mode; the rest is treated as the focus hint
- Otherwise `$ARGUMENTS` is the focus hint (gives matching content priority but the audit still scans all four categories)

**Why standalone instead of plugin:**

Claude Code plugins force their skills to be namespaced as `/plugin-name:skill-name`. To keep the short slash name `/memorize`, the skill must be installed at the standalone path `~/.claude/skills/memorize/`. `setup.sh` symlinks it there from this repo so the source-of-truth stays in version control.

**Why not a hook:**

An earlier draft used `PreCompact` and `SessionEnd` hooks to inject a four-question audit before context loss. Both empirically failed: `PreCompact` stdout reaches the model but is suppressed by the concurrent compact-summary task, and `SessionEnd` stdout/stderr is shown to the user only and never reaches the model. A model-invocable skill executes in a normal turn with full tool access, sidestepping both failure modes.

**Why model-invocation is enabled:**

The skill's frontmatter omits `disable-model-invocation: true`, so Claude can self-trigger `/memorize` when it detects memory-worthy moments mid-conversation. This complements (but does not replace) explicit user invocation. The `description` field enumerates trigger conditions for the model's auto-decision logic.

### 4.3 Trade-offs not made

The following adjacent ideas were considered and deferred:

- **UserPromptSubmit hook for active prefetch** (à la OpenClaw `active-memory`) — a more ambitious version of cross-cwd injection that pulls in relevant memory before each user turn, not just at session start. Held until the SessionStart index proves insufficient in practice.
- **Lesson Graduation** — porting muse-crystal-seed's `active`/`graduated`/`chronic` state machine to the global `Applied Learning` log. Held until that log accumulates ≥ 5 entries (currently 1).

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
├── hooks/
│   └── memory-aggregate.sh              SessionStart hook
└── skills/
    └── memorize/
        └── SKILL.md                     /memorize slash command
```

After install, the deployed surface is:

```
~/.claude/hooks/
  memory-aggregate.sh           -> /opt/projects/claude-memory/hooks/memory-aggregate.sh

~/.claude/skills/
  memorize                      -> /opt/projects/claude-memory/skills/memorize

~/.claude/system/memory         -> /opt/projects/claude-memory   (operational pointer)

~/.claude/settings.json
  hooks.SessionStart   includes  bash ~/.claude/hooks/memory-aggregate.sh
```

The repo is the single source of truth. Hooks at `~/.claude/hooks/` are symlinks back into the repo, so editing through either path stages the same file. The repo's location is portable (`SCRIPT_DIR=$(cd $(dirname $0) && pwd)` resolves at runtime).

## 6. Install Flow (`setup.sh`)

The installer runs five phases plus a tool dependency check, in order:

### 6.1 Tool dependency check

Verifies `jq` and `bash` are on `PATH`. Aborts with remediation hint if either is missing.

### 6.2 Phase 1 — install hook files

For each artifact (currently just `memory-aggregate.sh`):

| State at `~/.claude/hooks/<file>` | Action |
|---|---|
| Symlink already pointing at repo | Skip, mark ok |
| Symlink pointing elsewhere | Halt unless `--force`; with `--force`, relink |
| Real file with content matching repo | Move real file to `~/.claude/hooks/.bak/<timestamp>/`, then symlink |
| Real file with content differing from repo | Halt with diff unless `--force`; with `--force`, back up and replace |
| Absent | Symlink |

### 6.3 Phase 2 — wire `settings.json`

For each required hook entry (currently just one):

```
SessionStart  matcher='.*'  command='bash ~/.claude/hooks/memory-aggregate.sh'
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

### 6.5 Phase 4 — install skill directories

For each entry in `SKILL_DIRS` (currently `memorize`):

| State at `~/.claude/skills/<dir>` | Action |
|---|---|
| Symlink already pointing at repo | Skip, mark ok |
| Symlink pointing elsewhere | Halt unless `--force`; with `--force`, relink |
| Real directory | Halt unless `--force`; with `--force`, move to `~/.claude/hooks/.bak/<timestamp>/skill-<dir>/`, then symlink |
| Absent | Symlink |

The skill source must contain a `SKILL.md` file; phase aborts if absent.

### 6.6 Phase 5 — verify

Runs *after* every install phase, regardless of whether they wrote anything:

- Each deployed hook path must be a symlink whose target matches the repo file
- Each deployed skill path must be a symlink whose target matches the repo skill directory; the linked `SKILL.md` must declare a matching `name:` frontmatter field
- Smoke test: pipe a fake `cwd` JSON to `memory-aggregate.sh`; expect either empty output (fresh machine) or the `Cross-cwd memory index` header
- Each `settings.json` event must contain the exact-match command

If any check fails, the summary line is `Verification failed`. This is the answer to "if setup skipped, will the user know when something is wrong?" — the verify phase tests the deployed state directly, not the patch outcome.

### 6.7 Flags

- `--dry-run` — print every action that would be taken; do nothing
- `--force` — replace existing `~/.claude/hooks/memory-*` files and existing `~/.claude/skills/<dir>` directories even if content differs (settings.json conflicts still halt)
- `-h` / `--help` — print top-of-file documentation

## 7. Hook & Skill Contracts

### 7.1 Hook contract

Every hook script in this repo follows the same contract:

**Inputs**
- `stdin` — JSON object emitted by Claude Code, containing `session_id`, `cwd`, `transcript_path`, and event-specific fields. Read but tolerated as empty if missing
- Environment variables — none required; `$HOME` used implicitly via the script's path resolution

**Outputs**
- `stdout` — text content. For `SessionStart`, this becomes additional context injected into Claude's session
- Exit code — always `0`. The trap `trap 'exit 0' ERR` ensures any internal error degrades to a no-op rather than blocking Claude Code's lifecycle event

**Format conventions**
- Output is wrapped in `<system-reminder>...</system-reminder>` to mark it as system-injected context
- The wrapped content uses Markdown where useful but stays terse — Claude is the consumer, not a human reader

### 7.2 Skill contract

Every skill in this repo follows this layout:

**Directory structure**
- `skills/<name>/SKILL.md` — required; the only file Claude Code's standalone-skill loader needs

**Frontmatter (YAML)**
- `name` — must match the directory name; setup.sh verify enforces this
- `description` — used for the slash-command listing AND model-invocation decision; must enumerate trigger conditions when model-invocation is enabled
- `disable-model-invocation: true` — set only when the skill should be exclusively user-invocable

**Body conventions**
- English instructions (per the user's `Doc Language` rule)
- Numbered steps the model executes in order
- Use `$ARGUMENTS` for runtime input; document the parsing convention near the top
- For destructive defaults (write/commit/delete), provide an explicit opt-in confirmation flag (e.g. `dry`)

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
| Read trigger | Auto-load `MEMORY.md` at session start | Tool call when needed | SessionStart hook augments with cross-cwd index |
| Write trigger | Model self-judgment in conversation | Tool call when needed | `/memorize` skill (user or model invokes explicitly) |
| Granularity | Per-turn (model decision) | Per-tool-call | Per-session-start (read) + per-invocation (write) |
| Status in Claude Code CLI | Active | Not yet integrated (as of this writing) | Active |

When Claude Code integrates the Memory Tool natively, this repo's SessionStart augmentation still adds value — the Memory Tool does not natively know about other cwds. The `/memorize` skill could likewise coexist or be retired depending on whether Memory Tool's per-tool-call writes prove sufficient. The portable `~/.claude/hooks/memory-*.sh` and standalone-skill paths ensure that adapting to such changes is a localised edit.

## 10. Future Extensions (Not Implemented)

### 10.1 Lesson Graduation

Port muse-crystal-seed's lesson state machine into the user's global `Applied Learning` log:

- `active` — entry currently in effect, monitored for violations per session
- `graduated` — 7 consecutive sessions without violation; entry archived (still searchable, no longer reminded)
- `chronic` — entry has been re-added 3+ times after promotion; flagged for structural fix (hook, gate, automation) rather than another reminder

Defer until `Applied Learning` accumulates ≥ 5 entries (currently 1). Premature implementation would impose state machine overhead on a single rule.

### 10.2 Active prefetch

A `UserPromptSubmit` hook that searches all `~/.claude/projects/*/memory/` for keyword matches with each user message, injecting relevant entries proactively (à la OpenClaw `active-memory`).

Defer until the SessionStart cross-cwd index is observed for ≥ 2 weeks. If users still ask "did we work on X before?" after the index ships proactively, active prefetch closes the gap. If the index is sufficient, active prefetch is wasted token spend.

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
