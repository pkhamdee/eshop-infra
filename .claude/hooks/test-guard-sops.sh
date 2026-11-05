#!/usr/bin/env bash
# Tests .claude/hooks/guard-sops.sh: feeds it PreToolUse JSON and checks it blocks (exit 2) or allows (exit 0).
set -uo pipefail
hook="$(dirname "$0")/guard-sops.sh"
f=deploy/infrastructure/runners/eshop-e2e-github.sops.yaml
failures=0

run() { # run <expected exit> <description> <tool> <input field> <value>
  local want=$1 what=$2 tool=$3 field=$4 value=$5 got=0
  jq -n --arg t "$tool" --arg f "$field" --arg v "$value" '{tool_name: $t, tool_input: {($f): $v}}' \
    | "$hook" 2>/dev/null || got=$?
  if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what (exit $got, want $want)"; failures=$((failures + 1)); fi
}

run 2 "blocks Write of a SOPS file" Write file_path "/repo/$f"
run 2 "blocks Edit of a SOPS file" Edit file_path "/repo/$f"
run 2 "blocks a heredoc into a SOPS file" Bash command "cat >$f <<'EOF'
stringData: {}
EOF"
run 2 "blocks sops --encrypt" Bash command "sops --encrypt --in-place $f"
run 2 "blocks sops -d (decrypting credentials)" Bash command "SOPS_AGE_KEY_FILE=k sops -d $f | awk '{print}'"
run 2 "blocks sed -i on a SOPS file" Bash command "sed -i '' 's/a/b/' $f"
run 2 "blocks rm of a SOPS file" Bash command "rm $f"
run 2 "blocks cp onto a SOPS file" Bash command "cp /tmp/x $f"
run 0 "allows Write of another file" Write file_path /repo/deploy/infrastructure/runners/kustomization.yaml
run 0 "allows reading the ciphertext" Bash command "grep -n github_token $f"
run 0 "allows git diff of a SOPS file" Bash command "git diff -- $f"
run 0 "allows ls of the folder" Bash command "ls deploy/infrastructure/runners/"
run 0 "allows a command not naming a SOPS file" Bash command "echo hi > /tmp/out"
run 2 "blocks sops after other commands" Bash command "cd /repo && sops --encrypt --in-place $f"
run 2 "blocks a tee into a SOPS file" Bash command "echo x | tee $f"
run 0 "allows a commit message that mentions SOPS files and sops" Bash command "git commit -q -m \"Guard SOPS files

- a hook that blocks writing, running sops on, or deleting *.sops.yaml
  (e.g. sops --encrypt $f); reading stays allowed\" 2>/dev/null"
run 0 "allows a PR body that mentions a SOPS file" Bash command "gh pr create --body \"rm, cp or sops on *.sops.yaml is blocked\""

[ "$failures" = 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
