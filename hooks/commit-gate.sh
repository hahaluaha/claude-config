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
