---
name: memorize
description: Audit the current conversation and persist memory-worthy content (user preferences, feedback, project state, references) to the cwd's memory directory. Invoke when the user explicitly asks to remember something, OR when you detect non-obvious learnings that should outlive this session — e.g., the user corrected your approach, validated a non-obvious choice, revealed new domain context, or established new project facts.
---

Audit the current conversation against the four memory categories defined in the global `~/.claude/CLAUDE.md` auto-memory rules, and persist entries that should survive past this session.

`$ARGUMENTS` parsing:
- If `$ARGUMENTS` starts with the token `dry` (alone, or followed by whitespace + more text), enable **preview mode**: show the proposal first and wait for confirmation before writing. The rest of `$ARGUMENTS` after `dry` is the focus hint.
- Otherwise, `$ARGUMENTS` is the focus hint and the skill writes directly.

A **focus hint** gives matching content priority, but the audit still scans all four categories.

Examples:
- `/memorize` — write, no focus hint
- `/memorize hooks 設計決策` — write, focus on hooks design
- `/memorize dry` — preview, no focus hint
- `/memorize dry hooks 設計決策` — preview, focus on hooks design

## Step 1 — Locate the memory directory

The cwd's memory directory is the parent of the auto-loaded `MEMORY.md` already in your context (path matches `~/.claude/projects/<encoded-cwd>/memory/`). Use that exact path.

If `MEMORY.md` is not in context, derive the encoded cwd by checking `~/.claude/projects/*/` for a directory whose latest `*.jsonl` transcript first record has a `cwd` field matching the current cwd. Create the `memory/` subdirectory and an empty `MEMORY.md` (no frontmatter) if absent.

## Step 2 — Audit four categories

For each category below, decide YES or NO **explicitly**. Silent skipping is not acceptable.

1. **user** — Anything new revealed about the user's role, preferences, knowledge, or domain context?
2. **feedback** — Did the user correct your approach ("don't", "stop", "no, not that") OR validate a non-obvious choice ("yes exactly", "perfect, keep that")?
3. **project** — Did work-state, decisions, deadlines, or stakeholder context change?
4. **reference** — Were external systems, dashboards, docs, or tools cited as authoritative for some topic?

Before drafting entries, read existing files in the memory dir to avoid duplicates. If an existing entry already covers the same content, prefer updating it over creating a new one.

## Step 3 — Preview (only if `dry` mode)

If preview mode is enabled, do **not** write yet. Instead:

1. Print a short proposal: for each entry, show filename, type, and one-line summary. For non-trivial entries, also show the body preview (`Why:` and `How to apply:` lines for `feedback` / `project`).
2. Wait for the user's response in the next turn.
3. Apply their decision:
   - **Approval** ("ok", "go", "好", "yes", or similar) → proceed to Step 4
   - **Edits** ("drop the second one", "rephrase X", "merge 1 and 3") → apply, re-print the updated proposal, wait again
   - **Decline** ("no", "算了", "cancel") → abort, report nothing was saved

In default (non-dry) mode, skip this step entirely.

## Step 4 — Write the entries

Each entry is one `.md` file under the memory dir using this format:

```markdown
---
name: {{title}}
description: {{one-line description used to decide relevance in future conversations — be specific}}
type: {{user | feedback | project | reference}}
---

{{content body}}
```

For `feedback` and `project` types, the body must include:
- A `**Why:**` line — the reason behind the rule/fact (often a past incident or constraint)
- A `**How to apply:**` line — when/where this guidance applies

For `user` and `reference` types, the body is freeform but should stay terse.

## Step 5 — Update `MEMORY.md`

Append one pointer line per new entry to `MEMORY.md` in the same directory:

```
- [Title](filename.md) — one-line hook
```

Keep each line under ~150 characters. Do not duplicate existing pointers. `MEMORY.md` itself has no frontmatter and is index-only.

## Step 6 — Report

Print a short summary: filenames written, filenames updated, and confirmation that `MEMORY.md` index is in sync. If nothing was memory-worthy, say so explicitly — an empty audit is a valid result.

## Notes

- Convert relative dates ("Thursday", "next week") to absolute dates (`YYYY-MM-DD`) in saved content.
- Do **not** save: ephemeral task state, rediscoverable code patterns, content already in CLAUDE.md, or this conversation's summary text.
- If unsure whether something is worth saving, lean toward saving — an extra entry beats a lost one.
- Default behaviour is to write directly. Use `dry` mode for explicit preview-first; or honour an in-conversation override like "先給我看" without requiring the flag.
- This skill writes memory. To search/recall existing memory across all project cwds (read), use `/recall`.
