# claude-memory — Architecture & Decision Log

## 1. Problem Statement

Claude Code (the CLI) ships an auto-memory feature, on by default in local sessions (`autoMemoryEnabled: false` or `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` turns it off): Claude writes durable memory entries into `~/.claude/projects/<project>/memory/` over the course of conversations. The mechanism is prompt-driven — the model decides mid-conversation when content is "memorable enough" to save.

This repo addresses two failure modes of that design:

### 1.1 Per-project silos (read-time)

Memory is namespaced by project. Per the memory docs (<https://code.claude.com/docs/en/memory>, "Storage location"): "The `<project>` path is derived from the git repository, so all worktrees and subdirectories within the same repo share one auto memory directory. Outside a git repo, the project root is used instead." The folder name is the path with every non-alphanumeric character replaced by `-` (e.g. `/path/to/project` becomes `-path-to-project`); names over 200 characters are truncated and get a hash of the full path (<https://code.claude.com/docs/en/sessions>, "Where transcripts are stored"). A memory entry written in one repo lives only in that repo's memory folder and is **not visible** to a session started in another repo, or in a non-repo parent folder that holds several repos, even when the same person and the same broader project family are involved.

This becomes most painful when substantial work performed in one repo is later referenced from the parent workspace folder or a sibling repo, because Claude only loads the current project's `MEMORY.md` at startup — even though the relevant entry exists, just one folder over.

The `/recall` skill closes this gap by searching every project's memory on demand and reading the relevant entries.

Layout details the skills depend on (docs above plus the sub-agents page, verified against Claude Code 2.1.301):

- **Path overrides.** `autoMemoryDirectory` (any settings scope) moves the current project's memory dir; `CLAUDE_CODE_PROJECT_DIR_NAME` beside `CLAUDE_CONFIG_DIR` fixes the folder name; `CLAUDE_CONFIG_DIR` replaces `~/.claude`. The harness's system prompt names the resolved memory dir even before `MEMORY.md` exists, so the skills take the path from there and only derive it as a fallback.
- **Transcripts are keyed differently.** Transcripts live under the *working directory's* encoded path, not the repo's, so a session opened in a repo subdirectory writes its transcript to a folder that has no memory dir. Transcripts are deleted after `cleanupPeriodDays` (default 30) while memory files are exempt, and the JSONL format is internal. The first line of a transcript does not carry `cwd`; the skills take the first `cwd` value found anywhere in the file and fall back to the folder name.
- **Subagent memory** (`memory: user|project|local` in an agent definition) lives in `~/.claude/agent-memory/<agent>/`, `.claude/agent-memory/<agent>/` or `.claude/agent-memory-local/<agent>/`, with the same 200-line / 25KB `MEMORY.md` limit. `/recall` searches it; `/memorize` and `/tidy` do not write there.
- **Entry frontmatter.** Claude Code's own writes put `type` under `metadata:` and add a `modified` ISO timestamp on every save (v2.1.214+); older entries may have a top-level `type:`. The skills read both layouts and write the nested one.

### 1.2 Write-rate variance (write-time)

The auto-memory rules in the global `~/.claude/CLAUDE.md` instruct Claude to save memory entries when certain triggers occur (user corrections, validated approaches, project state changes, external references cited). Because the trigger is interpretive ("did anything memorable happen?"), the model sometimes does not notice. Some sessions yield no memory entries despite producing content that would have been worth saving.

The `/memorize` skill closes this gap. It is a slash command (and model-invocable) that audits the current session against the four memory categories explicitly and persists matching entries.

### 1.3 Index growth and misplacement (maintenance)

Only the first 200 lines or 25KB of a project's `MEMORY.md` load at session start; the rest is dropped without notice (<https://code.claude.com/docs/en/memory>). Writes accumulate, closed items keep their index lines, and when sessions are usually opened in a parent folder that holds several repos, entries about one repo's code collect in the parent's memory, where a session opened inside that repo never sees them.

The `/tidy` skill addresses this: it measures the index, repairs links, and moves each entry out of the index only by archiving, grouping or relocating it. No content is deleted.

## 2. Alternatives Considered

Before settling on a filesystem-native approach, the author surveyed several memory-system architectures. The matrix below is the relevant excerpt; full notes from the survey are kept in the user's session transcripts.

| System | Core idea | Why not adopted |
|---|---|---|
| [mem-palace](https://github.com/mempalace/mempalace) | Local-first verbatim transcript storage with hybrid semantic/lexical search; `wings/rooms/drawers` structure | Adds a vector DB stack; English-only default embedder needs replacement for the user's CJK conversations; overkill at the current memory volume |
| [Obsidian + Basic Memory](https://docs.basicmemory.com/integrations/obsidian) | Markdown vault with `[[wiki-links]]`; Claude reads/writes via MCP | User's `Applied Learning` rule prefers CLI over MCP; introduces a vault-management workflow the user does not need yet; Obsidian's value (graph view, manual curation) is orthogonal to the cross-cwd silo problem |
| [Karpathy LLM Wiki / claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian) | `/wiki`, `/save`, `/autoresearch` slash commands compile sessions into a maintained wiki of 10–15 pages | Requires conscious workflow discipline; useful long-term but does not address per-cwd memory invisibility |
| [OpenClaw](https://github.com/openclaw/openclaw) | Multi-layer plugin pipeline; daily logs → recall signals → background "dreaming sweep" → promoted into `MEMORY.md`; pluggable QMD / LanceDB / Honcho backends; CJK FTS5 trigram | OpenClaw is a separate AI-assistant gateway, not a Claude Code add-on; concepts inform a possible future promotion roadmap |
| [muse-crystal-seed](https://github.com/frank890417/muse-crystal-seed) | Seven-file agent decomposition (SOUL/IDENTITY/USER/MEMORY/AGENTS/HEARTBEAT/TOOLS); `after-action` skill enforces a six-step closing checklist; `Lesson Graduation` system for chronic feedback | The `Lesson Graduation` mechanism is held back as a future extension once the existing `Applied Learning` log accumulates enough entries to justify it |
| [Letta / MemGPT](https://github.com/letta-ai/letta) | OS virtual-memory metaphor (Core / Recall / Archival); agent runs inside Letta runtime | Wrong scope — would require migrating off Claude Code, not augmenting it |
| [Mem0](https://github.com/mem0ai/mem0) | Three-tier scope (user/session/agent), hybrid vector + graph + KV; drop-in API | API service; would introduce a vector DB and a service dependency for a problem that filesystem skills solve |
| [Zep / Graphiti](https://github.com/getzep/zep) | Temporal knowledge graph with fact-validity windows; ~63.8% on LongMemEval (vs Mem0 49.0%) | Architecturally interesting for "what was true on date X" queries, but daily-log dates already suffice for the user's current need |
| [Anthropic Memory Tool (`memory_20250818`)](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) | API-layer client-side tool with `view/create/str_replace/insert/delete/rename` over a `/memories` virtual directory; pairs with context editing | The official direction. As of writing, Claude Code's CLI auto-memory has not integrated it; this repo's skills are a parallel implementation at the slash-command layer rather than the tool-call layer. See § 9 for coexistence notes |

## 3. Why Skills (and why not a hook)

### 3.1 Scope alignment

Claude Code already keeps memory as plain markdown files at known paths. Any other system in § 2 introduces either a database, a service, an MCP server, or an external app. Skills are the lowest-overhead extension point that operates on the existing filesystem with zero new dependencies and stays compatible with the user's `Applied Learning` rule of "prefer CLI over MCP."

### 3.2 The read path was a hook — until the 10,000-char cap broke it

The original design injected the cross-cwd index via a `SessionStart` hook (`hooks/memory-aggregate.sh`). It enumerated every entry of every other cwd's `MEMORY.md` and printed the block to stdout, which Claude Code injects as session context.

This worked at low memory volume and failed as memory grew. **Claude Code caps hook output strings at 10,000 characters** — and the cap applies uniformly to plain `stdout`, `hookSpecificOutput.additionalContext`, and `systemMessage`. Output that exceeds the cap is saved to a file and replaced with a ~2 KB preview + file path, exactly the way large tool results are handled (source: <https://code.claude.com/docs/en/hooks>).

Once the aggregated index passed ~10 KB (it reached ~24 KB at ~120 entries across 17 cwds), the model received only a 2 KB preview — which, being a head-truncation, contained just the first cwd's entries. The other ~16 cwds silently vanished from context, and the spill file is not auto-read. The failure was silent and position-biased: the index appeared to work but covered a single project.

Three escape attempts were rejected:

- **Switch stdout → `additionalContext` JSON.** Same 10,000-char cap; no help. (Verified: the superpowers plugin injects its `using-superpowers` skill via exactly this path and fits only because the file is 5,421 bytes, under the cap — not because the channel is exempt.)
- **Compress the index** (cwd-level table of contents, drop per-entry descriptions, self-truncate). Any enumeration grows with memory volume; compression only postpones the cap and degrades the index into something too terse to judge relevance from. A losing battle by construction.
- **Hybrid (slim hook + skill).** Splits the read path across two mechanisms — the very ambiguity ("hook or skill?") this redesign exists to remove.

### 3.3 Skills resolve it structurally

The fix is to stop *injecting* and start *retrieving*. A skill's body loads on demand via the Skill tool; its always-on cost is just the one-line `description` in the skill listing (itself capped at 1,536 chars per skill, budget ≈ 1% of the context window, least-used descriptions trimmed first on overflow — never the whole skill). Crucially, retrieval returns only the **relevant slice** of memory, so nothing that scales with total memory volume is ever placed in context.

This mirrors how the superpowers plugin scales to arbitrarily many skills: it injects one constant-size *router* (`using-superpowers`) that says "use the Skill tool for everything else," and loads each skill body only when invoked. `/recall` applies the same router/content separation to memory: a constant-size capability (the skill's description), unbounded content fetched at query time.

### 3.4 Forward compatibility

When Anthropic's Memory Tool eventually lands in Claude Code, skills at the slash-command layer remain orthogonal to a tool firing per tool call. The two can coexist; § 9 discusses migration paths.

## 4. Architecture

### 4.1 Read — `/recall` skill

**Skill:** `skills/recall/SKILL.md`
**Type:** standalone slash command (also published as the `mem` plugin skill — see § 4.2, § 10.2)
**Trigger:** user invocation (`/recall <topic>`) OR model self-invocation

The skill instruction file walks Claude through retrieval:

1. **Parse `$ARGUMENTS`** — the search topic. If empty, infer the topic from the conversation; if still ambiguous, ask before searching.
2. **Derive search terms** — memory files are written in English but the user often converses in Traditional Chinese, so translate the topic to likely English keywords and add synonyms, variants, and symbol forms (recall is conceptual, not exact-match).
3. **Search** — case-insensitive recursive grep over every `<config dir>/projects/*/memory/` and `<config dir>/agent-memory/`, plus the current session's memory dir when an `autoMemoryDirectory` moved it, other `autoMemoryDirectory` values from settings, and the project's `.claude/agent-memory*/` dirs (both per-entry `*.md` and `MEMORY.md`); broaden on zero hits, narrow on too many.
4. **Read** the matching entry files for full content.
5. **Resolve project labels** only if precision is needed — the folder name is usually readable; otherwise take the first `cwd` value in the newest `*.jsonl` transcript (the folder-name encoding is lossy); with no transcript left, cite the folder name.
6. **Report** — lead with the conclusion, cite each memory's source project + filename and its `modified` date when present; an empty recall is a valid result.

**Why this design:**

- **Retrieve, don't inject** — grep returns only the matching subset, so the read path never places content into context that scales with total memory volume. This is the structural fix for the hook's 10,000-char cap (§ 3.2).
- **grep is the whole engine** — no helper script. The skill is self-contained: `SKILL.md` *is* the implementation. This keeps it portable (no path-coupled dependency to install) and avoids reintroducing custom bash that can break across platforms (BSD vs GNU). The retired hook's only unique feature — resolving the lossy folder-name encoding to a real cwd — is folded into the skill as an optional one-liner applied to matched projects only, not all of them.
- **Search includes the current project** — its `MEMORY.md` index is auto-loaded, but its individual entry bodies are not, so they are still worth grepping.

### 4.2 Write — `/memorize` skill

**Skill:** `skills/memorize/SKILL.md`
**Type:** standalone slash command (also published as the `mem` plugin skill — see § 4.2, § 10.2)
**Trigger:** user invocation OR model self-invocation

The skill instruction file walks Claude through a six-step audit:

1. **Locate the memory directory** — use the path the system prompt names (it already reflects repo keying, worktrees and path overrides). If none is named, warn that auto memory may be off and ask before writing; the fallback derivation encodes the main worktree root (`git rev-parse --git-common-dir`), or the launch directory outside a repo. Create the directory and an empty `MEMORY.md` if absent.
2. **Audit four categories** — `user`, `feedback`, `project`, `reference`. Decide YES / NO explicitly per category. Read existing entries to avoid duplicates and prefer updates over duplicates.
3. **Preview (only in `dry` mode)** — print proposed entries and wait for the user's response in the same skill execution; loop on edits, abort on decline.
4. **Write entries** — one `.md` file per memory under the memory dir, with `name` / `description` / `metadata.type` frontmatter (Claude Code's own layout; `modified` is left to Claude Code). `feedback` and `project` types must include `Why:` and `How to apply:` body lines.
5. **Update `MEMORY.md` index** — append one pointer line per new entry, ≤ 150 chars.
6. **Report** — list filenames written / updated; an empty audit is a valid result.

**`$ARGUMENTS` parsing:**
- Leading token `dry` (alone, or followed by whitespace + more text) enables preview mode; the rest is treated as the focus hint
- Otherwise `$ARGUMENTS` is the focus hint (gives matching content priority but the audit still scans all four categories)

**Why standalone *and* plugin (dual distribution):**

Claude Code plugins force their skills to be namespaced as `/plugin-name:skill-name`. To keep the short slash names `/recall`, `/memorize` and `/tidy`, the **primary** install is the standalone path `~/.claude/skills/<name>/` — `setup.sh` symlinks the skills there from this repo so the source-of-truth stays in version control, and a non-Claude harness that reads `skills/<name>/SKILL.md` directly can consume them too. The same skills are *also* published as the `mem` plugin (namespaced `/mem:recall`, `/mem:memorize`) for discoverable, managed install via marketplace; see § 10.2. All paths share one `skills/` tree.

**Why model-invocation is enabled (all skills):**

No skill's frontmatter sets `disable-model-invocation: true`, so Claude can self-trigger them. The `description` field of each enumerates concrete trigger phrases (Traditional Chinese + English) so the model's auto-decision fires reliably — auto-invocation is judgment-based (the model reads the description each turn), not event-deterministic like a hook, so the description is the only lever for trigger quality.

The `/recall` and `/memorize` descriptions are tuned for **high auto-invocation frequency** rather than minimal triggering: they use proactive self-invoke language and enumerate many trigger phrases so the model errs toward calling them. The enabling principle is to **decouple invocation frequency from write frequency** — `/memorize` audits often, but its dedup step (read existing entries, update-over-create) and the legitimacy of an empty audit mean frequent auditing raises recall quality without cluttering the store; `/recall` is read-only and cheap, so "when in doubt, recall." A future agent should not "simplify" these descriptions back toward terse triggering — the verbosity is deliberate, and both remain well under the 1,536-char listing cap (recall ≈1.1k, memorize ≈1.1k chars). This reflects a durable user preference for maximal memory-interaction frequency.

`/tidy` is triggered by need rather than by frequency: its description names the conditions (index near its limit, Claude Code's near-limit warning, stale or misplaced entries) and asks the model to offer it past about 60% of either limit. Because every run stops at a proposal, a needless trigger costs only a read.

### 4.3 Maintain — `/tidy` skill

**Skill:** `skills/tidy/SKILL.md`
**Trigger:** user invocation (`/tidy`, `/tidy <focus>`, `/tidy check`) OR model self-invocation (index near its limit, Claude Code's near-limit warning, stale or misplaced entries)

1. **Locate** the entry dir (the auto-loaded `MEMORY.md`), its child dirs (`<entry-folder>-*`, confirmed by transcript `cwd` when ambiguous) and git repos under the entry project that have no memory dir yet; a new repo's folder name is computed with the documented encoding. When `autoMemoryDirectory` moved the entry dir out of `<config dir>/projects/`, only the entry dir is tidied and nothing moves.
2. **Measure and check** each dir: line and byte count against the load limit, long index lines, dangling links, unindexed entries (not in the index, not under an indexed hub, not archived).
3. **Classify** every entry as keep / shorten / archive / group / move / fix / ask.
4. **Propose** the before-and-after size and per-action tables, then wait for approval. `check` mode stops after Step 2.
5. **Apply**: back up the touched dirs under `$TMPDIR`; add `archived: YYYY-MM-DD` to archived entries; write hub entries; move files and rewrite relative markdown links on both sides; rebuild the entry index in sections plus a `## Repo memories` pointer per child dir; diff each `MEMORY.md` against the Step 2 copy right before writing, so lines added by concurrent sessions survive.
6. **Verify** by re-running the Step 2 checks.
7. **Report** before/after numbers, counts, backup path, open questions.

**Placement rule.** An entry moves to a repo only when a session opened inside that repo would need it to change the repo's code. Infrastructure and operations entries stay in the entry dir even when they name one repo's service; user and feedback entries never move.

**Why it is not compression.** The read-path decision (§ 10.1) rejected shrinking an injected index because shrinking erodes meaning. `/tidy` removes nothing: archived entries keep their files and stay reachable through `/recall`; hubs keep one line per member; moved entries load natively in the repo's own sessions, and the entry index keeps a pointer with topic keywords so a parent-folder session knows which index to read.

### 4.4 Trade-offs not made

The following adjacent ideas were considered and deferred:

- **A residual SessionStart pointer.** A constant-size hook ("you have N cross-cwd memories; use /recall") would restore unconditional passive awareness. Dropped to keep the read path a single mechanism; `/recall`'s always-loaded description provides awareness that the capability exists, and the cross-cwd tier is inherently lower-relevance content that is fine to fetch on demand. The accepted cost: recall of another project's memory now requires the model to actively notice relevance (or the user to cue it), rather than being passively injected.
- **UserPromptSubmit hook for active prefetch** (à la OpenClaw `active-memory`) — pulling relevant memory before each user turn. Held until `/recall` proves insufficient in practice. (Subject to the same 10,000-char output cap, so it would need the same retrieve-don't-inject discipline.)
- **Lesson Graduation** — porting muse-crystal-seed's `active`/`graduated`/`chronic` state machine to the global `Applied Learning` log. Held until that log accumulates enough entries to justify the state-machine overhead.

## 5. File Layout

```
claude-memory/
├── .gitignore
├── .gitattributes
├── .claude-plugin/
│   ├── plugin.json                      plugin manifest (name: mem)
│   └── marketplace.json                 self-hosted single-plugin marketplace (source: "./")
├── LICENSE                              MIT
├── README.md                            human-facing intro & install (English)
├── README.zh-Hant.md                    same content in Traditional Chinese
├── CLAUDE.md                            agent index for working in this repo
├── SPEC.md                              this document
├── setup.sh                             idempotent installer + verifier
└── skills/
    ├── recall/
    │   └── SKILL.md                     /recall slash command (read)
    ├── memorize/
    │   └── SKILL.md                     /memorize slash command (write)
    └── tidy/
        └── SKILL.md                     /tidy slash command (maintain)
```

After install, the deployed surface is:

```
~/.claude/skills/
  recall                        -> <repo>/skills/recall
  memorize                      -> <repo>/skills/memorize
  tidy                          -> <repo>/skills/tidy

~/.claude/system/memory         -> <repo>   (operational pointer)
```

No hook is installed; `settings.json` is not modified by the current version (the installer only *removes* a legacy hook entry if one is present — see § 8). The repo is the single source of truth. Skill dirs at `~/.claude/skills/` are symlinks back into the repo, so editing through either path stages the same file. The repo's location is portable (`SCRIPT_DIR=$(cd $(dirname $0) && pwd)` resolves at runtime).

## 6. Install Flow (`setup.sh`)

The installer runs a tool dependency check plus four phases, in order:

### 6.1 Tool dependency check

Verifies `grep`, `jq`, and `bash` are on `PATH`. `grep` powers `/recall` search; `jq` reads `autoMemoryDirectory` from settings at runtime and performs the legacy-settings migration. Aborts with remediation hint if any is missing.

### 6.2 Phase 0 — migrate legacy hook

Removes artifacts from older hook-based installs so an upgrade is clean:

| Legacy artifact | Action |
|---|---|
| `~/.claude/hooks/memory-aggregate.sh` symlink/file | Remove |
| `settings.json` `SessionStart` entry matching `memory-(aggregate\|checkpoint)\.sh` | Strip via `jq` (removal-only; see § 8 discipline) |

If `settings.json` is absent or unreadable, the settings migration is skipped (nothing to clean).

### 6.3 Phase 1 — system link

Creates `~/.claude/system/memory` → repo path. Idempotent: skip if symlink already correct, halt on real-path occupation, relink with `--force` on wrong-target.

### 6.4 Phase 2 — install skill directories

For each entry in `SKILL_DIRS` (`memorize`, `recall`, `tidy`):

| State at `~/.claude/skills/<dir>` | Action |
|---|---|
| Symlink already pointing at repo | Skip, mark ok |
| Symlink pointing elsewhere | Halt unless `--force`; with `--force`, relink |
| Real directory | Halt unless `--force`; with `--force`, move to `~/.claude/skills/.bak/<timestamp>/skill-<dir>/`, then symlink |
| Absent | Symlink |

The skill source must contain a `SKILL.md` file; phase aborts if absent.

### 6.5 Phase 3 — verify

Runs *after* every install phase, regardless of whether they wrote anything:

- Each deployed skill path must be a symlink whose target matches the repo skill directory; the linked `SKILL.md` must declare a matching `name:` frontmatter field
- No legacy hook artifact may remain at `~/.claude/hooks/memory-aggregate.sh`
- `settings.json`, if present, must be clean of any `memory-(aggregate|checkpoint)\.sh` `SessionStart` entry

If any check fails, the summary line is `Verification failed`. The verify phase tests the deployed state directly, not the patch outcome. (Note: under `--dry-run`, freshly-planned links are not actually created, so verify reports them as not-yet-applied — expected.)

### 6.6 Flags

- `--dry-run` — print every action that would be taken; do nothing
- `--force` — replace existing `~/.claude/skills/<dir>` directories even if they are real dirs
- `-h` / `--help` — print top-of-file documentation

## 7. Skill Contract

Every skill in this repo follows this layout:

**Directory structure**
- `skills/<name>/SKILL.md` — required; the only file Claude Code's standalone-skill loader needs

**Frontmatter (YAML)**
- `name` — must match the directory name; `setup.sh` verify enforces this
- `description` — used for the slash-command listing AND model-invocation decision; must enumerate concrete trigger phrases (zh + en) when model-invocation is enabled, since auto-invocation is judgment-based and the description is the only lever. Combined `description` text is capped at 1,536 chars in the listing (configurable via `maxSkillDescriptionChars`)
- `disable-model-invocation: true` — set only when a skill should be exclusively user-invocable (no current skill sets it)

**Body conventions**
- English instructions (per the user's `Doc Language` rule)
- Numbered steps the model executes in order
- Use `$ARGUMENTS` for runtime input; document the parsing convention near the top
- For destructive defaults (write/commit/delete), provide an explicit opt-in confirmation flag (e.g. `/memorize dry`); read-only skills (`/recall`) need none
- No path-coupled helper scripts — a skill should be self-contained so it stays portable
- No positional parameters (`$0`, `$1`, …) anywhere in a SKILL.md, shell snippets included: Claude Code substitutes them with the skill's arguments at load time (`/tidy check` turned `awk 'length($0)…'` into `length(check)`). Use named variables and `awk`'s bare `length`. The same applies to `${CLAUDE_...}`: Claude Code substitutes that form, so shell snippets write `$CLAUDE_CONFIG_DIR` without braces

## 8. Legacy Hook Migration & settings.json Discipline

The current version **never adds** to `settings.json`. The only `settings.json` interaction is the one-time *removal* of a legacy `SessionStart` hook entry during Phase 0. That removal still follows the strict discipline established when the project did patch settings (a malformed write would break Claude Code's startup):

1. **Never write the whole file.** Only `jq`-mediated edits.
2. **Always back up.** `settings.json.bak.<timestamp>` is written before any mutation.
3. **Atomic write.** New content goes to a temp path, then `mv` replaces the original.
4. **Validate after.** `jq . settings.json >/dev/null` is run after writing.
5. **Restore on corruption.** If the post-write validation fails, the backup is restored automatically.
6. **Prune empties.** Matcher blocks left with no hooks are dropped; `SessionStart` is removed entirely if left empty.

Plugin-registered `SessionStart` hooks (e.g. the superpowers plugin) live in plugin `hooks.json`, not in `~/.claude/settings.json`, and are therefore untouched by this migration.

## 9. Relationship to Anthropic Memory Tool

Anthropic announced the Memory Tool (`memory_20250818`) and context editing on **2025-09-29**, alongside Claude Sonnet 4.5. Confirmed at <https://claude.com/blog/context-management>. The tool is API/SDK-layer:

- Operates client-side via tool calls — the application implements file ops
- Provides `view/create/str_replace/insert/delete/rename` commands over a `/memories` virtual directory
- Pairs with context editing: when context approaches the limit, old tool results are auto-cleared and Claude is warned to save important content into memory first

This repo's skills are a **parallel implementation at a different layer**:

| Layer | Native Claude Code | Anthropic Memory Tool | This repo |
|---|---|---|---|
| Where memory lives | `~/.claude/projects/<project>/memory/` (per git repo) | `/memories/` (client-defined) | Same as native |
| Read trigger | Auto-load `MEMORY.md` at session start | Tool call when needed | `/recall` skill greps all projects on demand |
| Write trigger | Model self-judgment in conversation | Tool call when needed | `/memorize` skill (user or model invokes explicitly) |
| Granularity | Per-turn (model decision) | Per-tool-call | Per-invocation (both read and write) |
| Status in Claude Code CLI | Active | Not yet integrated (as of this writing) | Active |

When Claude Code integrates the Memory Tool natively, this repo's `/recall` still adds value — the Memory Tool does not natively know about other projects. The `/memorize` skill could likewise coexist or be retired depending on whether Memory Tool's per-tool-call writes prove sufficient. The standalone-skill paths ensure that adapting to such changes is a localised edit.

## 10. Decision Log

### 10.1 Hook → Skill (2026-05-21)

The read path migrated from a `SessionStart` hook to the `/recall` skill. Rationale, condensed from the design discussion:

- **Trigger:** the cross-cwd index hook silently degraded as memory grew. Empirically, a ~24 KB injected index was truncated to a ~2 KB head preview; ~16 of 17 cwds disappeared from context, undetected.
- **Root cause:** Claude Code caps hook output at 10,000 characters across `stdout` / `additionalContext` / `systemMessage` alike (<https://code.claude.com/docs/en/hooks>). Over-cap output spills to a file the model does not auto-read.
- **Why not compress:** any startup-injected enumeration grows with memory volume; compression only delays the cap and erodes the index's usefulness. The problem is *injection*, not *format*.
- **Resolution:** retrieve at query time instead. A skill's description (constant size) is the always-on cost; grep returns only the relevant slice. Nothing scaling with memory volume enters context. This is the same router/content separation the superpowers plugin uses to scale across many skills.
- **Symmetry gained:** read and write are now both skills (`/recall` + `/memorize`), one paradigm instead of two.
- **Install simplified:** no hook to wire, so the current version never writes to `settings.json` (it only strips the legacy entry on upgrade).
- **Cost accepted:** loss of unconditional passive awareness at session start; cross-cwd recall now depends on the model noticing relevance or the user cueing it. Judged acceptable because the hook's passive awareness was already broken by truncation, and the current cwd's memory is still natively auto-loaded.

### 10.2 Plugin packaging — dual distribution (2026-05-21)

The skills gained a second distribution path: the `mem` Claude Code plugin, published both as a self-hosted single-plugin marketplace (this repo's `.claude-plugin/marketplace.json`, `source: "./"` → `install mem@claude-memory`) and as an entry in the central `howar31` marketplace (`install mem@howar31`). Both install the same plugin; plugin-managed skills are namespaced `/mem:recall` and `/mem:memorize`.

- **Trigger:** broaden distribution beyond clone-and-`setup.sh` to discoverable, managed install (`claude plugin install` + `update`).
- **Why keep `setup.sh` as primary:** it yields the shortest slash names (`/recall`, `/memorize`) — plugins are always namespaced and cannot — and it deploys plain skill directories that a non-Claude harness reading `skills/<name>/SKILL.md` can also consume, independent of any plugin manager.
- **Why nearly free:** the repo's `skills/<name>/SKILL.md` layout already matches plugin auto-discovery, and both skills are self-contained (no dependency on `setup.sh` or `~/.claude/system/memory`), so the same `skills/` tree serves all three paths. The only additions are two manifests (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) plus one entry in the central marketplace; `setup.sh` (fixed `SKILL_DIRS` array, ignores `.claude-plugin/`) and the skill bodies are untouched.
- **`mem` name:** the plugin name — hence the namespace — is the short handle `mem`; the project itself remains `claude-memory`. The self-hosted marketplace is named `claude-memory`, so the install id is `mem@claude-memory`. Modeled on the sibling `magi` plugin in `magi-workflow`, which uses the identical dual-marketplace pattern (`plugin.json` + a `source: "./"` `marketplace.json`, plus a central listing).
- **Cost accepted:** users who install both a standalone copy and the plugin get the skills under two names (`/recall` and `/mem:recall`); docs advise picking one. Plugin releases require a `version` bump in `plugin.json`. Full E2E of the central path can only be exercised after the repo is pushed to GitHub (the central entry references `howar31/claude-memory` via a `github` source).

### 10.3 `/tidy` maintenance skill (2026-10-16)

- **Trigger:** a parent-folder cwd that holds several repos approached the 25KB index limit, with closed incidents, per-person grants and repo-code entries all in one index.
- **Decision:** a third skill rather than a mode of `/memorize`, keeping one function per mechanism: `/recall` reads, `/memorize` writes new entries, `/tidy` maintains the store.
- **Archive over delete:** an `archived:` frontmatter field instead of deletion keeps history searchable and lets the unindexed-entry check tell intentional removals from omissions.
- **Proposal-first:** tidying without fixed rules tends to apply changes before confirmation, treat closed entries as delete-or-keep with no middle option, move infrastructure entries into a repo, and leave no pointer in the entry index. The skill makes the proposal a hard stop and states the placement test.
- **Cost accepted:** relocated entries no longer auto-load in parent-folder sessions; the pointer line and `/recall` cover that gap, at the price of one extra read when the topic comes up.

### 10.4 No `npx skills` channel (2026-10-16)

The cross-agent `npx skills` CLI would discover `skills/<name>/SKILL.md` in this repo, but all three skills operate on Claude Code's own memory store (`~/.claude/projects/*/memory/`, the auto-loaded `MEMORY.md` and its load limit). Installed into another agent they have nothing to act on, so distribution stays `setup.sh` + the `mem` plugin. Revisit only if another agent adopts the same memory layout.

### 10.5 Align with the documented memory layout (2026-10-16)

- **Trigger:** the docs and wording described memory as keyed by cwd; the memory docs key it by git repository (subdirectories and worktrees share one dir) and fall back to the project root outside a repo. Checking all three skills against the current docs and local data also found: the transcript-`cwd` lookup read line 1, which carries no `cwd`; `/memorize`'s fallback matched transcript `cwd` to the current directory, which picks a dir Claude Code never loads for a subdirectory or worktree session; `/tidy` documented only `/` and `_` in the folder-name encoding; `/memorize` wrote a top-level `type:` while Claude Code nests it under `metadata:`.
- **Decision:** take the memory dir from the system prompt; derive it only as a fallback from the main worktree root with the documented encoding; read `cwd` from anywhere in the newest transcript and fall back to the folder name; write `metadata.type`; let `/recall` also search subagent memory and `autoMemoryDirectory` dirs and cite `modified` dates; let `/tidy` judge age by `modified` and skip moves when the entry dir is outside `<config dir>/projects/`.
- **Cost accepted:** the skills now depend on more documented-but-changeable details (encoding, frontmatter layout, override settings); § 1.1 lists them with sources so a future check is one pass over the cited pages.

## 11. Future Extensions (Not Implemented)

### 11.1 Lesson Graduation

Port muse-crystal-seed's lesson state machine into the user's global `Applied Learning` log:

- `active` — entry currently in effect, monitored for violations per session
- `graduated` — N consecutive sessions without violation; entry archived (still searchable, no longer reminded)
- `chronic` — entry has been re-added repeatedly after promotion; flagged for structural fix (hook, gate, automation) rather than another reminder

Defer until `Applied Learning` accumulates enough entries to justify the state-machine overhead.

### 11.2 Active prefetch

A `UserPromptSubmit` hook that searches all `~/.claude/projects/*/memory/` for keyword matches with each user message, injecting relevant entries proactively (à la OpenClaw `active-memory`).

Defer until `/recall` is observed to be insufficient in practice. If the model still misses cross-project recall when not explicitly cued, active prefetch closes the gap. Note the 10,000-char output cap applies to `UserPromptSubmit` too, so any such hook must inject only a small relevant slice (retrieve-don't-inject), never an enumeration.

### 11.3 Promotion sweep

A periodic background job (cron or on-demand) that reviews recent daily logs and promotes content into `MEMORY.md` based on access frequency, à la OpenClaw `dreaming sweep` and `memory promote`.

Defer until daily logs exist; the user does not currently maintain `memory/YYYY-MM-DD.md` files. If short-term memory becomes a need, the daily-log + promote pipeline is the first step before any sweep.

## 12. References

### Anthropic primary sources
- [Claude Code hooks documentation](https://code.claude.com/docs/en/hooks) — establishes the 10,000-char hook output cap (§ 3.2, § 10)
- [Claude Code skills documentation](https://code.claude.com/docs/en/skills) — skill description budget, `maxSkillDescriptionChars`, overflow behaviour, argument and `${CLAUDE_*}` substitution (§ 7)
- [Claude Code memory documentation](https://code.claude.com/docs/en/memory) — memory dir per git repo, load limits, `autoMemoryDirectory`, `modified` field (§ 1)
- [Claude Code sessions documentation](https://code.claude.com/docs/en/sessions) — project folder-name encoding, transcript location and retention, `CLAUDE_CODE_PROJECT_DIR_NAME` (§ 1.1)
- [Claude Code sub-agents documentation](https://code.claude.com/docs/en/sub-agents) — subagent `memory` scopes and paths (§ 1.1)
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
