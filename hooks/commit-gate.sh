#!/bin/bash
# commit-gate.sh — PreToolUse gate.
# No `git commit` proceeds without (a) a clean gitleaks scan and
# (b) a review token matching the exact diff being committed.
set -uo pipefail

LOG_FILE="$HOME/.claude/logs/commit-gate.log"

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
