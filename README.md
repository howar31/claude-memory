# claude-memory

[![License](https://img.shields.io/github/license/howar31/claude-memory?style=flat-square)](LICENSE)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-D77655?style=flat-square)](https://claude.com/claude-code)
[![Made with Bash](https://img.shields.io/badge/made%20with-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-yellow?style=flat-square)](https://www.conventionalcommits.org)
[![Last Commit](https://img.shields.io/github/last-commit/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/commits/main)
[![Stars](https://img.shields.io/github/stars/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/stargazers)
[![Open Issues](https://img.shields.io/github/issues/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/issues)
[![Sponsor](https://img.shields.io/badge/Sponsor-donate.howar31.com-b4532c?style=flat-square&logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTIwLjg0IDQuNjFhNS41IDUuNSAwIDAgMC03Ljc4IDBMMTIgNS42N2wtMS4wNi0xLjA2YTUuNSA1LjUgMCAwIDAtNy43OCA3Ljc4bDEuMDYgMS4wNkwxMiAyMS4yM2w3Ljc4LTcuNzggMS4wNi0xLjA2YTUuNSA1LjUgMCAwIDAgMC03Ljc4eiIvPjwvc3ZnPg==)](https://donate.howar31.com/)

English | [正體中文](README.zh-Hant.md)

Three skills for [Claude Code](https://claude.com/claude-code)'s built-in auto-memory: a **read** skill that recalls memory across projects, a **write** skill that audits the conversation on demand, and a **maintenance** skill that keeps each project's memory index under its load limit. They work directly on the existing `~/.claude/projects/<project>/memory/` files. No vector database, no MCP server, no external service.

## What you get

### Read: `/recall` skill

Claude Code's auto-memory is kept per project: one memory folder per git repository, shared by all of its subdirectories and worktrees, and one per project directory outside a repo. A memory written in one repo is not visible from another repo, or from a parent folder that holds several repos, even when the topic is the same. Claude Code auto-loads only the **current** project's `MEMORY.md` at startup.

`/recall` covers that gap on demand: it greps every `~/.claude/projects/*/memory/` (plus subagent memory and any `autoMemoryDirectory` it finds in your settings) for the topic, reads the relevant entries, and answers from them, citing which project each came from.

```text
/recall <topic>     → search all projects' memory for the topic and report
/recall             → infer the topic from the conversation (or ask if unclear)
```

Recall happens **at query time** (grep returns only the matching slice) instead of injecting a full index at startup, so its context cost does not grow with the size of your memory. The skill is model-invocable and its description asks the model to call it often: when you reference past work in another project, when you ask what it remembers, and at the start of a task that resembles earlier work. It is read-only.

### Write: `/memorize` skill

Claude Code's auto-memory writes are prompt-driven: the model decides during a turn whether content is worth saving, and sometimes does not notice. `/memorize` is the explicit lever: it audits the current session against four memory categories (`user`, `feedback`, `project`, `reference`) and persists entries.

By default it writes directly. Pass `dry` to preview first and confirm before writing:

```text
/memorize                          → audit and write directly
/memorize <focus hint>             → write, prioritise content matching the hint
/memorize dry                      → list proposed entries, wait for "ok"
/memorize dry <focus hint>         → preview with focused audit
```

The skill is also model-invocable, and its description asks the model to run it whenever a turn may have produced something worth keeping (corrections, confirmed choices, new domain context, project state changes). It reads existing entries first and updates them instead of adding duplicates, and an empty audit is a valid outcome.

### Maintain: `/tidy` skill

Claude Code loads only the first 200 lines or 25KB of a project's `MEMORY.md` at session start; anything past that is dropped without notice. Memory also piles up in one place when sessions are usually opened in a parent folder that holds several repos, while a session opened inside one of those repos never sees it.

`/tidy` measures the index, checks for broken links and unindexed entries, and proposes one action per entry:

- **archive**: a closed item leaves the index; the file stays, marked `archived:`, and `/recall` still finds it
- **group**: several records of one kind (for example per-person access grants) sit under one hub entry, so the index keeps one line
- **move**: an entry about one repo's code goes to that repo's memory folder, and the parent folder's index keeps a pointer line with the topics it holds
- **shorten** / **fix**: long index lines, dangling links, unindexed files

Nothing changes until you approve the proposal. Files are never deleted, and the touched folders are backed up before any change.

```text
/tidy               → measure, classify, propose; apply after approval
/tidy <focus hint>  → same, prioritising a repo or topic
/tidy check         → read-only health report
```

All three skills complement the built-in auto-memory; they do not replace it. See [SPEC.md](SPEC.md) for the design rationale, why the earlier SessionStart hook was retired, alternatives considered (mem-palace, Obsidian, OpenClaw, muse-crystal-seed, Letta, Mem0, Zep), and the relationship to Anthropic's Memory Tool (released 2025-09-29 for the API).

## Architecture

```
/recall skill    -->  grep ~/.claude/projects/*/memory/ for the topic
                      read matching entries; answer with project citations

/memorize skill  -->  audit current session against four memory
                      categories; write entries + update MEMORY.md

/tidy skill      -->  measure MEMORY.md against its load limit; propose
                      archive / group / move per entry; apply on approval
```

Files installed:

```
~/.claude/skills/recall/      /recall skill     (symlink → repo)
~/.claude/skills/memorize/    /memorize skill   (symlink → repo)
~/.claude/skills/tidy/        /tidy skill       (symlink → repo)
~/.claude/system/memory       symlink → repo    (operational pointer)
```

No hook is installed and `settings.json` is not modified. If you installed an older hook-based version, `setup.sh` removes the legacy hook and its `settings.json` entry (see *Quick Start*).

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/howar31/claude-memory
```

The location is up to you; the installer resolves its own path and works from anywhere.

### 2. Install

```bash
cd claude-memory && ./setup.sh
```

The installer is idempotent and safe to re-run. It will:

- Remove any legacy `SessionStart` hook artifacts from an earlier install (symlink + `settings.json` entry, backed up first)
- Symlink the `recall`, `memorize` and `tidy` skill directories into `~/.claude/skills/` (backing up any existing real directory)
- Create `~/.claude/system/memory` → repo
- Run a verification phase that confirms the skill symlinks, their `SKILL.md` frontmatter, and that no legacy hook remains

If a step is unsafe to do automatically (an existing real directory at a skill path), the installer stops with a remediation message, with a backup already in place.

### 3. Verify

```bash
./setup.sh           # re-run any time; reports all checks or what is wrong
./setup.sh --dry-run # preview without applying
./setup.sh --force   # replace mismatched directories at ~/.claude/skills/
```

### 4. Use it

Skills are picked up dynamically; run `/reload-plugins` in an active session if `/recall`, `/memorize` and `/tidy` do not appear immediately. No restart is required (there is no hook to load).

## Install as a plugin (alternative)

If you prefer Claude Code's plugin manager over the symlink installer, the same skills are also published as the `mem` plugin. Plugin-managed skills are **namespaced**, so they appear as `/mem:recall`, `/mem:memorize` and `/mem:tidy` (the `setup.sh` method above keeps the shorter `/recall`, `/memorize` and `/tidy`; see the comparison below).

Two registration paths install the same plugin; pick one.

**Self-hosted marketplace** (this repo is its own marketplace):

```bash
claude plugin marketplace add howar31/claude-memory
claude plugin install mem@claude-memory
```

**Central marketplace** (all of howar31's plugins; register once, future plugins appear automatically):

```bash
claude plugin marketplace add howar31/howar31-marketplace
claude plugin install mem@howar31
```

### Which install method?

| | `setup.sh` (symlink) | plugin (`mem`) |
|---|---|---|
| Slash names | `/recall`, `/memorize`, `/tidy` (shortest) | `/mem:recall`, `/mem:memorize`, `/mem:tidy` |
| Install / update | clone + re-run `setup.sh` | `claude plugin install` / `update` |
| Discoverable | no | yes (via marketplace) |
| Non-Claude harnesses | works (plain skill dirs) | depends on the harness's plugin support |

Install one method, not both; both together expose the same skills under two names.

The skills are not offered through `npx skills`: all three work on Claude Code's own memory folders, so another agent has nothing for them to act on.

## What you'll see

When you reference past work in another project ("did we solve X in the other repo?", "find my preference for Y"), Claude invokes `/recall`, greps every project's memory, and answers from the matching entries, naming the source project. You can also call `/recall <topic>` explicitly.

Whenever you (or Claude) want to keep session content for the future, run `/memorize` (or `/memorize dry` to review the proposal first). Entries are written to the memory folder Claude Code uses for the current project (by default `~/.claude/projects/<project>/memory/`, where `<project>` is the repository's path with non-alphanumeric characters replaced by `-`), where the current session's auto-load and future `/recall` searches both pick them up.

When a project's `MEMORY.md` grows past about 60% of its load limit, or Claude Code warns that it is near the limit, run `/tidy` (or `/tidy check` for a read-only report).

## Backup

The skill directories in `~/.claude/skills/` and `~/.claude/system/memory` are symlinks back into the repo, so the repo is the single source of truth and any backup that includes the clone covers it.

If you also use [`claude-backup`](https://github.com/howar31/claude-backup) for the `~/.claude/` tree, the symlinks are covered there as well.

## Uninstall

```bash
# Remove the skill symlinks (replaced real dirs, if any, are in ~/.claude/skills/.bak/<timestamp>/)
rm ~/.claude/skills/recall
rm ~/.claude/skills/memorize
rm ~/.claude/skills/tidy
rm ~/.claude/system/memory
```

If you installed the plugin instead:

```bash
claude plugin uninstall mem@claude-memory   # or mem@howar31
```

There is nothing to undo in `settings.json`; the current version never writes to it.

## Reference

- [SPEC.md](SPEC.md): architecture, design decisions, alternatives considered, skill contracts, future extensions
- [CLAUDE.md](CLAUDE.md): agent index for working in this repo

## License

MIT
