# claude-memory

[![License](https://img.shields.io/github/license/howar31/claude-memory?style=flat-square)](LICENSE)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-D77655?style=flat-square)](https://claude.com/claude-code)
[![Made with Bash](https://img.shields.io/badge/made%20with-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-yellow?style=flat-square)](https://www.conventionalcommits.org)
[![Last Commit](https://img.shields.io/github/last-commit/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/commits/main)
[![Stars](https://img.shields.io/github/stars/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/stargazers)
[![Open Issues](https://img.shields.io/github/issues/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/issues)
[![Sponsor on Ko-fi](https://img.shields.io/badge/sponsor-Ko--fi-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white)](https://ko-fi.com/howar31)

Two complementary enhancements that close reliability gaps in [Claude Code](https://claude.com/claude-code)'s built-in auto-memory: a **read** layer that surfaces memory across project directories, and a **write** layer that audits the conversation on demand. Pure read/write on top of the existing `~/.claude/projects/<encoded-cwd>/memory/` filesystem. No vector database, no MCP server, no external service.

## What you get

### Read — Cross-cwd memory index (SessionStart hook)

Claude Code's auto-memory is namespaced per cwd. A memory written while working in one project directory lives in that cwd's memory folder and is invisible from a sibling or parent cwd, even when the topic is the same.

A `SessionStart` hook scans every `~/.claude/projects/*/memory/MEMORY.md`, resolves each cwd from the most recent transcript, and injects a compact index of all entries from **other** cwds as a `<system-reminder>`. The current cwd's `MEMORY.md` is already auto-loaded, so the hook only fills the cross-cwd gap. Claude reads the source file with the standard `Read` tool when an entry looks relevant.

### Write — `/memorize` skill

Claude Code's auto-memory writes are prompt-driven: the model decides during a turn whether content is worth saving, and sometimes does not notice. The `/memorize` skill is the explicit lever — it audits the current session against four memory categories (`user`, `feedback`, `project`, `reference`) and persists entries directly. Standalone (not plugin-bundled) so the slash name stays short.

Default behaviour writes directly. Pass `dry` to preview first and confirm before writing:

```text
/memorize                          → audit and write directly
/memorize <focus hint>             → write, prioritise content matching the hint
/memorize dry                      → list proposed entries, wait for "ok"
/memorize dry <focus hint>         → preview with focused audit
```

The skill is also model-invocable, so Claude can self-trigger it when memory-worthy moments are detected (corrections, validated choices, new domain context, project state changes).

Both layers complement (not replace) the built-in auto-memory. See [SPEC.md](SPEC.md) for the full design rationale, alternatives considered (mem-palace, Obsidian, OpenClaw, muse-crystal-seed, Letta, Mem0, Zep), and the relationship to Anthropic's official Memory Tool (released 2025-09-29 for the API).

## Architecture

```
SessionStart hook  -->  scan ~/.claude/projects/*/memory/MEMORY.md
                        emit cross-cwd index as system-reminder

/memorize skill    -->  audit current session against four memory
                        categories; write entries + update MEMORY.md
```

Files installed:

```
~/.claude/hooks/memory-aggregate.sh   SessionStart hook (symlink → repo)
~/.claude/skills/memorize/            /memorize skill   (symlink → repo)
~/.claude/settings.json               hook entry wired
~/.claude/system/memory               symlink → repo (operational pointer)
```

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

- Symlink the hook artifact into `~/.claude/hooks/` (backing up any existing real file)
- Patch `~/.claude/settings.json` to add the `SessionStart` entry (skipping if it already matches exactly)
- Symlink the `memorize` skill directory into `~/.claude/skills/`
- Create `~/.claude/system/memory` → repo
- Run a verification phase that smoke-tests the hook, settings entry, and skill

If anything is unsafe to do automatically (an existing file differs, a settings entry exists with a different command), the installer stops with a clear remediation message and a backup already in place.

### 3. Verify

```bash
./setup.sh           # re-run anytime — it will report all-green or pinpoint what's wrong
./setup.sh --dry-run # preview without applying
./setup.sh --force   # replace mismatched files at ~/.claude/hooks/ (settings.json conflicts still stop)
```

### 4. Restart Claude Code

The new `SessionStart` hook fires when a session starts, so the cross-cwd index will only appear in conversations begun after install.

## What you'll see

After install, every Claude Code session begins with an injected `<system-reminder>` block listing every memory entry from every other cwd you have worked in, formatted as a navigable index. Claude reads the source file with the standard `Read` tool when an entry is relevant to the current conversation.

Whenever you (or Claude) want to capture session content for the future, run `/memorize` (or `/memorize dry` to review the proposal first). Entries are written under the current cwd's `~/.claude/projects/<encoded-cwd>/memory/`, where the next session will pick them up automatically.

## Backup story

The repo lives at `/opt/projects/claude-memory` and is symlinked into `~/.claude/system/memory`. The artifacts in `~/.claude/hooks/` are themselves symlinks back into the repo, so the repo is the single source of truth and is naturally captured by any backup that includes `/opt/projects/`.

If you also use [`claude-backup`](https://github.com/howar31/claude-backup) for the `~/.claude/` tree, both this repo's path and the symlinks are covered.

## Uninstall

```bash
# Remove the symlinks (originals, if any, are in ~/.claude/hooks/.bak/<timestamp>/)
rm ~/.claude/hooks/memory-aggregate.sh
rm ~/.claude/skills/memorize
rm ~/.claude/system/memory

# Remove the settings.json entry — restore from the latest backup, or edit by hand:
ls ~/.claude/settings.json.bak.* | tail -1
```

A future `setup.sh --uninstall` flag may automate this; until then the manual path is documented above.

## Reference

- [SPEC.md](SPEC.md) — full architecture, design decisions, alternatives considered, hook contract, future extensions
- [CLAUDE.md](CLAUDE.md) — agent index for working in this repo

## License

MIT
