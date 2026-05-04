## Authority

This file is the source of truth for AI agent behavior in this repo. When rules conflict with the user's global `~/.claude/CLAUDE.md`, the global file wins (per its own authority rule).

## Architecture

Two-layer hook system that complements Claude Code's prompt-driven auto-memory:

- **Layer 1** — `SessionStart` hook injects a cross-cwd index of `~/.claude/projects/*/memory/MEMORY.md` files
- **Layer 2** — `PreCompact` + `SessionEnd` hooks inject a four-question audit prompt to force memory checkpoints before context is lost

Full design, decision log, and alternatives considered are in [SPEC.md](SPEC.md).

## Run / Setup

- Install: `./setup.sh` — idempotent; symlinks hook files, patches `~/.claude/settings.json`, links `~/.claude/system/memory` → repo, then verifies
- Preview: `./setup.sh --dry-run`
- Force replace mismatched hook files at `~/.claude/hooks/`: `./setup.sh --force` (does not apply to `settings.json` conflicts — those always halt)
- Verify any time: re-run `./setup.sh`

## Code Style

- Bash with `set -uo pipefail` (not `-e`; we surface errors via the verify phase, not via abort)
- POSIX-leaning where possible; bash-specific syntax fine where needed
- `eval` used only inside the `run()` wrapper for `--dry-run` support; arguments must come pre-quoted
- Comments in English

## settings.json Patch Discipline

- Never overwrite the whole file — only add/modify hook entries via `jq`
- Always back up to `settings.json.bak.<timestamp>` before any write
- Use atomic write (`tmp + mv`)
- Validate JSON before and after
- Detect existing entries: exact-command match → skip; different command in `memory-*` namespace → halt with diff and remediation hint
- `--force` does **not** override `settings.json` conflicts; user must edit manually

## Hook Contract

Each hook script:
- Reads stdin (the hook event JSON Claude Code passes); may use `cwd`, `session_id`, etc.
- Writes to stdout. For `SessionStart`, `PreCompact`, `SessionEnd`, stdout is injected as additional context for the model
- Exits 0 on any error (`trap 'exit 0' ERR`) so a hook failure never blocks Claude Code startup or compaction
- Wraps emitted prompt content in `<system-reminder>...</system-reminder>` to signal system context

## Doc Set

Three documents per the user's `/commit` skill convention:
- `README.md` — human-readable: project intro, quick start, install / uninstall
- `CLAUDE.md` (this file) — AI agent index, ≤ 200 lines, mostly pointers
- `SPEC.md` — AI-readable architecture, decision log, hook contract, references

Always update all three together when behavior or interface changes.

## Doc Language

All docs in English. Code comments in English. The user's conversation language may be Traditional Chinese, but commits and docs stay English (LLM tokenizer efficiency, global readability for a public repo).

## Commits

- Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, etc.)
- One commit per logical change
- Never commit automatically — present a summary and wait for explicit user approval
- Never push without approval

## Logs / State

- No persistent logs from this repo's hooks (output goes into Claude Code's context, not files)
- `setup.sh` writes backups to `~/.claude/hooks/.bak/<timestamp>/` and `~/.claude/settings.json.bak.<timestamp>` — gitignored when run inside a working tree, but those paths live outside the repo anyway
- Never delete backups without explicit user approval

## Backwards Compatibility

- The path `~/.claude/system/memory/` may be a symlink pointing here; do not introduce hardcoded `/opt/projects/claude-memory` references in scripts — use `SCRIPT_DIR`-relative paths so the repo is portable to other clone locations
- The hook command strings in `settings.json` use `~/.claude/hooks/memory-*.sh` (which resolve through the symlinks); do not bake repo-absolute paths into `settings.json`

## Relationship to Anthropic Memory Tool

Anthropic released a Memory Tool (`memory_20250818`) on 2025-09-29 alongside Claude Sonnet 4.5. It operates at the API/SDK layer (per-tool-call memory operations). Claude Code's CLI auto-memory is a separate, older, prompt-based mechanism using `~/.claude/projects/<cwd>/memory/`.

This repo enhances the **prompt-based mechanism** via lifecycle hooks. When/if Claude Code integrates the official Memory Tool, the two should coexist: hooks fire at lifecycle boundaries, the Memory Tool fires per tool call. They are orthogonal. See SPEC.md "Future" for migration notes.
