---
name: tidy
description: Use when a cwd's MEMORY.md index grows large or nears its auto-load limit (first 200 lines or 25KB), when Claude Code warns the memory index is near or over its read limit, when memory entries look stale, closed, duplicated or misplaced, when sessions are usually opened in a parent workspace folder holding several repos and repo-specific memories pile up there, or for periodic memory maintenance. Proactively offer it when MEMORY.md passes about 60% of either limit. Read-only health check — /tidy check. Trigger phrases — (zh) 「整理記憶」「記憶太大」「MEMORY.md 太長」「記憶瘦身」「清理記憶」「記憶搬到各專案」「檢查記憶」; (en) "tidy memory", "clean up memory", "memory index too big", "prune MEMORY.md", "reorganize memories", "move memories to the repo", "check memory health".
---

Keep the cwd's memory store loadable and well placed: the auto-loaded `MEMORY.md` stays under its limit, and each entry lives in the memory dir of the session that needs it. Nothing is deleted. An entry leaves the index only by being archived, grouped under a hub, or moved, and stays readable by `/recall`.

`$ARGUMENTS` parsing:
- `check` → read-only: run Steps 1–2, report, change nothing.
- Anything else is a focus hint (a repo name or topic) that gets priority; the run still covers the whole store.

**No file changes before the user approves the Step 4 proposal.** A request such as "tidy my memory" asks for a proposal; it does not approve specific actions.

## Step 1 — Locate the dirs

1. **Entry dir `E`** = the dir of the auto-loaded `MEMORY.md` (`<root>/<entry-folder>/memory/`). Projects root `R` = the parent of `<entry-folder>`.
2. **Child dirs** = `R/<entry-folder>-*/memory/`. Claude Code keys memory by git repo root (or by cwd outside a repo) and encodes the path with `/` and `_` as `-`, so sessions opened in subfolders of the cwd land in folders sharing this prefix. The encoding is lossy; when a prefix match is ambiguous, confirm with the `cwd` field of that folder's newest transcript: `head -1 "$(ls -t R/<folder>/*.jsonl | head -1)" | jq -r .cwd`.
3. **Repos without memory yet** = git repos directly under the cwd (`git -C <dir> rev-parse --show-toplevel` equals `<dir>`). Their memory folder is created on first move.

## Step 2 — Measure and check

Run in `E` and in every child dir; keep a copy of each `MEMORY.md` as read now (needed in Step 5.6):

```bash
cd "<memory dir>"
printf 'MEMORY.md: %s lines, %s bytes\n' "$(wc -l < MEMORY.md)" "$(wc -c < MEMORY.md)"
awk 'length > 150 { print "long line " NR ": " length }' MEMORY.md
for f in *.md; do
  grep -o '](\([^)#]*\.md\))' "$f" | sed 's/^](//; s/)$//' | while read -r l; do
    [ -f "$l" ] || echo "dangling in $f: $l"
  done
done
for f in *.md; do
  [ "$f" = MEMORY.md ] && continue
  grep -qF "($f)" MEMORY.md && continue
  grep -q '^[[:space:]]*archived:' "$f" && continue
  grep -o '](\([^)#]*\.md\))' MEMORY.md | sed 's/^](//; s/)$//' | while read -r h; do
    [ -f "$h" ] && grep -qF "($f)" "$h" && echo hub
  done | grep -q hub || echo "unindexed: $f"
done
```

The snippet runs the same in bash and zsh. `awk` may count bytes rather than characters, so CJK text and `—` read longer; treat the count as approximate.

Limits (Claude Code docs, memory page): the first 200 lines or 25KB of `MEMORY.md`, whichever comes first, load at session start; the rest is dropped silently. Entry files load on demand and do not count.

## Step 3 — Classify every entry

Read each entry (frontmatter and body, especially status lines). Give each exactly one action:

