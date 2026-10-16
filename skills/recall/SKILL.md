---
name: recall
description: Search and recall memories across ALL projects (cross-project), not just the current one. Claude Code auto-loads only the current project's memory (one per git repo, or per directory outside a repo); this skill greps every ~/.claude/projects/*/memory/ and subagent memory on demand and reads the relevant entries — scaling without limit instead of injecting an index at startup. It is read-only and cheap, so lean toward invoking: when in doubt, recall. Proactively self-invoke at the start of any task that resembles past work, before answering a question that prior decisions could inform, or when entering a project area you have touched before — do not wait to be asked. Also invoke when the user references past work in another project, asks what you remember about a topic, the current task echoes something likely recorded in another project, or asks a cross-project question. Trigger phrases — (zh) 「你記得…嗎」「我之前在別的專案…」「我們在 X repo 怎麼做的」「我哪個專案碰過…」「找一下我對…的習慣/設定」「之前有沒有處理過…」「跨專案查一下」; (en) "do you remember", "did we do X in another repo", "have I worked on X before", "recall", "search my memories", "what do you know about my preference for X", "across my projects".
---

Search the cross-project memory store on demand and answer from what you find. Claude Code keeps one memory dir per project: per git repository (its subdirectories and worktrees share it), or per launch directory outside a repo. It auto-loads the current project's `MEMORY.md`; this skill covers every **other** project (and the current project's full entry bodies, which are not all in context).

`$ARGUMENTS` parsing:
- `$ARGUMENTS` is the **search topic**. Example: `/recall 連結語法習慣`, `/recall branch protection`.
- If `$ARGUMENTS` is empty, infer the topic from the current conversation. If the topic is still ambiguous, ask the user for one before searching — do not grep blindly.

## Step 1 — Derive search terms

Memory files are written in **English** (per the store's doc-language rule), but the user often converses in Traditional Chinese. So:

1. Translate a Chinese topic into its likely English keywords.
2. Add synonyms, variant spellings, and related terms — recall is conceptual, not exact-match.
3. Include any obvious symbol forms.

Example: `連結語法` → `link`, `wikilink`, `\[\[`, `cross-reference`, `syntax`, `markdown`.

## Step 2 — Search across all memory dirs

Run a case-insensitive recursive grep over every memory dir for the alternation of terms. Search both the per-entry `.md` files (full content) and `MEMORY.md` (one-line hooks):

```bash
base="$HOME/.claude"; [ -n "$CLAUDE_CONFIG_DIR" ] && base="$CLAUDE_CONFIG_DIR"
grep -rilE 'term1|term2|term3' "$base"/projects/*/memory/ "$base/agent-memory/" 2>/dev/null
```

Add these dirs to the same grep when they exist:
- The current session's auto-memory dir named in your system prompt, when it lies outside `$base/projects/` (an `autoMemoryDirectory` setting moves it).
- Other `autoMemoryDirectory` values: `jq -r '.autoMemoryDirectory // empty' "$base/settings.json" .claude/settings.json .claude/settings.local.json 2>/dev/null` (expand a leading `~/`).
- The current project's subagent memory: `.claude/agent-memory/` and `.claude/agent-memory-local/`.

`agent-memory/<agent>/` dirs belong to subagents that declare a `memory` scope; cite them as that agent's memory.

- Zero hits → broaden terms (drop the narrowest, add synonyms) and retry.
- Too many hits → add a more specific term or AND-combine (pipe a second grep).
- This is the whole retrieval engine. There is **no helper script** — grep over the source files is the mechanism, by design.

## Step 3 — Read the matches

`Read` the top candidate **entry** files (the individual `*.md`, not `MEMORY.md`) for full content. Prefer entry files over `MEMORY.md`, which only holds one-line hooks.

## Step 4 — Resolve project labels (only if precision needed)

A project folder name is the project path with every non-alphanumeric character replaced by `-` (e.g. `/path/to/project` → `-path-to-project`), so it is usually readable enough to cite. The encoding is lossy. For the exact path, take the first `cwd` value in the folder's newest transcript; no fixed line holds it:

```bash
grep -m1 -o '"cwd":"[^"]*"' "$(ls -t "$base/projects/<dir>"/*.jsonl | head -1)" | cut -d'"' -f4
```

The result can be a subdirectory of the project. Transcripts are deleted after the retention period (`cleanupPeriodDays`, 30 days by default) while memory stays, and their format is internal to Claude Code; when no transcript or no `cwd` is found, cite the folder name.

## Step 5 — Report

Lead with the conclusion, then the evidence. For each relevant memory: state the fact and cite its source (project + filename). When its frontmatter has a `modified` timestamp (Claude Code writes it on each save, at top level or under `metadata:`), give the date so the user can judge how current the fact is. If two entries cross-link (`[[name]]` or a markdown link), follow the link. If nothing matches, say so explicitly and suggest broader terms — an empty recall is a valid result, not a failure to hide.

## Notes

- Memories are point-in-time observations. Before asserting a memory's `file:line`, flag, or behavior claim as current fact, verify it against the live code.
- Do not speculate about memory contents — always `Read` the source file when an entry looks relevant.
- Include the current project in the search: its `MEMORY.md` index is in context, but its individual entry bodies may not be.
- An entry whose frontmatter has `archived: YYYY-MM-DD` is closed history (removed from the index by `/tidy`). Cite it as past state, not as current.
- This skill is read-only. To write memory, use `/memorize`.
