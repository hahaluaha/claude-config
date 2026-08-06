#!/bin/bash
# Test harness for commit-gate.sh
set -uo pipefail

GATE="$HOME/.claude/hooks/commit-gate.sh"
PASS=0
FAIL=0

assert_exit() { # $1 = expected code, $2 = label, rest = command
  local expected="$1" label="$2"; shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'PASS  %s\n' "$label"; PASS=$((PASS+1))
  else
    printf 'FAIL  %s (expected %s, got %s)\n' "$label" "$expected" "$actual"; FAIL=$((FAIL+1))
  fi
}

# Builds a throwaway repo, echoes its path
make_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.local
  git -C "$d" config user.name Test
  printf 'hello\n' > "$d/file.txt"
  git -C "$d" add file.txt
  git -C "$d" commit -qm init
  printf '%s' "$d"
}

# Feeds a synthetic PreToolUse payload to the gate
run_gate() { # $1 = command string, $2 = cwd
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$GATE"
}

# --- gitleaks availability ---
assert_exit 0 "gitleaks is installed" command -v gitleaks

# --- run_gitleaks ---
source "$GATE"

clean_diff() { printf '+++ b/a.txt\n+just some ordinary text\n'; }
leak_diff()  { printf '+++ b/a.txt\n+slack_token = "xox%s-1234567890-abcdefghijklmnop"\n' b; }

clean_diff | run_gitleaks
assert_exit 0 "run_gitleaks: clean diff returns 0" test $? -eq 0

leak_diff | run_gitleaks
assert_exit 0 "run_gitleaks: AWS key returns 1" test $? -eq 1

# --- fail-closed paths ---

# Test: gitleaks missing from PATH returns 3
PATH="/usr/bin:/bin" bash -c "
  source \"$GATE\"
  command -v gitleaks >/dev/null 2>&1 && exit 1  # fail if gitleaks found
  clean_diff() { printf '+++ b/a.txt\n+just some ordinary text\n'; }
  clean_diff | run_gitleaks
"
assert_exit 0 "run_gitleaks: missing gitleaks returns 3" test $? -eq 3

# Test: gitleaks error (invalid flag) returns 3
# Create a wrapper that forces gitleaks to error
gitleaks_error_diff() { printf '+++ b/a.txt\n+just text\n'; }
gitleaks_error_diff | bash -c "
  source \"$GATE\"
  # Override gitleaks to return a non-0/1 exit code
  gitleaks() { command gitleaks \"\$@\" --invalid-flag; }
  export -f gitleaks
  run_gitleaks
"
assert_exit 0 "run_gitleaks: gitleaks error returns 3" test $? -eq 3

# --- parse_command ---
check_parse() { # $1 = label, $2 = command, $3 = expect match (0/1), $4 = expect ALL
  parse_command "$2"; local rc=$?
  if [ "$rc" -eq "$3" ] && { [ "$rc" -ne 0 ] || [ "$GATE_COMMIT_ALL" -eq "$4" ]; }; then
    printf 'PASS  %s\n' "$1"; PASS=$((PASS+1))
  else
    printf 'FAIL  %s (rc=%s all=%s)\n' "$1" "$rc" "${GATE_COMMIT_ALL:-unset}"; FAIL=$((FAIL+1))
  fi
}

check_parse "plain commit"          'git commit -m "hi"'                 0 0
check_parse "commit with -a"        'git commit -am "hi"'                0 1
check_parse "commit with --all"     'git commit --all -m "hi"'           0 1
check_parse "git -C path commit"    'git -C /tmp/x commit -m "hi"'       0 0
check_parse "chained add + commit"  'git add -A && git commit -m "hi"'   0 0
check_parse "not a commit"          'ls -la'                             1 0
check_parse "git log only"          'git log --oneline -5'               1 0
check_parse "commit inside message" 'git log --grep commit'              1 0
check_parse "message containing -a" 'git commit -m "fix -a flag bug"'    0 0
check_parse "message with chain op and -a" 'git commit -m "wip: fix; cleanup" -a'    0 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