| Action | When | Effect |
|---|---|---|
| keep | user and feedback entries; references still true; projects with open items or a future date | unchanged |
| shorten | index line over ~150 chars | rewrite the hook; detail stays in the file's `description` |
| archive | project closed (done, resolved, decided and applied), nothing pending, no future date | drop the index line; add `archived: YYYY-MM-DD` to the frontmatter; file stays |
| group | 3+ entries of one kind of standing record (per-person access grants, per-vendor contacts, per-environment settings) | one hub entry lists them; the index keeps only the hub line; member files unchanged |
| move | the entry is about one repo's code: source files, PRs, branches, repo conventions, a bug fixed by a code change | file goes to that repo's memory dir and its index |
| fix | dangling link, unindexed file, or a fact the user has since corrected | repair the link (a bare filename that lives in another memory dir becomes `../../<folder>/memory/<file>`); index or archive the file; update the fact |
| ask | status cannot be read from the file: a past deadline with no completion record, "pending" older than ~30 days | becomes a question in the proposal |

Placement test for **move**: would a session opened inside that repo need this entry to change the repo's code? Only a clear yes moves it. These stay in `E`:
- Infrastructure and operations about a service (load balancer, CDN, IAM, deploy platform, incidents), even when it names one repo's service.
- Entries mixing code and infrastructure.
- All user and feedback entries.

Archived files stay searchable through `/recall`, so archiving a closed incident loses nothing, including any fingerprint or diagnosis it records. A closed project entry stays indexed only when it is the sole written copy of a procedure that will be run again (a renewal, a rotation, a recurring migration); in that case propose keeping it, or moving the procedure into a reference first. A reference is never archived for being old.

## Step 4 — Proposal, then stop

Print, in this order:
1. `E`'s `MEMORY.md` now → expected after: lines, bytes, and percent of each limit.
2. One table per action (archive, group, move, shorten, fix): entry, target, one-line reason.
3. Questions from `ask`.

Then wait. Approval → Step 5. Edits → revise, reprint, wait again. Decline → stop; report that nothing changed. In `check` mode, print only item 1 and the Step 2 findings.

## Step 5 — Apply

1. **Backup.** Copy `E` and every child dir that will change to `${TMPDIR:-/tmp}/memory-tidy-<YYYYmmdd-HHMMSS>/`.
2. **Archive.** Insert `archived: YYYY-MM-DD` on the line after `type:`, same indentation.
3. **Group.** Write the hub entry (same `type` as its members). Body: one line per member in index format, then `**Why:**` and `**How to apply:**`, stating that new records of this kind are added to the hub, not to `MEMORY.md`.
4. **Move.** Create the target `memory/` and its `MEMORY.md` if missing. Move the file, append its index line in the target, then rewrite markdown links:
   - in the moved file, links to entries that stayed → `../../<entry-folder>/memory/<file>`;
   - in entries that stayed, links to the moved file → `../../<child-folder>/memory/<file>`;
   - between files moved to the same dir → bare filename.
   `[[name]]` wikilinks resolve by name; leave them.
5. **Rewrite `E`'s `MEMORY.md`.** Sections `## User & feedback`, `## Reference`, `## Project`, then `## Repo memories` with one pointer per child dir:
   `- [<repo>](../../<child-folder>/memory/MEMORY.md) — <topic keywords of its entries>`
   An entry session cannot auto-load child memory; the pointer's keywords tell it which index to read. Refresh the keywords whenever entries move.
6. **Concurrency guard.** Other sessions may write `MEMORY.md` meanwhile. Immediately before writing any `MEMORY.md`, diff it against the copy from Step 2 and carry new lines into the new version.

## Step 6 — Verify

Re-run Step 2 on every touched dir. Expected: no dangling links, no unindexed files, `E` smaller than before. Report any remaining finding as a finding; do not call the run complete while one is open.

## Step 7 — Report

Before → after numbers, count per action, the backup path, and open questions.

## Red flags

| Thought | Correct move |
|---|---|
| "The user asked to tidy, so I can apply." | Show the Step 4 proposal first. |
| "It's closed; delete it." | Archive. Files are never deleted. |
| "It names the repo's service, so it belongs to the repo." | Apply the placement test; infrastructure stays in `E`. |
| "The moved files link to each other, so links are fine." | Also check links from entries that stayed, and add the `## Repo memories` pointer. |
| "The deadline passed; it must be done." | Ask. |

## Notes

- Index line format matches `/memorize`: `- [Title](file.md) — hook`, about 150 characters at most.
- Edit entry bodies only for: the `archived` field, link rewrites, and facts the user confirmed in this run.
- Touch only `memory/` dirs; never transcripts.
- To read memory across cwds, use `/recall`; to write new entries, use `/memorize`.
