# claude-memory

[![License](https://img.shields.io/github/license/howar31/claude-memory?style=flat-square)](LICENSE)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-D77655?style=flat-square)](https://claude.com/claude-code)
[![Made with Bash](https://img.shields.io/badge/made%20with-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-yellow?style=flat-square)](https://www.conventionalcommits.org)
[![Last Commit](https://img.shields.io/github/last-commit/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/commits/main)

Hook-based enhancements that close two reliability gaps in [Claude Code](https://claude.com/claude-code)'s built-in auto-memory. The repo ships three hooks, an idempotent installer, and full architecture notes — pure read/write on top of the existing `~/.claude/projects/<encoded-cwd>/memory/` filesystem. No vector database, no MCP server, no external service.

## Two layers

### Layer 1 — Cross-cwd memory index

Claude Code's auto-memory is namespaced per cwd. A memory written while working in one project directory lives in that cwd's memory folder and is invisible from a sibling or parent cwd, even when the topic is the same. Layer 1 fixes this.

A `SessionStart` hook scans every `~/.claude/projects/*/memory/MEMORY.md`, resolves each cwd from the most recent transcript, and injects a compact index of all entries from **other** cwds as a `<system-reminder>`. The current cwd's `MEMORY.md` is already auto-loaded, so Layer 1 only fills the cross-cwd gap. Claude reads the source file with the standard `Read` tool when an entry looks relevant.

### Layer 2 — Audit checkpoint

Claude Code's auto-memory writes are prompt-driven — the model decides during a turn whether content is worth saving. Sometimes the model does not notice. Sessions can end with notable work unsaved. Layer 2 fixes this.

A `PreCompact` hook (and a `SessionEnd` second-line safety net) injects a four-category audit prompt before context is lost, requiring Claude to answer YES or NO explicitly per category (`user`, `feedback`, `project`, `reference`) and save a memory entry whenever the answer is YES. Silent skipping is forbidden by the prompt.

Both layers complement (not replace) the built-in auto-memory. See [SPEC.md](SPEC.md) for the full design rationale, alternatives considered (mem-palace, Obsidian, OpenClaw, muse-crystal-seed, Letta, Mem0, Zep), and the relationship to Anthropic's official Memory Tool (released 2025-09-29 for the API).

## Architecture

```
SessionStart hook  -->  scan ~/.claude/projects/*/memory/MEMORY.md
                        emit cross-cwd index as system-reminder

PreCompact hook    -->  inject 4-question audit prompt
SessionEnd hook    -->  (same prompt; second-line safety net)
```

Files installed:

```
~/.claude/hooks/
  memory-aggregate.sh           Layer 1, SessionStart
  memory-checkpoint.sh          Layer 2, PreCompact + SessionEnd
  memory-checkpoint-prompt.txt  Layer 2 prompt content
~/.claude/settings.json         hook entries wired
~/.claude/system/memory         symlink → repo (operational pointer)
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

- Symlink the three hook artifacts into `~/.claude/hooks/` (backing up any existing real files)
- Patch `~/.claude/settings.json` to add the `SessionStart`, `PreCompact`, and `SessionEnd` entries (skipping any that already match exactly)
- Create `~/.claude/system/memory` → repo
- Run a verification phase that smoke-tests every hook and every settings entry

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

Before context compaction or session end, Claude is prompted with a four-category audit (`user`, `feedback`, `project`, `reference`) and required to answer each explicitly — making silent skips less likely.

## Backup story

The repo lives at `/opt/projects/claude-memory` and is symlinked into `~/.claude/system/memory`. The artifacts in `~/.claude/hooks/` are themselves symlinks back into the repo, so the repo is the single source of truth and is naturally captured by any backup that includes `/opt/projects/`.

If you also use [`claude-backup`](https://github.com/howar31/claude-backup) for the `~/.claude/` tree, both this repo's path and the symlinks are covered.

## Uninstall

```bash
# Remove symlinks (originals are in ~/.claude/hooks/.bak/<timestamp>/)
rm ~/.claude/hooks/memory-aggregate.sh
rm ~/.claude/hooks/memory-checkpoint.sh
rm ~/.claude/hooks/memory-checkpoint-prompt.txt
rm ~/.claude/system/memory

# Remove settings.json entries — restore from the latest backup, or edit by hand:
ls ~/.claude/settings.json.bak.* | tail -1
```

A future `setup.sh --uninstall` flag may automate this; until then the manual path is documented above.

## Reference

- [SPEC.md](SPEC.md) — full architecture, design decisions, alternatives considered, hook contract, future extensions
- [CLAUDE.md](CLAUDE.md) — agent index for working in this repo

## License

MIT
