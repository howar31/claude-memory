## Authority

This file is the source of truth for AI agent behavior in this repo. When rules conflict with the user's global `~/.claude/CLAUDE.md`, the global file wins (per its own authority rule).

## Architecture

Two complementary skills that augment Claude Code's prompt-driven auto-memory. The primary install is standalone (symlinked into `~/.claude/skills/`) so the slash names stay short (`/recall`, `/memorize`); the same skills are also packaged as the `mem` plugin for marketplace distribution (namespaced `/mem:recall`, `/mem:memorize`) — see *Distribution*. Both are model-invocable:

- **Read** — `/recall` skill (`skills/recall/SKILL.md`) greps `~/.claude/projects/*/memory/` on demand and reads the relevant entries. Cross-cwd recall is retrieval-at-query-time, not an index injected at startup — so it scales without limit as memory grows.
- **Write** — `/memorize` skill (`skills/memorize/SKILL.md`) audits the current session against the four memory categories and persists entries.

No hook, no `settings.json` patch. The earlier `SessionStart` index hook was retired because hook output is capped at 10,000 chars (stdout / `additionalContext` / `systemMessage` alike); a growing index silently collapsed to a 2 KB preview + spill file. See [SPEC.md](SPEC.md) for the full design, decision log, and alternatives considered.

## Run / Setup

- Install: `./setup.sh` — idempotent; symlinks skill dirs into `~/.claude/skills/`, links `~/.claude/system/memory` → repo, migrates away any legacy hook, then verifies
- Preview: `./setup.sh --dry-run` (note: verify phase reports against real state, so freshly-planned links show as not-yet-applied under dry-run)
- Force replace mismatched dirs at `~/.claude/skills/`: `./setup.sh --force`
- Verify any time: re-run `./setup.sh`

## Distribution

Three coexisting install paths, all serving the **same** `skills/` tree:

- **`setup.sh` (standalone, primary)** — symlinks `skills/<name>/` into `~/.claude/skills/`. Yields the shortest names (`/recall`, `/memorize`) and deploys plain skill dirs a non-Claude harness can also read. Kept as primary for exactly these two reasons.
- **Self-hosted marketplace** — `.claude-plugin/marketplace.json` (`source: "./"`) makes this repo a single-plugin marketplace: `claude plugin marketplace add howar31/claude-memory` → `install mem@claude-memory`.
- **Central marketplace** — an entry in `howar31/howar31-marketplace` referencing this repo: `install mem@howar31`.

Plugin manifests: `.claude-plugin/plugin.json` (`name: mem` → the namespace; skills auto-discovered from `skills/`, no declaration needed) and `.claude-plugin/marketplace.json`. Plugin-managed skills are always namespaced, so the marketplace paths give `/mem:recall` / `/mem:memorize`. `mem` is only the plugin/skill handle; the project is `claude-memory`. `setup.sh` and the skill bodies are untouched by plugin packaging (it iterates a fixed `SKILL_DIRS` array and ignores `.claude-plugin/`). Modeled on the sibling `magi` plugin's dual-marketplace pattern. Bump `plugin.json` `version` on each plugin release. Full rationale: [SPEC.md](SPEC.md) § 4.2, § 10.2.

## Code Style

- Bash with `set -uo pipefail` (not `-e`; we surface errors via the verify phase, not via abort)
- POSIX-leaning where possible; bash-specific syntax fine where needed
- `eval` used only inside the `run()` wrapper for `--dry-run` support; arguments must come pre-quoted
- Comments in English

## Legacy Hook Migration

`setup.sh` Phase 0 removes artifacts from older hook-based installs: the `~/.claude/hooks/memory-aggregate.sh` symlink and any `SessionStart` entry whose command matches `memory-(aggregate|checkpoint)\.sh`. The `settings.json` edit is removal-only and follows the same discipline as the old patcher: back up to `settings.json.bak.<timestamp>` first, atomic `tmp + mv`, validate JSON after, restore backup on corruption, drop matcher blocks left empty, drop `SessionStart` if left empty. This repo no longer *adds* anything to `settings.json`.

## Skill Contract

Both skills (`skills/<name>/SKILL.md`):
- Frontmatter requires `name` (must match dir name) and `description` (drives both listing and model-invocation decision); the `description` enumerates concrete trigger phrases (zh + en) so auto-invocation fires reliably
- Body is numbered steps, English, terse
- `$ARGUMENTS` parsing documented near the top
- Destructive default actions must offer an opt-in confirmation flag (e.g. `/memorize dry`); `/recall` is read-only

## Doc Set

Three documents per the user's `/commit` skill convention:
- `README.md` — human-readable: project intro, quick start, install / uninstall
- `CLAUDE.md` (this file) — AI agent index, ≤ 200 lines, mostly pointers
- `SPEC.md` — AI-readable architecture, decision log, skill contracts, references

Always update all three together when behavior or interface changes.

## Doc Language

All docs in English. Code comments in English. The user's conversation language may be Traditional Chinese, but commits and docs stay English (LLM tokenizer efficiency, global readability for a public repo).

## Commits

- Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, etc.)
- One commit per logical change
- Never commit automatically — present a summary and wait for explicit user approval
- Never push without approval

## Logs / State

- No persistent logs from this repo's skills (output goes into Claude Code's context, not files)
- `setup.sh` writes backups to `~/.claude/skills/.bak/<timestamp>/` (replaced skill dirs) and `~/.claude/settings.json.bak.<timestamp>` (legacy-hook migration only) — both live outside the repo
- Never delete backups without explicit user approval

## Backwards Compatibility

- The path `~/.claude/system/memory/` may be a symlink pointing here; do not introduce hardcoded `/opt/projects/claude-memory` references in scripts — use `SCRIPT_DIR`-relative paths so the repo is portable to other clone locations
- Skill directories at `~/.claude/skills/<name>/` must be symlinks resolving to the repo; never copy real files there (drift kills the SSOT property)
- `/recall` must not hardcode the repo path or shell out to any helper script — grep over `~/.claude/projects/*/memory/` is the whole engine, keeping the skill self-contained and portable

## Relationship to Anthropic Memory Tool

Anthropic released a Memory Tool (`memory_20250818`) on 2025-09-29 alongside Claude Sonnet 4.5. It operates at the API/SDK layer (per-tool-call memory operations). Claude Code's CLI auto-memory is a separate, older, prompt-based mechanism using `~/.claude/projects/<cwd>/memory/`.

This repo enhances the **prompt-based mechanism** via two skills: `/recall` (read) and `/memorize` (write). When/if Claude Code integrates the official Memory Tool, the layers should coexist: this repo operates at the skill/invocation layer over the existing filesystem, the Memory Tool fires per tool call. See SPEC.md "Future" for migration notes.
