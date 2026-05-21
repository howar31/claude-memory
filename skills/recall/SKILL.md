---
name: recall
description: Search and recall memories across ALL project directories (cross-cwd), not just the current one. Claude Code auto-loads only the current cwd's memory; this skill greps every ~/.claude/projects/*/memory/ on demand and reads the relevant entries — scaling without limit instead of injecting an index at startup. Invoke when the user references past work in another project, asks what you remember about a topic, the current task echoes something likely recorded in another cwd, or the user asks a cross-project question. Trigger phrases — (zh) 「你記得…嗎」「我之前在別的專案…」「我們在 X repo 怎麼做的」「我哪個專案碰過…」「找一下我對…的習慣/設定」「之前有沒有處理過…」「跨專案查一下」; (en) "do you remember", "did we do X in another repo", "have I worked on X before", "recall", "search my memories", "what do you know about my preference for X", "across my projects".
---

Search the cross-cwd memory store on demand and answer from what you find. Claude Code already auto-loads the current cwd's `MEMORY.md`; this skill covers everything in **other** cwds (and the current cwd's full entry bodies, which are not all in context).

`$ARGUMENTS` parsing:
- `$ARGUMENTS` is the **search topic**. Example: `/recall 連結語法習慣`, `/recall branch protection`.
- If `$ARGUMENTS` is empty, infer the topic from the current conversation. If the topic is still ambiguous, ask the user for one before searching — do not grep blindly.

## Step 1 — Derive search terms

Memory files are written in **English** (per the store's doc-language rule), but the user often converses in Traditional Chinese. So:

1. Translate a Chinese topic into its likely English keywords.
2. Add synonyms, variant spellings, and related terms — recall is conceptual, not exact-match.
3. Include any obvious symbol forms.

Example: `連結語法` → `link`, `wikilink`, `\[\[`, `cross-reference`, `syntax`, `markdown`.

## Step 2 — Search across all cwd memory dirs

Run a case-insensitive recursive grep over every memory dir for the alternation of terms. Search both the per-entry `.md` files (full content) and `MEMORY.md` (one-line hooks):

```bash
grep -rilE 'term1|term2|term3' ~/.claude/projects/*/memory/ 2>/dev/null
```

- Zero hits → broaden terms (drop the narrowest, add synonyms) and retry.
- Too many hits → add a more specific term or AND-combine (pipe a second grep).
- This is the whole retrieval engine. There is **no helper script** — grep over the source files is the mechanism, by design.

## Step 3 — Read the matches

`Read` the top candidate **entry** files (the individual `*.md`, not `MEMORY.md`) for full content. Prefer entry files over `MEMORY.md`, which only holds one-line hooks.

## Step 4 — Resolve project labels (only if precision needed)

The project folder name (e.g. `-opt-projects--mirror-kintai`) is usually readable enough to cite. If you need the exact cwd path, read the first line of the most recent `*.jsonl` transcript in that project dir and extract its `cwd` field (the folder-name encoding is lossy, so the transcript is authoritative):

```bash
head -1 "$(ls -t ~/.claude/projects/<dir>/*.jsonl | head -1)" | jq -r '.cwd'
```

## Step 5 — Report

Lead with the conclusion, then the evidence. For each relevant memory: state the fact and cite its source (project + filename). If two entries cross-link via `[[name]]`, follow the link. If nothing matches, say so explicitly and suggest broader terms — an empty recall is a valid result, not a failure to hide.

## Notes

- Memories are point-in-time observations. Before asserting a memory's `file:line`, flag, or behavior claim as current fact, verify it against the live code.
- Do not speculate about memory contents — always `Read` the source file when an entry looks relevant.
- Include the current cwd in the search: its `MEMORY.md` index is in context, but its individual entry bodies may not be.
- This skill is read-only. To write memory, use `/memorize`.
