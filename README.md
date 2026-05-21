# claude-memory

[![License](https://img.shields.io/github/license/howar31/claude-memory?style=flat-square)](LICENSE)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-D77655?style=flat-square)](https://claude.com/claude-code)
[![Made with Bash](https://img.shields.io/badge/made%20with-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-yellow?style=flat-square)](https://www.conventionalcommits.org)
[![Last Commit](https://img.shields.io/github/last-commit/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/commits/main)
[![Stars](https://img.shields.io/github/stars/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/stargazers)
[![Open Issues](https://img.shields.io/github/issues/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/issues)
[![Sponsor on Ko-fi](https://img.shields.io/badge/sponsor-Ko--fi-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white)](https://ko-fi.com/howar31)

Two complementary skills that close reliability gaps in [Claude Code](https://claude.com/claude-code)'s built-in auto-memory: a **read** skill that recalls memory across project directories, and a **write** skill that audits the conversation on demand. Pure read/write on top of the existing `~/.claude/projects/<encoded-cwd>/memory/` filesystem. No vector database, no MCP server, no external service.

## What you get

### Read — `/recall` skill

Claude Code's auto-memory is namespaced per cwd. A memory written while working in one project directory lives in that cwd's memory folder and is invisible from a sibling or parent cwd, even when the topic is the same. Claude Code auto-loads only the **current** cwd's `MEMORY.md` at startup.

`/recall` closes that gap on demand: it greps every `~/.claude/projects/*/memory/` for the topic, reads the relevant entries, and answers from them — citing which project each came from.

```text
/recall <topic>     → search all cwds' memory for the topic and report
/recall             → infer the topic from the conversation (or ask if unclear)
```

Because recall happens **at query time** (grep returns only the matching slice) rather than by injecting a full index at startup, it scales without limit as your memory grows. The skill is model-invocable, so Claude self-triggers it when you reference past work in another project or ask what it remembers about a topic.

### Write — `/memorize` skill

Claude Code's auto-memory writes are prompt-driven: the model decides during a turn whether content is worth saving, and sometimes does not notice. The `/memorize` skill is the explicit lever — it audits the current session against four memory categories (`user`, `feedback`, `project`, `reference`) and persists entries directly.

Default behaviour writes directly. Pass `dry` to preview first and confirm before writing:

```text
/memorize                          → audit and write directly
/memorize <focus hint>             → write, prioritise content matching the hint
/memorize dry                      → list proposed entries, wait for "ok"
/memorize dry <focus hint>         → preview with focused audit
```

The skill is also model-invocable, so Claude can self-trigger it when memory-worthy moments are detected (corrections, validated choices, new domain context, project state changes).

Both skills complement (not replace) the built-in auto-memory. See [SPEC.md](SPEC.md) for the full design rationale, why the earlier SessionStart hook was retired, alternatives considered (mem-palace, Obsidian, OpenClaw, muse-crystal-seed, Letta, Mem0, Zep), and the relationship to Anthropic's official Memory Tool (released 2025-09-29 for the API).

## Architecture

```
/recall skill    -->  grep ~/.claude/projects/*/memory/ for the topic
                      read matching entries; answer with project citations

/memorize skill  -->  audit current session against four memory
                      categories; write entries + update MEMORY.md
```

Files installed:

```
~/.claude/skills/recall/      /recall skill     (symlink → repo)
~/.claude/skills/memorize/    /memorize skill   (symlink → repo)
~/.claude/system/memory       symlink → repo    (operational pointer)
```

No hook is installed and `settings.json` is not modified. (If you installed an
older hook-based version, `setup.sh` removes the legacy hook and its
`settings.json` entry automatically — see *Quick Start*.)

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/howar31/claude-memory /opt/projects/claude-memory
```

(The path is up to you. The installer reads `$BASH_SOURCE` and works from anywhere.)

### 2. Install

```bash
cd /opt/projects/claude-memory && ./setup.sh
```

The installer is idempotent and safe to re-run. It will:

- Remove any legacy `SessionStart` hook artifacts from an earlier install (symlink + `settings.json` entry, backed up first)
- Symlink the `recall` and `memorize` skill directories into `~/.claude/skills/` (backing up any existing real directory)
- Create `~/.claude/system/memory` → repo
- Run a verification phase that confirms the skill symlinks, their `SKILL.md` frontmatter, and that no legacy hook remains

If anything is unsafe to do automatically (an existing real directory at a skill path), the installer stops with a clear remediation message and a backup already in place.

### 3. Verify

```bash
./setup.sh           # re-run anytime — it will report all-green or pinpoint what's wrong
./setup.sh --dry-run # preview without applying
./setup.sh --force   # replace mismatched directories at ~/.claude/skills/
```

### 4. Use it

Skills are picked up dynamically — run `/reload-plugins` in an active session if `/recall` and `/memorize` do not appear immediately. No restart is required (there is no hook to load).

## Install as a plugin (alternative)

If you prefer Claude Code's plugin manager over the symlink installer, the same skills are also published as the `mem` plugin. Plugin-managed skills are **namespaced**, so they appear as `/mem:recall` and `/mem:memorize` (the `setup.sh` method above keeps the shorter `/recall` and `/memorize` — see the trade-off below).

Two registration paths install the same plugin — pick one:

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
| Slash names | `/recall`, `/memorize` (shortest) | `/mem:recall`, `/mem:memorize` |
| Install / update | clone + re-run `setup.sh` | `claude plugin install` / `update` |
| Discoverable | no | yes (via marketplace) |
| Non-Claude harnesses | works (plain skill dirs) | depends on the harness's plugin support |

Install one method or the other, not both — they would expose the same skills under two names.

## What you'll see

When you reference past work in another project ("did we solve X in the other repo?", "find my preference for Y"), Claude invokes `/recall`, greps every cwd's memory, and answers from the matching entries — naming the source project. You can also call `/recall <topic>` explicitly.

Whenever you (or Claude) want to capture session content for the future, run `/memorize` (or `/memorize dry` to review the proposal first). Entries are written under the current cwd's `~/.claude/projects/<encoded-cwd>/memory/`, where the current session's auto-load and future `/recall` searches both pick them up.

## Backup story

The repo lives at `/opt/projects/claude-memory` and is symlinked into `~/.claude/system/memory`. The skill directories in `~/.claude/skills/` are themselves symlinks back into the repo, so the repo is the single source of truth and is naturally captured by any backup that includes `/opt/projects/`.

If you also use [`claude-backup`](https://github.com/howar31/claude-backup) for the `~/.claude/` tree, both this repo's path and the symlinks are covered.

## Uninstall

```bash
# Remove the skill symlinks (replaced real dirs, if any, are in ~/.claude/skills/.bak/<timestamp>/)
rm ~/.claude/skills/recall
rm ~/.claude/skills/memorize
rm ~/.claude/system/memory
```

If you installed the plugin instead:

```bash
claude plugin uninstall mem@claude-memory   # or mem@howar31
```

There is nothing to undo in `settings.json` — the current version never writes to it.

## Reference

- [SPEC.md](SPEC.md) — full architecture, design decisions, alternatives considered, skill contracts, future extensions
- [CLAUDE.md](CLAUDE.md) — agent index for working in this repo

## License

MIT
