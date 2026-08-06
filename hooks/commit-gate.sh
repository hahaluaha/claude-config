#!/bin/bash
# commit-gate.sh — PreToolUse gate.
# No `git commit` proceeds without (a) a clean gitleaks scan and
# (b) a review token matching the exact diff being committed.
set -uo pipefail

LOG_FILE="${GATE_LOG_FILE:-$HOME/.claude/logs/commit-gate.log}"

# Reads a unified diff on stdin. 0 = clean, 1 = leaks found, 3 = unavailable/errored.
run_gitleaks() {
  command -v gitleaks >/dev/null 2>&1 || return 3

  local tmp; tmp="$(mktemp -d)" || return 3
  # Scan added lines only: removed lines are already in history, and context
  # lines would re-flag secrets on every unrelated commit that touches the file.
  grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//' > "$tmp/added-content.txt"

  if [ ! -s "$tmp/added-content.txt" ]; then
    rm -rf "$tmp"; return 0
  fi

  local rc
  if gitleaks dir --help >/dev/null 2>&1; then
    gitleaks dir "$tmp" --no-banner --redact >/dev/null 2>&1; rc=$?
  else
    gitleaks detect --no-git --source "$tmp" --no-banner --redact >/dev/null 2>&1; rc=$?
  fi
  rm -rf "$tmp"

  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 3 ;;
  esac
}

# Replaces spaces, semicolons, and pipe/ampersand chars inside quoted spans
# with \x01 so that `set --` treats a quoted argument as a single token,
# and the chain-operator split doesn't cut mid-quote.
mask_quoted_chars() {
  awk '
  {
    out = ""; inq = 0; qc = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (inq) {
        if (c == qc) inq = 0
        else if (c == " " || c == ";" || c == "&" || c == "|") c = "\001"
      } else if (c == "\"" || c == "'"'"'") { inq = 1; qc = c }
      out = out c
    }
    print out
  }'
}

# Sets GATE_COMMIT_ALL. Returns 0 if the command invokes `git commit`.
parse_command() {
  local cmd="$1"
  GATE_COMMIT_ALL=0

  local seg
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    set -f                      # no globbing when we word-split
    # shellcheck disable=SC2086
    set -- $seg
    set +f

    local saw_git=0 sub="" tok
    local seg_all=0
    while [ $# -gt 0 ]; do
      tok="$1"; shift

      if [ "$saw_git" -eq 0 ]; then
        case "$tok" in
          git|*/git) saw_git=1 ;;
        esac
        continue
      fi

      if [ -z "$sub" ]; then
        # git's own options, before the subcommand
        case "$tok" in
          -C|-c|--git-dir|--work-tree|--namespace|--exec-path) shift || true ;;
          -*) ;;
          *) sub="$tok" ;;
        esac
        continue
      fi

      # after the subcommand: find -a/--all, skipping options that take a value
      case "$tok" in
        -m|--message|-F|--file|--author|--date|-C|--reuse-message|\
        -c|--reedit-message|-S|--gpg-sign|-t|--template|--fixup|--squash)
          shift || true ;;
        --all) seg_all=1 ;;
        --*) ;;
        -*a*) seg_all=1 ;;
      esac
    done

    if [ "$sub" = "commit" ]; then
      GATE_COMMIT_ALL="$seg_all"
      return 0
    fi
  done < <(printf '%s\n' "$cmd" | mask_quoted_chars | sed -E 's/(\|\||&&|;|\|)/\n/g')

  return 1
}

hash_stdin() { shasum -a 256 | cut -d' ' -f1; }

staged_diff() { git diff --cached; }
# `git commit -a` also sweeps unstaged changes to tracked files.
all_diff() { git diff --cached; git diff; }

target_diff() {
  if [ "${GATE_COMMIT_ALL:-0}" -eq 1 ]; then all_diff; else staged_diff; fi
}

token_path() { printf '%s/claude-review-ok' "$(git rev-parse --absolute-git-dir)"; }

# Both hashes are written because --approve runs before the commit and cannot
# know whether that commit will use -a.
write_token() {
  local p; p="$(token_path)" || return 1
  {
    printf 'staged=%s\n' "$(staged_diff | hash_stdin)"
    printf 'all=%s\n'    "$(all_diff | hash_stdin)"
  } > "$p"
}

read_token_field() { # $1 = staged | all
  local p; p="$(token_path)" || return 1
  [ -f "$p" ] || return 1
  sed -n "s/^$1=//p" "$p"
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s  %s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(pwd)" "$1" >> "$LOG_FILE"
}

block() { printf '%s\n' "$1" >&2; exit 2; }

main() {
  if [ "${1:-}" = "--approve" ]; then
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 1; }
    write_token
    echo "Review token written for the current diff."
    exit 0
  fi

  local input cmd cwd
  input="$(cat)"
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"

  [ -n "$cmd" ] || exit 0
  parse_command "$cmd" || exit 0

  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null
  git rev-parse --git-dir >/dev/null 2>&1 || exit 0

  local diff; diff="$(target_diff)"
  [ -n "$diff" ] || exit 0   # nothing to commit; let git report it

  # --- gate 1: secrets. No override, fails closed. ---
  printf '%s\n' "$diff" | run_gitleaks
  case $? in
    1) log_line "BLOCKED-SECRET  $cmd"
       block "BLOCKED: gitleaks found a secret in this diff.
Run 'gitleaks dir <path> --redact' to see it. Remove the secret and re-stage.
This gate cannot be bypassed." ;;
    3) log_line "BLOCKED-NOGITLEAKS  $cmd"
       block "BLOCKED: gitleaks is unavailable, so the secret scan could not run.
Install it with 'brew install gitleaks'. The gate fails closed by design." ;;
  esac

  # --- gate 2: review token. Bypassable. ---
  if printf '%s' "$cmd" | grep -q 'CLAUDE_COMMIT_GATE=off'; then
    log_line "BYPASS  $cmd"
    exit 0
  fi

  local field expected actual
  if [ "${GATE_COMMIT_ALL:-0}" -eq 1 ]; then field="all"; else field="staged"; fi
  expected="$(read_token_field "$field" 2>/dev/null)"
  actual="$(printf '%s\n' "$diff" | hash_stdin)"

  if [ -z "$expected" ]; then
    block "BLOCKED: this diff has not been reviewed.
Review the staged changes, then run:
  bash ~/.claude/hooks/commit-gate.sh --approve
Do not approve if the review found correctness, security, or data-loss issues."
  fi

  if [ "$expected" != "$actual" ]; then
    block "BLOCKED: the review token is stale — the diff changed since it was approved.
Re-review the current diff, then run:
  bash ~/.claude/hooks/commit-gate.sh --approve"
  fi

  exit 0
}

# Only run when executed, not when sourced by the test harness.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
