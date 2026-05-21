#!/usr/bin/env bash
# claude-memory setup — idempotent installer for the memory skills.
#
# Symlinks repo skill directories into ~/.claude/skills/ and creates
# ~/.claude/system/memory. Cross-cwd recall and memory writes are both skills
# (/recall, /memorize) — there is no hook and no settings.json patch.
#
# Also migrates away from the legacy SessionStart hook (memory-aggregate.sh):
# removes its symlink and its settings.json entry if a previous install left
# them behind. The cross-cwd index is now the on-demand /recall skill.
#
# Safe to re-run. Backs up before any destructive action. Verifies after install.
#
# Flags:
#   --dry-run   Show what would happen, don't apply
#   --force     Replace existing real directories at ~/.claude/skills/<skill>/
#   -h, --help  Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIRS=("memorize" "recall")
CLAUDE_HOOKS_DIR="$HOME/.claude/hooks"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
SETTINGS="$HOME/.claude/settings.json"
SYSTEM_LINK="$HOME/.claude/system/memory"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Legacy artifacts to clean up from older (hook-based) installs.
LEGACY_HOOK="memory-aggregate.sh"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'; C_DIM=$'\033[0;90m'; C_RST=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_DIM=""; C_RST=""
fi

ok()    { printf '  %sok%s   %s\n'   "$C_OK"   "$C_RST" "$*"; }
warn()  { printf '  %swarn%s %s\n'   "$C_WARN" "$C_RST" "$*"; }
err()   { printf '  %serr%s  %s\n'   "$C_ERR"  "$C_RST" "$*" >&2; }
note()  { printf '  %s··%s   %s\n'   "$C_DIM"  "$C_RST" "$*"; }
header(){ printf '\n=== %s ===\n' "$*"; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would: %s\n' "$C_DIM" "$C_RST" "$*"
  else
    eval "$@"
  fi
}

# --- Tool dependency check ---
header "Tool dependencies"
missing=0
for cmd in grep jq bash; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; else err "$cmd missing"; missing=1; fi
done
[ "$missing" -eq 1 ] && { err "Install missing dependencies and re-run"; exit 1; }
note "grep powers /recall search; jq resolves cwd labels and migrates legacy settings"

# --- Phase 0: migrate away from the legacy SessionStart hook ---
header "Phase 0 — migrate legacy hook"

legacy_path="$CLAUDE_HOOKS_DIR/$LEGACY_HOOK"
if [ -L "$legacy_path" ] || [ -e "$legacy_path" ]; then
  run "rm -f '$legacy_path'"
  ok "removed legacy hook: $legacy_path"
else
  note "no legacy hook symlink"
fi

if [ -f "$SETTINGS" ] && jq . "$SETTINGS" >/dev/null 2>&1; then
  legacy_in_settings=$(jq '[(.hooks.SessionStart // [])[].hooks[]? | select((.command // "") | test("memory-(aggregate|checkpoint)\\.sh"))] | length' "$SETTINGS")
  if [ "$legacy_in_settings" -gt 0 ]; then
    settings_backup="$SETTINGS.bak.$TIMESTAMP"
    run "cp '$SETTINGS' '$settings_backup'"
    note "Backup: $settings_backup"
    if [ "$DRY_RUN" -eq 1 ]; then
      note "[dry-run] would strip $legacy_in_settings legacy memory-* SessionStart hook entr(y/ies)"
    else
      tmp="$SETTINGS.tmp.$$"
      # Drop matching commands; drop matcher blocks left with no hooks; drop SessionStart if left empty.
      jq '
        if (.hooks.SessionStart // null) == null then .
        else
          .hooks.SessionStart |= ( map(
              .hooks |= map(select((.command // "") | test("memory-(aggregate|checkpoint)\\.sh") | not))
            ) | map(select((.hooks | length) > 0)) )
          | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
        end
      ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
      if jq . "$SETTINGS" >/dev/null 2>&1; then
        ok "stripped legacy SessionStart hook from settings.json"
      else
        err "settings.json corrupted after migration — restoring backup"
        cp "$settings_backup" "$SETTINGS"
        exit 1
      fi
    fi
  else
    note "no legacy hook in settings.json"
  fi
else
  note "settings.json absent or unreadable — skipping settings migration"
fi

# --- Phase 1: system link ---
header "Phase 1 — system link"
mkdir -p "$HOME/.claude/system"
if [ -L "$SYSTEM_LINK" ]; then
  if [ "$(readlink "$SYSTEM_LINK")" = "$SCRIPT_DIR" ]; then
    ok "$SYSTEM_LINK already correct"
  elif [ "$FORCE" -eq 1 ]; then
    run "rm '$SYSTEM_LINK' && ln -s '$SCRIPT_DIR' '$SYSTEM_LINK'"
    ok "$SYSTEM_LINK relinked"
  else
    err "$SYSTEM_LINK points elsewhere: $(readlink "$SYSTEM_LINK")"
    err "  use --force to relink"
  fi
elif [ -e "$SYSTEM_LINK" ]; then
  err "$SYSTEM_LINK exists as real path; refusing to clobber"
else
  run "ln -s '$SCRIPT_DIR' '$SYSTEM_LINK'"
  ok "$SYSTEM_LINK linked → $SCRIPT_DIR"
fi

# --- Phase 2: install skill directories (symlinks) ---
header "Phase 2 — install skill directories"
mkdir -p "$CLAUDE_SKILLS_DIR"
backup_dir="$CLAUDE_SKILLS_DIR/.bak/$TIMESTAMP"

for d in "${SKILL_DIRS[@]}"; do
  src="$SCRIPT_DIR/skills/$d"
  dst="$CLAUDE_SKILLS_DIR/$d"

  [ -d "$src" ] || { err "Source missing: $src"; exit 1; }
  [ -f "$src/SKILL.md" ] || { err "Source missing SKILL.md: $src/SKILL.md"; exit 1; }

  if [ -L "$dst" ]; then
    actual="$(readlink "$dst")"
    if [ "$actual" = "$src" ]; then
      ok "$d skill symlink already correct"
    elif [ "$FORCE" -eq 1 ]; then
      run "rm '$dst' && ln -s '$src' '$dst'"
      ok "$d skill relinked (was: $actual)"
    else
      err "$d skill symlink points elsewhere: $actual"
      err "  use --force to relink"
      exit 1
    fi
  elif [ -e "$dst" ]; then
    if [ "$FORCE" -eq 1 ]; then
      run "mkdir -p '$backup_dir' && mv '$dst' '$backup_dir/skill-$d' && ln -s '$src' '$dst'"
      ok "$d skill real dir replaced (backup: $backup_dir/skill-$d)"
    else
      err "$d skill real directory exists at $dst"
      err "  use --force to backup-and-replace"
      exit 1
    fi
  else
    run "ln -s '$src' '$dst'"
    ok "$d skill symlinked (fresh)"
  fi
done

# --- Phase 3: verify ---
header "Phase 3 — verify"
fail=0

verify_skill() {
  local d="$1"
  local path="$CLAUDE_SKILLS_DIR/$d"
  if [ ! -L "$path" ]; then err "skill $d: $path not a symlink"; fail=1; return; fi
  local target; target="$(readlink "$path")"
  if [ "$target" != "$SCRIPT_DIR/skills/$d" ]; then
    err "skill $d: symlink → $target (expected repo)"; fail=1; return
  fi
  ok "skill $d symlink → repo"

  local skill_md="$path/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    err "skill $d: SKILL.md missing at $skill_md"; fail=1; return
  fi
  if ! grep -q "^name: *$d *$" "$skill_md"; then
    err "skill $d: SKILL.md frontmatter must include 'name: $d'"; fail=1; return
  fi
  ok "skill $d SKILL.md frontmatter ok"
}

for d in "${SKILL_DIRS[@]}"; do
  verify_skill "$d"
done

# Confirm the legacy hook is fully gone.
if [ -L "$CLAUDE_HOOKS_DIR/$LEGACY_HOOK" ] || [ -e "$CLAUDE_HOOKS_DIR/$LEGACY_HOOK" ]; then
  err "legacy hook still present at $CLAUDE_HOOKS_DIR/$LEGACY_HOOK"; fail=1
else
  ok "no legacy hook artifact"
fi
if [ -f "$SETTINGS" ] && jq . "$SETTINGS" >/dev/null 2>&1; then
  leftover=$(jq '[(.hooks.SessionStart // [])[].hooks[]? | select((.command // "") | test("memory-(aggregate|checkpoint)\\.sh"))] | length' "$SETTINGS")
  if [ "$leftover" -gt 0 ]; then err "legacy hook still wired in settings.json"; fail=1; else ok "settings.json clean of legacy hook"; fi
fi

# --- Summary ---
header "Summary"
if [ "$fail" -eq 0 ]; then
  printf '  %sAll checks passed.%s Memory skills installed.\n\n' "$C_OK" "$C_RST"
  printf '  /recall   — search memory across all project cwds (read)\n'
  printf '  /memorize — audit this session and persist entries (write)\n\n'
  printf '  Skills are picked up dynamically; run /reload-plugins in an active session if needed.\n'
  exit 0
else
  printf '  %sVerification failed.%s See errors above.\n' "$C_ERR" "$C_RST"
  exit 1
fi
